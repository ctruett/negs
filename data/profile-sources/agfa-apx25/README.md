# Agfapan APX 25 source record — 3 November 2026

One new preparation: **Agfapan APX 25, Agfa's recommended development at
20 °C**. A new source-based preparation, not a renamed donor stock. See
[recipe.json](recipe.json) for the document hash, the derived PDF coordinates
and axis transforms, conditions, assumptions and authorship.

| Source | Extraction | Measured/plotted range used |
|---|---|---|
| Agfa Datenblatt APX 25, status 08/1995, 1st edition, PDF p2, "Dichtekurve" panel | Vector path; 193 points in `apx25-density.csv`, including original PDF coordinates | log exposure −3.9658 to +2.0080 lx·s; total diffuse density 0.2289–2.3569 |
| Same document, same page, "Spektrale Empfindlichkeit" panel | Vector path; 353 points in `apx25-sensitivity.csv` | 380.60–664.61 nm; engine uses 385–660 nm and relative shape only |

**Calibration is derived, not measured by hand.** Unlike the bw-expansion
record, which carries a hand-read `drawing_index` and axis transform per
graph, `scripts/bw_expansion/extract_graphs.py` finds the plot frames from the
page's long strokes, the ticks from its short ones and its gridlines, and the
mapping to data coordinates by snapping the printed axis labels to those
ticks. The result is written back into `recipe.json` under each graph's
`derived` key, so it can be read and checked like a hand-measured one. Worst
label error after fitting: 0.0085 log exposure and 0.0048 D on the density
panel, 0.0212 nm and 0.0050 log units on the sensitivity panel.

Two traps this sheet sets, both handled in the extractor: Agfa writes its
minus signs as en dashes (U+2013), and its axis labels carry explicit `+`
signs.

**What the sheet does not say.** The density panel states no developer, time
or densitometry, and the sensitivity panel states no density criterion or
exposure — both unlike the Kodak sheets. The development conditions were
therefore inferred rather than read: the curve's average gradient is 0.632
over 1.3 decades and 0.648 over 1.5, measured from the point 0.1 above base,
while the sheet's own gamma-time curves read 0.644 to 0.651 for all five
listed developers at their recommended 20 °C times. The curve is consistent
with recommended development in any of them, so the profile is labelled that
way and carries 6 minutes as a representative time. **It is not a measurement
of a particular developer**, and it is not evidence that the five developers
render identically — only that they reach the same average gradient at the
times Agfa recommends.

**Assumptions.** Base density 0.225 is an estimated asymptote just below the
lowest plotted total density of 0.2299. The 3.5 total-density ceiling is not
measured: the plot stops at 2.36, still rising, and 3.5 matches what the
existing B&W preparations assume. Sensitivity is truncated at 660 nm because
the trace meets the panel's −2.0 floor at 664.6 nm, and 380 nm is left
unmeasured because the trace begins at 380.6 nm; both are explicit
unmeasured-tail approximations, not proof of zero sensitivity. Pairing with
`ilford_mgrc_deluxe_grade2` is a rendering choice — Agfa published no paper
pairing for this film.

**Agreement.** Maximum source-point error is 0.0113 D against a 0.018 D gate.
That gate is set from the printed line rather than borrowed: this panel's
curve is stroked at 0.997 pt, which is 0.0284 D on its scale, against 0.0156 D
for the Kodak sheet behind the Tri-X preparation. The error is 0.40 of the
stroke width. These are graph-fitting tolerances, not empirical accuracy
claims. Overlays and the report are in
[docs/profile-sources-review/agfa-apx25](../../../docs/profile-sources-review/agfa-apx25).

Run from the repository root with Python 3.13 and
`scripts/bw_expansion/requirements.txt` installed in a dedicated environment:

```sh
# Normal regeneration uses the checked-in points, not the PDF.
python scripts/bw_expansion/prepare_bw_film.py --source agfa-apx25 --output-dir target/bw-profiles

# Optional re-extraction: supply the exact document. Hash mismatches are rejected.
python scripts/bw_expansion/extract_graphs.py --pdf /path/to/agfapanapx25.pdf
```

The profile stays outside the catalogue unless `--output-dir data/profiles` is
explicitly supplied.

New extraction, preparation and profile: spektrafilm-rs contributors,
Claude-assisted, 2026; new profile/preparation data under CC BY-SA 4.0.
Spektrafilm schema and pipeline: Andrea Volpato and contributors, with
existing repository attribution preserved. Manufacturer graph excerpts retain
AGFA-GEVAERT rights; this record does not grant a new licence to their
document, and no manufacturer's endorsement or laboratory comparison is
claimed.
