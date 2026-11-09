# Lab Scanner Looks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every scan goes through a simulated Fuji Frontier or Noritsu, which inverts negatives, auto-corrects each frame and applies a colour look fitted to Color Precision's studio chart scans; Paper print stays a separate output.

**Architecture:** A new `lab_scan` stage replaces `stages::scanning` on the film-scan route:
1. **Scanner densities.** It reads the developed film's spectral density through Status M into RGB densities, using a 3D LUT over CMY, and subtracts the film base.
2. **Auto correction.** It normalises each channel with a per-frame auto balance, metered and pinned like auto exposure, then adds the operator keys.
3. **Look.** It applies each scanner's look for the film type: a per-channel curve and a 3×3 matrix in log space.

The look's numbers live in `data/scanners/*.toml` and come from a committed Python fitting tool that renders the charts through the CLI.

**Tech Stack:** Rust (spektrafilm-core, -native, -cli), SwiftUI (macos/), Python 3 with numpy, scipy and imageio for fitting.

**Spec:** `docs/superpowers/specs/2026-11-08-lab-scanner-looks-design.md`

## Global Constraints

- **Scanners:** `frontier` (default) or `noritsu`. There's no "None".
- **Outputs:** Lab scan and Paper print don't overlap. Lab scan never uses paper. Paper print has no scanner and renders exactly as today, bit for bit.
- **Looks:** one transform per scanner per film type (colour negative, slide, B&W), shared by every film. No per-film terms.
- **Greys:** a neutral grey card comes out neutral on colour films, on both scanners.
- **B&W:** keeps its tint. The auto correction balances density only, never colour.
- **Data:** studio images stay out of the repository. Only fitted numbers and the report are committed.
- **Held-out frames:** −1 and +2 EV of every film, plus all of Portra 800 and UltraMax 400.
- **Target:** beat the current route on held-out frames, aiming for a mean hue error of ≤ 6° per scanner and film type.
- **Python parity:** tests are Paper-print or upstream-scan only, and must stay green.
- **Git:** `HANDOFF.md` stays uncommitted. Push only when asked.

### Route key (the user's call: use the new key)

`io.output_route` (`lab_scan` | `paper_print`) is the source of truth.

**Reading old edits.** `io.scan_film` is kept only as a legacy input. When `output_route` is missing, it's inferred in the same pass as `infer_input_interpretation`: `scan_film: true` gives `lab_scan`, and anything else gives `paper_print`.

**What new edits write.** They write `output_route` and stop writing `scan_film`. Serialising skips it.

**Engine reads.** `IoParams::scans_film(&self) -> bool` returns `output_route == LabScan || settings.upstream_film_scan`. It replaces every engine read of `io.scan_film` (the list from `rg scan_film crates`).

**Presets.** `simulation.route` maps to and from `output_route`.

**The app.** It reads and writes `io.output_route`, and the CLI's `--scan-film` sets it.

The user-facing name is "Output: Lab scan / Paper print". The other new key is `scanner.model`.

## Review Focus

1. **A frame that's almost one colour** (a sunset, a blue sky, a black frame). The auto balance mustn't blow up or go NaN. It meters a trimmed mean, clamps the correction, and falls back to neutral when there's too little signal. Task 3 tests a uniform red frame and an all-black frame.
2. **Preview, export and zone readout must agree.** The balance is metered once on the metering preview and pinned, never metered per tile or crop size. Task 3 tests that a 1/4-size render and a full-size render give the same balance. Task 4 tests that `zones::readout` uses the photo's balance.
3. **Picking a negative film after a slide.** The route mustn't silently flip. Only a positive forces Lab scan, since Paper print can't take a slide. Task 6 tests that choosing Portra after Provia keeps Lab scan, and keeps Paper print when it was set.
4. **Old edits and presets.** Missing `scanner.model` reads as Frontier. Missing keys read as 0. A paper edit renders identically to before. Task 2 tests deserialisation. Task 4 tests that a Paper-print render is byte-identical to `main`'s.
5. **The GPU resident chain.** It would silently render the old film scan. Task 4 tests that the lab-scan route never takes it: the output differs from the upstream scan, and is identical whatever the backend.

---

### Task 1: Status M scanner densities

**Files:**
- Create: `data/scanners/status_m.json`
- Create: `crates/spektrafilm-core/src/lab_scan/mod.rs` and `density.rs`
- Modify: `crates/spektrafilm-core/src/lib.rs` (add `pub mod lab_scan;`)
- Test: `crates/spektrafilm-core/tests/lab_scan.rs`

