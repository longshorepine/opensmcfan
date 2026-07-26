# MySMC — Vision & Project Scope

## Overview

MySMC is a native macOS fan control application for Intel Macs, built in **Swift + AppKit**. It replaces the current Python prototype with a compiled, zero-dependency `.app` bundle that lives in the menu bar — comparable to Macs Fan Control but fully open and customizable.

The app reads and writes Apple SMC (System Management Controller) keys via IOKit to give users complete authority over fan behavior, temperature monitoring, and thermal profiles.

### Target Platform

- macOS 10.15 Catalina and later (Intel Macs, pre-T2 and T2)
- Native x86_64 binary, single `.app` bundle
- No runtime dependencies (no Python, no Homebrew, no frameworks to install)

---

## Current State (Python Prototype)

What exists today in `smc_fan_control.py`:

- SMC connection via ctypes → IOKit (`AppleSMC` service)
- Read/write SMC keys with type parsing (`sp78`, `fpe2`, `flt`, `ui8`, `ui16`, `ui32`, `si8`, `si16`, `flag`, `ch8*`)
- 22 known temperature sensor keys (CPU, GPU, memory, ambient, battery, northbridge)
- Fan enumeration via `FNum`, per-fan read of `Ac` (actual), `Mn` (min), `Mx` (max), `Tg` (target)
- Fan write: target RPM (`F{i}Tg`), mode (`F{i}Md`), minimum (`F{i}Mn`)
- CLI commands: `status`, `set`, `auto`, `monitor`, `profile`
- 4 hardcoded profiles: quiet (2000), balanced (3500), cool (5000), max (6200)

### What the Prototype Lacks

- No GUI
- No custom fan curves (only flat RPM profiles)
- No per-fan independent control in profiles
- No temperature-reactive automation
- No persistent settings
- No menu bar integration
- No startup-at-login
- No alert system

---

## Architecture

```
MySMC.app/
├── SMCKit/                        — Low-level SMC layer
│   ├── SMCConnection.swift        — IOKit service open/close, raw read/write
│   ├── SMCTypes.swift             — Struct definitions (SMCKeyData, SMCKeyInfoData, etc.)
│   └── SMCParser.swift            — Type encoding/decoding (sp78, fpe2, flt, etc.)
│
├── Core/                          — Domain logic
│   ├── TemperatureMonitor.swift   — Polls sensors, tracks history, detects spikes
│   ├── Fan.swift                  — Fan model (index, actual, min, max, target, mode)
│   ├── FanController.swift        — Applies RPM targets, manages auto/manual mode
│   ├── FanCurve.swift             — Piecewise-linear curve engine (temp → RPM mapping)
│   ├── Profile.swift              — Named profile with per-fan curves + metadata
│   ├── ProfileStore.swift         — Load/save/import/export profiles (JSON on disk)
│   └── ThermalEngine.swift        — Main loop: read temps → evaluate curves → set fans
│
├── App/                           — GUI layer (AppKit)
│   ├── AppDelegate.swift          — App lifecycle, NSStatusItem setup
│   ├── StatusBarController.swift  — Menu bar icon + dropdown menu
│   ├── MainPopover.swift          — Primary popover panel (dashboard view)
│   ├── FanControlView.swift       — Per-fan sliders, mode toggle, live RPM display
│   ├── FanCurveEditor.swift       — Visual curve editor (the core custom profile UI)
│   ├── ProfileManagerView.swift   — List/create/edit/delete/import/export profiles
│   ├── TemperatureView.swift      — Sensor grid with live readings + sparklines
│   ├── PreferencesWindow.swift    — General settings (polling, startup, alerts)
│   └── AboutWindow.swift          — Version, credits, links
│
├── CLI/                           — Optional CLI target (preserves current functionality)
│   └── main.swift                 — Argument parsing, same commands as Python version
│
├── Resources/
│   ├── Assets.xcassets            — Menu bar icons, app icon
│   └── DefaultProfiles.json       — Ships with quiet/balanced/cool/max
│
└── Info.plist
```

---

## Feature Specification

### 1. Menu Bar App

The app runs as a menu bar agent (LSUIElement = true). No Dock icon.

**Menu bar icon** shows a small fan glyph. Optionally overlays the current hottest temperature as text (e.g., "72°").

**Left-click** opens the main popover dashboard.
**Right-click** opens a quick menu:
- Current temp summary
- Active profile name
- Quick-switch profile list
- Separator
- Preferences...
- Quit

### 2. Dashboard (Main Popover)

The primary interface that appears when clicking the menu bar icon.

#### 2a. Temperature Panel

