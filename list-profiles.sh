#!/bin/bash
# Ensure the profiles exist for the connected monitors, then list them as a
# JSON array (individual monitors first, "All" last) for aaronsr.monitor.
config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
profiles_dir="$config_dir/omarchy/monitor-profiles"
script_dir="$(cd "$(dirname "$0")" && pwd)"

"$script_dir/generate-profiles.sh" || exit 1

# Bounds for the concatenated JSON. The profiles dir is user-writable, so cap
# both the number of files and the bytes emitted; the panel buffers the whole
# array, so an oversized or flooded directory must not be able to exhaust it.
max_files=64
max_file_bytes=$((64*1024))
max_total_bytes=$((512*1024))

files=()
all_file=""
total_bytes=0
shopt -s nullglob
for f in "$profiles_dir"/*.json; do
  [[ -f $f && ! -L $f ]] || continue
  sz=$(wc -c < "$f")
  (( sz <= max_file_bytes )) || continue
  (( total_bytes + sz <= max_total_bytes )) || break
  files+=("$f")
  total_bytes=$((total_bytes + sz))
  [[ $f == "$profiles_dir/All.json" ]] && all_file="$f"
  (( ${#files[@]} < max_files )) || break
done
if ((${#files[@]} == 0)); then
  echo '[]'
  exit 0
fi
printf '['
first=1
# Individual monitor profiles first, then "All".
for f in "${files[@]}"; do
  name=$(jq -r '.name // ""' "$f")
  [[ $name != "All" ]] || continue
  if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
  cat "$f"
done
if [[ -n $all_file ]]; then
  if [[ $first -eq 1 ]]; then first=0; else printf ','; fi
  cat "$all_file"
fi
printf ']\n'