**Interfaces:**
- Produces:
  - `lab_scan::density::Sensitivity::load(data_dir: &Path) -> Result<Sensitivity, String>`, with 3 rows of 81 weights on 380–780 nm in 5 nm steps, each row summing to 1
  - `lab_scan::density::DensityLut::new(film: &Profile, params: &RuntimeParams, sens: &Sensitivity) -> DensityLut`
  - `DensityLut::net(&self, cmy: [f64; 3]) -> [f64; 3]`: the RGB scanner density above the film base
  - `DensityLut::apply(&self, img: &ImageBuf) -> ImageBuf`
- `apply` is per pixel: tetrahedral lookup, using the LUT grid and `scanner_lut_bounds` pattern from `stages/scanning.rs`, at `params.settings.lut_resolution`.

- [x] **Step 1:** `data/scanners/status_m.json` is already committed. It holds ISO 5-3:1984 Table 4, transcribed from the standard and checked against the rendered page:
  - Each row has `start_nm`, a 10 nm step, its `log_product` values and its edge slopes.
  - Rows: blue 410–510, green 470–610, red 620–770.
  - `Sensitivity::load` extends each row beyond its range at the stated slopes, interpolates linearly in log onto 380–780 nm in 5 nm steps, and turns the result into linear weights with `10^x`.
  - Test that load gives each row its peak at the tabulated 5.000 (blue 450, green 540, red 640).
- [ ] **Step 2: Write the failing tests** in `tests/lab_scan.rs`:
  - `base_has_zero_net_density`: `lut.net([0.0;3])` is within 1e-6 of `[0,0,0]` for `kodak_portra_400`, which uses `bases::film_base_density`.
  - `density_rises_with_dye`: on Portra, `net([0.5,0.5,0.5])` is greater than `net([0.25,0.25,0.25])` on every channel.
  - `bw_film_reads_near_neutral`: on `kodak_trix`, `net([1.0;3])` has a channel spread of less than 0.08.
- [ ] **Step 3: Run the tests.**
  - Run: `cargo test --release -p spektrafilm-core --test lab_scan`
  - Expected: FAIL (module missing).
- [ ] **Step 4: Implement it.**
  - Spectral density is `Σ cmy_i·channel_density_i(λ) + base(λ)`.
  - The signal is `S_c = Σ 10^(−D(λ))·w_c(λ)`, and the scanner density is `D_c = −log10 S_c`, minus the same quantity computed for the bare base.
  - Use f64 throughout.
- [ ] **Step 5: Check the tests pass** (same command). Expected: PASS.
- [ ] **Step 6: Commit:** "Read a developed film through Status M, as a lab scanner's sensor does".

### Task 2: Scanner parameters and route semantics

**Files:**
- Modify: `crates/spektrafilm-core/src/params.rs` (`ScannerParams`)
- Modify: `crates/spektrafilm-core/src/presets.rs`
- Test: inline `#[cfg(test)]` in `params.rs` and `presets.rs`

**Interfaces:**
- Produces `OutputRoute { LabScan, PaperPrint }` (snake_case serde) as `IoParams.output_route`, and `IoParams::scans_film()`. Replace every engine read of `io.scan_film` with it, in core, native, cli and gpu param builders.
- Produces new `ScannerParams` fields, all `#[serde(default)]`:
  - `model: ScannerModel` (`Frontier` by default, `Noritsu`), serialised lowercase
  - `density_key: f32`, `cyan_key: f32`, `magenta_key: f32`, `yellow_key: f32`, each in key steps from −20 to +20
- Produces `pub const KEY_STEP_LOG10: f64 = 0.025;` in `lab_scan/mod.rs`. One click is 0.025 log₁₀, about 1/12 stop.
- Key directions follow the labs. A positive density key makes the scan darker. A positive C, M or Y key adds that colour.

- [ ] **Step 1: Write the failing tests:**
  - `output_route_inferred_from_scan_film`: `{"io":{"scan_film":true}}` gives `LabScan`, while `{}` and `{"io":{"scan_film":false}}` give `PaperPrint`. Serialising gives `output_route` and no `scan_film`.
  - `scans_film_follows_route`: `scans_film()` is true for `LabScan`, false for `PaperPrint`, and true for `PaperPrint` when `settings.upstream_film_scan` is set.
  - `old_params_read_as_frontier_with_no_keys`: `{}` gives `model == Frontier` and every key 0.
  - `noritsu_round_trips`: `{"scanner":{"model":"noritsu"}}` serialises back to `"noritsu"`.
  - `preset_exports_scanner_keys`: the preset state written for a Lab-scan edit holds `negs.scanner.model` and the four keys, and reading it back restores them. Follow how Negs's own keys are already exported in `presets.rs`.
  - `paper_preset_has_no_scanner`: a Paper-print preset doesn't write `negs.scanner.*`.
