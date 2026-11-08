# RPP-style Colour Finishing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Scan › Tone gets RPP's per-channel Contrast, a chroma-only Saturation in OKLab, and a new halo-resistant Local Contrast.

**Architecture:** Post (`crates/spektrafilm-core/src/post.rs`) stays a tabulated per-pixel pass, applied on the CPU by `PostProcess::apply_rgb` and on the GPU by `display_post.wgsl` with the same tables. Contrast moves from the luminance table to a new per-channel table. Saturation moves to OKLab. Local Contrast is a new whole-image stage in a new `local_contrast.rs`, run by `Pipeline::apply_post` before the per-pixel pass. While it's on, the GPU display path stands down.

**Tech Stack:** Rust (spektrafilm-core, spektrafilm-gpu, WGSL), Swift/SwiftUI (macOS app).

**Spec:** `docs/superpowers/specs/2026-11-08-rpp-colour-finishing-design.md`

## Global Constraints

- Sliders: Contrast and Saturation keep `-100…100`; `post.local_contrast` is `0…100`, default 0.
- Contrast pivot: `PIVOT = 0.461_356` (sRGB-encoded middle grey, already in `post.rs`).
- Saturation: `C = 248.4375`. A positive slider maps to `s = 0.621 × slider`, `k = C / (C − 2s)`, so +100 gives 2.0. A negative slider gives `k = 1 + slider/100`, so −100 is grey. Only OKLab a and b are scaled.
- Local contrast: `k = amount/100 + 0.1`. A positive `L − blur` is damped by `3/7`. The radius grows with the amount.
- Old edits get the new behaviour. There is no compatibility path.
- The CPU and the GPU display pass agree within one 8-bit step (`tests/display_post.rs`).
- Every Post change keeps black at black and white at white, and every curve keeps rising.

## Review Focus

1. Contrast at ±100 on pure black (0) and pure white (1) must give exactly 0 and 1, with no NaN. RPP's curve turns white into NaN with negative contrast. Covered by a test in Task 1.
2. Saturation +100 on a saturated primary in a wide space (ProPhoto) must stay inside [0, 1] with its hue and OKLab L unchanged. Covered by a test in Task 2.
3. Local Contrast on an image smaller than its radius (for example 3 × 2 pixels) must not panic and must leave a flat field unchanged. Covered by a test in Task 4.
4. Local Contrast must look the same in the preview and the export: the same edit on a picture and on that picture at half size gives the same overshoot, as a share of the edge. Covered by a test in Task 4.
5. With Local Contrast on, the GPU display path must not show a frame without it. Covered by a test in Task 4.

---

### Task 1: Per-channel contrast

**Files:**
- Modify: `crates/spektrafilm-core/src/post.rs` (`tone`, `PostProcess`, `apply_rgb`, the module doc)
- Test: `crates/spektrafilm-core/src/post.rs` (`mod tests`)

**Interfaces:**
- Produces: `fn contrast_curve(contrast: f32, e: f64) -> f64` (encoded → encoded). `PostProcess` gains a field `channel: Vec<f32>` (linear channel → linear channel, sampled on √x) and replaces `tone` with two luminance tables, `tone: Vec<f32>` (Brightness) and `levels: Vec<f32>` (Whites, Blacks, then the `AnchorCurve`), both sampled on √Y. Task 3 mirrors these tables.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn contrast_keeps_its_ends_and_rises() {
    for c in [-100.0, -40.0, 0.0, 40.0, 100.0] {
        assert_eq!(contrast_curve(c, 0.0), 0.0);
        assert_eq!(contrast_curve(c, 1.0), 1.0);
        assert!((contrast_curve(c, PIVOT) - PIVOT).abs() < 1e-12);
        let mut last = 0.0;
        for i in 1..=1000 { let v = contrast_curve(c, i as f64 / 1000.0); assert!(v.is_finite() && v >= last); last = v; }
    }
    let slope = |c| (contrast_curve(c, PIVOT + 1e-6) - contrast_curve(c, PIVOT - 1e-6)) / 2e-6;
    assert!((slope(100.0) - 2.0).abs() < 1e-3);
    assert!((slope(-100.0) - 0.25).abs() < 1e-3);
}

#[test]
fn contrast_makes_a_darkened_colour_richer() {
    let post = PostProcess::new(&PostParams { contrast: 60.0, ..Default::default() }, false, "sRGB");
    let skin = [0.30f32, 0.18, 0.12]; // linear, below middle grey
    let out = post.apply_rgb(skin);
    let ratio = |c: [f32; 3]| c[0] / c[2];
    assert!(out[1] < skin[1], "darker");
    assert!(ratio(out) > ratio(skin), "the channels spread apart");
}
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `cargo test --release -p spektrafilm-core --lib post::tests::contrast_`
Expected: FAIL, because `contrast_curve` isn't defined.