- Grid of all detected sensors grouped by component:
  - **CPU**: TC0P (proximity), TC0D (die), TC0H (heatsink), TC1C/TC2C/TC3C (per-core), TCGC (GPU compute on CPU die)
  - **GPU**: TG0P, TG0D, TG0H, TG1D, TG1H
  - **Memory**: Tm0P, Tm1P
  - **Heatsink**: Th0H, Th1H, Th2H
  - **Ambient**: TA0P
  - **Battery**: TB0T, TB1T, TB2T
  - **Northbridge**: TN0P
- Each sensor shows: name, friendly label, current °C, small sparkline of last 60 readings
- Hottest sensor highlighted
- User can hide sensors they don't care about (persisted in preferences)

#### 2b. Fan Panel

For each fan detected via `FNum`:

- **Fan name**: "Fan 0 (Left)", "Fan 1 (Right)" — user-renamable
- **Live RPM gauge**: circular or horizontal bar showing actual RPM within min–max range
- **Current values**: Actual RPM, Target RPM, Min RPM, Max RPM
- **Mode toggle**: Auto / Manual
  - Auto: SMC controls fan speed; app only monitors
  - Manual: app controls fan speed via target RPM or fan curve
- **Quick RPM slider** (manual mode): drag to set a flat target RPM, bounded by hardware min/max

#### 2c. Active Profile Indicator

- Shows the currently active profile name and a colored dot (green = auto, yellow = manual flat, blue = curve-controlled)
- Dropdown to switch profiles instantly

### 3. Fan Curve Editor (Custom Profiles)

This is the core differentiator. Users define a **temperature-to-RPM curve** per fan.

#### 3a. Curve Concept

A fan curve is a piecewise-linear function mapping a **reference temperature** (from a chosen sensor or the hottest-of-set) to a **target RPM**.

The curve is defined by **control points** that the user places on a 2D graph:

```
RPM (Y-axis)
 6200 ┤                                          ●━━━━━━━ Max RPM
      │                                       ╱
 5000 ┤                                    ●
      │                                 ╱
 3500 ┤                           ●
      │                        ╱
 2000 ┤              ●━━━━━━●
      │           ╱
 1200 ┤  ●━━━━━●
      │
    0 ┼──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──┬──
       30  35  40  45  50  55  60  65  70  75  80  85  90  95  °C

       ↑                    ↑                          ↑
    Base Temp          Ramp Zone                  Throttle Point
  (fans at idle)    (linear interpolation)     (fans at maximum)
```

#### 3b. Curve Control Points

Each control point is a `(temperature °C, RPM)` pair. The user gets:

- **Minimum 2 points** (base temp → idle RPM, throttle point → max RPM)
- **Up to 8 points** for fine-grained shaping
- **Drag points** on the graph to adjust visually
- **Numeric input** for precise values (text fields beside each point)
- **Add point**: click on the curve to insert a new control point
- **Remove point**: right-click or delete key (cannot remove below 2 points)

#### 3c. Key Parameters per Fan Curve

| Parameter | Description | Default |
|-----------|-------------|---------|
| **Reference Sensor** | Which temperature sensor drives this curve | Hottest CPU sensor |
| **Base Temperature** | Below this temp, fan stays at idle RPM | 40°C |
| **Base RPM** | Fan speed at or below base temperature | Hardware minimum (e.g., 1200 RPM) |
| **Throttle Temperature** | At or above this temp, fan runs at max RPM | 85°C |
| **Throttle RPM** | Fan speed at throttle point | Hardware maximum (e.g., 6200 RPM) |
| **Hysteresis** | Temp must drop this many °C below a point before fan slows down (prevents oscillation) | 3°C |
| **Ramp Rate** | Max RPM change per second (smooths transitions, prevents jarring speed jumps) | 500 RPM/s |
| **Response Delay** | Seconds the temp must stay above a threshold before ramping (filters transient spikes) | 2s |

#### 3d. Curve Editor UI

The editor is a dedicated panel/window with:

1. **Graph area** (main visual):
   - X-axis: Temperature (°C), range from 20°C to 105°C, gridlines every 5°C
   - Y-axis: RPM, range from 0 to hardware max, gridlines every 500 RPM
   - Shaded regions: green (idle zone), yellow (ramp zone), red (throttle zone)
   - Draggable control points (circles) connected by line segments
   - Live temperature indicator: a vertical dashed line showing the current reference temp
   - Live RPM indicator: a horizontal dashed line showing the current actual RPM
   - The intersection shows where the fan "is" on the curve right now

2. **Control point table** (below or beside the graph):
   - Rows of (Temperature, RPM) with editable numeric fields
   - Add / Remove buttons
   - Sort by temperature automatically

