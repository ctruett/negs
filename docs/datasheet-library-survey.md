# Film & paper datasheet library — survey

**Date:** 2026-11-04
**Library:** `/Volumes/storage/30-39 Photography/33 Film/Film datasheets`
**Companion:** `index.md` (the full file map lives there; this is the *panel survey* on top of it).

This documents the datasheet library, what each PDF could yield for a spektrafilm `.json`
profile, and the tooling that already does the extraction. The pipeline is **built** and lives
in this repo under `scripts/bw_expansion/` (`extract_graphs.py` → `prepare_bw_film.py` /
`prepare_colour_film.py` → `render_review.py`). Nothing here re-implements it.

---

## 1. Summary

- **293 datasheet PDFs** (+ 1 stray JPG, `kodak/black-and-white-film/2475.jpg`, and
  `index.md`), across **10 brands**.
- A fresh automated sweep (this survey) across all 293 PDFs found:
  - **153** PDFs with ≥ 1 extractable **characteristic-curve** panel (log exposure → density);
  - **123** PDFs with ≥ 1 **spectral** panel (wavelength → sensitivity or dye density);
  - **110** PDFs with **both** — the minimum data set to attempt any film/paper profile;
  - **37** PDFs with **all three** roles (characteristic + sensitivity + dye) — a full colour profile.
- **Already extracted:** 32 stocks under `data/profile-sources/`; **28 profiles** ship upstream
  in the spektrafilm Python repo.
- **Hard limits:** ~17 raster-only scans (no vectors to read) and the outline-label brands
  (Ilford, Rollei, Maco, Kentmere, and much of Fuji) where axis numbers are drawn as paths,
  not text — those need OCR, which is out of scope for the vector extractor.

The headline numbers in §5 are advisory: the definitive per-panel classification for a real
extraction is the human-authored `recipe.json` (that is by design — §4).

---

## 2. Inventory

### By brand

| brand | PDFs |
|---|---:|
| kodak | 123 |
| polaroid | 58 |
| fujifilm | 39 |
| ilford-harman | 30 |
| konica | 19 |
| agfa | 7 |
| rollei | 7 |
| kentmere | 4 |
| maco | 4 |
| charts (ilford) | 2 |
| **total** | **293** |

### By media type / folder role

| media type | PDFs |
|---|---:|
| black-and-white film | 75 |
| color-negative film | 66 |
| instant film (polaroid) | 55 |
| color-reversal film | 39 |
| reference | 29 |
| black-and-white paper | 12 |
| motion-picture film | 10 |
| guides (polaroid) | 3 |
| charts (ilford) | 2 |
| infrared (rollei) | 1 |
| unsorted (rollei) | 1 |
| **total** | **293** |

---

## 3. What a profile needs — the yield model

A spektrafilm profile is `info` + `data`. The `data` arrays come from datasheet **plots**;
`info` is text a human reads off the sheet (densitometer status, reference/viewing illuminant,
sensitivity criterion, antihalation, target print). Each plot role maps to specific fields:

| panel role | axis | → profile field(s) |
|---|---|---|
| **characteristic** | log exposure → density | `log_exposure`, `density_curves` (+ parametric `density_curves_model`, `density_curves_layers`) |
| **sensitivity** | wavelength → log sensitivity | `log_sensitivity` |
| **dye** | wavelength → diffuse spectral density | `channel_density`, `base_density`, `midscale_neutral_density` |

So the minimum to attempt a profile is **characteristic + sensitivity**; a full **colour
negative** additionally needs the **dye** panel (C/M/Y dye curves plus min/mid neutral).
Colour negatives also require the densitometer responsivity CSVs for unmixing; reversal
positives publish their dye curves outright and skip the dye reconstruction.

