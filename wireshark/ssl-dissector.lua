-- RoboCup SSL dissector: game-controller rcon (TCP), simulation-protocol (UDP),
-- and cosmetic labeling for vision/referee (UDP).
--
-- Vision and referee traffic (ports 10003/10005/10006/10010) decode fully and
-- correctly using Wireshark's built-in Protobuf UDP Message Type preference table
-- alone, with no Lua involved (see wireshark/README.md for the exact table
-- entries). Each of these ports carries only one message type, so that table can
-- express them completely. The block at the bottom of this file, which wraps
-- those same ports, is purely additive: it adds a friendlier Protocol column
-- name and an Info summary of which optional branches are set (for example,
-- "detection+geometry"). If this script is not loaded, the preference-table
-- path keeps working with no change.
--
-- rcon and simulation, below, are the ports that actually require Lua: the
-- message type depends on which direction a packet is travelling, and the UDP
-- Message Type table cannot express that at all.
--
-- Requires: Preferences -> Protocols -> ProtoBuf -> Protobuf search paths must
-- include this repository's proto/ directory, so the built-in protobuf
-- dissector can resolve message definitions by name.

local protobuf_dissector = Dissector.get("protobuf")

-- Hands a byte range off to Wireshark's built-in protobuf dissector as the named
-- message type. message_name must be the fully-qualified name (dotted, if the
-- .proto file declares a package -- only the legacy vision schema does).
--
-- Wireshark's protobuf dissector writes its own Protocol/Info column text when
-- it runs, using an append rather than a replace. Setting pinfo.cols.protocol
-- and pinfo.cols.info again AFTER this call (confirmed directly) fully
-- replaces that text rather than appending to it, which is how callers below
-- get a short, custom summary instead of the full field dump.
local function dissect_as(message_name, tvb, pinfo, tree)
    pinfo.private["pb_msg_type"] = "message," .. message_name
    local ok = pcall(function() protobuf_dissector:call(tvb, pinfo, tree) end)
    if not ok then
        tree:add_expert_info(PI_MALFORMED, PI_ERROR,
            "Failed to decode as " .. message_name .. " (wrong direction guess, or Protobuf search path not configured)")
    end
end

-- Every dissector below ends by setting the Protocol column to this shared
-- format, once the message type is known.
local function set_protocol_col(pinfo, message_type)
    pinfo.cols.protocol = "SSL " .. message_type .. " - Protobuf"
end

----------------------------------------------------------------------
-- Simulation protocol (UDP, unicast, bidirectional) -- one message per datagram,
-- no reassembly needed. Message type depends only on which side sent it.
----------------------------------------------------------------------

local function make_sim_udp_dissector(name, port, request_type, response_type)
    local proto = Proto(name, "SSL Simulation - " .. name)

    function proto.dissector(tvb, pinfo, tree)
        local msg_type, info
        if pinfo.dst_port == port then
            msg_type = request_type
            info = request_type .. " -> simulator"
        else
            msg_type = response_type
            info = response_type .. " -> client"
        end
        dissect_as(msg_type, tvb, pinfo, tree)
        set_protocol_col(pinfo, msg_type)
        pinfo.cols.info = info
    end

    DissectorTable.get("udp.port"):add(port, proto)
    return proto
end

make_sim_udp_dissector("ssl_sim_control", 10300, "SimulatorCommand", "SimulatorResponse")
make_sim_udp_dissector("ssl_sim_robot_control_blue", 10301, "RobotControl", "RobotControlResponse")
make_sim_udp_dissector("ssl_sim_robot_control_yellow", 10302, "RobotControl", "RobotControlResponse")

