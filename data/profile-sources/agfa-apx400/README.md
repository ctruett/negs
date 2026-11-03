# Agfapan APX 400 source record — 3 November 2026

One new preparation from Agfa Datenblatt APX 400, status 08/1995, 1st edition. A new source-based preparation, not a renamed
donor stock. The method, the two traps this sheet template sets (en-dash minus
signs, explicit `+` on axis labels) and the derived-calibration approach are
described once in [the APX 25 record](../agfa-apx25/README.md); this file
records only what differs. See [recipe.json](recipe.json) for the document
hash, derived PDF coordinates and axis transforms, conditions and assumptions.

| Source | Extraction | Range used |
|---|---|---|
| Agfa Datenblatt APX 400, status 08/1995, 1st edition, PDF p2, "Dichtekurve" panel | Vector path; 193 points in `apx400-density.csv` | log exposure −3.9720 to +1.9970 lx·s; total diffuse density 0.1570–2.8504 |
| Same page, "Spektrale Empfindlichkeit" panel | Vector path; 257 points in `apx400-sensitivity.csv` | 379.97–664.93 nm; engine uses 380–660 nm, relative shape only |

**Development conditions: unknown, and not inferable from this sheet.** The panel names no developer or time, and unlike APX 25 and APX 100 the sheet cannot place it. Its average gradient is 0.530 over 1.3 decades and 0.548 over 1.5. Every curve on the sheet's own gamma-time panel sits at or above about 0.55 across its whole plotted range, so no developer and time on this datasheet produces the contrast the density panel shows. The 6 minutes in the profile is a nominal label only, and this stock is the weakest-grounded of the three.

**Assumptions.** Base density 0.153 is an estimated asymptote just below the
lowest plotted total density of 0.1570. The 3.5 total-density ceiling is not
measured. Pairing with `ilford_mgrc_deluxe_grade2` is a rendering choice —
Agfa published no paper pairing for this film.

**Agreement.** Maximum source-point error 0.0081 D against the same 0.018 D
gate as the APX 25 record, which is 0.64 of this sheet template's 0.0284 D
printed stroke. Graph-fitting tolerance, not an empirical accuracy claim.
Overlays and report:
[docs/profile-sources-review/agfa-apx400](../../../docs/profile-sources-review/agfa-apx400).

```sh
python scripts/bw_expansion/prepare_bw_film.py --source agfa-apx400 --output-dir target/bw-profiles
python scripts/bw_expansion/extract_graphs.py --source agfa-apx400 --pdf /path/to/apx400.pdf
```

New extraction, preparation and profile: spektrafilm-rs contributors,
Claude-assisted, 2026; new profile/preparation data under CC BY-SA 4.0.
Manufacturer graph excerpts retain AGFA-GEVAERT rights.
