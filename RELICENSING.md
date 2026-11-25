# Relicensing to MIT

The `.proto` files in this repository were imported from `ssl-vision`,
`ssl-game-controller`, and `ssl-simulation-protocol` (GPL-3.0). Parts of
`ssl_gc_referee_message.proto` originated in `ssl-refbox` (GPL-2.0). The
files are now distributed under MIT. Only the `.proto` files were relicensed;
everything else in this repository was already MIT. The upstream projects'
software licenses are unaffected, and earlier revisions of this repository remain
available under their original licenses.

## Contributors and Permission

Contributors were identified from the upstream git histories.

| Contributor | Contribution | Permission |
|---|---|---|
| Stefan Zickler | Original vision schema, including legacy | Attempts to reach in writing were unsuccessful. Contribution is interface definitions only; the SSL committee believes this use is fair use (see *Google v. Oracle*, 2021). |
| Joydeep Biswas | Vision field geometry | Written |
| Christopher Head | Original referee message | Written |
| Rolf van de Hulst | Camera calibration fields | Written |
| Nicolai Ommer | Game controller, simulation, vision geometry | Written |
| Tobias Heineken | Simulation fields | Written |
| Lixfel | `t_offsets` field in vision detection (contributed here) | Written |
| Jay Kamat, DennisdeW, Emiel Steerneman | No schema content (syntax line, file modes, merge) | Written |

## Concerns

If you hold rights in any of these files and object to the relicensing,
please open an issue in this repository.
