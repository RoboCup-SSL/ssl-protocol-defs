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

This repo carries multiple licenses, inherited per-file from the source
repos these definitions were vendored from ([`LICENSE-MIT`](LICENSE-MIT),
[`LICENSE-GPL-2.0`](LICENSE-GPL-2.0), [`LICENSE-GPL-3.0`](LICENSE-GPL-3.0)):

| License | Files |
|---|---|
| **GPL-2.0** | `proto/gc/ssl_gc_referee_message.proto` |
| **GPL-3.0** | every other file under `proto/` |
| **MIT** | everything else in this repo (docs, `Makefile`, `flake.nix`, CI config, etc.) |

The SSL committee is pursuing relicensing of the GPL-covered `.proto` files
to MIT with the original authors; until that's complete, those files remain
under their current license. **All new contributions to this repo must be
made under MIT.**

## Quick Start

Clone this repo, then point `protoc` (or your language's protobuf plugin) at `proto/` as the include root — every import in this repo is written relative to it, so no other setup is required:

```sh
protoc --proto_path=proto --python_out=gen $(find proto -name '*.proto')
```

Swap `--python_out` for `--cpp_out`, `--go_out`, `--java_out`, etc. depending on your team's language.

All files currently in this repo are `proto2`, matching the software that authors them. A few adjacent SSL tools (match-stats, log-labeling) use `proto3` instead; if those get vendored in here later, expect a mix.

## Setup for New Teams

Most teams will want these definitions checked out inside their own robot/AI codebase rather than copy-pasted, so updates here can be pulled in with a normal `git submodule update`:

```sh
git submodule add https://github.com/RoboCup-SSL/ssl-protocol-defs.git third_party/ssl-protocol-defs
git submodule update --init --recursive
```

Then point `--proto_path` at `third_party/ssl-protocol-defs/proto` instead. If you're cloning a team repo that already depends on this one, remember `git clone --recurse-submodules` (or run the `update --init` command above after a normal clone).

**Reference**, if any of this is new:

- [Protocol Buffers documentation](https://protobuf.dev/) — overview and install instructions
- [Proto2 language guide](https://protobuf.dev/programming-guides/proto2/) — the syntax version used by every file in this repo today
- [Proto3 language guide](https://protobuf.dev/programming-guides/proto3/) — used by a few adjacent SSL tools, in case those get added here later
- [protoc releases](https://github.com/protocolbuffers/protobuf/releases) — compiler downloads, if not available via your package manager
- [Git submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules) — what they are, how they differ from a normal clone/dependency

## Development

This repo uses [Nix](https://nixos.org/) to pin `protoc`/`buf`/`make` to known-good versions, so validation is identical on every machine and in CI.

```sh
nix develop        # drops you into a shell with protoc, buf, and make on PATH
make check          # validates every .proto file under proto/ compiles
```

No Nix installed? Install `protoc` yourself and run `make check` directly — the Makefile doesn't require Nix, Nix just guarantees the version.

`check` is the only Makefile target today; `install`/`test` will be added as the repo grows.

### CI

Every push to `main` and every pull request runs the **Protos Compile** job (`.github/workflows/ci.yml`), which is just `nix flake check` — the same command as above, run in a clean environment. A red check means some `.proto` file in the PR fails to compile; a green one only confirms that, not that the change is otherwise correct (naming, drift vs. upstream, etc. are still manual review for now).
