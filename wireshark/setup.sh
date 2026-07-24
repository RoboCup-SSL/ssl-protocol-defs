#!/usr/bin/env bash
# Installs or uninstalls the SSL Wireshark dissector for the current user.
# No GUI Preferences editing is needed. See wireshark/README.md for what
# this does, and why it deliberately does not touch the
# protobuf_udp_message_types table.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$REPO_ROOT/proto"
DISSECTOR="$REPO_ROOT/wireshark/ssl-dissector.lua"

usage() {
    echo "Usage: $0 {check|install|uninstall}"
    exit 1
}

check() {
    if ! command -v tshark >/dev/null 2>&1; then
        echo "tshark not found on PATH -- install Wireshark, or run inside 'nix develop'" >&2
        exit 1
    fi
    if ! tshark -G protocols 2>/dev/null | grep -qw protobuf; then
        echo "tshark found, but its protobuf dissector is not registered -- a Wireshark build with Protobuf support is required" >&2
        exit 1
    fi
    echo "tshark OK: $(tshark -v | head -1), protobuf dissector present"
}

# tshark -G folders output is "Label:\tPath", one per line.
wireshark_folder() {
    tshark -G folders | awk -F'\t' -v label="$1" '$1 == label { print $2 }'
}

wkt_include_dir() {
    local protoc_bin
    protoc_bin="$(command -v protoc)"
    echo "$(dirname "$(dirname "$protoc_bin")")/include"
}

# The two entries install/uninstall both need to agree on -- computed fresh
# each time rather than cached, since wkt_include_dir() depends on PATH at
# call time. Format is "path|load_all", one per line.
#
# The well-known-types directory is deliberately "FALSE" (load on demand), not
# "TRUE" (load all files eagerly). Confirmed directly: newer protobuf releases'
# descriptor.proto uses an extension-declaration syntax
# (`extensions N [declaration = {...}]`) that Wireshark's own simplified .proto
# parser cannot read, and "TRUE" here makes Wireshark try to parse every file
# in the directory -- including descriptor.proto, which nothing in this repo
# even imports -- and crash on it. "FALSE" resolves google/protobuf/any.proto
# (the one well-known type this repo's files actually import) only when
# something imports it, and never touches descriptor.proto at all.
search_path_entries() {
    local wkt_dir
    wkt_dir="$(wkt_include_dir)"
    echo "$PROTO_DIR|TRUE"
    echo "$wkt_dir|FALSE"
}

# Finds the existing row for a given path in a protobuf_search_paths-style UAT
# file, whatever its load_all value is -- used so install/uninstall match a
# path regardless of which value an earlier version of this script wrote
# there, rather than only matching an exact, fully-formed row.
find_row_for_path() {
    local file="$1" path="$2"
    # "|| true": under `set -e`, a plain grep-finds-nothing here (the normal
    # case for a path that has no existing row yet) would otherwise abort the
    # whole script, since this runs outside any if/conditional at the call site.
    grep -F "\"$path\"," "$file" 2>/dev/null | head -1 || true
}