| media type | yields |
|---|---|
| color-negative film | full colour film profile (needs all three roles; dye often absent → donor dye from a sibling sheet) |
| color-reversal film | positive film profile (characteristic + sensitivity + dye published outright) |
| black-and-white film | B&W film profile (`channel_model: bw`; 1 characteristic + 1 sensitivity) |
| black-and-white paper | print profile (`stage: printing`) |
| motion-picture film | film profile (`use: cine`, e.g. the Vision3 line) |
| instant film | D–log H density curve only (no spectral panels); low priority, odd chemistry |
| reference / charts | not a stock — densitometer responsivity & family-comparison inputs to the colour unmixing step |

---

## 4. Method (how this survey scanned every PDF)

The sweep reuses the built extractor's primitives — `extract_graphs.py`'s
`segments` / `frames` / `ticks` / `labels` / `calibrate` (frames from long strokes, ticks from
short strokes and gridlines, axis calibration by snapping printed labels to ticks) — exactly as
the production `--source/--pdf` flow does. Per PDF, per page it: detects vector frames,
calibrates their axes, keeps the largest frame per region (the extractor's own dedup), and
classifies each calibrated frame by axis range + nearby axis-title text into
**characteristic / sensitivity / dye**. Raw results:
[`datasheet-library-survey.json`](datasheet-library-survey.json).

**Classification caveats** (why these are advisory, not final):

- "wavelength vs log-exposure" (spectral vs characteristic) is unambiguous from the axis
  numbers. Within a spectral panel the "sensitivity" vs "dye" split is weaker: several vendors
  print sensitivity axes on a *positive relative* scale, which this heuristic reads as dye.
  Read the two spectral buckets **together** as "spectral panels"; the `recipe.json` `role` is
  the ground truth when preparing a stock.
- Konica's characteristic curves did not calibrate in this sweep (its log-exposure labels are in
  a form `labels()` misses), so Konica shows as spectral-only here. Historically it is
  extractable (§5 baseline) — it needs a targeted look, not a rewrite.
- `raster_only` (no vectors) and `no_label_only` (frames but no numeric labels) flags are
  approximate; the latter is inflated by the same Fuji/Konica label-format weakness.

---

## 5. Coverage — fresh sweep (293 PDFs)

Per brand: PDFs with a **characteristic** panel / a **spectral** panel / **both** / **all
three** roles.

| brand | PDFs | char | spectral | char+spectral | all three |
|---|---:|---:|---:|---:|---:|
| kodak | 123 | 107 | 98 | 96 | 31 |
| polaroid | 58 | 28 | 0 | 0 | 0 |
| fujifilm | 39 | 7 | 10 | 7 | 3 |
| agfa | 7 | 7 | 7 | 7 | 3 |
| konica | 19 | 0* | 8 | 0* | 0* |
| ilford-harman | 30 | 2 | 0 | 0 | 0 |
| rollei | 7 | 1 | 0 | 0 | 0 |
| maco | 4 | 1 | 0 | 0 | 0 |
| kentmere | 4 | 0 | 0 | 0 | 0 |
| charts | 2 | 0 | 0 | 0 | 0 |

`*` Konica: characteristic curves exist on the sheets but did not auto-calibrate here (see §4) —
treat as under-reported, not absent.

Historical baseline, same library at an earlier 251-PDF snapshot (author's sweep recorded in the
spektrafilm datasheet-extraction design doc): 369 characteristic, 182 sensitivity, 113 dye-density
plots; 155/251 PDFs usable; 73 with sensitivity + characteristic; 44 with dye too; Kodak 103/109,
Agfa 7/7, Polaroid 30/58, Fuji 9/35, Konica 6/19, Ilford/Rollei/Maco 0/21. The library has since
grown (notably +14 Kodak, +4 Fuji, +4 Kentmere and more Ilford), which is why this survey re-ran
the sweep.

---

## 6. Yield by media type

- **color-negative film (66):** the largest pool of new colour is the Kodak E-code family sheets
  (Pro/Supra/Portra/Ektacolor — one sheet carries several stocks). Full-colour-capable where dye
  density is present; otherwise a donor relationship is required. 12 are already prepared (§7).
- **color-reversal film (39):** straightforward positives. Ektachrome E-codes dominate; Agfa RSX II
  and Fuji Astia/Provia/Velvia are the historical donors.
