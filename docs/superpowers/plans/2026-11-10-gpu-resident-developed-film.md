# Keep the developed film on the GPU between lab-scan renders

## Problem

On the lab-scan route, a change that only touches the scan (the contrast, density and colour keys, Auto colour, or the scanner model) re-runs the whole GPU film chain:

- the front pass, filming exposure, halation, development, DIR couplers and grain
- then the lab LUT, gamut compression, unsharp mask and readback

On a 45 MP source rendered at a 12 MP preview, that's about 255 ms per change (measured 2026-11-10, wgpu, Apple Silicon). The helper writes the preview in 11 ms, and the rest is spent waiting on the GPU.

The CPU path has a developed-film cache (`DevelopedFrame`, `pipeline.rs`), but the resident GPU chain runs first and never consults it. Forcing the CPU path is slower: grain takes about 1.9 s on the first render, and each rescan then costs about 340 ms on the CPU (`lab_scan::process`).

## Goal

When only the scan changes, keep the developed film density resident on the GPU and run only the scan half of the chain:

- lab LUT
- gamut compression
- scanner lens blur and unsharp mask
- encode, when the GPU encodes
- readback

The target is about 50 ms or less per change at a 12 MP preview, against the current ~255 ms. The output must stay within the parity tests' tolerances of the full chain.

## Design

1. **Key the developed density.**
   - Add an optional `developed_key: Option<u64>` to `spektrafilm_gpu::FilmChainParams`: the caller's name for the developed film this chain produces.
   - The key covers everything up to development: the input pixels or `image_key`, every param except `scanner.*`, `post` and `settings.lab_look_override`, plus the autoexposure EV, the stock and the dimensions. This mirrors `Pipeline::developed_key`. Reuse or factor that function, but don't hash 36M floats per render: derive the key from `image_key` when there is one.
2. **Keep the density in the wgpu backend.**
   - After development, DIR couplers and grain, keep the film density buffer under `developed_key`. Use a small newest-first store like the keyed inputs (`wgpu_backend.rs` around line 335), holding one or two entries.
   - Evict it on memory pressure, the same way keyed inputs are evicted.
3. **Skip ahead on a hit.**
   - When `developed_key` matches a kept buffer, skip from the front pass through grain, and start the encoder at the lab LUT pass, reading the kept buffer.
   - All later passes stay unchanged.
   - Apply this on the lab route only (`lab_lut.is_some()`); the paper route is out of scope.
4. **Wire the pipeline.**
   - In `Pipeline::try_gpu_resident` / `borrowed_resident`, compute the developed key when the caller supplies a `DevelopedFrame` slot (the helper already does, in `developed_photo` / `developed_interactive`) and pass it through.
   - The helper should need no protocol changes. Check that `process_resident_borrowed` passes an `image_key`, or add one for the helper's source so the key is cheap.
5. **CUDA backend:** a no-op. Ignore `developed_key` there and keep it compiling. Note it in the docs.

## Tests

- **GPU parity:** a lab render with a kept density (second call, same `developed_key`, a different `contrast_key`) matches, within the existing lab GPU tolerance, a fresh full-chain render at that contrast.
- **Invalidation:** changing a film-side param, such as exposure compensation or the film stock, changes the key and re-runs development.
- **Reuse counter:** a counter or tracing hook proves the second render skipped development. Follow `DevelopedFrame::reuses` for the pattern.
- **Benchmark:** record before and after with `scripts/benchmark` or a small driver of the helper. The baseline is 45 MP source, 12 MP preview, `contrast_key` stepping 0→3: about 255 ms per step.
- **Suites:** `cargo test --release -p spektrafilm-core -p spektrafilm-io -p spektrafilm-native -p spektrafilm-gpu` and `cd macos && swift test` must stay green.

## Constraints

- Match the surrounding code: its comment density, naming and doc style.
- Anything printed to stdout in the helper breaks its JSON-lines protocol; use stderr.
- Run the app and helper in release builds (`--release`).
- Grain is seeded per pixel, so the kept density has exactly the grain a full render would draw. Parity therefore holds bit for bit before the LUT, apart from f32 differences.
