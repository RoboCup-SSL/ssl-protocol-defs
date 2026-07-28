# ssl-protocol-defs

Central, authoritative copy of the protobuf definitions used to interface with RoboCup Small Size League (SSL) software: vision, game controller / referee, and simulation.

## Layout

```
proto/
  vision/       Camera detection, field geometry, and the UDP wrapper around them
  gc/           Referee state, game events, and team/autoref remote control
  simulation/   Simulator control: robot commands, teleportation, config, errors
```

See each subfolder for the specific files. Deeper documentation on protocol-level details is coming later.

## Licensing

This repository uses multiple licenses. Each file's license depends on which
source repository it was copied from
([`LICENSE-MIT`](LICENSE-MIT), [`LICENSE-GPL-2.0`](LICENSE-GPL-2.0), [`LICENSE-GPL-3.0`](LICENSE-GPL-3.0)):

| License | Files |
|---|---|
| **GPL-2.0** | `proto/gc/ssl_gc_referee_message.proto` |
| **GPL-3.0** | every other file under `proto/` |
| **MIT** | everything else in this repository (docs, `Makefile`, `flake.nix`, CI config, etc.) |

The SSL committee is working with the original authors to relicense the
GPL-covered `.proto` files as MIT. Until that work is complete, those files
remain under their current license. **All new contributions to this
repository must be made under MIT.**

## Quick Start

Clone this repository. Then point `protoc` (or your language's protobuf
plugin) at `proto/` as the include root. Every import in this repository is
written relative to that root, so no other setup is required:

```sh
protoc --proto_path=proto --python_out=gen $(find proto -name '*.proto')
```

Replace `--python_out` with `--cpp_out`, `--go_out`, `--java_out`, etc.,
depending on your team's language.

All files in this repository currently use `proto2` syntax, matching the
software that produces them. A few related SSL tools (match-stats,
log-labeling) use `proto3` instead. If those tools' definitions are added
here later, this repository will contain a mix of both.

## Setup for New Teams

Most teams should add these definitions as a dependency inside their own
robot or AI codebase, instead of copying the files directly. This way,
updates to this repository can be pulled in with a normal
`git submodule update`:

```sh
git submodule add https://github.com/RoboCup-SSL/ssl-protocol-defs.git third_party/ssl-protocol-defs
git submodule update --init --recursive
```

Then point `--proto_path` at `third_party/ssl-protocol-defs/proto` instead.
If you are cloning a team repository that already depends on this one, use
`git clone --recurse-submodules`, or run the `update --init` command above
after a normal clone.

**Reference material**, if any of this is new to you:

- [Protocol Buffers documentation](https://protobuf.dev/) — overview and install instructions
- [Proto2 language guide](https://protobuf.dev/programming-guides/proto2/) — the syntax version used by every file in this repository today
- [Proto3 language guide](https://protobuf.dev/programming-guides/proto3/) — used by a few related SSL tools; included in case those definitions are added to this repository later
- [protoc releases](https://github.com/protocolbuffers/protobuf/releases) — compiler downloads, if not available through your package manager
- [Git submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules) — what they are, and how they differ from a normal clone or dependency

## Development

This repository uses [Nix](https://nixos.org/) to provide `protoc`, `buf`,
`make`, `tshark`, and the Python dependencies for dissector testing
([uv](https://docs.astral.sh/uv/) + [uv2nix](https://github.com/pyproject-nix/uv2nix),
see `wireshark/pyproject.toml`) at known-good versions. This makes
validation identical on every machine and in CI.

**Step 1: start a development shell.** This puts every tool listed above on
your `PATH`.

```sh
nix develop
```

**Step 2: run commands from inside that shell.**

Validation targets:

```sh
make compile-protos              # (default target) validates every .proto file under proto/ compiles
make test-wireshark-dissectors   # regenerates protobuf bindings fresh, then runs the
                                  # Wireshark dissector tests against synthetic pcaps
```

Wireshark dissector setup targets:

```sh
make check-wireshark-dependencies    # confirms tshark is present with protobuf support
make install-wireshark-dissectors    # sets up the Wireshark dissector, no GUI steps
make uninstall-wireshark-dissectors  # removes exactly what install added
```

If Nix is not installed: install `protoc` and `tshark` yourself, and set up
a Python environment with `scapy` and `protobuf` (see
`wireshark/pyproject.toml`). Then run the same commands directly. The
Makefile does not require Nix — Nix only guarantees the tool versions.

### CI

Every push to `main`, and every pull request, runs two independent jobs in a
clean, sandboxed environment with no network access
(`.github/workflows/ci.yml`), each building one Nix flake check:

- **Protos Compile** (`nix build .#checks.proto-compile`) — confirms every
  `.proto` file under `proto/` compiles. A red result means a file in the
  pull request fails to compile. A green result only confirms that the
  files compile — it does not confirm the change is otherwise correct.
  Naming and drift from the upstream source are still checked manually.
- **Dissector Tests** (`nix build .#checks.wireshark-dissector-test`) —
  regenerates protobuf bindings from the current `.proto` files, then runs
  the Wireshark dissector against synthetic packets built from those
  bindings. If a schema change breaks an assumption the dissector depends
  on, such as a message name or field number, this check fails instead of
  the problem going unnoticed.

The two run as separate jobs, so either can pass or fail independently
instead of a single combined result.
