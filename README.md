# Display & profiles

A bar widget for the Omarchy shell that adds a **native monitor profile switcher** to the display panel. Selecting a profile rewrites the managed block in `~/.config/hypr/monitors.lua`, enabling/disabling the chosen monitors, and reloads Hyprland. No hyprmoncfg.

![Display & profiles](screenshots/preview.png)

## Requirements

- The Omarchy shell with the built-in bar (Quickshell).
- Hyprland.
- `jq`.

## Install (copy & paste)

```bash
# 1. Add the plugin from git (enables it automatically)
omarchy plugin add https://github.com/AaronSR-54/omarchy-monitor-profiles --enable --yes

# 2. Place it in the bar
omarchy bar move aaronsr.monitor --section right

# 3. Reload the shell so the widget appears
omarchy restart shell

# 4. Nothing else — the profiles are generated automatically from the monitors
#    you have connected (one per monitor, plus "All").
```

That's it — the bar now shows the display widget. Open it by left-clicking the monitor icon. The profile switcher lists one entry per connected monitor (e.g. `DP-1`, `DP-2`) plus `All`, Windows-style: pick "only this monitor" or "both".

## Profiles

Profiles are plain JSON files in `~/.config/omarchy/monitor-profiles/`. They are **generated automatically** from the connected monitors, so you normally don't need to touch them. Existing per-monitor settings (position, scale, mode) are preserved when they regenerate.

If you want to hand-tune one, the format is:

```json
{
  "name": "All",
  "monitors": [
    { "output": "DP-1", "enabled": true, "mode": "2560x1440@120", "position": "1979x-100", "scale": 1 },
    { "output": "DP-2", "enabled": true, "mode": "1920x1080@60", "position": "59x80", "scale": 1 }
  ]
}
```

Find your monitor names and modes with `hyprctl monitors`.

- `output` — the Hyprland monitor name.
- `enabled` — whether the monitor is active in this profile.
- `mode`, `position`, `scale` — monitor settings. `scale` is per monitor and is kept in sync across all profiles when you change it from the panel.
- `position` is a hint for the initial arrangement: applying a profile from the panel centers the layout, while positions you set by dragging (and save) are kept as-is.

## Features

- **Brightness, text-size, and scale controls** — inherited from the `omarchy.monitor` panel.
- **Per-monitor scale** — the scale slider (and `SUPER+/` / `SUPER+ALT+/`) changes the scale of the focused monitor only, and persists it in every profile plus `monitors.lua`.
- **Horizontal profile switcher** — one pill per connected monitor plus `All` (auto-generated, Windows-style); click to apply.
- **Graphical layout preview** — the applied profile is drawn as an interactive canvas on a subtle grid. Each monitor is a rectangle at its relative logical size and position, labelled with its output, physical name, resolution, refresh rate and position. With several monitors active you can **drag them to reposition**:
  - **Magnet snapping** — on drop, the monitor glues to the nearest one along the side you released it (keeping your offset on the other axis, no forced centering) and never overlaps another.
  - **Explicit save** — dragging only updates the draft. Press **SAVE** to write the positions and apply, or **DISCARD** to revert.
  - The dragged monitor stays above the others while you move it.
- **Keyboard navigation** — j/k move between sections, h/l walk the profiles, Enter applies, Esc closes.

## Optional keybindings

```lua
-- ~/.config/hypr/bindings.lua

-- Open the profile selector focused on the active profile; each press
-- advances the selection, Enter applies.
o.bind("SUPER + SHIFT + P", "Monitor profiles", "omarchy-shell omarchy.monitor step")

-- Per-monitor scaling on the focused monitor.
hl.unbind("SUPER + SLASH")
o.bind("SUPER + SLASH", "Monitor scaling up", "bash -c '\"$HOME/.config/omarchy/plugins/aaronsr.monitor/set-scale.sh\" up'")
hl.unbind("SUPER + ALT + SLASH")
o.bind("SUPER + ALT + SLASH", "Monitor scaling down", "bash -c '\"$HOME/.config/omarchy/plugins/aaronsr.monitor/set-scale.sh\" down'")
```

## License

MIT. Derived from the `omarchy.monitor` panel (MIT, © Omarchy).