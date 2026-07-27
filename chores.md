# Chores — Dead Code & Cleanup

Tracked dead code and backend junk found during audit (2026-07-27).
Safe to delete — none are called by any code path.

## Dead Code

*(all cleared)*

## Backend Junk

*(all cleared)*

## Done (already fixed)

- [x] Delete `FanCurveEditorView.swift` — 393 lines, unreferenced after UI rewrite.
- [x] Path traversal in `ProfileStore` — sanitize profile IDs before building file paths (runs as root).
- [x] `fpe2` Int16 → UInt16 — prevent sign-wrap/trap on unsigned 14.2 fixed-point encoding.
- [x] Cache fan max RPMs in `FanController` — eliminates 4 redundant SMC reads per fan per tick.
- [x] `callSMC` error tag `"raw"` → `"iokit"` — write failures no longer say "read failed".
