# Lab scanner looks

Fits the Frontier and Noritsu looks in `data/scanners/*.toml` to Color
Precision's studio scans, and scores them in `docs/lab-scan-accuracy.md`.

## Data

The studio scans live in `experimental/studio/` (with its `index.csv`). They
aren't in the repository and must never be committed. A worktree finds the
main checkout's copy; `LAB_SCAN_STUDIO` points elsewhere.

Each frame holds a ColorChecker Digital SG on the left, which is what's
measured, against the published D50 values (colour-science's "ColorCheckerSG
- After November 2014"). The chart on the right is a Datacolor SpyderCheckr
24, which isn't used.

## Run

Build the CLI first, from the repository root:

```bash
cargo build --release -p spektrafilm-cli --bin spektrafilm
cd scripts/lab_scan
R="uv run --no-project --with-requirements requirements.txt python -I"
$R -m pytest -q -p no:cacheprovider .            # chart finder and look port
$R charts.py /tmp/sheet.png                      # find every chart; contact sheet
$R fit.py --scanner frontier --type colour_negative   # and slide, bw; and noritsu
$R report.py                                     # docs/lab-scan-accuracy.md
```

`fit.py` reads each frame's look input once through the CLI and caches it in
`target/lab_scan/` (rebuilt when the CLI is). The look is then evaluated in
numpy exactly as `lab_scan/look.rs` does, which `test_fit.py` checks against
the engine.

## The fit

- One look per scanner and film type, shared by every film: per-channel
  curves and a 3×3 log-space matrix for colour negatives, one curve and a
  matrix for slides, one curve and a tint for B&W.
- Every curve passes through the reference grey, and matrix rows sum to 1, so
  a metered grey card scans neutral at 18% (B&W: with the look's tint).
- Training: the profiled films at 0 and +1 EV. Held out: −1 and +2 EV, and
  all of Portra 800 and UltraMax 400.
- Residual: OKLab after one luminance scale per frame, plus a smoothness
  penalty that keeps each curve's slope steady beyond the data (`SMOOTH`,
  chosen by held-out error).
