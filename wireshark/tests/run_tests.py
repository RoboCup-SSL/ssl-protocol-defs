#!/usr/bin/env python3
"""Regression tests for ssl-dissector.lua.

Generates protobuf Python bindings fresh from proto/ (so these tests can
never silently drift from schema changes), builds synthetic pcaps with
scapy, runs tshark against them, and asserts the expected message types and
field values actually appear in the decoded output -- not just "no error".

Requires protoc, tshark, and a Python environment with scapy + protobuf on
PYTHONPATH (see wireshark/pyproject.toml -- `nix develop` or the
`wireshark-dissector-test` flake check both provide this).
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROTO_ROOT = REPO_ROOT / "proto"
DISSECTOR = REPO_ROOT / "wireshark" / "ssl-dissector.lua"
PROTO_PACKAGE = "sslproto"

sys.path.insert(0, str(REPO_ROOT / "python"))
from python_bindings import generate_python_bindings  # noqa: E402

PROTO_FILES = [
    "gamecontroller/ssl_gc_common.proto",
    "gamecontroller/ssl_gc_geometry.proto",
    "gamecontroller/ssl_gc_game_event.proto",
    "gamecontroller/ssl_gc_referee_message.proto",
    "gamecontroller/ssl_gc_rcon.proto",
    "gamecontroller/ssl_gc_rcon_team.proto",
    "vision/ssl_vision_detection.proto",
    "vision/ssl_vision_geometry.proto",
    "vision/ssl_vision_wrapper.proto",
    "simulation/ssl_simulation_control.proto",
    "simulation/ssl_simulation_config.proto",
    "simulation/ssl_simulation_error.proto",
]


def find_protoc_include_dir(protoc_path: str) -> str:
    import os
    env_dir = os.environ.get("PROTOBUF_INCLUDE_DIR")
    if env_dir:
        return env_dir
    # protoc lives at <prefix>/bin/protoc; well-known types ship at <prefix>/include
    guess = Path(protoc_path).resolve().parent.parent / "include"
    if (guess / "google" / "protobuf" / "any.proto").exists():
        return str(guess)
    raise RuntimeError(
        "Could not locate google/protobuf/any.proto -- set PROTOBUF_INCLUDE_DIR"
    )


def generate_bindings(workdir: Path) -> Path:
    """Generate bindings with the same helper consuming projects use.

    Nesting everything under one package keeps proto/vision/ and friends from
    becoming top-level module names here. See python/python_bindings.py.
    """
    gen_dir = workdir / "gen"
    try:
        generate_python_bindings(
            out_dir=gen_dir,
            package=PROTO_PACKAGE,
            proto_root=PROTO_ROOT,
            explicit=PROTO_FILES,
            pyi=False,
        )
    except RuntimeError as exc:
        sys.exit(str(exc))
    return gen_dir


def build_pcaps(gen_dir: Path, workdir: Path) -> dict:
    sys.path.insert(0, str(gen_dir))
    from scapy.all import Ether, IP, UDP, TCP, Raw, wrpcap

    from sslproto.vision.ssl_vision_wrapper_pb2 import SSL_WrapperPacket
    from sslproto.gamecontroller.ssl_gc_referee_message_pb2 import Referee, GROUP_PHASE
    from sslproto.gamecontroller.ssl_gc_common_pb2 import Team
    from sslproto.gamecontroller.ssl_gc_rcon_team_pb2 import TeamToController
    from sslproto.simulation.ssl_simulation_control_pb2 import (
        SimulatorCommand,
        SimulatorResponse,
    )

    def varint(n):
        out = bytearray()
        while True:
            b = n & 0x7F
            n >>= 7
            if n:
                out.append(b | 0x80)
            else:
                out.append(b)
                return bytes(out)

    pcaps = {}

    # SSL_WrapperPacket with BOTH detection and geometry set -- the one-level-down case.
    wrapper = SSL_WrapperPacket()
    wrapper.detection.frame_number = 42
    wrapper.detection.t_capture = 123.456
    wrapper.detection.t_sent = 123.457
    wrapper.detection.camera_id = 0
    wrapper.geometry.field.field_length = 9000
    wrapper.geometry.field.field_width = 6000
    wrapper.geometry.field.goal_width = 1000
    wrapper.geometry.field.goal_depth = 180
    wrapper.geometry.field.boundary_width = 300
    p = (
        Ether() / IP(src="192.168.1.50", dst="224.5.23.2")
        / UDP(sport=40000, dport=10006) / Raw(load=wrapper.SerializeToString())
    )
    pcaps["vision"] = (workdir / "vision.pcap", [p])

    # Referee -- single flat message, no wrapper. match_type and next_command are
    # set here (they are optional in the schema) so the Info-column summary test
    # below can exercise all four of the fields it trims down to.
    ref = Referee()
    ref.packet_timestamp = 1000000
    ref.stage = Referee.NORMAL_FIRST_HALF
    ref.command = Referee.HALT
    ref.command_counter = 7
    ref.command_timestamp = 999999
    ref.match_type = GROUP_PHASE
    ref.next_command = Referee.STOP
    for team, name, keeper in ((ref.yellow, "Yellow Team", 0), (ref.blue, "Blue Team", 1)):
        team.name = name
        team.score = 0
        team.red_cards = 0
        team.yellow_cards = 0
        team.timeouts = 4
        team.timeout_time = 300000000
        team.goalkeeper = keeper
    p = (
        Ether() / IP(src="192.168.1.60", dst="224.5.23.1")
        / UDP(sport=40001, dport=10003) / Raw(load=ref.SerializeToString())
    )
    pcaps["referee"] = (workdir / "referee.pcap", [p])

    # TeamToController over TCP rcon, varint length-prefixed -- exercises our
    # Lua script's desegmentation and direction detection.
    t2c = TeamToController()
    t2c.desired_keeper = 5
    t2c_bytes = t2c.SerializeToString()
    framed = varint(len(t2c_bytes)) + t2c_bytes
    p = (
        Ether() / IP(src="192.168.1.70", dst="192.168.1.1")
        / TCP(sport=55000, dport=10008, flags="PA", seq=1, ack=1) / Raw(load=framed)
    )
    pcaps["rcon_team"] = (workdir / "rcon_team.pcap", [p])

    # SimulatorCommand / SimulatorResponse pair -- exercises direction detection on UDP.
    cmd = SimulatorCommand()
    tr = cmd.control.teleport_robot.add()
    tr.id.id = 3
    tr.id.team = Team.YELLOW
    resp = SimulatorResponse()
    err = resp.errors.add()
    err.code = "TEST_ERR"
    err.message = "test message"
    cmd_pkt = (
        Ether() / IP(src="192.168.1.80", dst="192.168.1.2")
        / UDP(sport=45000, dport=10300) / Raw(load=cmd.SerializeToString())
    )
    resp_pkt = (
        Ether() / IP(src="192.168.1.2", dst="192.168.1.80")
        / UDP(sport=10300, dport=45000) / Raw(load=resp.SerializeToString())
    )
    pcaps["simulation"] = (workdir / "simulation.pcap", [cmd_pkt, resp_pkt])

    for path, packets in pcaps.values():
        wrpcap(str(path), packets)

    return {name: path for name, (path, _) in pcaps.items()}


def run_tshark(pcap: Path, extra_prefs=(), use_lua=False, verbose=True) -> str:
    tshark = shutil.which("tshark")
    if not tshark:
        sys.exit("tshark not found on PATH")
    include_dir = find_protoc_include_dir(shutil.which("protoc"))
    args = [
        tshark,
        "-o", f'uat:protobuf_search_paths:"{PROTO_ROOT}","TRUE"',
        # "FALSE" (load on demand), not "TRUE": matches wireshark/setup.sh --
        # newer protobuf releases' descriptor.proto uses syntax Wireshark's
        # simplified .proto parser cannot read, and eagerly loading everything
        # in this directory crashes on it. "FALSE" still resolves
        # google/protobuf/any.proto (the only well-known type this repo's
        # files import) on demand, without ever touching descriptor.proto.
        "-o", f'uat:protobuf_search_paths:"{include_dir}","FALSE"',
        "-o", "protobuf.preload_protos:TRUE",
    ]
    for pref in extra_prefs:
        args += ["-o", pref]
    if use_lua:
        args += ["-X", f"lua_script:{DISSECTOR}"]
    args += ["-r", str(pcap)]
    if verbose:
        args += ["-V"]
    result = subprocess.run(args, capture_output=True, text=True)
    return result.stdout + result.stderr


def check(name: str, output: str, expected: list, absent: list = ()) -> bool:
    missing = [e for e in expected if e not in output]
    present = [e for e in absent if e in output]
    if missing or present:
        if missing:
            print(f"FAIL: {name} -- missing: {missing}")
        if present:
            print(f"FAIL: {name} -- should be absent but found: {present}")
        return False
    print(f"PASS: {name}")
    return True


def main():
    with tempfile.TemporaryDirectory() as tmp:
        workdir = Path(tmp)
        gen_dir = generate_bindings(workdir)
        pcaps = build_pcaps(gen_dir, workdir)

        results = []

        out = run_tshark(pcaps["vision"], extra_prefs=['uat:protobuf_udp_message_types:"10006","SSL_WrapperPacket"'])
        results.append(check(
            "vision wrapper: one-level-down detection+geometry",
            out,
            ["Message: SSL_WrapperPacket", "Message: SSL_DetectionFrame", "Message: SSL_GeometryData",
             "frame_number = 42", "field_length = 9000"],
        ))

        out = run_tshark(pcaps["referee"], extra_prefs=['uat:protobuf_udp_message_types:"10003","Referee"'])
        results.append(check(
            "referee: flat message, built-in UDP table",
            out,
            ["Message: Referee", "packet_timestamp = 1000000", "NORMAL_FIRST_HALF", "HALT"],
        ))

        # Cosmetic layer: with the Lua script loaded, the vision port also gets a
        # friendlier Protocol column and an Info-column summary. Checked as a plain
        # summary line (no -V), since that's what the Protocol/Info columns actually
        # are.
        out = run_tshark(pcaps["vision"], use_lua=True, verbose=False)
        results.append(check(
            "vision wrapper: cosmetic Protocol/Info column summary (with Lua script loaded)",
            out,
            ["SSL SSL_WrapperPacket - Protobuf", "SSL_WrapperPacket: detection+geometry"],
        ))

        # And without the script at all: the UDP Message Type table alone must still
        # fully decode it -- the cosmetic layer above must never be a requirement.
        out = run_tshark(
            pcaps["vision"],
            extra_prefs=['uat:protobuf_udp_message_types:"10006","SSL_WrapperPacket"'],
            use_lua=False, verbose=False,
        )
        results.append(check(
            "vision wrapper: still fully decodes with no Lua script loaded at all",
            out,
            ["UDP/PB(SSL_WrapperPacket)", "detection", "geometry"],
            absent=["SSL SSL_WrapperPacket - Protobuf"],
        ))

        # Referee-specific Info column trimming: only match_type/stage/command/
        # next_command, as raw enum integers, not the full field dump.
        out = run_tshark(pcaps["referee"], use_lua=True, verbose=False)
        results.append(check(
            "referee: cosmetic Protocol/Info column trimmed to 4 fields (with Lua script loaded)",
            out,
            ["SSL Referee - Protobuf", "match_type=1", "stage=1", "command=0", "next_command=1"],
        ))

        out = run_tshark(pcaps["rcon_team"], use_lua=True)
        results.append(check(
            "rcon team: TCP desegmentation + direction typing",
            out,
            ["Message: TeamToController", "desired_keeper = 5"],
        ))

        out = run_tshark(pcaps["simulation"], use_lua=True)
        results.append(check(
            "simulation: UDP direction typing (command vs response)",
            out,
            ["Message: SimulatorCommand", "Message: SimulatorResponse"],
        ))

        if not all(results):
            sys.exit(1)
        print(f"\nAll {len(results)} dissector tests passed.")


if __name__ == "__main__":
    main()
