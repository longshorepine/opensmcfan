# MySMC

Native macOS fan control app for Intel Macs. Reads/writes Apple SMC via IOKit.

## Build

```bash
make            # Build both CLI + GUI app
make cli        # Build CLI only → .build/mysmc
make app        # Build GUI only → .build/MySMC.app
make clean      # Remove build artifacts
make install    # Copy CLI to /usr/local/bin/mysmc
make install-app # Copy app to /Applications/MySMC.app
make run-app    # Build + launch GUI app (sudo)
```

- No Xcode required — uses `swiftc` directly via Makefile
- Swift 5.3+ (ships with Command Line Tools on Catalina)
- Package.swift exists for SPM but SPM requires full Xcode (`xctest`); use Makefile instead

## Run

```bash
sudo .build/mysmc status       # SMC access requires root
sudo .build/mysmc set 0 3500
sudo .build/mysmc auto
sudo .build/mysmc monitor -i 1
sudo .build/mysmc profile balanced
sudo .build/mysmc curve 0 TC0D 40:1200 55:2000 70:4000 85:6200
```

## Architecture

```
Sources/
├── CSMCTypes/          C header — SMCKeyData struct (80 bytes, kernel ABI)
├── SMCKit/             IOKit bindings + type codec (sp78, fpe2, flt, etc.)
├── MySMCCore/          Domain: Fan, FanCurve, FanController, Profile,
│                       ProfileStore, TemperatureMonitor, ThermalEngine
├── mysmc/              CLI entry point
└── App/                GUI: AppDelegate, StatusBarController,
│                       DashboardViewController (popover), PreferencesWindowController,
│                       FanCurveEditorView
Resources/
└── Info.plist          App bundle config (LSUIElement=true, no Dock icon)
```

CLI and GUI are separate build targets sharing SMCKit + MySMCCore.
All Swift files compile as a single module via `-import-objc-header`.
No cross-module imports — everything is flat within one module per target.

## Key Files

- `Sources/CSMCTypes/include/smc_types.h` — C structs MUST match kernel ABI (80 bytes for SMCKeyData_t). Do not change field order or types.
- `Sources/SMCKit/SMCConnection.swift` — IOKit calls. Selector `2` = kSMCHandleYPCEvent. data8 values: `5`=read, `6`=write, `9`=keyinfo.
- `Sources/MySMCCore/FanCurve.swift` — Piecewise-linear interpolation. Points auto-sort by temperature.
- `Sources/MySMCCore/ThermalEngine.swift` — GCD timer loop. Emergency override at 95°C.
- `vision.md` — Full project scope, feature specs, and implementation phases.

## Gotchas

- **SMC access requires root** — all read/write operations go through IOKit which needs elevated privileges
- **No async/await** — Swift 5.3 on Catalina; use GCD (DispatchQueue/DispatchSourceTimer)
- **Single module build** — do NOT use `import SMCKit` or `import MySMCCore` in source files; the bridging header + flat compilation handles everything
- **Struct layout matters** — `SMCKeyData_t` is defined in C to guarantee kernel-compatible memory layout. A pure Swift struct risks alignment differences.
- **Fan RPM encoding** — fans use `fpe2` format (14.2 fixed point): `rawValue = rpm * 4.0`
- **Temperature encoding** — most sensors use `sp78` format (signed 7.8 fixed point): `rawValue = celsius * 256.0`

## Code Style

- Swift source, no third-party dependencies
- Public API on types that will be consumed by the GUI layer (Phase 4+)
- Codable structs for anything persisted to JSON (profiles, fan curves)
- Error handling: SMCError enum with localized descriptions

## Commit Convention

- Write descriptive commit messages: summary line + blank line + body explaining what and why
- End every commit with: `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`
- Stage specific files (`git add <file>...`), never `git add -A`
- Verify build compiles (`make`) before committing

## Self-Test & Audit Checklist

Before committing changes, verify:

1. **Build** — `make clean && make` must succeed with zero warnings
2. **CLI smoke test** — `sudo .build/mysmc --help` prints usage
3. **Struct size** — if touching `smc_types.h`, verify `sizeof(SMCKeyData_t) == 80`
4. **Type codec** — if changing SMCParser, verify encode/decode roundtrips for sp78, fpe2, flt
5. **Fan safety** — all RPM writes MUST clamp to hardware min/max (`F{i}Mn` / `F{i}Mx`)
6. **Emergency override** — ThermalEngine must force max fans if any sensor >= 95°C
7. **Auto-reset on quit** — engine stop must reset fans to auto mode (FanMode 0)

## Project Phase

Current: **Phase 6 complete** (Preferences window with Monitor/Profiles tabs, fan curve editor, lightweight popover)
Next: **Phase 7** — Profile persistence (save/load custom profiles to ~/Library/Application Support/MySMC/)
See `vision.md` for full 9-phase roadmap.
