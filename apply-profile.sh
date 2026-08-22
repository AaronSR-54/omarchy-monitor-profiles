#!/bin/bash
# Apply a monitor profile by rewriting the managed block in monitors.lua,
# then reloading Hyprland.
set -euo pipefail

name="${1:?usage: apply-profile.sh <profile-name> [--positions <json>]}"
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
profiles_dir="$config_dir/omarchy/monitor-profiles"
profile_file="$profiles_dir/$name.json"
monitor_lua="$config_dir/hypr/monitors.lua"
script_dir="$(cd "$(dirname "$0")" && pwd)"

# Only a safe basename may be used in a file path.
if [[ ! $name =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "invalid profile name: $name" >&2
  exit 1
fi

# Optional: a JSON array of {"output","x","y"} to apply before rewriting.
positions=""
if [[ ${2:-} == "--positions" ]]; then
  positions="${3:-}"
fi

if [[ ! -f $profile_file ]]; then
  echo "profile not found: $name" >&2
  exit 1
fi

# Apply pending drag positions (manual), skipping recentering so they win.
if [[ -n $positions ]]; then
  tmp=$(mktemp)
  jq --argjson pos "$positions" '
    reduce $pos[] as $p (.;
      .monitors |= map(if .output == $p.output then . + { position: (($p.x | tostring) + "x" + ($p.y | tostring)) } else . end))
  ' "$profile_file" > "$tmp" && mv "$tmp" "$profile_file"
  rm -f "$tmp"
fi

# Recompute positions so the layout stays centered for the current scales.
# OMARCHY_SKIP_CENTER=1 preserves manual positions (used by set-position.sh).
if [[ ${OMARCHY_SKIP_CENTER:-0} != 1 && -z $positions ]]; then
  "$script_dir/center-layout.sh" "$profile_file"
fi

start_marker='-- >>> aaronsr.monitor managed <<<'
end_marker='-- <<< aaronsr.monitor managed >>>'

block=$(jq -r '
  # Escape a value for a double-quoted Lua string.
  def lua_escape: gsub("\\\\"; "\\\\\\\\") | gsub("\""; "\\\\\"") | gsub("\n"; "\\\\n") | gsub("\r"; "\\\\r");
  # Scale must be a finite number; anything else defaults to 1.
  def safe_scale: if type == "number" and isfinite then tostring else "1" end;
  ["-- >>> aaronsr.monitor managed <<<",
   "-- Profile \"" + (.name | lua_escape) + "\" applied"] +
  ([.monitors[] |
    if .enabled then
      "hl.monitor({ output = \"" + (.output | lua_escape) + "\", mode = \"" + (.mode | lua_escape) + "\", position = \"" + (.position | lua_escape) + "\", scale = " + (.scale | safe_scale) + " })"
    else
      "hl.monitor({ output = \"" + (.output | lua_escape) + "\", disabled = true })"
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