do_install() {
    check

    local plugin_dir conf_dir search_file link_target path bool desired existing
    local link_changed=false
    local -a rows_added=()
    local -a rows_updated=()

    plugin_dir="$(wireshark_folder "Personal Lua Plugins:")"
    mkdir -p "$plugin_dir"
    link_target="$plugin_dir/ssl-dissector.lua"
    if [ -L "$link_target" ] && [ "$(readlink -f "$link_target")" = "$(readlink -f "$DISSECTOR")" ]; then
        : # already correct, nothing to do
    else
        ln -sf "$DISSECTOR" "$link_target"
        link_changed=true
    fi

    conf_dir="$(wireshark_folder "Personal configuration:")"
    mkdir -p "$conf_dir"
    search_file="$conf_dir/protobuf_search_paths"
    touch "$search_file"
    while IFS='|' read -r path bool; do
        desired="\"$path\",\"$bool\""
        existing="$(find_row_for_path "$search_file" "$path")"
        if [ "$existing" = "$desired" ]; then
            : # already correct, nothing to do
        elif [ -n "$existing" ]; then
            # A row for this path exists but with the wrong load_all value --
            # e.g. an older version of this script wrote "TRUE" and this one
            # wants "FALSE". Replace it rather than adding a second, conflicting
            # row for the same path.
            grep -vF "$existing" "$search_file" > "$search_file.tmp" && mv "$search_file.tmp" "$search_file"
            echo "$desired" >> "$search_file"
            rows_updated+=("$existing -> $desired")
        else
            echo "$desired" >> "$search_file"
            rows_added+=("$desired")
        fi
    done < <(search_path_entries)

    echo
    if [ "$link_changed" = false ] && [ "${#rows_added[@]}" -eq 0 ] && [ "${#rows_updated[@]}" -eq 0 ]; then
        echo "Already up to date -- nothing to install. Symlink and Protobuf search"
        echo "paths were already set up from a previous run."
    else
        if [ "$link_changed" = true ]; then
            echo "Symlinked wireshark/ssl-dissector.lua -> $link_target"
        else
            echo "Symlink already up to date: $link_target"
        fi
        if [ "${#rows_added[@]}" -gt 0 ]; then
            echo "Added ${#rows_added[@]} new row(s) to $search_file:"
            for desired in "${rows_added[@]}"; do
                echo "  $desired"
            done
        fi
        if [ "${#rows_updated[@]}" -gt 0 ]; then
            echo "Updated ${#rows_updated[@]} row(s) in $search_file:"
            for desired in "${rows_updated[@]}"; do
                echo "  $desired"
            done
        fi
        if [ "${#rows_added[@]}" -eq 0 ] && [ "${#rows_updated[@]}" -eq 0 ]; then
            echo "Protobuf search paths already up to date: $search_file"
        fi
    fi

    echo
    echo "Done. No GUI steps are needed. Restart Wireshark or tshark if it was already running."
    echo
    echo "This does not touch protobuf_udp_message_types. The installed Lua script"
    echo "already covers vision/referee decoding and labeling on its own. Adding"
    echo "those preference-table entries as well would override the plugin's labels"
    echo "with generic ones for those ports. Decoding stays correct either way, but"
    echo "there is no benefit once the plugin is installed. See wireshark/README.md"
    echo "for the table-only, no-plugin alternative."
}

do_uninstall() {
    if ! command -v tshark >/dev/null 2>&1; then
        echo "tshark not found on PATH -- cannot look up the config paths automatically." >&2
        echo "If you know them, remove the files yourself; see wireshark/README.md" >&2
        exit 1
    fi

    local plugin_dir conf_dir search_file link_target path bool existing

    plugin_dir="$(wireshark_folder "Personal Lua Plugins:")"
    link_target="$plugin_dir/ssl-dissector.lua"
    if [ -L "$link_target" ] && [ "$(readlink -f "$link_target")" = "$(readlink -f "$DISSECTOR")" ]; then
        rm -f "$link_target"
        echo "Removed symlink $link_target"
    elif [ -e "$link_target" ]; then
        echo "Skipped $link_target -- it exists but does not point at this repository's dissector, so it was left alone"
    else
        echo "No symlink found at $link_target, nothing to remove"
    fi

    conf_dir="$(wireshark_folder "Personal configuration:")"
    search_file="$conf_dir/protobuf_search_paths"
    if [ -f "$search_file" ]; then
        while IFS='|' read -r path bool; do
            # Matches by path only, regardless of its load_all value -- so this
            # also cleans up a row written by an older version of this script
            # with a different value, not just an exact match of what install
            # would write today.
            existing="$(find_row_for_path "$search_file" "$path")"
            if [ -n "$existing" ]; then
                grep -vF "$existing" "$search_file" > "$search_file.tmp" && mv "$search_file.tmp" "$search_file"
                echo "Removed row from $search_file: $existing"
            fi
        done < <(search_path_entries)
    fi
    echo "Done. Any unrelated entries you had in protobuf_search_paths were left alone."
}

case "${1:-}" in
    check) check ;;
    install) do_install ;;
    uninstall) do_uninstall ;;
    *) usage ;;
esac