- **black-and-white film (75):** cheapest to add — one density curve + one sensitivity curve.
  Agfa Agfapan (done), Kodak F-4016/F-4017/F-4018 (T-Max/Tri-X/Plus-X), Ilford Delta/FP4/HP5/SFX/Ortho
  (blocked: outline labels), Rollei/Maco/Kentmere (blocked).
- **black-and-white paper (12):** Ilford Multigrade/Ilfobrom/Galerie/Direct Positive + Kentmere;
  printing-stage profiles. Ilford is the known outline-label blocker.
- **motion-picture film (10):** Kodak Vision3 / Ektachrome 100D / print films; the shipped
  Vision3 + 2383/2393 profiles already cover most of this.
- **instant film (55):** Polaroid D–log H density curves only; no spectral panels in the sweep.
  Not a priority for the spectral model.
- **reference (29) + charts (2):** Kodak E-88/p255/professional-film-data-guide, Agfa `agfa-films`,
  Fuji `profilm-misc`/`proseries`, the two Ilford charts — calibration inputs, not stocks.

---

## 7. Already built

**28 shipped profiles** (spektrafilm `src/spektrafilm/data/profiles/`): Kodak Portra / Gold /
Ultramax / Ektar / Ektachrome / Kodachrome / Vision3 / Verita negatives and reversals, plus 8
print papers (Endura family, Supra, Portra Endura, Ektacolor Edge, Fuji Crystal Archive, Kodak
2383/2393).

**32 prepared sources** in this repo (`data/profile-sources/`), each with extracted CSVs, a
`recipe.json` naming its sheet + frame, and a review render in `docs/profile-sources-review/`:

- *B&W film:* agfa-apx100, agfa-apx25, agfa-apx400, Kodak Tri-X 400 (`bw-expansion`).
- *Colour reversal (positive):* agfa-rsx2-100/200/50, ektachrome100 (control), fuji-provia-400x,
  fuji-t64, kodachrome64 (control), kodak-ektachrome-160t/400x/e200/p1600/64epr/64t-epy,
  kodachrome200/kodachrome25.
- *Colour negative:* kodak-bright-sun-ga, kodak-ektapress-pj400,
  kodak-portra-160nc/160vc/400nc/400vc, kodak-pro-1000-pmz, kodak-pro-400-ppf,
  kodak-pro-400mc-pmc, kodak-supra-100/200/400/800.

---

## 8. Blockers & non-goals

- **Raster / scanned sheets (~17):** no vector content — the vector extractor cannot read them.
  Concentrated in Konica, Rollei, Maco, Fuji.
- **Outline-label sheets:** Ilford, Rollei, Maco, Kentmere (and much of Fuji) print axis numbers
  as drawn outlines, not selectable text, so `labels()` finds nothing. OCR on a rendered crop is
  the only route and is a separate piece of work.
- **MTF / RMS granularity / reciprocity / development-time plots** are present on many sheets but
  the profile format has no field for them — out of scope by design.

---

## 9. Recommendations

1. **Close the Konica gap** — its characteristic curves are almost certainly recoverable vector
   panels; a label-format fix to `labels()`/`as_number` would move 19 Konica PDFs from
   spectral-only to profiled, and Fuji's unexplained low yield is likely the same class of issue.
   Highest value per effort.
2. **Mine the Kodak E-code family sheets** (one sheet → several stocks). Many
   Pro/Supra/Portra/Ultra negatives on the E-codes are un-prepped and full-colour-capable.
3. **Treat "spectral" buckets as one family** until a recipe exists: the sensitivity-vs-dye split
   in this survey is heuristic; the human-authored `recipe.json` `role` is definitive.
4. **Defer OCR** (Ilford/Rollei/Maco/Kentmere) until the vector well is dry — it is the whole
   reason those B&W/paper brands read as empty here.
5. **Keep extracted CSVs + provenance in-repo** next to each `recipe.json` (as already done) so a
   rebuilt profile is reproducible from sheet hash alone.
