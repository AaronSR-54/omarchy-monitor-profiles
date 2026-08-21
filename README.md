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
- **Automatic centering** — whenever a scale changes or a profile is applied, monitor positions are recomputed so the layout stays centered: enabled monitors remain horizontally adjacent (the leftmost keeps its `x`) and their vertical centers are aligned (the tallest keeps its `y`).
- **Horizontal profile switcher** — every profile in `~/.config/omarchy/monitor-profiles/` as a pill. Click one to apply it.
- **Graphical layout preview** — instead of a text list, the applied profile is drawn as an interactive canvas: each enabled monitor is a rectangle at its relative logical size and position. With several monitors active you can **drag them to reposition**; dropping saves the new position (no recentering) and reloads Hyprland. A `⟳ CENTRAR` button restores the centered layout.
- **Edit button** — an `✎ EDITAR MONITORS.LUA` button below the preview opens `monitors.lua` in the editor (no more implicit shortcut on the preview card).
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
- `mode`, `position`, `scale` — monitor settings. `position` is a hint: it is recomputed automatically so the layout stays centered.
- `scale` is per monitor and is kept in sync across all profiles when you change it from the panel.

### Selecting a profile

Left-click the display icon in the bar to open the panel, then click a profile. Applying a profile rewrites the managed `-- >>> aaronsr.monitor managed <<<` block in `~/.config/hypr/monitors.lua` and reloads Hyprland.

### Optional keybinding

You can summon the selector from the keyboard — the panel opens focused on the active profile, each press advances the selection, and Enter applies:

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + SHIFT + P", "Monitor profiles", "omarchy-shell omarchy.monitor step")
```

### Helpers

The plugin ships four scripts (installed next to `Panel.qml`):

- `apply-profile.sh <name>` — rewrite the managed block in `monitors.lua` from a profile and reload. Set `OMARCHY_SKIP_CENTER=1` to preserve manual positions.
- `list-profiles.sh` — print all profiles as a JSON array (used by the panel).
- `set-scale.sh <monitor> <scale|up|down>` — set one monitor's scale, keep every profile in sync, and re-apply the active profile. Called without a monitor, it targets the focused monitor.
- `set-position.sh <monitor> <x> <y>` — set one monitor's position in the active profile and re-apply it without recentering (used by the drag-to-reposition canvas).
- `center-layout.sh <profile.json>` — recompute a profile's positions so the layout stays centered.

## License

MIT. Derived from the `omarchy.monitor` panel (MIT, © Omarchy).