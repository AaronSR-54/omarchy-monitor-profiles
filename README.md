# Display & profiles

A bar widget for the Omarchy shell that adds a **native monitor profile switcher** to the display panel. Selecting a profile rewrites the managed block in `~/.config/hypr/monitors.lua`, enabling/disabling the chosen monitors, and reloads Hyprland. No hyprmoncfg.

## Requirements

- The Omarchy shell with the built-in bar (Quickshell).
- Hyprland (obviously).
- `jq` (used by the helper scripts).

Profiles are plain JSON files under `~/.config/omarchy/monitor-profiles/`. See the example profiles in `profiles/`.

## Features

- **Brightness, text-size, and scale controls** — inherited from the `omarchy.monitor` panel.
- **Per-monitor scale** — the scale slider (and the `SUPER+/` / `SUPER+ALT+/` keybinds) changes the scale of the focused monitor only, and persists it in every profile plus `monitors.lua`. Different monitors can have different scales.
- **Horizontal profile switcher** — every profile in `~/.config/omarchy/monitor-profiles/` as a pill. Click one to apply it.
- **Graphical layout preview** — the applied profile is drawn as an interactive canvas on a subtle grid: each enabled monitor is a rectangle at its relative logical size and position, labelled with its output, physical name (`make + model`), resolution, refresh rate and position. With several monitors active you can **drag them to reposition**:
  - **Magnet snapping** — on drop, the monitor glues to the nearest one along the side you released it (keeping your offset on the other axis, no forced centering) and never overlaps another; a small screen dropped on top of a big one is pushed out, not hidden.
  - **Explicit save** — dragging only updates the draft. Press **SAVE** to write the positions into the active profile and apply, or **DISCARD** to revert. Nothing is applied while you are still arranging.
  - The dragged monitor stays above the others while you move it.
- **Keyboard navigation** — j/k move between sections, h/l walk the profiles, Enter applies the selected profile, Esc closes.

## Install

Once listed on the marketplace, install from there. To install from a git URL:

```bash
omarchy plugin add <this-repo-url> --enable --yes
omarchy bar move aaronsr.monitor --section right
```

## Usage

### Profiles

Create JSON profiles in `~/.config/omarchy/monitor-profiles/`. Each file:

```json
{
  "name": "All",
  "monitors": [
    { "output": "DP-1", "enabled": true, "mode": "2560x1440@120", "position": "1979x-100", "scale": 1 },
    { "output": "DP-2", "enabled": true, "mode": "1920x1080@60", "position": "59x80", "scale": 1 }
  ]
}
```

- `output` — the Hyprland monitor name (`hyprctl monitors`).
- `enabled` — whether the monitor is active in this profile.
- `mode`, `position`, `scale` — monitor settings.
- `scale` is per monitor and is kept in sync across all profiles when you change it from the panel.
- `position` is a hint for the initial arrangement: when a profile is applied from the panel the layout is centered, but positions you set by dragging (and saving) are kept as-is.

### Selecting a profile

Left-click the display icon in the bar to open the panel, then click a profile. Applying a profile rewrites the managed `-- >>> aaronsr.monitor managed <<<` block in `~/.config/hypr/monitors.lua` and reloads Hyprland.

### Optional keybindings

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

### Helpers

The plugin ships scripts (installed next to `Panel.qml`):

- `apply-profile.sh <name> [--positions <json>]` — rewrite the managed block in `monitors.lua` from a profile and reload. Pass `--positions` (a JSON array of `{"output","x","y"}`) to save manual positions without recentering; set `OMARCHY_SKIP_CENTER=1` for the same without the JSON.
- `list-profiles.sh` — print all profiles as a JSON array (used by the panel).
- `set-scale.sh <monitor> <scale|up|down>` — set one monitor's scale, keep every profile in sync, and re-apply the active profile. Called without a monitor, it targets the focused monitor.
- `set-position.sh <monitor> <x> <y>` — set one monitor's position in the active profile and re-apply it without recentering (used by the drag-to-reposition canvas).
- `center-layout.sh <profile.json>` — recompute a profile's positions so the layout stays centered (used when applying a profile from the panel).

## License

MIT. Derived from the `omarchy.monitor` panel (MIT, © Omarchy).