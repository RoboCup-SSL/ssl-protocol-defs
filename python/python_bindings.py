#!/usr/bin/env python3
"""Generate namespaced Python bindings from the SSL protocol definitions.

Because every import here is written relative to `proto/`, protoc names the
generated packages after the top-level directories -- `vision`,
`gamecontroller`, `simulation` -- and emits cross-imports like
`from vision import x_pb2`. Those only resolve if the output directory itself
is on `sys.path`, which makes all three top-level module names in the consuming
project. That works, but it is rarely what the project wants, and it means any
directory added here later can collide with something already imported there.

(One such collision used to be fatal rather than merely untidy: this repository
called the game-controller directory `gc`, and Python's `gc` is a *builtin*
module that always wins over `sys.path`, so `import gc.ssl_gc_common_pb2`
failed outright. The directory has since been renamed, but the general hazard
is what this script exists to remove.)

This script generates the same bindings nested inside a single package of the
caller's choosing and rewrites the generated cross-imports to match, so the
result is imported as e.g.

    from sslproto.vision.ssl_vision_wrapper_pb2 import SSL_WrapperPacket
    from sslproto.gamecontroller.ssl_gc_referee_message_pb2 import Referee

Only the generated Python changes. The descriptor pool still sees the
canonical file names (`vision/ssl_vision_wrapper.proto`), so nothing about the
wire format or reflection is affected.

Usage:

    python3 python/python_bindings.py --out-dir gen
    python3 python/python_bindings.py --out-dir src --package sslproto --include vision

Requires `protoc` on PATH.
"""
from __future__ import annotations

import argparse
import re
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PROTO_ROOT = REPO_ROOT / "proto"
DEFAULT_PACKAGE = "sslproto"


def discover_protos(
    proto_root: Path,
    includes: list[str] | None = None,
    explicit: list[str] | None = None,
) -> list[str]:
    """Return proto paths relative to `proto_root`, sorted and deduplicated.

    `explicit` entries are used as given. `includes` are directories relative
    to `proto_root`, each expanded recursively. With neither, every .proto in
    the repository is returned.
    """
    selected: set[str] = set()

    for rel in explicit or []:
        if not (proto_root / rel).is_file():
            raise FileNotFoundError(f"no such proto: {proto_root / rel}")
        selected.add(str(Path(rel).as_posix()))

    for rel in includes or []:
        subdir = proto_root / rel
        if not subdir.is_dir():
            raise FileNotFoundError(f"no such directory: {subdir}")
        for path in subdir.rglob("*.proto"):
            selected.add(str(path.relative_to(proto_root).as_posix()))

    if not selected:
        for path in proto_root.rglob("*.proto"):
            selected.add(str(path.relative_to(proto_root).as_posix()))

    if not selected:
        raise FileNotFoundError(
            f"no .proto files found under {proto_root}. If this repository is a "
            "git submodule, run `git submodule update --init --recursive`."
        )
    return sorted(selected)


def _rewrite_imports(package_dir: Path, package: str, top_levels: set[str]) -> None:
    """Point the generated cross-imports at the nested package.

    protoc emits `from vision import x_pb2` and `from vision.legacy import
    y_pb2`; both become `from <package>.vision...`. Imports of `google.protobuf`
    are left alone -- only the top-level directories of this repository are
    rewritten.
    """
    if not top_levels:
        return
    alternatives = "|".join(re.escape(name) for name in sorted(top_levels))
    from_import = re.compile(rf"^from ({alternatives})(\.[\w.]+)? import ", re.MULTILINE)
    plain_import = re.compile(rf"^import ({alternatives})(\.[\w.]+)", re.MULTILINE)

    for generated in sorted(package_dir.rglob("*_pb2.py*")):
        if generated.suffix not in (".py", ".pyi"):
            continue
        text = generated.read_text()
        patched = from_import.sub(rf"from {package}.\1\2 import ", text)
        patched = plain_import.sub(rf"import {package}.\1\2", patched)
        if patched != text:
            generated.write_text(patched)


def generate_python_bindings(
    out_dir: Path,
    package: str = DEFAULT_PACKAGE,
    proto_root: Path = DEFAULT_PROTO_ROOT,
    includes: list[str] | None = None,
    explicit: list[str] | None = None,
    pyi: bool = True,
) -> Path:
    """Generate bindings into `out_dir/package/` and return that directory.

    Add `out_dir` to `sys.path` (or make it your project root) and import as
    `<package>.<subdir>.<name>_pb2`.
    """
    protoc = shutil.which("protoc")
    if not protoc:
        raise RuntimeError("protoc not found on PATH")

    protos = discover_protos(proto_root, includes, explicit)
    top_levels = {Path(rel).parts[0] for rel in protos if len(Path(rel).parts) > 1}

    package_dir = out_dir / package
    # Clear only the trees this run owns, so an out_dir shared with other
    # generated or hand-written code is left intact.
    for name in top_levels:
        shutil.rmtree(package_dir / name, ignore_errors=True)
    package_dir.mkdir(parents=True, exist_ok=True)

    cmd = [protoc, f"--proto_path={proto_root}", f"--python_out={package_dir}"]
    if pyi:
        try:
            subprocess.run([*cmd, f"--pyi_out={package_dir}", *protos], check=True)
        except subprocess.CalledProcessError:
            # protoc older than 3.20 (e.g. Ubuntu 22.04) has no --pyi_out.
            subprocess.run([*cmd, *protos], check=True)
    else:
        subprocess.run([*cmd, *protos], check=True)

    _rewrite_imports(package_dir, package, top_levels)
    return package_dir


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "protos",
        nargs="*",
        help="proto files to generate, relative to the proto root "
        "(default: every .proto in the repository)",
    )
    parser.add_argument(
        "--out-dir",
        required=True,
        type=Path,
        help="directory to create the generated package in; put this on sys.path",
    )
    parser.add_argument(
        "--package",
        default=DEFAULT_PACKAGE,
        help=f"name of the generated package (default: {DEFAULT_PACKAGE})",
    )
    parser.add_argument(
        "--proto-root",
        default=DEFAULT_PROTO_ROOT,
        type=Path,
        help="protoc include root (default: this repository's proto/)",
    )
    parser.add_argument(
        "--include",
        action="append",
        metavar="SUBDIR",
        help="include every .proto under SUBDIR, relative to the proto root; "
        "repeatable",
    )
    parser.add_argument(
        "--no-pyi", action="store_true", help="skip .pyi type stub generation"
    )
    parser.add_argument("--quiet", action="store_true", help="suppress the summary line")
    args = parser.parse_args(argv)

    try:
        package_dir = generate_python_bindings(
            out_dir=args.out_dir,
            package=args.package,
            proto_root=args.proto_root,
            includes=args.include,
            explicit=args.protos,
            pyi=not args.no_pyi,
        )
    except (FileNotFoundError, RuntimeError) as exc:
        # These are user-facing setup mistakes (missing protoc, a typo in a
        # proto name, an uninitialised submodule) -- report them as errors
        # rather than as a traceback.
        parser.error(str(exc))
    except subprocess.CalledProcessError as exc:
        # protoc already printed its own diagnostics to stderr.
        return exc.returncode or 1
    if not args.quiet:
        print(f"Generated Python bindings in {package_dir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
