#!/bin/bash
# Set the color temperature (warmth) of a single monitor via a generated
# per-monitor screen shader. hyprsunset only supports a global temperature,
# so warmth is applied per output with Hyprland's decoration:screen_shader
# and the `wl_output` uniform instead.
#
# Usage:
#   set-warmth.sh <monitor> <percent>   Set one monitor's warmth (0-100).
#   set-warmth.sh --apply               Rebuild + reapply from the state file
#                                       (after monitor/profile changes).
set -euo pipefail

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
state_file="$config_dir/omarchy/monitor-warmth.json"
plugin_dir="$config_dir/omarchy/plugins/aaronsr.monitor"
shader_file="$plugin_dir/warmth.frag"

rebuild_and_apply() {
  # Regenerate the per-monitor screen shader from the state file and apply it.
  # If no monitor has any warmth, drop the shader so the screen is untouched.
  if [[ -f $state_file ]] \
     && python3 "$plugin_dir/generate-warmth-shader.py" "$state_file" "$shader_file" \
     && grep -q 'wl_output == ' "$shader_file"; then
    hyprctl eval "hl.config({ decoration = { screen_shader = \"$shader_file\" } })" >/dev/null
  else
    hyprctl eval 'hl.config({ decoration = { screen_shader = "" } })' >/dev/null
  fi
}

if [[ ${1:-} == "--apply" ]]; then
  rebuild_and_apply
  exit 0
fi

monitor="${1:?usage: set-warmth.sh <monitor> <percent>}"
percent="${2:?}"

[[ $percent =~ ^[0-9]+$ ]] && (( percent >= 0 && percent <= 100 )) || {
  echo "percent must be 0-100: $percent" >&2
  exit 1
}

hyprctl monitors -j | jq -e --arg m "$monitor" 'any(.[]; .name == $m)' >/dev/null 2>&1 || {
  echo "unknown monitor: $monitor" >&2
  exit 1
}

# 1. Persist the per-monitor warmth.
mkdir -p "$config_dir/omarchy"
if [[ -f $state_file ]]; then
  tmp=$(mktemp)
  jq --arg m "$monitor" --argjson p "$percent" '.[$m] = $p' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
else
  printf '{"%s": %s}\n' "$monitor" "$percent" > "$state_file"
fi

# 2. Rebuild and apply the shader.
rebuild_and_apply