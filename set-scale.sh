#!/bin/bash
# Set the scale of a single monitor (per-monitor, not global) and persist it
# into the monitor profiles and monitors.lua so it survives profile switches
# and reboots. Native alternative to omarchy-hyprland-monitor-scaling's
# single global knob.
#
# Usage:
#   set-scale.sh <monitor> <scale|up|down>
#   set-scale.sh <scale|up|down>          (applies to the focused monitor)
set -euo pipefail

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
profiles_dir="$config_dir/omarchy/monitor-profiles"
monitor_lua="$config_dir/hypr/monitors.lua"

presets=(1 1.25 1.6 2 3 4)

monitor="${1:-}"
arg="${2:-}"

# If the first argument isn't an active monitor name, treat it as the scale
# directive and resolve the focused monitor.
if ! hyprctl monitors -j | jq -e --arg m "$monitor" 'any(.[]; .name == $m)' >/dev/null 2>&1; then
  arg="$monitor"
  monitor=$(hyprctl monitors -j | jq -r '[.[] | select(.focused == true)][0].name // ""')
fi

if [[ -z $monitor || -z $arg ]]; then
  echo "usage: set-scale.sh <monitor> <scale|up|down>" >&2
  exit 1
fi

current=$(hyprctl monitors -j | jq -r --arg m "$monitor" '.[] | select(.name == $m) | .scale' | head -1)
[[ -n $current ]] || { echo "monitor not found: $monitor" >&2; exit 1; }

scale=$(awk -v value="$arg" -v cur="$current" -v list="${presets[*]}" '
  function abs(x) { return x < 0 ? -x : x }
  BEGIN {
    n = split(list, p, " ")
    if (value ~ /^[0-9]+([.][0-9]+)?$/) { print value; exit }
    best = 1; bestdiff = 1e9
    for (i = 1; i <= n; i++) { d = abs(p[i] - cur); if (d < bestdiff) { bestdiff = d; best = i } }
    if (value == "up") idx = best < n ? best + 1 : n
    else if (value == "down") idx = best > 1 ? best - 1 : 1
    else idx = best
    print p[idx]
  }')

# 1. Persist the scale for this monitor in every profile and re-center the
#    layout positions so the monitors stay centered (a monitor's scale belongs
#    to the monitor, not the layout).
script_dir="$(cd "$(dirname "$0")" && pwd)"
tmp=$(mktemp)
for f in "$profiles_dir"/*.json; do
  [[ -f $f ]] || continue
  jq --arg m "$monitor" --arg s "$scale" '
    (.monitors[] | select(.output == $m)) .scale = ($s | tonumber)
  ' "$f" > "$tmp" && mv "$tmp" "$f"
  "$script_dir/center-layout.sh" "$f"
done
rm -f "$tmp"

# 2. Re-apply the active profile (the one matching the currently enabled
#    monitors) so the managed block in monitors.lua reflects the new scale and
#    centered positions.
enabled=$(hyprctl monitors all -j | jq -r '[.[] | select(.disabled != true) | .name] | sort | join(",")')
active=""
for f in "$profiles_dir"/*.json; do
  [[ -f $f ]] || continue
  pe=$(jq -r '[.monitors[] | select(.enabled) | .output] | sort | join(",")' "$f")
  if [[ $pe == "$enabled" ]]; then
    active=$(jq -r '.name' "$f")
    break
  fi
done

if [[ -n $active ]]; then
  exec "$script_dir/apply-profile.sh" "$active"
fi

# Fallback (no matching profile): rewrite the monitor's scale in the managed
# block directly. Saving the file makes Hyprland reload it automatically.
if grep -q "output = \"$monitor\"" "$monitor_lua"; then
  sed -i -E \
    "s|(hl\\.monitor\\(\\{ output = \"$monitor\".*scale = )[^,}]+( \}\\))|\\1$scale\\2|" \
    "$monitor_lua"
fi

hyprctl reload