- [ ] **Step 2: Run the tests** to see them fail: `cargo test --release -p spektrafilm-core params:: presets::`
- [ ] **Step 3: Implement it**, then run the tests again. Expected: PASS.
- [ ] **Step 4: Commit:** "Scanner model and operator keys".

### Task 3: Frame auto correction

**Files:**
- Create: `crates/spektrafilm-core/src/lab_scan/balance.rs`
- Modify: `crates/spektrafilm-core/src/pipeline.rs`. Add `with_lab_balance` and `lab_balance` next to `with_autoexposure_ev` and `autoexposure_ev` (around line 302).
- Test: `crates/spektrafilm-core/tests/lab_scan.rs`

**Interfaces:**
- Consumes `DensityLut` (Task 1).
- Produces `lab_scan::balance::Balance { offset: [f64; 3] }`, the log₁₀ value subtracted per channel so the frame's neutral lands at the look's reference.
- Produces `balance::meter(net: &ImageBuf, film_type: FilmType) -> Balance`, where `FilmType` is `ColourNegative`, `Slide` or `BlackAndWhite`, taken from the profile's `info.type`.
- Produces `Pipeline::lab_balance(&self, preview: &ImageBuf) -> Balance`, which films, develops and reads the metering preview on the CPU, as `autoexposure_ev` does.
- Produces `Pipeline::with_lab_balance(self, b: Balance) -> Self`.

How metering works:
- For each channel, take the mean of the net density over the 5th–95th percentile of that channel, with negatives inverted. These are the per-channel offsets.
- For colour, each channel's offset is limited to ±0.6 log₁₀ around their mean, which keeps strong casts in check.
- For B&W, all three offsets equal the mean of the three, so the tint is kept.
- If fewer than 1% of pixels have a net density above 0.02, the frame is too thin to judge. Use the type's default offsets: the trained mean, kept in the look file (Task 4) and 0 until it's fitted.

- [ ] **Step 1: Write the failing tests:**
  - `grey_frame_balances_neutral`: a uniform 18% grey through Portra gives offsets whose spread equals the spread of `net` at that grey, within 1e-6.
  - `red_frame_stays_finite_and_bounded`: a uniform pure red gives finite offsets, each within 0.6 of their mean.
  - `black_frame_falls_back`: an all-zero input gives the default offsets, with no NaN.
  - `bw_keeps_tint`: on Tri-X the three offsets are equal.
  - `balance_ignores_render_size`: `lab_balance` on the same preview gives equal results whether the pipeline later renders at 1/4 size or full size, because it's metered only from the preview.
- [ ] **Step 2: Run them to see them fail:** `cargo test --release -p spektrafilm-core --test lab_scan`
- [ ] **Step 3: Implement it**, then run again. Expected: PASS.
- [ ] **Step 4: Commit:** "Auto colour correction per frame, with B&W balanced for density only".

### Task 4: Scanner looks and the lab-scan route

**Files:**
- Create: `crates/spektrafilm-core/src/lab_scan/look.rs`
- Create: `data/scanners/frontier.toml` and `data/scanners/noritsu.toml`
- Modify: `crates/spektrafilm-core/src/pipeline.rs`:
  - the route around lines 906 and 978 (`process_taps`)
  - skip `try_gpu_resident` when `io.scans_film()`
- Modify: `crates/spektrafilm-core/src/zones.rs` (`Pointwise::new` takes `Option<Balance>`)
- Modify: `crates/spektrafilm-core/src/lut_export.rs`. It meters a uniform 18% grey frame, and names the LUT `<film>_<scanner>`.
- Modify: `crates/spektrafilm-core/src/color_reference.rs`. No B&W/slide luminance remap on the lab-scan route; the filming exposure correction stays.
- Modify: `crates/spektrafilm-native/src/main.rs`. Meter the balance with auto exposure, cache it under the same key, and pass it to the pipeline and `zone_readout`.
- Modify: `crates/spektrafilm-cli/src/main.rs`. Add `--scanner frontier|noritsu`; `--scan-film` stays as the route switch.
- Modify: the tests that pin `scan_film`'s old output (`lut_export.rs`, `colorspaces.rs` and the like). Re-point upstream-parity cases to a hidden `settings.upstream_film_scan: bool` (default false) that keeps the old `stages::scanning` path for parity only.
- Test: `crates/spektrafilm-core/tests/lab_scan.rs`