3. **Curve settings sidebar**:
   - Reference sensor dropdown
   - Hysteresis slider (0–10°C)
   - Ramp rate slider (100–2000 RPM/s)
   - Response delay slider (0–10s)

4. **Preview**: a "Simulate" toggle that lets the user drag a virtual temperature slider and see what RPM the curve would produce — without actually changing fan speeds

#### 3e. Per-Fan Independence

Each fan in the system gets its own curve within a profile. A profile with 2 fans contains 2 independent curves. The user can:

- Use the same curve for all fans (link mode)
- Set different curves per fan (independent mode) — e.g., left fan follows CPU temp, right fan follows GPU temp

### 4. Profile System

#### 4a. Profile Structure

A profile is a named collection of per-fan configurations:

```json
{
  "name": "Gaming",
  "icon": "flame",
  "description": "Aggressive cooling for GPU-heavy workloads",
  "created": "2026-07-26T12:00:00Z",
  "modified": "2026-07-26T14:30:00Z",
  "fans": [
    {
      "fanIndex": 0,
      "label": "Left Fan",
      "mode": "curve",
      "referenceSensor": "TG0D",
      "curve": [
        { "temp": 40, "rpm": 1200 },
        { "temp": 55, "rpm": 2000 },
        { "temp": 70, "rpm": 4000 },
        { "temp": 80, "rpm": 5500 },
        { "temp": 90, "rpm": 6200 }
      ],
      "hysteresis": 3,
      "rampRate": 500,
      "responseDelay": 2
    },
    {
      "fanIndex": 1,
      "label": "Right Fan",
      "mode": "curve",
      "referenceSensor": "TC0D",
      "curve": [
        { "temp": 35, "rpm": 1200 },
        { "temp": 50, "rpm": 2500 },
        { "temp": 65, "rpm": 4000 },
        { "temp": 80, "rpm": 5000 },
        { "temp": 90, "rpm": 6200 }
      ],
      "hysteresis": 4,
      "rampRate": 400,
      "responseDelay": 3
    }
  ]
}
```

#### 4b. Profile Modes

Each fan within a profile operates in one of three modes:

| Mode | Behavior |
|------|----------|
| **Auto** | SMC controls the fan. App only monitors. |
| **Fixed RPM** | Fan locked to a user-specified RPM. Simple slider. |
| **Curve** | Fan speed follows a temperature-to-RPM curve. Full curve editor. |

#### 4c. Built-in Profiles (Ships with App)

| Profile | Fan Mode | Behavior |
|---------|----------|----------|
| **Auto (System Default)** | Auto | All fans under SMC control. Monitoring only. |
| **Quiet** | Fixed | All fans at minimum RPM. For silent work. |
| **Balanced** | Curve | Gentle ramp: 1200 RPM at 40°C → 3500 RPM at 75°C → max at 90°C |
| **Cool** | Curve | Aggressive ramp: 2000 RPM at 35°C → 5000 RPM at 65°C → max at 80°C |
| **Max** | Fixed | All fans at hardware maximum RPM. |

Built-in profiles cannot be deleted but can be duplicated and customized.

#### 4d. Profile Management

- **Create**: new blank profile or duplicate an existing one
- **Edit**: open curve editor, change name/icon/description
- **Delete**: user-created profiles only (with confirmation)
- **Import/Export**: single profile as `.smcprofile` (JSON) file, for sharing
- **Reorder**: drag to reorder in the quick-switch menu

### 5. Thermal Engine (Background Control Loop)

The core runtime that ties monitoring to fan control.

#### 5a. Loop Architecture

```
Every [polling interval]:
  1. Read all active temperature sensors
  2. For each fan in the active profile:
     a. If mode == Auto   → do nothing (SMC controls)
     b. If mode == Fixed  → write target RPM (only if changed)
     c. If mode == Curve  →
        i.   Get reference sensor reading
        ii.  Apply response delay filter (ignore transient spikes)
        iii. Evaluate curve: interpolate (temp → target RPM)
        iv.  Apply hysteresis (only ramp down if temp dropped enough)
        v.   Apply ramp rate (limit RPM change per tick)
        vi.  Write target RPM to SMC
  3. Update UI (dashboard, menu bar temp display)
  4. Check alert thresholds → fire notifications if exceeded
  5. Append to history buffer (for sparklines)
```

#### 5b. Polling Interval

- Default: 2 seconds
- Configurable: 1s – 10s
- Adaptive option: poll faster (1s) when temps are above 70°C, slower (5s) when idle

#### 5c. Safety Measures

