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

# The profile read and generated block must stay bounded; otherwise an
# oversized profile could exhaust the shell while it is buffered.
max_profile_bytes=$((512*1024))

# Only a safe basename may be used in a file path. The charset already
# excludes "/", but reject the reserved dot components "." and ".."
# explicitly: they are never valid profile names and are reserved path
# elements that could aim a constructed path at the parent directory.
if [[ ! $name =~ ^[A-Za-z0-9._-]+$ || $name == "." || $name == ".." ]]; then
  echo "invalid profile name: $name" >&2
  exit 1
fi

# Defense in depth: guarantee the resolved profile path stays inside the
# profiles directory. Covers any future path-construction mistake and any
# name that sneaks past the charset check above.
profile_canon="$(cd "$(dirname "$profile_file")" 2>/dev/null && pwd)/$(basename "$profile_file")"
if [[ "$profile_canon" != "$profiles_dir"/* ]]; then
  echo "profile path escapes profiles dir: $name" >&2
  exit 1
fi

# Optional: a JSON array of {"output","x","y"} to apply before rewriting.
positions=""
if [[ ${2:-} == "--positions" ]]; then
  positions="${3:-}"
fi

# Refuse to rewrite monitors.lua through a symlink or non-regular file: shell
# redirection would follow the link and truncate whatever it points at.
if [[ -L "$monitor_lua" ]]; then
  echo "refusing symlink: $monitor_lua" >&2
  exit 1
fi
if [[ ! -e "$monitor_lua" || ! -f "$monitor_lua" ]]; then
  echo "refusing non-regular file: $monitor_lua" >&2
  exit 1
fi

if [[ ! -f $profile_file || -L $profile_file ]]; then
  echo "profile not found: $name" >&2
  exit 1
fi
if (( $(wc -c < "$profile_file") > max_profile_bytes )); then
  echo "profile too large: $name" >&2
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

backup="$monitor_lua.bak.$(date +%s)"
if [[ -L "$backup" ]]; then
  echo "refusing symlink: $backup" >&2
  exit 1
fi
cp "$monitor_lua" "$backup"

mode=$(stat -c %a "$monitor_lua")
tmp=$(mktemp "$(dirname "$monitor_lua")/.monitors.XXXXXX")

# Strip any existing managed region so it can be rewritten below.
awk -v start="$start_marker" -v end="$end_marker" '
  $0 ~ start && !inside { inside = 1; next }
  inside && $0 ~ end { inside = 0; next }
  !inside { print }
' "$monitor_lua" > "$tmp"

final=$(mktemp "$(dirname "$monitor_lua")/.monitors.XXXXXX")
{
  cat "$tmp"
  echo
  echo "$block"
} > "$final"
rm -f "$tmp"

# Atomic rename in the same directory: the fixed monitors.lua path is never
# truncated in place, so a symlink swapped in mid-write can't redirect the
# write onto another user's file.
chmod "$mode" "$final"
mv -f "$final" "$monitor_lua"

hyprctl reload