----------------------------------------------------------------------
-- Game-controller rcon (TCP, unicast) -- each direction carries a sequence of
-- messages, each prefixed by its length as a protobuf varint (standard delimited-
-- protobuf framing; see ssl-game-controller's sslconn.go).
--
-- Known limitation: the *Registration message, sent once when a connection
-- starts, shares the same port and direction as steady-state *ToController
-- traffic below, and is not detected separately. It is dissected as the
-- steady-state type, and shows as malformed for that one frame. This is not a
-- silent failure -- the expert-info warning above appears for it.
----------------------------------------------------------------------

-- Reads a protobuf-style base-128 varint starting at `offset`.
-- Returns value, bytes_consumed -- or nil, nil if there is not enough data yet
-- (the caller should ask Wireshark for more of the TCP stream and retry).
local function read_varint(tvb, offset)
    local value = 0
    local shift = 0
    local pos = offset
    local len = tvb:len()
    while true do
        if pos >= len then
            return nil, nil
        end
        local byte = tvb(pos, 1):uint()
        value = value + (byte % 128) * (2 ^ shift)
        pos = pos + 1
        if byte < 128 then
            return value, pos - offset
        end
        shift = shift + 7
        if shift > 63 then
            return nil, nil -- malformed varint, stop rather than loop forever
        end
    end
end

local function make_rcon_tcp_dissector(name, port, to_controller_type, from_controller_type)
    local proto = Proto(name, "SSL rcon - " .. name)

    function proto.dissector(tvb, pinfo, tree)
        local offset = 0
        local buf_len = tvb:len()

        while offset < buf_len do
            local msg_len, prefix_len = read_varint(tvb, offset)
            if not msg_len then
                pinfo.desegment_offset = offset
                pinfo.desegment_len = DESEGMENT_ONE_MORE_SEGMENT
                return
            end

            local remaining = buf_len - offset - prefix_len
            if remaining < msg_len then
                pinfo.desegment_offset = offset
                pinfo.desegment_len = (prefix_len + msg_len) - (buf_len - offset)
                return
            end

            local msg_tvb = tvb(offset + prefix_len, msg_len):tvb()
            local msg_type, info
            if pinfo.dst_port == port then
                msg_type = to_controller_type
                info = to_controller_type .. " -> controller"
            else
                msg_type = from_controller_type
                info = from_controller_type .. " -> client"
            end
            dissect_as(msg_type, msg_tvb, pinfo, tree)
            set_protocol_col(pinfo, msg_type)
            pinfo.cols.info = info

            offset = offset + prefix_len + msg_len
        end
    end

    DissectorTable.get("tcp.port"):add(port, proto)
    return proto
end

make_rcon_tcp_dissector("ssl_gc_rcon_autoref", 10007, "AutoRefToController", "ControllerToAutoRef")
make_rcon_tcp_dissector("ssl_gc_rcon_team", 10008, "TeamToController", "ControllerToTeam")
make_rcon_tcp_dissector("ssl_gc_rcon_remotecontrol", 10011, "RemoteControlToController", "ControllerToRemoteControl")

----------------------------------------------------------------------
-- Vision + referee (UDP, multicast broadcast) -- cosmetic only, see header comment.
-- Single fixed message type per port, so no direction logic needed here.
----------------------------------------------------------------------

-- Scans the top-level fields of a message without fully decoding it, to see which
-- field numbers are present. This is enough to show "detection+geometry" in the
-- Info column without opening the tree. It stops, rather than raising an error,
-- on anything it does not recognize. This is a simple hint, not a full parser.
local function toplevel_fields_present(tvb)
    local present = {}
    local pos = 0
    local len = tvb:len()
    while pos < len do
        local tag, tag_len = read_varint(tvb, pos)
        if not tag then break end
        local field_num = math.floor(tag / 8)
        local wire_type = tag % 8
        present[field_num] = true
        pos = pos + tag_len

        if wire_type == 0 then -- varint
            local _, vlen = read_varint(tvb, pos)
            if not vlen then break end
            pos = pos + vlen
        elseif wire_type == 1 then -- 64-bit (fixed64/double)
            pos = pos + 8
        elseif wire_type == 2 then -- length-delimited (string/bytes/message)
            local val_len, len_bytes = read_varint(tvb, pos)
            if not val_len then break end
            pos = pos + len_bytes + val_len
        elseif wire_type == 5 then -- 32-bit (fixed32/float)
            pos = pos + 4
        else
            break -- group or unknown wire type -- not handled, this is only a hint
        end
    end
    return present
end

-- Same top-level scan as toplevel_fields_present, but for varint (wire type 0)
-- fields it also records the decoded value, keyed by field number. Used to
-- pull a handful of scalar/enum values straight out of the wire bytes for a
-- short Info column summary, without re-implementing a full message parser.
local function toplevel_varint_values(tvb)
    local values = {}
    local pos = 0
    local len = tvb:len()
    while pos < len do
        local tag, tag_len = read_varint(tvb, pos)
        if not tag then break end
        local field_num = math.floor(tag / 8)
        local wire_type = tag % 8
        pos = pos + tag_len

        if wire_type == 0 then -- varint
            local value, vlen = read_varint(tvb, pos)
            if not vlen then break end
            values[field_num] = value
            pos = pos + vlen
        elseif wire_type == 1 then -- 64-bit (fixed64/double)
            pos = pos + 8
        elseif wire_type == 2 then -- length-delimited (string/bytes/message)
            local val_len, len_bytes = read_varint(tvb, pos)
            if not val_len then break end
            pos = pos + len_bytes + val_len
        elseif wire_type == 5 then -- 32-bit (fixed32/float)
            pos = pos + 4
        else
            break -- group or unknown wire type -- not handled, this is only a hint
        end
    end
    return values
end

-- field_labels is an optional list of {num=<field number>, label=<name>} used to
-- build a presence-only Info summary, e.g. "detection+geometry". value_fields is
-- an optional list of {num=<field number>, label=<name>} used instead to build a
-- "label=value" summary from the raw enum/integer values on the wire. Only one
-- of the two would normally be passed for a given message. Pass both nil for
-- messages with nothing worth summarizing -- the Info column then just shows
-- the message type name. Either way, the full field detail is untouched in the
-- packet detail tree; this only shortens the one-line packet list summary.
local function make_fixed_udp_dissector(name, port, message_type, field_labels, value_fields)
    local proto = Proto(name, "SSL - " .. name)

    function proto.dissector(tvb, pinfo, tree)
        local info
        if field_labels then
            local present = toplevel_fields_present(tvb)
            local parts = {}
            for _, f in ipairs(field_labels) do
                if present[f.num] then
                    table.insert(parts, f.label)
                end
            end
            info = message_type .. (#parts > 0 and (": " .. table.concat(parts, "+")) or "")
        elseif value_fields then
            local values = toplevel_varint_values(tvb)
            local parts = {}
            for _, f in ipairs(value_fields) do
                if values[f.num] ~= nil then
                    -- string.format("%d", ...) rather than tostring(): Lua's "^" operator in
                    -- read_varint always returns a float, so tostring() would print "1.0".
                    table.insert(parts, f.label .. "=" .. string.format("%d", values[f.num]))
                end
            end
            info = table.concat(parts, " ")
        else
            info = message_type
        end
        dissect_as(message_type, tvb, pinfo, tree)
        set_protocol_col(pinfo, message_type)
        pinfo.cols.info = info
    end

    DissectorTable.get("udp.port"):add(port, proto)
    return proto
end

make_fixed_udp_dissector("ssl_vision_legacy", 10005, "RoboCup2014Legacy.Wrapper.SSL_WrapperPacket",
    { { num = 1, label = "detection" }, { num = 2, label = "geometry" } })
make_fixed_udp_dissector("ssl_vision", 10006, "SSL_WrapperPacket",
    { { num = 1, label = "detection" }, { num = 2, label = "geometry" } })
make_fixed_udp_dissector("ssl_vision_tracker", 10010, "TrackerWrapperPacket",
    { { num = 3, label = "tracked_frame" } })
-- match_type=19, stage=2, command=4, next_command=12 in ssl_gc_referee_message.proto.
-- Values are the raw enum integers, not the resolved names, to avoid duplicating
-- the enum definitions here -- the full names are still in the detail tree below.
make_fixed_udp_dissector("ssl_referee", 10003, "Referee", nil,
    { { num = 19, label = "match_type" }, { num = 2, label = "stage" },
      { num = 4, label = "command" }, { num = 12, label = "next_command" } })