- [ ] **Step 3: Implement**

Use RPP's curve, rewritten so it pivots at `PIVOT`. It keeps 0 and 1, rises for every `B > 0`, and has slope `B` at the pivot:

```rust
fn contrast_curve(contrast: f32, e: f64) -> f64 {
    let c = contrast as f64 / 100.0;
    let b = if c < 0.0 { 1.0 + 0.75 * c } else { 1.0 + c };
    if e <= 0.0 { return 0.0; }
    if e >= 1.0 { return 1.0; }
    PIVOT.powf((e.ln() / PIVOT.ln()).powf(b))
}
```

Drop the contrast blend from `tone()`, and split what's left:
- `tone` = Brightness on luminance.
- `levels` = Whites and Blacks, then `AnchorCurve::map_luminance`.

The `channel` table is `srgb_decode(contrast_curve(c, srgb_encode(s*s)))`.

The order in `apply_rgb`:
1. Decode.
2. Brightness through `tone`, scaling R, G and B by `y2 / y` and keeping the existing "above white" pull-in.
3. Each channel through `channel`.
4. Luminance through `levels`, scaling R, G and B again.
5. Saturation, still the existing code until Task 2.
6. Encode.

Update the module doc. "Each pixel keeps its colour ratios, so contrast doesn't shift the film's hues" is no longer true for Contrast.

- [ ] **Step 4: Run the Post tests**