**Interfaces:**
- Consumes `DensityLut`, `Balance`, `ScannerParams` and `KEY_STEP_LOG10`.
- Produces a look file shaped like this, one table per type, with three curve rows:
  ```toml
  [colour_negative]          # also [slide] and [bw]
  curve_knots = [...]        # 9 shared x positions, log10 units
  curve = [[...],[...],[...]]
  matrix = [[1,0,0],[0,1,0],[0,0,1]]
  default_offset = [0,0,0]
  cast = [0,0,0]             # bw only: log10 tint added after the curve
  ```
  The curve is a monotone cubic (Fritsch–Carlson). Its output is log₁₀ linear light. The matrix applies after the curve, in log space, with rows summing to 1 so it keeps greys.
- Produces `look::Look::load(data_dir, model, film_type) -> Result<Look, String>` and `Look::apply(log_rgb: [f64;3]) -> [f64;3]`.
- Produces `lab_scan::process(filmed: ImageBuf, film: &Profile, params: &RuntimeParams, balance: &Balance, data_dir: &Path, gamut: &OutputGamutCompress) -> ImageBuf`. Per pixel it does: net density, sign (negative +, slide −), minus `offset`, plus keys × `KEY_STEP_LOG10`, then the look, then `10^x` into linear Rec.2020. After that it converts to the output space, compresses the gamut and encodes, reusing `scanning::convert_output` and `encode_output`.
- The initial look files are hand-set so the route already gives a correctly inverted, neutral image before fitting:
  - linear curves of slope −1 for negatives (+1 for slides) through the reference grey at log₁₀ 0.18
  - identity matrices
  - zero casts

- [ ] **Step 1: Write the failing tests:**
  - `negative_is_inverted`: through Portra, a brighter input patch gives a brighter output.
  - `grey_card_is_neutral`: an 18% grey on Portra, Frontier and Noritsu gives an output whose R, G and B are within 0.5% of each other.
  - `keys_move_the_scan`: `density_key = 4` makes the grey darker. `yellow_key = 4` raises R+G against B.
  - `paper_print_unchanged`: a Paper-print render of `tests/fixtures`' reference image is byte-identical to a golden made from `main` before this task. Create the golden in Step 0 and commit it.
  - `lab_scan_skips_resident_chain`: the lab-scan output on the default backend equals the CPU backend's, within 1/255.
  - `zone_readout_uses_photo_balance`: `zones::readout` with the photo's balance equals what the full render gives on that pixel, within 0.5 L*.
- [ ] **Step 2: Run them to see them fail:** `cargo test --release -p spektrafilm-core --test lab_scan`
- [ ] **Step 3: Implement it.**
- [ ] **Step 4: Run everything:** `cargo test --release -p spektrafilm-core -p spektrafilm-io -p spektrafilm-native`. Expected: all pass, Python parity included.
- [ ] **Step 5: Commit:** "Lab scan route: Frontier and Noritsu invert, balance and render each frame".

### Task 5: Fitting tool and the fitted looks

**Files:**
- Create: `scripts/lab_scan/charts.py`. It holds the Digital SG (140) and Passport (24) published L\*a\*b\* D50 values, a `locate(img) -> (sg_boxes, passport_boxes)` that matches a template inside a fixed search window, and `sample(img, boxes) -> linear sRGB means`.
- Create: `scripts/lab_scan/render.py`:
  - builds the chart image as reflectances under D65 (one patch per square, as `experimental/chart/reference_chart.png` is laid out)
  - renders it through `target/release/spektrafilm process --scan-film --scanner M --film F`, with a `--params` JSON carrying the exposure and the look under test as `settings.lab_look_override`, a path to a temp TOML that `Look::load` prefers when set
- Create: `scripts/lab_scan/fit.py`:
  - `--scanner frontier|noritsu --type colour_negative|slide|bw`
  - fits curve knots and matrix (or the cast, for B&W) with `scipy.optimize.least_squares` on the training split
  - writes the TOML
- Create: `scripts/lab_scan/report.py`. It writes `docs/lab-scan-accuracy.md`: mean hue error (°) and mean OKLab ΔE ×100 per film, scanner and exposure, before (the hand-set looks) and after, with the held-out rows marked.
- Create: `scripts/lab_scan/README.md`, with the commands and the data paths (`experimental/studio`, not in the repository).
- Delete: `crates/spektrafilm-core/examples/grey_wedge.rs` and `slide_chroma.rs`. Fold any logic still needed into `report.py` (the grey-neutrality check from −6 to +6 EV).
- Modify: `data/scanners/frontier.toml` and `noritsu.toml`, with the fitted values.

