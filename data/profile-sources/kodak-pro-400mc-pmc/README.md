# Kodak Pro Films source record — 4 November 2026

Publication **E-182** (February 1997) covers five colour negatives — Pro 100 /
PRN, Pro 100T / PRT, Pro 400 / PPF, Pro 400 MC / PMC and Pro 1000 / PMZ — one
to a page, each with its own characteristic, spectral-sensitivity and
spectral-dye-density panels. **Two are shipped.** See
[the Supra record](../kodak-supra-200/README.md) for how multi-stock sheets are
handled here and [the Ektachrome 64 EPR record](../kodak-ektachrome64-epr/README.md)
for the extraction and unmixing method, which is shared.

| Stock | Characteristic | Sensitivity | Spectral dye | Shipped |
|---|---|---|---|---|
| Pro 100 / PRN | p8, −3.00…1.00 | p8, axis unusable | p8, 400–700 nm | no |
| Pro 100T / PRT | p9, −3.00…1.00 | p9, axis unusable | p9, 400–700 nm | no |
| Pro 400 / PPF | p10, −3.00…0.37 | p10, 407–690 nm | p10, 400–700 nm | no |
| Pro 400 MC / PMC | p11, −3.00…0.57 | p11, 380–680 nm | p11, 400–700 nm | **yes** |
| Pro 1000 / PMZ | p12, −3.88…−0.08 | p12, 380–690 nm | p12, 400–700 nm | **yes** |

## This sheet strokes its curves in pieces

Every panel here hands back more polylines than it plots curves: the dye panels
three for two, the Pro 1000 sensitivity panel five for three. The pieces are
one curve with the pen lifted, and they meet end to end — usually within a
tenth of a point, at worst within two. `extract_graphs.py` gains an opt-in
`join_fragments` that reunites them, considering **endpoints only**, so two
curves crossing each other are never merged: at a crossing neither has an end.

Joining also needs the stray-stroke filter relaxed. A curve's steep left
shoulder is often its own 12-to-17-point stroke, well under the tenth of the
frame width that separates a curve from a stray mark, so under
`join_fragments` the gathering threshold drops to a thirtieth and whatever is
still short after joining is dropped. The steepest few nanometres at the blue
end stay unrecoverable — drawn too near vertical to be single-valued — so the
dye traces begin 5 to 8 nm inside the panel's 400 nm edge. Each recipe's
`known_gaps` says so.

## Neutrality

Balanced through the print, repeatedly until the fit stopped moving. Holding
the print filters fixed, that converges:

| Stock | before | after |
|---|---|---|
| Pro 400 MC / PMC | 26.2% | **5.0%** |
| Pro 1000 / PMZ | 28.9% | **4.4%** |

Pro 1000 PMZ is the best-balanced colour negative in the catalogue, ahead of
Portra 160VC at 4.9% and well ahead of the shipped references (Ektar 100 7.7%,
Portra 800 10.1%, Gold 200 10.4%, Portra 400 13.0%, Portra 160 15.9%). PMC is
third. Pro 400 PPF reached 10.4% and is still not shipped — see below.

Convergence is worth stating plainly, because it is the counterpart to a result
recorded with the Supra sheets: balance and print-filter derivation *diverge*
when iterated against each other, while the balance on its own, with the
filters held where they were derived, settles. PPF took two passes to find its
exposure shift at all; the first left it at 18.9%.

## A good ramp score is not a good render

Pro 400 PPF scored 10.4% off neutral — mid-table, better than shipped Gold 200
— and renders a washed-out, flat frame with a blue-grey veil. The cause is its
mid-grey anchor. Engine zero is placed where each layer reaches the density the
densitometer reads through the sheet's own midscale neutral, found by
interpolating the characteristic curves; for PPF's green and blue layers that
density lies **below everything the panel plots**, so the interpolation clamps
and the anchor lands at the left edge of the plotted range: −2.63, −3.00, −3.00
against a panel starting at −3.00. The whole exposure scale is then shifted
about three stops.

The grey ramp cannot see this, because a uniformly misplaced anchor is still
neutral. `prepare_colour_film.py` now refuses a pinned anchor outright, and
re-preparing every colour source here confirms PPF is the only one it catches.
Its characteristic panel is also the coarsest in the repository — 17 line
segments where the others carry 100 to 130 points.

## Two more stocks lose their axes

Pro 100 / PRN and Pro 100T / PRT lose their sensitivity panels, which draw
almost no gridlines the tick finder can see: their only honest ticks are the
frame edges, and no pairing of labels to ticks is collinear. Calibrating them
anyway lands 2 to 7 nm out depending on the tolerance chosen, which is exactly
the kind of silent error worth failing on, so `calibrate` holds its fallback
pass to a tight collinearity threshold and these panels fail. With no
sensitivity there is no profile. Their characteristic and dye panels extract
cleanly, so a donor sensitivity set would complete them — a borrow larger than
anything taken here so far. Losing PRT also costs this sheet's only
tungsten-balanced stock.

## Agreement

Maximum residual on the unmixed dye amounts, over the inner 98% of the plotted
range, against a 0.02 gate: Pro 400 MC 0.0107, Pro 1000 0.0153. Dye donors were
chosen by sweeping every shipped colour negative against each sheet's own
midscale-neutral-minus-D-min: `fujifilm_pro_400h` for PMC at 0.092 and
`kodak_portra_800` for PMZ at 0.038. PMC's is the poorest donor fit of anything
shipped here and it balances to 5.0%, which is further evidence — after the
Supra sheets — that the spectral residual does not predict neutrality.

```sh
python scripts/bw_expansion/extract_graphs.py --source kodak-pro-1000-pmz --pdf /path/to/e182-Pro_Films.pdf
python scripts/bw_expansion/prepare_colour_film.py --source kodak-pro-1000-pmz --output-dir target/colour-profiles
```

New extraction, preparation and profile: spektrafilm-rs contributors,
Claude-assisted, 2026; new profile/preparation data under CC BY-SA 4.0.
Manufacturer graph excerpts retain Eastman Kodak rights; no manufacturer's
endorsement or laboratory comparison is claimed.
