# MySMC

Native macOS menu bar app for Intel Mac fan control via the System Management Controller (SMC).

![macOS](https://img.shields.io/badge/macOS-10.15%2B-blue) ![Intel](https://img.shields.io/badge/CPU-Intel%20only-lightgrey) ![License](https://img.shields.io/badge/license-GPLv3-green)

---

## Features

- **Menu bar control** — fan speed always visible, profile switching one click away
- **Built-in profiles** — Auto, Quiet, Balanced, Cool, Max
- **Custom fan curves** — piecewise-linear temperature → RPM curves per fan
- **Profile persistence** — last active profile restored automatically on launch
- **Multi-fan support** — each fan uses its own hardware min/max limits
- **Auto root elevation** — shows a standard macOS admin dialog on first launch; no `sudo` needed after install
- **LaunchAgent** — optional auto-start as root on every login

## Requirements

- Intel Mac (SMC fan control is Intel-only; Apple Silicon has no SMC fan keys)
- macOS 10.15 Catalina or later
- Xcode Command Line Tools (`xcode-select --install`)

## Install

### Option A — DMG (recommended)

1. Download `MySMC-v1.0.dmg` from [Releases](https://github.com/longshorepine/opensmcfan/releases)
2. Open the DMG, drag `MySMC.app` anywhere (or run `install.sh`)
3. Double-click `MySMC.app` — it will ask for your password once, then run as root

> **Gatekeeper note:** The app is not code-signed. Right-click → Open on first launch to bypass the warning.

### Option B — Build from source

```bash
git clone https://github.com/longshorepine/opensmcfan.git
cd opensmcfan
make app
open .build/MySMC.app
```

### Option C — Permanent install (auto-starts on every login)

```bash
make app
sudo make install-agent
```

Installs to `/Applications/MySMC.app` and registers a LaunchAgent so it starts as root automatically.

**Uninstall:**

```bash
sudo ./scripts/uninstall.sh
```

## Build

```bash
make          # Build CLI + GUI app
make app      # GUI only → .build/MySMC.app
make cli      # CLI only → .build/mysmc
make package  # DMG → .dist/MySMC-<version>.dmg
make clean
```

No Xcode required — uses `swiftc` directly.

## CLI Usage

```bash
sudo .build/mysmc status
sudo .build/mysmc set 0 3500        # Set fan 0 to 3500 RPM
sudo .build/mysmc auto              # Return all fans to auto
sudo .build/mysmc monitor -i 1      # Live RPM monitor, 1s interval
sudo .build/mysmc profile max       # Apply a named profile
sudo .build/mysmc curve 0 TC0D 40:1200 55:2000 70:4000 85:6200
```

## Architecture

```
Sources/
├── CSMCTypes/      C header — SMCKeyData_t struct (kernel ABI, must be 80 bytes)
├── SMCKit/         IOKit bindings + type codec (sp78, fpe2, flt, ui16)
├── MySMCCore/      Fan, FanController, FanCurve, Profile, ProfileStore,
│                   TemperatureMonitor, ThermalEngine
├── mysmc/          CLI entry point
└── App/            Menu bar app — AppDelegate, StatusBarController,
                    PreferencesWindowController, FanCurveEditorView
Resources/
├── Info.plist              App bundle config
├── AppIcon.icns            App icon
└── com.mysmc.app.plist     LaunchAgent plist
scripts/
├── install.sh
└── uninstall.sh
```

CLI and GUI share `SMCKit` + `MySMCCore`. All Swift files compile as a single flat module per target — no `import SMCKit` needed.

## How fan control works

MySMC writes to the SMC key `F{i}Mn` (fan minimum RPM) to force a floor, combined with `F{i}Md` (forced mode) and `F{i}Tg` (target RPM). This is the same approach used by [smcFanControl](https://github.com/hholtmann/smcFanControl) and is the most reliable method on Intel Macs.

On quit, all fans are returned to automatic control (`F{i}Mn` restored to hardware defaults, `F{i}Md = 0`).

Emergency override: if any sensor reads ≥ 95°C, ThermalEngine forces all fans to maximum regardless of the active profile.

## License

GNU General Public License v3.0 — see [LICENSE](LICENSE).
