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
script_dir="$(cd "$(dirname "$0")" && pwd)"

# Regenerate the profiles first so they describe the monitors that are
# connected right now (output names can change across reboots). Saved settings
# are preserved by physical identity, so this does not lose custom scales.
# A failure here is not fatal: the existing profiles are used as a fallback.
"$script_dir/generate-profiles.sh" || true

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

# Physical identity (make/model/serial) of the monitor. Profiles are matched by
# identity so a saved scale follows the panel even when its output name changes
# after a reboot or recabling; the output name remains the fallback.
identity=$(hyprctl monitors -j | jq -r --arg m "$monitor" '.[] | select(.name == $m) | ((.description // "") | tostring)' | head -1)

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
tmp=$(mktemp)
for f in "$profiles_dir"/*.json; do
  [[ -f $f ]] || continue
  jq --arg m "$monitor" --arg id "$identity" --arg s "$scale" '
    (.monitors[] | select(.output == $m or ($id != "" and .identity == $id))) .scale = ($s | tonumber)
  ' "$f" > "$tmp" && mv "$tmp" "$f"
  "$script_dir/center-layout.sh" "$f"
done
rm -f "$tmp"

# 2. Re-apply the active profile (the one matching the currently enabled
#    monitors) so the managed block in monitors.lua reflects the new scale and
#    centered positions.
# Virtual outputs (HEADLESS-N) get no profile, so they must not take part in
# the active-profile match; otherwise a headless output being on would hide the
# real profile and the re-apply below would be skipped.
enabled=$(hyprctl monitors all -j | jq -r '
  [.[] | select(.disabled != true) | (.name // "") | select(test("^HEADLESS-[0-9]+$") | not)] | sort | join(",")
')
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
  # sed -i writes through a symlink, so refuse to follow one: it could
  # truncate whatever the link points at.
  if [[ -L "$monitor_lua" ]]; then
    echo "refusing symlink: $monitor_lua" >&2
    exit 1
  fi
  sed -i -E \
    "s|(hl\\.monitor\\(\\{ output = \"$monitor\".*scale = )[^,}]+( \}\\))|\\1$scale\\2|" \
    "$monitor_lua"
fi

hyprctl reload