# Kodak Supra source record — 4 November 2026

Covers all four Supra stocks: **Supra 100** from publication E-2519 (May 2003)
and **Supra 200, 400 and 800** from E-4029 (May 2003). Sources sit in
`../kodak-supra-100`, `../kodak-supra-200`, `../kodak-supra-400` and
`../kodak-supra-800`; each `recipe.json` carries its own document hash, derived
coordinates and conditions. See
[the Ektachrome 64 EPR record](../kodak-ektachrome64-epr/README.md) for the
extraction and unmixing method, which is shared, and
[the APX 25 record](../agfa-apx25/README.md) for the axis calibration.

These are the first **multi-stock** sheets prepared here: one publication, three
or four films, their panels interleaved across pages.

| Stock | Characteristic | Sensitivity | Spectral dye |
|---|---|---|---|
| Supra 100 | E-2519 p7, −2.84…1.16 | p7, 403–682 nm | p7, 400–700 nm |
| Supra 200 | E-4029 p7, −3.14…0.86 | p7, 375–695 nm | p7, 380–750 nm |
| Supra 400 | E-4029 p8, −3.44…0.56 | p8, 380–695 nm | p8, 380–750 nm |
| Supra 800 | E-4029 p9, −3.74…0.26 | p9, 380–701 nm | p10, 400–700 nm |

Each page also carries the same stock's Push 1 and Push 2 characteristic panels
on identical axes, and the sensitivity and dye pages carry siblings, so the x
range alone cannot pick a panel out. The recipes give each frame's top-left
corner in PDF points and `extract_graphs.py` matches on position within 12 pt.
Only the normal process is prepared; the push panels are left unread.

## Royal Supra is the same film

Publication E-4026 (June 2002) plots **Royal Supra 200, 400 and 800**. Extracted
side by side with E-4029's Supra panels, the two agree to **0.0001 density** on
every characteristic curve and 0.006 log units on sensitivity; the dye panels
differ only in how their Bézier segments were sampled. They are one set of
measurements published under two names, so Royal Supra is not shipped
separately. That agreement is also the strongest check this repository has on
the extractor: two independent redraws of the same data, traced by the same
code, landing on the same numbers.

## Two pipeline fixes this family forced

**The solver was running out of budget, not out of accuracy.** All four stocks
failed `fit_channel` with *"maximum number of function evaluations is
exceeded"* — the same failure that had shelved Portra 400NC, Agfachrome RSX II
200 and Ektachrome P1600. It is not a bad fit: given 50,000 evaluations instead
of 4,000 the solver converges on `xtol` at the residual it had already reached
by evaluation 4,000. Raising the cap unblocked these four **and Portra 400NC**,
which now ships. Re-preparing Bright Sun GA, Portra 160NC, Ektachrome 64 EPR and
Kodachrome 200 under both caps gives **byte-identical** profiles, so nothing
already shipped moved. Ektachrome P1600 still fails — but now on fit quality
(0.0353 against a 0.02 gate), which is a different and honest reason.

**A curve may leave its own panel.** Supra 100's midscale-neutral dye trace
passes 2.5 D at the left edge of a box whose top *is* 2.5, so the containment
test discarded it and the panel read one trace where it plots two. `curves_in`
now takes an opt-in `clip_to_frame`, which keeps the longest run of a trace
inside the frame instead of rejecting the trace whole. Opt-in, because a trace
that leaves its frame is also what a misidentified frame looks like.

## A better spectral fit is not a better render

Dye shapes are a donor's, scaled so their mixture reproduces each sheet's own
midscale-neutral-minus-D-min. Sweeping every shipped colour negative as donor,
`kodak_ektar_100` fits Supra 100's measured neutral best by a wide margin —
residual 0.0304 against 0.0703 for `kodak_portra_160`. Balanced through the
print it also renders **worst**: 26.3% off neutral, against 14.9% for Portra
160, 14.5% for Portra 400 and 14.5% for Portra 800. A better spectral fit to
the neutral bought worse neutrality, which is the opposite of what the residual
suggests and is worth recording. Donors here are therefore chosen on the
balanced ramp, which is what this repository gates on, with the spectral
residual reported beside it: Portra 400 for Supra 100, 200 and 400, Ektar 100
for Supra 800 (17.0% against Portra 800's 18.0%).

## Print filters and balance must not chase each other

A negative's print filters are solved from its profile; its ramp balance is
then fitted *given* those filters. Re-deriving the filters afterwards — from the
now-balanced profile — invalidates the balance. Measured: re-deriving once took
Supra 200 from 15.0% to 22.2% and Supra 800 from 17.0% to 23.0%, and iterating
balance-then-derive three times **diverged** for Supra 200 (15.0 → 19.8 → 25.7)
while improving Supra 400 (15.9 → 13.4 → 12.6). There is no fixed point to
iterate to with this pair of fits. The procedure is therefore one pass, in this
order, and it reproduces exactly: prepare → derive filters → balance once →
stop. The numbers below were reproduced from a clean filter database.

## Neutrality

Worst channel deviation from neutral across a five-stop grey ramp, balanced
through the print as a negative must be:

| Stock | before | after | worst at |
|---|---|---|---|
| Supra 100 | 45.4% | **14.5%** | EV−2, R/G |
| Supra 200 | 74.5% | **15.0%** | EV−2, R/G |
| Supra 400 | 76.4% | **15.9%** | EV−2, R/G |
| Supra 800 | 44.7% | **17.0%** | EV−2, R/G |
| Portra 400NC | 11.8% | **7.5%** | EV−2, R/G |

For scale, on the same ramp: shipped Portra 160 15.9%, Portra 400 13.0%, Gold
200 10.4%; prepared here, Portra 160VC 4.9%, Bright Sun GA 8.4%, Portra 400VC
9.0%, Portra 160NC 9.7%. The Supras sit at the bad end of the shipped band
rather than outside it, and their error has the same shape as the shipped
profiles' — worst at the darkest step, small from EV 0 up.

Two candidate causes were measured and do **not** explain the gap: per-channel
gamma spread (Bright Sun GA has the widest spread, 24.4%, and the best
neutrality of anything prepared here) and the donor dye fit (above). The cause
is not established.

## Agreement

Maximum residual on the unmixed dye amounts, over the inner 98% of the plotted
range, against a 0.02 gate: Supra 100 0.0171, Supra 200 0.0150, Supra 400
0.0157, Supra 800 0.0154. Axis calibration is exact to 0.0001 on every
characteristic panel. Supra 100's sensitivity panel reports a 5.05 nm worst
label error, which is a tick-detection artefact rather than a bad axis:
recalibrating that panel independently from its frame edges, which are the 250
and 750 nm gridlines, moves the three peaks by 1.3, 0.9 and 0.3 nm.

```sh
python scripts/bw_expansion/extract_graphs.py --source kodak-supra-200 --pdf /path/to/e4029-2003_05.pdf
python scripts/bw_expansion/prepare_colour_film.py --source kodak-supra-200 --output-dir target/colour-profiles
```

New extraction, preparation and profile: spektrafilm-rs contributors,
Claude-assisted, 2026; new profile/preparation data under CC BY-SA 4.0.
Manufacturer graph excerpts retain Eastman Kodak rights; no manufacturer's
endorsement or laboratory comparison is claimed.
