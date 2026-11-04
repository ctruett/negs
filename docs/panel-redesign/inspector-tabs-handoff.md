# Inspector redesign: six workflow tabs — completed handoff

**Status:** implemented 3 November 2026.

- Code: `feat/inspector-tabs` at `f495fd5`, worktree `/Users/christophertruett/Public/negs-inspector-tabs`.
- Base: `main` (`2caecdf`) plus the earlier nine inspector commits.
- This document is tracked on `profile/agfa-apx25`; the feature branch does not carry `docs/panel-redesign`.

## What shipped

### Tab bar
The inspector has six equal tabs under the histogram, in light order:
**Camera · Film · Print · Scan · Finish · Export**.
The selected tab persists for the session and across photographs. While *Scan film directly* is on, Print is dimmed/struck through and its controls are disabled. The footer Back/Next buttons from the original brief were removed at the user's request; **Reset Adjustments** remains pinned below the form.

### Camera
- Input Colour (non-RAW) or RAW White Balance.
- Exposure: Auto exposure, metering, Exposure (EV).
- Lens: **Film format menu** (110, Half frame, 35 mm (135), 6×4.5 / 6×6, 6×7, 6×9, 4×5, Custom), lens blur, lens corrections, Lens Diffusion.
- Image Size was **moved out of Camera** into Export.

### Film
- Film Stock picker / preview grid, Development, Scan film directly.
- Emulsion groups in light order: Halation, Film Curves, DIR Couplers, Grain, Film Base.

### Print
- Paper, Enlarger (always expanded, with Print Diffusion), Darkroom (Print Curves, Print Base, Glare).
- While scanning film directly: “Print step is skipped” notice and **Use print instead**.

### Scan
- Scanner controls.
- **Detail → Midtone Detail** (`prep.midtone_detail`), new in this branch.
- Color Management.

### Finish
- Tone: Brightness, Contrast, Whites, Blacks, Saturation.
- Border: style, width, colours, Instagram extension.

### Export / Output
- **Image Size** first: Original / Longest side, pixel field, photograph dimensions/MP, limit warning.
- File format, bit depth, JPEG quality.
- Output colour space, curve encoding, include border.
- Export engine, export size, performance, and **Export Image…**.

### Toolbar
Two native `NSToolbarItemGroup`s, expanded/momentary, so the icons share rounded capsules like a native app:
- **View:** Open, Film Strip, Fit, Actual Size, Rotate, Crop.
- **Actions:** Export, Presets, Adjustments.
- Crop mode inserts Cancel/Done beside Actions and disables Export there.

### Viewer
Fit never enlarges past 1:1; double-click toggles fit/1:1; the fit or 1:1 setting persists across photographs; custom viewer background and small-window inspector minimums remain from the earlier commits.

## Engine work for Detail
- Ported the upstream scene-prep filter (`crates/spektrafilm-core/src/prep.rs` and `prep/guided.rs`).
- Added `prep: PrepParams` to `RuntimeParams`; Prep is applied in `stages::filming::expose` after input decoding and exposure compensation.
- Added `prep` to the preset KEPT list.
- The GPU-resident fast path falls back to the CPU chain when Prep is non-identity; fast export with Detail is therefore CPU-only for now.
- Only `prep.midtone_detail` is exposed in the app; the other Prep controls remain at their defaults.
- Film format already had engine support; the menu writes `camera.film_format_mm` (Custom long edge range 4…120).

## Validation at handoff
- `swift build` passes.
- `swift test`: **127 tests, 7 skipped, 0 failures**.
- `cargo test -p spektrafilm-core --lib`: **90 passed, 0 failed**.
- `cargo test -p spektrafilm-core --lib prep`: **9 passed**.
- Release `spektrafilm-native` and `spektrafilm-f64` rebuilt for the new Prep parameter.
- The layout test now pins `inspectorPane` to Adjustments (and restores it), because a previously open Presets pane leaves no inspector scroll view.

## Known issue at handoff
The native toolbar capsules are macOS chrome for the **key window**. The layout test explicitly calls `NSApp.activate`/`makeKeyAndOrderFront` and is 1100×860, so its capsules render strongly. A real build launched from Terminal can be inactive and render the same grouped toolbar flat/grey; comparisons showed the app window was not frontmost. The app and test use the same `EditorWindowController`; there is no test-only toolbar implementation. Verify the real window is key first. If it still differs when key, the next step is a custom persistent capsule background for the group (rather than relying on system active-window chrome).

## Original brief (historical)
Replace the two-tab inspector with six tabs, keep the histogram and Reset Adjustments, and reorganise existing controls without changing behavior. Mockup: `inspector-mockup.html`. The implementation above supersedes the brief's Back/Next footer and Camera Image Size placement.
