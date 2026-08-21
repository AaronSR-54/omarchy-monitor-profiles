# Display & profiles

A bar widget for the Omarchy shell that adds a **hyprmoncfg monitor profile switcher** to the display panel.

## Requirements

- **hyprmoncfg** (required) — this widget lists and applies your saved hyprmoncfg profiles. The profiles come from hyprmoncfg's own profile store (`~/.config/hyprmoncfg/profiles/`), so you need hyprmoncfg installed and at least one profile saved.
  - Project: [github.com/crmne/hyprmoncfg](https://github.com/crmne/hyprmoncfg) · [hyprmoncfg.dev](https://hyprmoncfg.dev/)
  - On Arch: `omarchy pkg aur add hyprmoncfg` (or install the `hyprmoncfg` AUR package)
- The Omarchy shell with the built-in bar (Quickshell).
- Hyprland (obviously).

> If hyprmoncfg is not installed, the profiles section stays empty; the panel still offers the standard display controls (brightness, text size, scale).

## Features

- **Brightness, text-size, and scale controls** — inherited from the `omarchy.monitor` panel.
- **Horizontal profile switcher** — every saved hyprmoncfg profile as a pill. Click one to apply it (`hyprmoncfg apply <name>`).
- **Applied-profile preview** — a card showing the active profile's monitors (resolution, position), disabled outputs dimmed. Click it to open the hyprmoncfg TUI.
- **Keyboard navigation** — j/k move between sections, h/l walk the profiles, Enter applies the selected profile, Esc closes.

## Install

Once listed on the marketplace, install from there. To install from a git URL:

```bash
omarchy plugin add <this-repo-url> --enable --yes
omarchy bar move aaronsr.monitor --section right
```

## Usage

Left-click the display icon in the bar to open the panel, then click a profile to switch. Profiles are applied with no revert window by default; to enable hyprmoncfg's confirmation/revert, set `confirmTimeout` (seconds) on the widget's layout entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "aaronsr.monitor", "confirmTimeout": 10 }
```

### Optional keybinding

You can summon the selector from the keyboard — the panel opens focused on the active profile, each press advances the selection, and Enter applies:

```lua
-- ~/.config/hypr/bindings.lua
o.bind("SUPER + SHIFT + P", "Monitor profiles", "omarchy-shell omarchy.monitor step")
```

## License

MIT. Derived from the `omarchy.monitor` panel (MIT, © Omarchy) and integrates with [hyprmoncfg](https://github.com/crmne/hyprmoncfg) (MIT).