Run: `cargo test --release -p spektrafilm-core --lib post`
Expected: PASS. If an existing test asserted the old ratio-keeping contrast, change its expectation to the new behaviour (the user's decision), and don't delete it.

- [ ] **Step 5: Commit**

```bash
git add crates/spektrafilm-core/src/post.rs
git commit -m "Contrast bends each channel, as RPP's does, so darkened tones get richer"
```

### Task 2: Chroma saturation in OKLab

**Files:**
- Modify: `crates/spektrafilm-core/src/post.rs`
- Test: `crates/spektrafilm-core/src/post.rs` (`mod tests`)

**Interfaces:**
- Consumes: the `PostProcess` from Task 1.
- Produces: `fn chroma_scale(saturation: f32) -> f32`. `PostProcess` gains `to_xyz: [[f32; 3]; 3]` and `from_xyz: [[f32; 3]; 3]`, the output space's matrices from `RgbColourspace::output(color_space)`. `saturation` now holds `chroma_scale(params.saturation)`, not `params.saturation / 100`. Task 3 relies on all three.

- [ ] **Step 1: Write the failing tests**

```rust
#[test]
fn the_chroma_scale_follows_rpp() {
    assert_eq!(chroma_scale(0.0), 1.0);
    assert!((chroma_scale(100.0) - 2.0).abs() < 1e-4);
    assert_eq!(chroma_scale(-100.0), 0.0);
    assert!((chroma_scale(-50.0) - 0.5).abs() < 1e-6);
    assert!(chroma_scale(50.0) < 1.5, "gentle at first, then rising faster");
}

#[test]
fn saturation_keeps_oklab_lightness_and_hue_and_stays_in_gamut() {
    for space in ["sRGB", "ProPhoto RGB"] {
        for s in [-100.0, 40.0, 100.0] {
            let post = PostProcess::new(&PostParams { saturation: s, ..Default::default() }, false, space);
            for rgb in [[0.8f32, 0.3, 0.1], [0.05, 0.6, 0.9], [0.95, 0.02, 0.9]] {
                let (before, after) = (post.oklab(rgb), post.oklab(post.apply_rgb(rgb)));
                assert!((before[0] - after[0]).abs() < 2e-3, "{space} {s} lightness");
                assert!(post.apply_rgb(rgb).iter().all(|v| (0.0..=1.0).contains(v)));
                if s > -100.0 {
                    let hue = |c: [f32; 3]| c[2].atan2(c[1]);
                    assert!((hue(before) - hue(after)).abs() < 2e-3, "{space} {s} hue");
                }
            }
        }
    }
}
```

`fn oklab(&self, linear: [f32; 3]) -> [f32; 3]` is a `pub(crate)` helper on `PostProcess`. Write it as part of Step 3.

- [ ] **Step 2: Run them to make sure they fail**

Run: `cargo test --release -p spektrafilm-core --lib post::tests::the_chroma post::tests::saturation_keeps_oklab`
Expected: FAIL, because `chroma_scale` and `oklab` don't exist.

- [ ] **Step 3: Implement**

- **`chroma_scale`:** follow Global Constraints.
- **`oklab` and its inverse:** output-space linear RGB → XYZ (`to_xyz`) → OKLab, using Björn Ottosson's published M1 and M2 matrices, and back. Take XYZ as the space gives it, with no chromatic adaptation.
- **In `apply_rgb`:** this replaces the old saturation step.
  1. Convert to OKLab and scale a and b by `k`.
  2. If any channel then leaves [0, 1], bisect `k'` in `[1, k]` for 12 steps, keeping the largest `k'` that stays in gamut. Do the same in `[k, 1]` when `k < 1`.
  3. Clamp to [0, 1].
- **Docs:** update the doc of `saturation` on `PostParams` to say chroma in OKLab.

- [ ] **Step 4: Run the Post tests**

Run: `cargo test --release -p spektrafilm-core --lib post`
Expected: PASS. If the existing tests `saturation_keeps_luminance_and_greys` and the ProPhoto monochrome test assert the old luminance-weighted grey, assert equal OKLab L instead.

- [ ] **Step 5: Commit**

```bash
git add crates/spektrafilm-core/src/post.rs
git commit -m "Saturation scales chroma in OKLab, as RPP scales it in Lab, and never moves lightness"
```

### Task 3: The GPU display pass matches

**Files:**
- Modify: `crates/spektrafilm-gpu/src/lib.rs` (`DisplayPost`)
- Modify: `crates/spektrafilm-gpu/src/wgpu_backend.rs:1968-1990` (`post_buffers`: the `Post` uniform and the tables)
- Modify: `crates/spektrafilm-shaders/wgsl/display_post.wgsl`
- Modify: `crates/spektrafilm-core/src/post.rs` (`PostProcess::display`)
- Test: `crates/spektrafilm-core/tests/display_post.rs`

**Interfaces:**
- Consumes: from Tasks 1 and 2, the `PostProcess` fields `tone`, `channel`, `levels`, `to_xyz`, `from_xyz`, and `saturation` holding the chroma scale.
- Produces: `DisplayPost { luma, saturation /* the chroma scale k */, encoded, decode, encode, tone, channel, levels, to_xyz: [[f32;3];3], from_xyz: [[f32;3];3] }`. The `Post` uniform gains the two matrices as three `vec4<f32>` rows each. `post_tables` holds five tables in this order: decode 0, encode 1, tone 2, channel 3, levels 4.

- [ ] **Step 1: Write the failing test**

Add these cases to `display_post_matches_the_cpu`, using the file's `post(...)` helper:
- `post(0.0, 100.0, 0.0, 0.0, 0.0)`
- `post(0.0, -100.0, 0.0, 0.0, 0.0)`
- `post(0.0, 0.0, 0.0, 0.0, 100.0)` on the saturated image (already there)
- `post(30.0, 60.0, 10.0, -10.0, 80.0)`

- [ ] **Step 2: Run it to make sure it fails**

Run: `cargo test --release -p spektrafilm-core --test display_post`
Expected: FAIL: the GPU still applies the old contrast and saturation (bytes differ by more than one step).

- [ ] **Step 3: Implement**

Mirror `apply_rgb` in `post_rgb` step for step, including the 12-step bisection and its `f32` arithmetic. Extend `post_buffers` and `PostProcess::display` to carry the new fields.

- [ ] **Step 4: Run it to make sure it passes**

Run: `cargo test --release -p spektrafilm-core --test display_post && cargo test --release -p spektrafilm-core --lib post`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/spektrafilm-gpu crates/spektrafilm-shaders crates/spektrafilm-core
git commit -m "The display pass applies the new contrast and saturation as the CPU does"
```

### Task 4: Local Contrast

**Files:**
- Create: `crates/spektrafilm-core/src/local_contrast.rs`
- Modify: `crates/spektrafilm-core/src/lib.rs` (add `pub mod local_contrast;`)
- Modify: `crates/spektrafilm-core/src/post.rs` (`PostParams.local_contrast`)
- Modify: `crates/spektrafilm-core/src/pipeline.rs:800-812` (`apply_post`) and `:997` (`display_on_gpu`)
- Test: `crates/spektrafilm-core/src/local_contrast.rs` (`mod tests`), plus one test in `pipeline.rs`'s tests

**Interfaces:**
- Consumes: `PostProcess::oklab` and its inverse from Task 2. Expose both as `pub(crate)` free functions taking the matrices, so this module can use them without a `PostProcess`.
- Produces:
  - `pub fn apply(image: &mut ImageBuf, amount: f32, encoded: bool, color_space: &str)`;
  - `PostParams.local_contrast: f32` (`#[serde(default)]`, 0…100).

- [ ] **Step 1: Write the failing tests**

```rust
#[test] fn a_flat_field_is_untouched_at_any_size() {
    for (w, h) in [(3, 2), (40, 30)] {
        let mut img = flat(w, h, 0.4);
        let before = img.data.clone();
        apply(&mut img, 100.0, true, "sRGB");
        assert!(img.data.iter().zip(&before).all(|(a, b)| (to_f32(*a) - to_f32(*b)).abs() < 1e-5));
    }
}
#[test] fn dark_detail_is_lifted_more_than_light_detail() {
    // A step edge from 0.3 to 0.7, encoded: the overshoot on the dark side,
    // as a share of the step, beats the light side's by about 7:3.
    let (dark_overshoot, light_overshoot) = edge_overshoots(200, 100, 60.0);
    assert!(dark_overshoot > 1.8 * light_overshoot && light_overshoot > 0.0);
}
#[test] fn the_effect_scales_with_the_picture() {
    let full = edge_overshoots(400, 200, 60.0);
    let half = edge_overshoots(200, 100, 60.0);
    assert!((full.0 - half.0).abs() < 0.15 * full.0);
}
#[test] fn the_display_pass_stands_down_while_it_is_on() {
    // in pipeline.rs tests: a Pipeline with post.local_contrast = 40 reports
    // display_on_gpu(&backend) == false for any backend.
}
```

`flat` and `edge_overshoots(w, h, amount) -> (f32, f32)` are test helpers. `edge_overshoots` builds a vertical step edge and returns the most-below-0.3 and most-above-0.7 values after `apply`, each divided by the step.

- [ ] **Step 2: Run them to make sure they fail**

Run: `cargo test --release -p spektrafilm-core --lib local_contrast`
Expected: FAIL, because the module doesn't exist.

- [ ] **Step 3: Implement**

`apply`, with nothing to do at amount 0:
1. Decode the image, and convert it to OKLab with the output space's matrices.
2. Blur L with three box passes, separable, in rayon chunks. The radius in pixels is `max(1, round((amount / 100) × 0.02 × min(w, h)))`. That's RPP's amount × radius, with a base of 2 % of the shorter side at 100 (designer's call).
3. `d = L − blur`. If `d > 0`, multiply it by `3/7`. Then `L' = L + (amount/100 + 0.1) × d`.
4. Convert back from OKLab, clamp to [0, 1], and re-encode.

Wiring:
- **`apply_post`:** after `clip_to_display`, call `local_contrast::apply` before `PostProcess::apply`. Make the identity guard check `local_contrast` too, which `is_identity` already covers through `PartialEq`.
- **`display_on_gpu`:** return false when `self.params.post.local_contrast > 0.0`.

- [ ] **Step 4: Run them to make sure they pass**

Run: `cargo test --release -p spektrafilm-core --lib local_contrast pipeline`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add crates/spektrafilm-core/src
git commit -m "Add Local Contrast: RPP's lightness unsharp mask, easy on light detail so it doesn't halo"
```

### Task 5: The app and the presets

**Files:**
- Modify: `macos/Sources/NegsApp/Inspector.swift:116-122` (`toneControls`)
- Modify: `crates/spektrafilm-gui/src/main.rs`, only if it lists Post's sliders by hand (search for `post.saturation`)
- Test: `macos/Tests/NegsTests/SimpleInspectorTests.swift`, `crates/spektrafilm-core/src/presets.rs` (`mod tests`)

**Interfaces:**
- Consumes: `post.local_contrast` from Task 4.

- [ ] **Step 1: Write the failing tests**

- In `SimpleInspectorTests`, the Scan tab's labels include "Local Contrast", after "Saturation".
- In `presets.rs`, `a_finish_section_leaves_the_photographs_pins_alone` or a new test: export with `include_finish` and `post.local_contrast = 30.0`, import, apply, and assert `applied.post.local_contrast == 30.0`. Applying a file without the key gives 0.

- [ ] **Step 2: Run them to make sure they fail**

Run: `cd macos && swift test --filter SimpleInspectorTests` and `cargo test --release -p spektrafilm-core --lib presets`
Expected: the Swift test fails, because there's no slider yet. The preset test may already pass through serde. If so, keep it as a guard.

- [ ] **Step 3: Implement**

Add `.slider("Local Contrast", "post.local_contrast", 0...100, 1)` after Saturation in `toneControls`. Give the GUI crate the same slider if it lists Post's sliders.

- [ ] **Step 4: Run the full suites**

Run:
- `cargo build --release -p spektrafilm-native && cargo build --release -p spektrafilm-cli --bin spektrafilm && cargo build --release -p spektrafilm-cli --bin spektrafilm-f64 --features precision-f64`
- `cargo test --release -p spektrafilm-core -p spektrafilm-io -p spektrafilm-native`
- `cd macos && swift test`

Expected: all pass, the zone readout tests in `ZoneModelTests` included. If a readout test misses its tolerance because Post changed, check that the readout's one-pixel prediction (`printed_lstar`) still goes through `PostProcess::apply_rgb`. It should, with nothing extra needed.

- [ ] **Step 5: Commit**

```bash
git add macos crates
git commit -m "Show Local Contrast in Scan › Tone"
```
