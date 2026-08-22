#!/usr/bin/env python3
"""Generate a per-monitor warmth screen shader for Hyprland.

Reads a JSON map of output name -> warmth percent and the currently
connected monitors (hyprctl), then emits a GLSL screen shader that tints
each monitor by its color temperature. Hyprland exposes the monitor id as
the `wl_output` uniform, so one screen shader can apply a different warmth
per output.

Usage: generate-warmth-shader.py <state-file> <shader-file>
"""
import json
import math
import subprocess
import sys

COOL_TEMP = 6500
WARM_TEMP = 2700


def clamp(x, lo, hi):
    return max(lo, min(hi, x))


def gains_for_temp(temp_kelvin):
    """Per-channel color gains for a blackbody temperature, relative to 6500K.

    Uses Tanner Helland's temperature->RGB approximation (temperature/100).
    Gains are rgb(T) / rgb(6500) so 6500K is a neutral (1, 1, 1).
    """
    t = temp_kelvin / 100.0
    if t <= 66.0:
        r = 255.0
        g = 99.4708025861 * math.log(t) - 161.1195681661
        b = 0.0 if t <= 19.0 else 138.5177312231 * math.log(t - 10.0) - 305.0447927307
    else:
        r = 329.698727446 * math.pow(t - 60.0, -0.1332047592)
        g = 288.1221695283 * math.pow(t - 60.0, -0.0755148492)
        b = 255.0
    return (clamp(r, 0.0, 255.0) / 255.0,
            clamp(g, 0.0, 255.0) / 255.0,
            clamp(b, 0.0, 255.0) / 255.0)


def temp_for_percent(p):
    return round(COOL_TEMP - (p / 100.0) * (COOL_TEMP - WARM_TEMP))


def main():
    if len(sys.argv) != 3:
        print("usage: generate-warmth-shader.py <state-file> <shader-file>", file=sys.stderr)
        return 1

    state_path = sys.argv[1]
    out_path = sys.argv[2]

    try:
        with open(state_path, "r", encoding="utf-8") as f:
            state = json.load(f)
    except (OSError, ValueError):
        state = {}

    try:
        monitors = json.loads(subprocess.check_output(["hyprctl", "-j", "monitors"]))
    except (subprocess.CalledProcessError, ValueError):
        monitors = []

    branches = []
    for m in monitors:
        name = m.get("name", "")
        mid = m.get("id", -1)
        pct = clamp(int(state.get(name, 0) or 0), 0, 100)
        if pct <= 0 or mid < 0:
            continue  # neutral monitor: the shader's default passthrough covers it
        rg, gg, bg = gains_for_temp(temp_for_percent(pct))
        branches.append("  if (wl_output == %d) {\n"
                        "    c = vec4(c.r * %.3f, c.g * %.3f, c.b * %.3f, c.a);\n"
                        "  }" % (mid, rg, gg, bg))

    shader = [
        "#version 320 es",
        "precision highp float;",
        "uniform sampler2D tex;",
        "uniform int wl_output;",
        "in vec2 v_texcoord;",
        "out vec4 fragColor;",
        "",
        "void main() {",
        "  vec4 c = texture(tex, v_texcoord);",
    ]
    if branches:
        shader.append("")
        shader.extend(branches)
    shader.extend([
        "  fragColor = c;",
        "}",
        "",
    ])

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("\n".join(shader))

    return 0


if __name__ == "__main__":
    sys.exit(main())