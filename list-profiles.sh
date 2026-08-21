#!/bin/bash
# List monitor profiles as a JSON array for aaronsr.monitor.
profiles_dir="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/monitor-profiles"
mkdir -p "$profiles_dir"
shopt -s nullglob
files=("$profiles_dir"/*.json)
if ((${#files[@]} == 0)); then
  echo '[]'
  exit 0
fi
printf '['
first=1
for f in "${files[@]}"; do
  if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
  cat "$f"
done
printf ']\n'