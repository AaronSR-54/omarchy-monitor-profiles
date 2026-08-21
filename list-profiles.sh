#!/bin/bash
# Ensure the profiles exist for the connected monitors, then list them as a
# JSON array (individual monitors first, "All" last) for aaronsr.monitor.
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
profiles_dir="$config_dir/omarchy/monitor-profiles"
script_dir="$(cd "$(dirname "$0")" && pwd)"

"$script_dir/generate-profiles.sh" || exit 1

shopt -s nullglob
files=("$profiles_dir"/*.json)
if ((${#files[@]} == 0)); then
  echo '[]'
  exit 0
fi
printf '['
first=1
# Individual monitor profiles first, then "All".
for f in "$profiles_dir"/*.json; do
  [[ -f $f ]] || continue
  name=$(jq -r '.name // ""' "$f")
  [[ $name != "All" ]] || continue
  if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
  cat "$f"
done
if [[ -f "$profiles_dir/All.json" ]]; then
  if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
  cat "$profiles_dir/All.json"
fi
printf ']\n'