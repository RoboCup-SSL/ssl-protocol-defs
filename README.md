# ssl-protocol-defs

Central, authoritative copy of the protobuf definitions used to interface with RoboCup Small Size League (SSL) software.

This readme targets protocol maintainers. For all other uses and documentation, please see and contribute to the [Wiki](https://github.com/RoboCup-SSL/ssl-protocol-defs/wiki). 

## Layout

```
proto/
  vision/          Camera detection, field geometry, and the UDP wrapper around them
  gamecontroller/  Referee state, game events, and team/autoref remote control
  simulation/      Simulator control: robot commands, teleportation, config, errors
```

See each subfolder for the specific files. Deeper documentation on protocol-level details is coming later.

## Quick Start

Clone this repository. Then point `protoc` (or your language's protobuf
plugin) at `proto/` as the include root. Every import in this repository is
written relative to that root:

```sh
protoc --proto_path=proto --cpp_out=gen $(find proto -name '*.proto')
```

Replace `--cpp_out` with `--go_out`, `--java_out`, etc., depending on your
team's language.

For Python, see [Python bindings](#python-bindings) below.

### Layout of generated code

protoc derives generated package names from the top-level directories here and
emits cross-references in the same shape: generated `vision` code refers to
generated `gamecontroller` code as `gamecontroller/...`. The output directory
must therefore be on the include or import path for those cross-references to
resolve.

For C++, add the output directory to the include path.
[`cmake/SSLProtocolDefs.cmake`](cmake/SSLProtocolDefs.cmake) provides a CMake
function that does this, and documents why protobuf's own
`protobuf_generate()` does not work when this repository is a submodule.

### Python bindings

`protoc --python_out` requires its output directory on `sys.path` for the
generated cross-imports to resolve. That makes `vision`, `gamecontroller` and
`simulation` top-level module names in the consuming project, and any
directory added here later becomes a new top-level name.

[`python/python_bindings.py`](python/python_bindings.py) generates the same
bindings nested inside one package and rewrites the generated cross-imports to
match:

```sh
python3 python/python_bindings.py --out-dir gen              # or: make python-bindings
```

```python
import sys; sys.path.insert(0, "gen")   # or set PYTHONPATH=gen

from sslproto.vision.ssl_vision_wrapper_pb2 import SSL_WrapperPacket
from sslproto.gamecontroller.ssl_gc_referee_message_pb2 import Referee
```

`--package` sets the package name; `--include vision` restricts generation to
one subdirectory. Only the generated Python changes: the descriptor pool retains
the canonical file names (`vision/ssl_vision_wrapper.proto`), so wire format
and reflection are unaffected.

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
`third_party/` is only a convention; any path works, and projects that consume
nothing else this way often just use `proto/`.
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

### Dependencies

This repository uses [Nix](https://nixos.org/) to provide `protoc`, `buf`,
`make`, `tshark`, and the Python dependencies for dissector testing
([uv](https://docs.astral.sh/uv/) + [uv2nix](https://github.com/pyproject-nix/uv2nix),
see `wireshark/pyproject.toml`) at known-good versions. This makes
validation identical on every machine and in CI.

```sh
nix develop
```

#### Ubuntu/Debian Manual Install

On Ubuntu/Debian, apt covers everything except `buf`:

```sh
sudo apt install protobuf-compiler make tshark python3-scapy python3-protobuf
```

`buf` isn't packaged for apt — see [buf's install docs](https://buf.build/docs/installation).

### Compile Protos

```sh
make compile-protos              # (default target) validates every .proto file under proto/ compiles
```

### Code Generation

```sh
make python-bindings             # generates nested Python bindings into gen/sslproto/
                                  # (override with PYTHON_BINDINGS_OUT / PYTHON_BINDINGS_PACKAGE)
```

### Proto Utilities

```sh
cd proto
buf lint .
buf breaking . --config ../buf-breaking-wire.yaml --against "../.git#subdir=proto,ref=HEAD"
```

`buf breaking` also has a `buf-breaking-reflection.yaml` config for the
stricter reflection/JSON compatibility check (see `ci.yml`). Swap `ref=HEAD`
for the commit/branch you want to diff against.

### Wireshark Dissector

A wireshark dissector is provided to help debug league tools and to capture and share network level misbehavior. Filter non-ssl packets with `frame.protocols contains "ssl_"`. View the [wireshark dissector readme](./wireshark/README.md) for more info.

```sh
make install-wireshark-dissectors    # sets up the Wireshark dissector, no GUI steps
make uninstall-wireshark-dissectors  # removes exactly what install added
make test-wireshark-dissectors   # regenerates protobuf bindings fresh, then runs the
```

## Licensing

This repository is licensed under the [MIT License](LICENSE). The `.proto`
files were previously GPL-licensed; see [RELICENSING.md](RELICENSING.md) for
details. All contributions must be made under MIT.