- **Never write below hardware minimum** (`F{i}Mn`): clamp all targets to the SMC-reported minimum
- **Never exceed hardware maximum** (`F{i}Mx`): clamp all targets to the SMC-reported maximum
- **Watchdog**: if the app crashes or is force-quit, fans revert to SMC auto control (write `F{i}Md = 0` on app termination, and register a `SIGTERM`/`SIGINT` handler)
- **Emergency override**: if any sensor exceeds 95°C, force all fans to maximum regardless of profile, and show a critical alert
- **Failsafe on sensor loss**: if reference sensor becomes unreadable, fall back to hottest available sensor or switch to auto mode

### 6. Alerts & Notifications

- **High temperature warning**: configurable threshold (default 85°C), sends macOS notification
- **Critical temperature alert**: 95°C, forces max fans + persistent notification
- **Fan failure detection**: if a fan reports 0 RPM when target > 0 for more than 10 seconds, alert the user
- **Fan speed anomaly**: if actual RPM deviates from target by more than 30% for extended period
- All alerts are optional and individually toggleable in preferences

### 7. Preferences

#### General
- Polling interval (1s – 10s slider)
- Start at login (toggle, implemented via SMLoginItemSetEnabled or LaunchAgent)
- Show temperature in menu bar (toggle)
- Menu bar display: hottest temp / specific sensor / fan RPM
- Temperature unit: °C / °F

#### Sensors
- Show/hide individual sensors from the dashboard
- Rename sensors with friendly names (e.g., TC0D → "CPU Die")
- Set which sensors appear in the menu bar

#### Fans
- Rename fans (e.g., Fan 0 → "Left Exhaust")

#### Alerts
- Enable/disable each alert type
- Temperature thresholds for warnings
- Notification style (macOS notification center, sound, both)

#### Advanced
- Reset all fans to auto on quit (toggle, default: on)
- Emergency max threshold (default: 95°C)
- Log SMC reads/writes to file (for debugging)

### 8. CLI Target (Optional)

Preserve the current CLI functionality as a separate build target within the same Xcode project. Same SMCKit core, no GUI dependency.

Commands (matching current Python interface):

```
mysmc status              — Show all temps and fan speeds
mysmc set <fan> <rpm>     — Set fan target RPM
mysmc auto <fan>          — Reset fan to automatic mode
mysmc monitor [-i 2]      — Live terminal monitor
mysmc profile <name>      — Apply a named profile
mysmc profile --list      — List available profiles
mysmc curve <fan> <sensor> <t1:rpm1> <t2:rpm2> ...  — Set a curve from CLI
```

---

## Implementation Phases

### Phase 1 — SMCKit (Core Foundation)
Port the Python SMC class to Swift. IOKit bindings, read/write, type parsing. Unit-testable with no GUI dependency.

### Phase 2 — Thermal Engine
Fan model, temperature monitor, fan curve evaluation, profile loading/saving, control loop. All headless — can be validated via CLI.

### Phase 3 — CLI Target
Swift CLI that wraps the thermal engine. Feature parity with the Python prototype. Validates that the core works before building UI.

### Phase 4 — Menu Bar App Shell
NSStatusItem, popover, basic dashboard showing live temps and fan speeds. Read-only — no fan control yet in GUI.

### Phase 5 — Fan Control UI
Fan sliders, mode toggles (auto/manual/curve), apply RPM changes. Profiles list with quick-switch.

### Phase 6 — Fan Curve Editor
The visual curve editor: draggable control points on a temp-vs-RPM graph, numeric inputs, hysteresis/ramp-rate/delay controls, simulation mode.

### Phase 7 — Profiles & Persistence
Full profile CRUD, import/export, built-in profiles, JSON storage in `~/Library/Application Support/MySMC/`.

### Phase 8 — Alerts, Preferences & Polish
Notification system, preferences window, start-at-login, sensor renaming, menu bar customization.

### Phase 9 — Distribution
Code signing, notarization, DMG packaging, auto-update (Sparkle framework or manual check).

---

## Data Storage

All persistent data lives in `~/Library/Application Support/MySMC/`:

```
~/Library/Application Support/MySMC/
├── profiles/
│   ├── auto.json
│   ├── quiet.json
│   ├── balanced.json
│   ├── cool.json
│   ├── max.json
│   └── gaming.json          (user-created)
├── preferences.json
└── history.log              (optional debug log)
```

---

## Non-Goals (Out of Scope)

- Apple Silicon support (M1/M2/M3 — different thermal architecture, no user-accessible SMC fan keys)
- Windows/Linux support
- Kernel extension or driver-level modifications
- Overclocking or voltage control
- App Store distribution (requires sandboxing that blocks IOKit SMC access)
