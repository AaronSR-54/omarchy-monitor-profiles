#!/bin/bash
# Recompute a profile's monitor positions so the layout stays centered:
# - enabled monitors stay horizontally adjacent (leftmost monitor keeps its x)
# - their vertical centers are aligned (tallest enabled monitor keeps its y)
# - disabled monitors are left untouched
set -euo pipefail

file="${1:?usage: center-layout.sh <profile.json>}"
[[ -f $file ]] || exit 0

# An enabled monitor without a concrete mode/position can't be measured; leave
# the layout as-is rather than erroring out (apply-profile fills safe defaults).
if jq -e 'any(.monitors[]; .enabled and (.mode == null or .position == null))' "$file" >/dev/null 2>&1; then
  exit 0
fi

tmp=$(mktemp)
jq '
  def compute:
    map(. as $e |
      {
        key: $e.key,
        enabled: $e.value.enabled,
        mode: $e.value.mode,
        scale: ($e.value.scale // 1),
        position: $e.value.position,
        w: (($e.value.mode | split("@")[0] | split("x")[0]) | tonumber) / ($e.value.scale // 1),
        h: (($e.value.mode | split("@")[0] | split("x")[1]) | tonumber) / ($e.value.scale // 1),
        x: (($e.value.position | split("x")[0]) | tonumber),
        y: (($e.value.position | split("x")[1]) | tonumber)
      });

  def layout_enabled:
    sort_by(.x) as $s
    | ($s | map(.h) | max) as $maxh
    | ($s | map(select(.h == $maxh)) | .[0]) as $anchor
    | ($s[0].x) as $x0
    | reduce range(0; ($s | length)) as $i ([]; . + [
        $s[$i] as $m |
        {
          key: $m.key,
          x: if $i == 0 then $x0 else ($s[0:$i] | map(.w) | add) + $x0 end,
          y: ($anchor.y + ($anchor.h - $m.h) / 2 | round)
        }
      ]);

  . as $orig
  | ([$orig.monitors | to_entries[] | select(.value.enabled)] | compute | layout_enabled) as $laid
  | .monitors |= (
      [range(0; length) as $i |
        $orig.monitors[$i] as $m |
        if $m.enabled then
          ($laid | map(select(.key == $i)) | .[0]) as $r |
          $m + { position: (($r.x | tostring) + "x" + ($r.y | tostring)) }
        else
          $m
        end
      ]
    )
' "$file" > "$tmp" && mv "$tmp" "$file"