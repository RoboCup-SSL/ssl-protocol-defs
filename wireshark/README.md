# Wireshark support for SSL protocols

This dissector decodes RoboCup SSL network traffic directly from this
repository's `.proto` files. There is no separate schema to maintain, and
no risk of drift between the network traffic and what the dissector
understands.

## Setup

There are two ways to set this up. Choose one. See the note at the end of
this section explaining why you should not use both together.

### Scripted install

```sh
make install-wireshark-dissectors      # or: wireshark/setup.sh install
make uninstall-wireshark-dissectors    # removes exactly what install added, nothing else
```

This creates a symlink, not a copy, so edits to the script take effect
immediately with no stale copy. It links `ssl-dissector.lua` into your
Wireshark personal Lua plugins folder, and writes the Protobuf search path
preference. Both locations are found automatically using `tshark -G
folders`.

### Alternative: no plugin, GUI only, vision/referee only

Use this method if you do not want to load any Lua plugin. Go to Edit →
Preferences → Protocols → ProtoBuf → *Protobuf search paths*, and add this
repository's `proto/` directory. Check "Load all files". Then add the four
rows from the table below to *Message Types* in the same panel.

This method fully decodes vision and referee traffic on its own, but only
with generic labels. It cannot decode rcon or simulation traffic at all,
because those protocols need direction-dependent logic that a preference
table cannot express.

**Do not use both methods at the same time.** Checked directly: if the Lua
plugin is installed and the Message Type table also has an entry for the
same port, the table's setting overrides the plugin for that port.
Decoding still works correctly either way, but the plugin's improved
labels stop working for that port.

### Troubleshooting: no decoding when Wireshark runs as root

Do not run Wireshark as root (for example with `sudo wireshark`). A root
session reads configuration from `/root/.config/wireshark`, not from your
own user's home directory, so it never sees what `install-wireshark-dissectors`
set up. This normally looks like "the dissector was installed, but nothing
decodes."

The correct fix is to give the packet-capture helper the specific Linux
capabilities it needs, so Wireshark can capture packets without running as
root at all. On Debian or Ubuntu:

```sh
sudo dpkg-reconfigure wireshark-common
```

Select **Yes** when asked whether non-superusers should be able to capture
packets. This creates a `wireshark` group and sets the correct permissions
on `dumpcap`, the helper program that performs the actual capture.

Then add your user to that group:

```sh
sudo usermod -aG wireshark $USER
```

Log out and back in for the group change to take effect (`newgrp wireshark`
applies it to the current shell only, without a full logout). After that,
run plain `wireshark`, with no `sudo`, and it will use your own
configuration.

If `dpkg-reconfigure` is not available, the manual equivalent is:

```sh
sudo groupadd -f wireshark
sudo usermod -aG wireshark $USER
sudo setcap cap_net_raw,cap_net_admin+eip $(which dumpcap)
```

## Packet list display

With the Lua plugin loaded, the packet list at the top of the Wireshark
window shows a shortened Protocol and Info column, so a live capture stays
readable. The full field detail is unchanged in the packet detail pane at
the bottom — this only affects the one-line summary.

- **Protocol column**: `SSL <message type> - Protobuf`, for example
  `SSL Referee - Protobuf` or `SSL SimulatorCommand - Protobuf`.
- **Info column**: a short, message-specific summary instead of every
  field. For `Referee`, this is exactly four fields —
  `match_type`, `stage`, `command`, and `next_command` — shown as their raw
  enum numbers (not the resolved names, to avoid duplicating the enum
  definitions here; the names are still in the detail pane). For
  `SSL_WrapperPacket` and the legacy/tracker wrapper messages, it shows
  which optional branches are set, for example `detection+geometry`. Other
  message types show the direction of travel, for example
  `TeamToController -> controller`.

This only applies when the Lua plugin is loaded. The GUI-only, no-plugin
setup described above does not customize these columns.

### Filtering to only SSL traffic

To show only SSL packets, of any kind, in the packet list, use this display
filter:

```
frame.protocols contains "ssl_"
```

This works with no plugin code needed. Every protocol this dissector
registers (`ssl_vision`, `ssl_referee`, `ssl_gc_rcon_team`, `ssl_sim_control`,
and so on) already shares the `ssl_` prefix, and `frame.protocols` is
Wireshark's own field listing every protocol layer present in a packet.
Verified directly against all message types this dissector handles.

## Testing

Test against a real capture:

```sh
nix shell nixpkgs#tshark --command tshark -X lua_script:ssl-dissector.lua -r <capture.pcap> -V
```

A correctly configured capture shows fields from the actual message, for
example `stage`, `command`, `yellow`, and `blue` for a `Referee` packet, in
the packet detail tree. It should not show only raw bytes.
`make test-wireshark-dissectors` runs an automated version of this test
against synthetic packets (see `wireshark/tests/run_tests.py`). These
packets are regenerated from the current `.proto` files every time the
test runs.

## Port Reference

### Multicast and Broadcast

| Port | Address | Message type (paste as-is) |
|---|---|---|
| 10005/udp | 224.5.23.2 | `RoboCup2014Legacy.Wrapper.SSL_WrapperPacket` |
| 10006/udp | 224.5.23.2 | `SSL_WrapperPacket` |
| 10010/udp | 224.5.23.2 | `TrackerWrapperPacket` |
| 10003/udp | 224.5.23.1 | `Referee` |

These addresses are true IP multicast (class D addresses). One publisher
can send to any number of listeners, with no connection required. A
capture filter of `host 224.5.23.1 or host 224.5.23.2` isolates all four
ports.

### Unicast

| Port | Transport | Client → server | Server → client |
|---|---|---|---|
| 10007/tcp | TCP, length-prefixed | `AutoRefToController` | `ControllerToAutoRef` |
| 10008/tcp | TCP, length-prefixed | `TeamToController` | `ControllerToTeam` |
| 10011/tcp | TCP, length-prefixed | `RemoteControlToController` | `ControllerToRemoteControl` |
| 10300/udp | UDP, one message/datagram | `SimulatorCommand` | `SimulatorResponse` |
| 10301/udp | UDP, one message/datagram | `RobotControl` (blue) | `RobotControlResponse` |
| 10302/udp | UDP, one message/datagram | `RobotControl` (yellow) | `RobotControlResponse` |

None of these ports use multicast. Each is a direct connection between one
client and the game controller or simulator. Not all SSL network traffic
is broadcast.

**Known limitation**: the dissector does not detect the one-time
`*Registration` message. This message is the first frame sent on a new
connection, before steady-state `*ToController` traffic begins. The
dissector always assumes client-to-server traffic is the steady-state
type, so this first frame shows a malformed-decode warning instead of
decoding correctly. Every frame after it decodes correctly.

**Out of scope by design**: the game-controller CI interfaces (ports
10009 and 10013). These are development and testing tools, not live-match
traffic. Support for them can be added later, following the same pattern
used elsewhere in `ssl-dissector.lua`.