**Interfaces:**
- Consumes the CLI flags from Task 4 and `settings.lab_look_override` (add it to `params.rs` in this task, `Option<String>`, skipped when serialising if `None`).
- The film map from `index.csv` names to Negs profiles is a dict in `charts.py`, holding exactly the spec's 12 films.
- Metrics follow the Portra fit (`fit.py` backed up at `$CLAUDE_JOB_DIR/tmp/fit.py.bak`):
  - normalise both sides per channel on the neutral patches
  - compare in OKLab
  - hue error is on patches with chroma > 0.02
- Residuals also include the grey patches' L, so the curve is fitted.

- [ ] **Step 1: Write the test.** `scripts/lab_scan/test_charts.py` checks that `locate` finds both charts on 3 sample frames (Frontier and Noritsu, colour and B&W), and that the sampled Passport white is brighter than its black. Run it: `python3 -I -m pytest scripts/lab_scan -q`. Expected: FAIL.
- [ ] **Step 2: Implement** `charts.py`, then run the test again. Expected: PASS.
- [ ] **Step 3: Implement** `render.py`, `fit.py` and `report.py`. Run the "before" report.
- [ ] **Step 4: Fit the six looks**, scanners × types: `python3 -I scripts/lab_scan/fit.py --scanner frontier --type colour_negative`, and so on.
- [ ] **Step 5: Write the "after" report.**
  - Gate: on held-out frames, every scanner and type beats "before" and the current direct-scan route.
  - Report whether each meets the ≤ 6° aim. A miss is recorded, not hidden.
- [ ] **Step 6:** Run `cargo test --release -p spektrafilm-core --test lab_scan`. The grey-card neutrality test must still pass with the fitted looks.
- [ ] **Step 7: Commit:** "Fit Frontier and Noritsu looks to the studio chart scans", with the TOMLs, scripts and report, and no images.

### Task 6: The app: Output, Scanner and keys

**Files:**
- Modify: `macos/Sources/NegsApp/Inspector.swift`:
  - Film tab: remove the "Scan film directly" toggle.
  - Print tab, top: an **Output** segmented control, Lab scan or Paper print. On Lab scan the tab shows only an `InkNote`, "Lab scans don't use paper", and the Paper card and print controls are hidden.
  - Scan tab: a new **Lab Scanner** section, first in the tab and shown only on Lab scan. It has a Frontier/Noritsu segmented control and Density, Cyan, Magenta and Yellow steppers or sliders from −20 to +20 in steps of 1, with ⌥-click to reset. The section is hideable and movable like the others (`InkSection` with a key).
- Modify: `macos/Sources/NegsApp/EditorModel.swift`:
  - `pairFilm` and `reset`: a positive film forces `io.output_route = "lab_scan"`, while a negative keeps the current value. On a positive, the Output control shows Paper print disabled, with a help tag.
  - New photos default to `io.output_route = "lab_scan"`.
  - Subtitle and `stock`: `"\(filmName) → Frontier"` on Lab scan.
  - The LUT name uses the scanner.
- Modify: `macos/Sources/NegsApp/Previews.swift:34`, the same pairing rule.
- Modify: `macos/Sources/NegsApp/Engine.swift:354`, which passes `--scanner`.
- Test: `macos/Tests/NegsTests/LabScanTests.swift`

**Interfaces:**
- Consumes the param paths `io.output_route` (replacing every app read and write of `io.scan_film`), `scanner.model`, `scanner.density_key`, `scanner.cyan_key`, `scanner.magenta_key` and `scanner.yellow_key`.
- Batch edit and paste carry the scanner keys like other params. Unlike Zone Shift, they aren't per photo.

- [ ] **Step 1: Write the failing tests:**
  - `testNewPhotoDefaultsToLabScanOnFrontier`
  - `testPickingNegativeAfterSlideKeepsLabScan`
  - `testPickingNegativeKeepsPaperPrintWhenSet`
  - `testPositiveFilmForcesLabScan`
  - `testOldDirectScanEditOpensAsFrontierLabScan`
  - `testSubtitleNamesScanner`
- [ ] **Step 2: Run them to see them fail:** `cd macos && swift test --filter LabScanTests`
- [ ] **Step 3: Implement it**, then run `swift test`. Expected: all pass, apart from the known flaky `testAFrameComesBackFromTheDiskAfterARestart`, which passes on a rerun.
- [ ] **Step 4:** Build release and launch, as in `HANDOFF.md` ("Build and run"), for the user to look at.
- [ ] **Step 5: Commit:** "Output choice of Lab scan or Paper print, with Frontier and Noritsu and the lab's keys".
