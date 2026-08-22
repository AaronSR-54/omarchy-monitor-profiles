#!/bin/bash
# Auto-generate the monitor profiles from the connected monitors: one profile
# per monitor (only that monitor enabled) plus "All". Existing per-monitor
# settings (mode, position, scale) are preserved, so a manual arrangement or
# custom scales aren't lost. Users never need to create profiles by hand.
set -euo pipefail

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
profiles_dir="$config_dir/omarchy/monitor-profiles"
mkdir -p "$profiles_dir"

connected=$(hyprctl monitors all -j)
names=$(printf '%s' "$connected" | jq -r '.[].name')
[[ -n "$names" ]] || exit 0

# Merge existing per-monitor settings across all current profiles
# (first occurrence wins, so All.json takes precedence).
existing=$(jq -s '
  reduce (.[] | .monitors[]) as $m ({}; .[$m.output] //= $m)
' "$profiles_dir"/*.json 2>/dev/null || printf '{}')

# Settings per connected monitor, preferring saved settings over live state.
settings=$(printf '%s' "$connected" | jq -c --argjson ex "$existing" '
  [.[] | {
    output: .name,
    mode: ((.width | tostring) + "x" + (.height | tostring) + "@" + ((.refreshRate + 0.5) | floor | tostring)),
    position: ((.x | tostring) + "x" + (.y | tostring)),
    scale: .scale
  } | . + (($ex[.output] // {}) | {mode, position, scale})]
')

# Write All.json (every connected monitor enabled).
printf '%s' "$settings" | jq '{name: "All", monitors: map({output, enabled: true, mode, position, scale})}' > "$profiles_dir/All.json"

# Write one profile per monitor (only that one enabled, the rest disabled).
printf '%s' "$names" | while read -r name; do
  # Only a safe basename may be used as a file name.
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || continue
  printf '%s' "$settings" | jq --arg n "$name" '
    { name: $n, monitors: map({output, enabled: (.output == $n), mode, position, scale}) }
  ' > "$profiles_dir/$name.json"
done

# Drop stale per-monitor profiles for monitors that are no longer connected.
shopt -s nullglob
for f in "$profiles_dir"/*.json; do
  [[ -f $f ]] || continue
  base=$(basename "$f" .json)
  [[ $base == "All" ]] && continue
  if ! printf '%s\n' "$names" | grep -qx "$base"; then
    rm -f "$f"
  fi
done