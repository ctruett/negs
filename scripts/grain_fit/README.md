# Grain fitting: measure scan grain, reproduce it with the engine

Tools to measure the film grain in real scans and to fit the engine's grain
parameters (`film_render.grain`, plus optionally the lab scanner's sharpening)
so the engine reproduces it. The reference data are the Color Precision
studio scans in `experimental/studio/` (52 stocks, each scanned on a Frontier
and a Noritsu at several exposures; `index.csv` lists them). That folder isn't
in git.

Everything runs through `uv`, which provides numpy/scipy/Pillow/tifffile from
the script header. The engine is the release CLI:

```sh
cargo build --release -p spektrafilm-cli --bin spektrafilm
uv run scripts/grain_fit/grain_tool.py --help
```

## Commands

| Command | What it does |
| --- | --- |
| `analyze SCAN... [-o sig.json]` | Measure a scan's grain signature and print it per tone level. |
| `survey` | Analyze every scan in `experimental/studio/index.csv`; writes `target/grain_fit/survey/survey.csv` and one signature per scan. |
| `render --like SCAN [--params P]` | Render the engine's grain like that scan (same film, scanner, pixel pitch, file format), print its signature and the distance to the scan. |
| `fit SCAN... [--free ...]` | Fit the engine's grain parameters to one or more scans of one film. Writes `target/grain_fit/fit_<film>.json` (preset vs fitted, per-part distances) and `fit_<film>.params.json`, which `spektrafilm process --params` takes. |
| `compare SCAN [--params P] -o out.png` | Side-by-side image, magnified: the scan's flat patches (left) and the engine's (right) at matching tone levels. |
| `selftest [--film F]` | Render the engine with known grain (rms x1.6, blur x0.6), treat it as the scan, and check that `fit` recovers those values. |

The film and scanner come from the studio path
(`studio/<stock>/<frontier|noritsu>/daylight_<ev>.*`); `--film` and
`--scanner` override them. Studio stocks without an engine profile of the
same name map to a near relative (`engine.STUDIO_TO_PROFILE`), and stocks with
no relative (most Ilford films) need an explicit `--film`, for example a B&W
profile to start from.

Typical use, fitting one film from all its exposures on one scanner:

```sh
uv run scripts/grain_fit/grain_tool.py fit experimental/studio/kodak_portra_800/frontier/*.png
uv run scripts/grain_fit/grain_tool.py compare experimental/studio/kodak_portra_800/frontier/daylight_+0.0.png \
  --params target/grain_fit/fit_kodak_portra_800.params.json -o target/grain_fit/portra800_compare.png
```

## Method

**Signature** (`grainstats.py`). The scan is cut into 32 px tiles. Each tile
loses its best-fit plane, and is kept as flat grain when a Gaussian low-pass
(sigma 3 px) of the remainder keeps under 30% of its standard deviation
(edges and texture keep most of theirs) and it isn't clipped. Tiles are
grouped by tone level (16 bins of luminance), and each group records:

- `sigma` per channel: grain strength in encoded output values;
- `rho1`, `rho2` per channel: autocorrelation at 1 and 2 px, i.e. grain size;
- `corr` (rg, rb, gb): how neutral (high) or colourful (low) the grain is;

and the whole scan gets a normalised luminance noise power spectrum (`nps`).

**Reproduction** (`engine.py`). The engine develops a synthetic grey wedge
(16 flat patches, 6 stops under to 5 over mid grey) with the trial grain,
scanned on the same lab scanner (`--scan-film --scanner`) at the scan's
micrometres per pixel (`camera.film_format_mm` set so the wedge has the scan's
pitch). The render is then stored like the scan: rounded to 8 bits, and for a
JPEG re-encoded with the scan's own quantisation tables and chroma
subsampling, so compression removes the same fine grain from both. Each
patch's interior is one signature group. Halation and auto exposure are off.
Renders are deterministic (the engine seeds every grain stream), so the
objective has no run-to-run noise.

**Distance** (`grainstats.distance`). For each of the scan's groups, the
render's curves are interpolated at the same value of each channel (so a
coloured patch meets the wedge where that channel matches). The parts are the
RMS log ratio of sigma (with half an 8-bit code added to both, so grain lost
in quantisation can't dominate), the RMS differences of rho and corr
(weighted down where the grain is below that floor), and the RMS log ratio of
the spectra.

**Fit** (`grain_tool.fit_params`). `rms_granularity` is solved per channel
inside every step: the mean sigma log ratio is driven to 0 by secant steps in
log rms, then bisection once bracketed (sigma isn't monotonic in rms: very
coarse grain loses sigma again). The shape parameters
(`--free`: `uniformity`, `blur`, `dye` = `blur_dye_clouds_um`, `micro` =
micro-structure clump size, `usm` = `mult_usm_amount`, `scanner_usm`) get a
coarse two-sided scan each, then Nelder-Mead in log/logit coordinates.

## Limits

- The pixel pitch isn't in the files: it assumes a 36 mm frame across the
  file's long side (`--frame-mm`, `--um-per-px` override). If the lab
  downsampled the scan, the fitted blur absorbs it.
- The scanner's own sensor noise and its sharpening are in the scan's sigma.
  The engine's lab scanner models the sharpening (`scanner_usm`) but not the
  sensor noise, so the fit attributes sensor noise to grain. That matters most
  in the shadows of dense negatives.
- Tone matching is by output value. The engine's scanner balance meters the
  wedge, not the studio scene, so a level can map to a slightly different
  exposure in the two; the per-level comparison absorbs most of this.
- Coverage depends on the scene: the studio frames have large flat areas only
  in the black background, the grey card and the white board, plus the
  ColorChecker patches. Fitting several exposures of a film together covers
  more of the tone range.
