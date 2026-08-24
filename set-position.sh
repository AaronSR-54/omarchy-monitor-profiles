#!/bin/bash
# Set the position of a single monitor in the active profile and re-apply it
# without recentering, so a manual drag position wins until the next scale
# change. Repositioning only matters when several monitors are active.
set -euo pipefail

monitor="${1:?usage: set-position.sh <monitor> <x> <y>}"
x="${2:?usage: set-position.sh <monitor> <x> <y>}"
y="${3:?usage: set-position.sh <monitor> <x> <y>}"

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
profiles_dir="$config_dir/omarchy/monitor-profiles"
script_dir="$(cd "$(dirname "$0")" && pwd)"

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

if [[ -z $active ]]; then
  echo "no active profile matches the enabled monitors" >&2
  exit 1
fi

# The active name is read back from an untrusted profile file, so guard it
# the same way apply-profile.sh guards its argument: reject the reserved dot
# components and anything outside the safe basename charset before it is used
# in a path or forwarded to apply-profile.sh.
if [[ ! $active =~ ^[A-Za-z0-9._-]+$ || $active == "." || $active == ".." ]]; then
  echo "invalid active profile name: $active" >&2
  exit 1
fi

profile_file="$profiles_dir/$active.json"

tmp=$(mktemp)
jq --arg m "$monitor" --arg p "${x}x${y}" '
  (.monitors[] | select(.output == $m)) .position = $p
' "$profile_file" > "$tmp" && mv "$tmp" "$profile_file"
rm -f "$tmp"

OMARCHY_SKIP_CENTER=1 "$script_dir/apply-profile.sh" "$active"