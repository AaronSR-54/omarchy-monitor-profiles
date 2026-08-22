#!/bin/bash
# Set the screen color temperature (warmth) via hyprsunset, ensuring the
# service is running first. Mirrors omarchy-toggle-nightlight so the shell's
# nightlight indicator stays in sync.
#
# Usage:
#   set-warmth.sh <temperature-kelvin>
set -euo pipefail

temperature="${1:-}"
if [[ ! $temperature =~ ^[0-9]+$ ]]; then
  echo "usage: set-warmth.sh <temperature-kelvin>" >&2
  exit 1
fi

# Ensure hyprsunset is running.
if ! pgrep -x hyprsunset >/dev/null; then
  setsid uwsm-app -- hyprsunset >/dev/null 2>&1 &
fi

# A freshly-started hyprsunset applies its default temperature at the end of
# its boot, overriding anything set before then — so resend until it sticks.
for _ in {1..10}; do
  hyprctl hyprsunset temperature "$temperature" >/dev/null 2>&1
  sleep 0.2
  current=$(hyprctl hyprsunset temperature 2>/dev/null | grep -oE '[0-9]+' | head -n1)
  if [[ -n $current && $current -ge $((temperature - 15)) && $current -le $((temperature + 15)) ]]; then
    break
  fi
done

omarchy-shell -q nightlight refresh