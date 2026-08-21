#!/bin/bash
# Apply a monitor profile by rewriting the managed block in monitors.lua,
# then reloading Hyprland. Native alternative to hyprmoncfg.
set -euo pipefail

name="${1:?usage: apply-profile.sh <profile-name>}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
profiles_dir="$config_dir/omarchy/monitor-profiles"
profile_file="$profiles_dir/$name.json"
monitor_lua="$config_dir/hypr/monitors.lua"
script_dir="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f $profile_file ]]; then
  echo "profile not found: $name" >&2
  exit 1
fi

# Recompute positions so the layout stays centered for the current scales.
"$script_dir/center-layout.sh" "$profile_file"

start_marker='-- >>> aaronsr.monitor managed <<<'
end_marker='-- <<< aaronsr.monitor managed >>>'

block=$(jq -r '
  ["-- >>> aaronsr.monitor managed <<<",
   "-- Profile \"" + .name + "\" applied"] +
  ([.monitors[] |
    if .enabled then
      "hl.monitor({ output = \"" + .output + "\", mode = \"" + .mode + "\", position = \"" + .position + "\", scale = " + ((.scale // 1) | tostring) + " })"
    else
      "hl.monitor({ output = \"" + .output + "\", disabled = true })"
    end]) +
  ["-- <<< aaronsr.monitor managed >>>"]
  | join("\n")
' "$profile_file")

cp "$monitor_lua" "$monitor_lua.bak.$(date +%s)"

tmp=$(mktemp)

# Strip any existing managed region so it can be rewritten below.
awk -v start="$start_marker" -v end="$end_marker" '
  $0 ~ start && !inside { inside = 1; next }
  inside && $0 ~ end { inside = 0; next }
  !inside { print }
' "$monitor_lua" > "$tmp"

{
  cat "$tmp"
  echo
  echo "$block"
} > "$monitor_lua"

rm -f "$tmp"

hyprctl reload