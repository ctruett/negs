# Inspector redesign: split into workflow tabs

Replace the current two-tab inspector (Lab / Post) with six tabs in pipeline order. Keep the existing header (export, copy, adjustments icons), histogram and "Reset Adjustments" footer. No control behavior changes — this is a reorganization only. Reference mockup: `inspector-mockup.html` (markup is illustrative; match the app's existing components and styling).

## Tab bar
Segmented control under the histogram, 6 equal tabs, icon above a short label:
Camera · Film · Print · Scan · Finish · Export

Footer gains "‹ Back" / "Next: <tab> ›" buttons above Reset Adjustments that step through the tabs in order.

## Tab contents (in this order)

### 1. Camera
- **Input**: Size (Longest side ▾), Longest side [2048] px, Photograph (read-only dimensions · MP). Footnote: "Resized first, before film simulation, halation and grain."
- **White Balance**: RAW white balance (As Shot ▾) — promoted from the RAW White Balance disclosure.
- **Exposure**: Auto exposure toggle, Metering ▾, Exposure (EV) slider.
- **Lens**: Film format (mm) slider, Lens blur (µm) slider, Lens Diffusion disclosure + toggle.

### 2. Film
- **Film Stock**: Film ▾, Scan film directly toggle (subtitle: "Skips the Print step").
- **Emulsion** (reordered to follow the light path): Halation, Film Curves, DIR Couplers, Grain, Film Base — each disclosure + toggle as today.

### 3. Print
- **Paper**: Paper ▾ (moved out of the old Film & Paper section).
- **Enlarger**: always expanded as its own section (no disclosure) — all current Enlarger options shown inline.
- **Darkroom**: Print Curves, Print Base, Glare.
- When *Scan film directly* is ON: show the tab label dimmed/struck through, skip it in Back/Next, and on the tab show a notice ("Print step is skipped…") with a "Use print instead" button that turns the toggle off. Dim and disable the Print controls.

### 4. Scan
- **Scanner**: always expanded (no disclosure) — all current Scanner options shown inline.
- **Color**: Color Management disclosure.

### 5. Finish (formerly Post)
- **Tone**: Brightness, Contrast, Whites, Blacks, Saturation sliders (Saturation merged into this group). Footnote: "Adjusts the finished scan. To recover a clipped highlight, use Exposure in Camera."
- **Border**: Add border toggle, style picker (Solid / Film / Keyline / 35mm), Width slider, Color swatch, Extend to 3:4 for Instagram toggle.

### 6. Export
- **Output**: Colour space ▾, Encode with the colour space's curve toggle, Include border toggle (moved from Border's "Include in export").
- **Performance**: Limit preview to 12 MP, Use less memory for export.
- Primary "Export Image…" button (same action as the header export icon).

## Notes
- Persist the selected tab per session.
- Existing disclosure rows keep their current expanded contents.
