# Agfapan APX 100 source record — 3 November 2026

One new preparation from Agfa Datenblatt APX 100, status 08/1995, 1st edition. A new source-based preparation, not a renamed
donor stock. The method, the two traps this sheet template sets (en-dash minus
signs, explicit `+` on axis labels) and the derived-calibration approach are
described once in [the APX 25 record](../agfa-apx25/README.md); this file
records only what differs. See [recipe.json](recipe.json) for the document
hash, derived PDF coordinates and axis transforms, conditions and assumptions.

| Source | Extraction | Range used |
|---|---|---|
| Agfa Datenblatt APX 100, status 08/1995, 1st edition, PDF p2, "Dichtekurve" panel | Vector path; 193 points in `apx100-density.csv` | log exposure −3.9690 to +2.0090 lx·s; total diffuse density 0.3024–2.5887 |
| Same page, "Spektrale Empfindlichkeit" panel | Vector path; 417 points in `apx100-sensitivity.csv` | 380.42–662.45 nm; engine uses 385–660 nm, relative shape only |

**Development conditions: softer than recommended, by a consistent factor.** The panel names no developer or time. Its average gradient is 0.567 over 1.3 decades and 0.598 over 1.5, from the point 0.1 above base, while the sheet's own gamma-time curves read about 0.650 at every recommended 20 °C time. Reading those curves back at 0.598 gives 3.4, 4.4, 6.1 and 14.4 minutes against recommended 4, 6, 8 and 17 — about 0.8 of each. The panel therefore shows less than recommended development; the exact conditions are not recoverable, and the 6 minutes in the profile is a nominal label only.

**Assumptions.** Base density 0.298 is an estimated asymptote just below the
lowest plotted total density of 0.3024. The 3.5 total-density ceiling is not
measured. Pairing with `ilford_mgrc_deluxe_grade2` is a rendering choice —
Agfa published no paper pairing for this film.

**Agreement.** Maximum source-point error 0.0063 D against the same 0.018 D
gate as the APX 25 record, which is 0.64 of this sheet template's 0.0284 D
printed stroke. Graph-fitting tolerance, not an empirical accuracy claim.
Overlays and report:
[docs/profile-sources-review/agfa-apx100](../../../docs/profile-sources-review/agfa-apx100).

```sh
python scripts/bw_expansion/prepare_bw_film.py --source agfa-apx100 --output-dir target/bw-profiles
python scripts/bw_expansion/extract_graphs.py --source agfa-apx100 --pdf /path/to/apx100.pdf
```

New extraction, preparation and profile: spektrafilm-rs contributors,
Claude-assisted, 2026; new profile/preparation data under CC BY-SA 4.0.
Manufacturer graph excerpts retain AGFA-GEVAERT rights.
