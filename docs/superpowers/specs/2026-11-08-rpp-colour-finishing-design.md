# RPP-style colour finishing: design

Date: 2026-11-08. Branch: `claude/inspector-redesign`.

## Intent

When a tone gets darker in Negs, it loses colour. Skin shows it most, but it
happens to every tone. Today Scan › Tone Contrast bends only luminance and
scales R, G and B by the same factor. That keeps hue and channel ratios, but
a darker tone looks duller, because perceived chroma falls with lightness.

The user wants Negs to finish colour the way Raw Photo Processor (RPP) does,
bringing over as much of its colour care as makes sense. A survey of the RPP
analysis (`photo.rpp-branch/.../analysis/specs`, outside this repository)
narrowed that to three stages, all in the finishing edits after the film:

1. **Per-channel contrast**: RPP's power curve applied to R, G and B
   separately (`tone-stages.md` §3.4). Darkened tones get richer, as with a
   contrastier paper.
2. **Chroma saturation**: RPP's `C/(C−2s)` chroma scale (`lab-stages.md` §5),
   which leaves lightness alone.
3. **Local contrast that resists halos**: RPP's unsharp mask on lightness only,
   with light detail damped to 3/7 (`lab-stages.md` §8).

## Goals

- Contrast in Scan › Tone becomes per-channel. Raising it makes darker tones
  richer, not duller. The user chose this over a hue-preserving version and
  accepts that hues may drift a little.
- Saturation in Scan › Tone becomes a chroma scale that never changes lightness.
- A new **Local Contrast** slider in Scan › Tone.
- Old edits switch to the new behaviour. The user decided this: no
  compatibility path for the old Contrast or Saturation.
- The CPU, the GPU display pass and the zone readout agree, as Post does today.

## Non-goals

- RPP's other stages. The black shift, lightness-curve modes, highlight
  compression, L\* levels from a measured black and white, the 0.1–0.9
  squeeze, UP Lab and per-camera ICC profiles are already covered by Negs or
  don't fit it (see the survey in the conversation of 2026-11-08).
- Prep's controls, which act on the scene before the film. They stay as they are.
- Bit-exact parity with RPP. It runs on raw sensor data before demosaic, and
  Negs runs on the scan after the film. The aim is RPP's behaviour, not its
  rounding.

## Anti-goals

- Contrast that clips or posterizes. Black must stay black and white must stay
  white, and the curve must keep rising, as Post's contrast does now.
- A saturation boost that pushes colours outside the output gamut or turns
  hues. The current gamut-boundary stop, which keeps hue, stays.
- Bright halos from Local Contrast.
- Wrecking the zone readout: whatever the readout predicts must still land
  within its tests' tolerance.

## Constraints

- Post (`crates/spektrafilm-core/src/post.rs`) runs on the scan clipped to
  [0, 1], in the output space, encoded or linear. It is tabulated per pixel
  (`PostProcess`). The GPU display pass mirrors it through
  `spektrafilm_gpu::DisplayPost` in `wgpu_backend.rs`, and also in
  `cuda_backend.rs` and the CPU backend. Any per-pixel change has to land in
  all of them, under the existing parity tests.
- Local Contrast is spatial: it needs a blur, so it can't live in the
  per-pixel table. It runs on the whole image as a stage before the per-pixel
  Post, on the CPU, and on the GPU if the GPU path is the one rendering.
- `printed_lstar` and the zone readout (`zones::readout`) push single pixels
  through Post. They get the per-pixel parts (contrast and saturation). Local
  Contrast depends on neighbours, so a one-pixel prediction can't include it.
  That is acceptable: the readout already ignores grain, halation and Midtone
  Detail for the same reason.
- Presets with Finish carry `post.contrast`, `post.saturation` and the new
  field. A file without the new field gets 0 (off).

## What was decided, and how

### 1. Per-channel contrast

- Applied to each of R, G and B on the sRGB-encoded (perceptual) value, the
  same domain the current curve works in, pivoting at `PIVOT` (middle grey).
- Shape: RPP's `out = v^((−ln(v)·k)^(B−1))` family, with `B = 1 + c/40` in
  RPP's units, rescaled so it pivots at `PIVOT`, keeps 0 and 1, and stays
  rising across the slider's range. Builder: the exact form and the mapping
  from the −100…100 slider to `B` are yours, provided that:
  - at +100 the slope at the pivot is close to today's +100 (2×), so the
    slider's reach feels the same;
  - negative values flatten without inverting;
  - the NaN at `v = 1` with negative contrast (`tone-stages.md` §3.6.1) can't
    happen.
- Order inside Post: Brightness (luminance, as now) → per-channel Contrast →
  Whites and Blacks (as now) → Saturation.

### 2. Chroma saturation

- In OKLab, the user's call. a and b are scaled by
  `k = C / (C − 2s)` with `C = 248.4375` and `s` the slider (−100…100).
  L is untouched.
- −100 is full desaturation: `k = 0`, as RPP's monochrome sentinel does,
  rather than the formula's 0.554.
- *Designer's call:* positive slider values map to `s = 0.621 × slider`, so
  +100 gives `k = 2`, the reach today's slider has. RPP's +100 would give
  about 5×. The curve keeps RPP's shape: gentle at first, rising faster.
  Negative values blend `k` linearly from 1 at 0 to 0 at −100.
- Out-of-gamut results: keep today's rule of stopping at the gamut boundary
  without changing hue or lightness.

### 3. Local Contrast

- New `post.local_contrast`, 0…100, default 0. It lives in Scan › Tone,
  under Saturation.
- On lightness only (OKLab L): blur L, `d = L − blur`, damp positive `d` by
  3/7, and `L' = L + k·d` with `k = amount/100 + 0.1` when amount > 0
  (RPP §8.2).
- Radius: RPP's grows with the amount (`amount × radius`). Builder: pick a
  fixed radius as a fraction of the image's shorter side, so it looks the
  same at preview and export sizes. Whether it also grows with the amount is
  yours.
- Chroma and hue are untouched.

### 4. Old edits

- No migration code. Old edits with Contrast or Saturation set simply develop
  with the new behaviour. The cached frames are keyed on the engine's files,
  so they refresh by themselves.

## What's left to the builder

- The exact contrast curve, within §1's conditions.
- The OKLab conversion: the existing helpers if Post has them, otherwise
  standard OKLab from linear sRGB. Use the output space's primaries, so the
  same settings look the same in every output space, as Post does now.
- The Local Contrast blur (a box or Gaussian approximation is fine) and where
  its stage sits in the CPU and GPU render paths.
- Inspector and preset wiring for `post.local_contrast`, including the
  spektrafilm-gui crate if it lists Post's sliders.
- Tests:
  - contrast keeps black and white and keeps rising, raises chroma in
    darkened tones, and is the identity at 0;
  - saturation leaves OKLab L alone, reaches grey at −100, and stays in gamut;
  - local contrast leaves a flat field alone and makes a dark-edge overshoot
    larger than a light-edge one;
  - the CPU and GPU agree;
  - the zone readout tests still pass.
