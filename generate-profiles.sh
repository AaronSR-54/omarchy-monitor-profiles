#!/bin/bash
# Auto-generate the monitor profiles from the connected monitors: one profile
# per monitor (only that monitor enabled) plus "All". Existing per-monitor
# settings (mode, position, scale) are preserved, so a manual arrangement or
# custom scales aren't lost. Users never need to create profiles by hand.
set -euo pipefail

config_dir="${XDG_CONFIG_HOME:-$HOME/.config}"
profiles_dir="$config_dir/omarchy/monitor-profiles"
mkdir -p "$profiles_dir"

# Bounds for reading back existing profiles. The profiles dir is user-writable,
# so cap both the number of files and the bytes merged/emitted; otherwise an
# oversized or flood-filled directory could exhaust memory while the panel
# buffers the whole result.
max_files=64
max_file_bytes=$((64*1024))
max_total_bytes=$((512*1024))

# Hyprland's virtual outputs (`hyprctl output create headless`, named
# HEADLESS-N) have no physical panel behind them and no EDID. They are not
# display choices, so they get no profile and are left out of "All"; the stale
# profile cleanup below also drops any HEADLESS-N.json left by older versions.
virtual_re='^HEADLESS-[0-9]+$'
connected=$(hyprctl monitors all -j | jq -c --arg re "$virtual_re" '
  map(select((.name // "") | test($re) | not))
')
names=$(printf '%s' "$connected" | jq -r '.[].name')
[[ -n "$names" ]] || exit 0

# Merge existing per-monitor settings across all current profiles
# (first occurrence wins, so All.json takes precedence). Settings are keyed by
# the physical monitor identity (make/model/serial as reported by hyprctl's
# "description") so they follow the monitor even if its output name changes
# after a reboot or recabling. Profiles written before identities existed are
# still honoured through their output name. Only a bounded set of regular files
# is read and oversized entries are skipped, so a flooded or oversized profiles
# dir can't exhaust memory.
existing='{"byIdentity":{},"byOutput":{}}'
files=()
total_bytes=0
shopt -s nullglob
for f in "$profiles_dir"/*.json; do
  [[ -f $f && ! -L $f ]] || continue
  sz=$(wc -c < "$f")
  (( sz <= max_file_bytes )) || continue
  (( total_bytes + sz <= max_total_bytes )) || break
  files+=("$f")
  total_bytes=$((total_bytes + sz))
  (( ${#files[@]} < max_files )) || break
done
if ((${#files[@]})); then
  existing=$(jq -s '
    def merge_settings($m):
      .output = $m.output
      | .mode = (.mode // $m.mode)
      | .position = (.position // $m.position)
      | .scale = (.scale // $m.scale);
    reduce (.[] | .monitors[] | select(type == "object" and .output != null)) as $m
      ({ byIdentity: {}, byOutput: {} };
        (($m.identity // "") | tostring) as $id
        | (if $id != "" then
            .byIdentity[$id] = ((.byIdentity[$id] // {}) | merge_settings($m))
          else
            # Legacy entries without an identity can only be matched by output.
            # Identity-bearing entries are deliberately *not* indexed by output:
            # a different physical monitor that later lands on the same output
            # must not inherit the arrangement of the monitor it replaced.
            .byOutput[$m.output] = ((.byOutput[$m.output] // {}) | merge_settings($m))
          end)
      )
  ' "${files[@]}") || existing='{"byIdentity":{},"byOutput":{}}'
fi

# Settings per connected monitor, preferring saved settings over live state.
# A null saved field never overrides the live value, and live values from a
# disabled monitor ("0x0@60" / "-1x-1") fall back to safe defaults so the
# resulting profile is always applicable.
#
# The identity is only used for matching when it is unique among the connected
# monitors: two identical panels that share a serial (or report none) would
# otherwise steal each other's saved arrangement.
settings=$(printf '%s' "$connected" | jq -c --argjson ex "$existing" '
  def ident:
    ((.description // "") | tostring)
    | gsub("\\s+"; " ")
    | sub("^ "; "")
    | sub(" $"; "");
  . as $all
  | ($all | map(ident)) as $ids
  | ($ids | group_by(.) | map({ key: .[0], value: length }) | from_entries) as $idCounts
  | ([range(0; ($all | length)) as $i
      | $all[$i] as $live
      | $ids[$i] as $id
      | (if $id != "" and $idCounts[$id] == 1 then $ex.byIdentity[$id] else null end) as $byId
      | ($ex.byOutput[$live.name] // {}) as $byOut
      | ($byId // $byOut) as $saved
      | {
          output: $live.name,
          mode: ($saved.mode // (($live.width | tostring) + "x" + ($live.height | tostring) + "@" + (($live.refreshRate + 0.5) | floor | tostring))),
          position: ($saved.position // (($live.x | tostring) + "x" + ($live.y | tostring))),
          scale: ($saved.scale // $live.scale // 1)
        }
        + (if $id != "" and $idCounts[$id] == 1 then { identity: $id } else {} end)
    ])
  | map(.mode = (if (.mode == null or .mode == "0x0@60") then "preferred" else .mode end)
      | .position = (if (.position == null or .position == "-1x-1") then "auto" else .position end)
      | .scale = (.scale // 1))
')

# Write All.json (every connected monitor enabled). The write goes through a
# temp file in the same directory and an atomic rename, so a symlink planted at
# the target can't redirect the write onto another user's file.
all_tmp=$(mktemp "$profiles_dir/.All.json.XXXXXX")
printf '%s' "$settings" | jq '{name: "All", monitors: map(. + {enabled: true})}' > "$all_tmp"
mv -f "$all_tmp" "$profiles_dir/All.json"

# Write one profile per monitor (only that one enabled, the rest disabled).
# The trailing newline matters: command substitution strips it from $names, and
# `read` drops an unterminated last line, which used to lose the final monitor.
while IFS= read -r name; do
  # Only a safe basename may be used as a file name.
  [[ $name =~ ^[A-Za-z0-9._-]+$ ]] || continue
  tmp=$(mktemp "$profiles_dir/.$name.json.XXXXXX")
  printf '%s' "$settings" | jq --arg n "$name" '
    { name: $n, monitors: map(. + {enabled: (.output == $n)}) }
  ' > "$tmp"
  mv -f "$tmp" "$profiles_dir/$name.json"
done < <(printf '%s\n' "$names")

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