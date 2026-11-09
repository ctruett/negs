"""Write docs/lab-scan-accuracy.md: how close each route comes to the real
Frontier and Noritsu scans of the studio charts.

    report.py

Three routes are scored on every profiled frame the chart is found on:
- the old direct film scan (`settings.upstream_film_scan`),
- the lab scanner with the hand-set look (identity, before fitting),
- the lab scanner with the looks in data/scanners, rendered by the CLI.

Hue error (°) follows the Portra fit: both sides normalised per channel on
the neutral patches, OKLab hue on patches with chroma > 0.02. ΔE is OKLab
×100 after one luminance scale. Held-out frames are marked.
"""
from __future__ import annotations

import sys
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import warnings

import numpy as np

import charts
import fit
import render

ROUTES = ("direct", "hand-set", "fitted")
WEDGE_EVS = (-6, -4, -2, 0, 2, 4, 6)
AIM = 6.0


def scores(row: charts.Row, scanner: str, held: bool, real: np.ndarray):
    film = charts.FILMS[row.film]
    sims = {}
    # The old direct scan only inverts nothing: on a negative it shows the
    # negative itself, so it's scored on slides only.
    if row.type == "slide":
        sims["direct"] = fit._cached("direct_srgb", row, lambda: render.direct(film, scanner, row.ev), render.CLI.stat().st_mtime)
    sims |= {
        "hand-set": fit.Look.identity().srgb(fit.signal(row, scanner)),
        # As exported: sRGB, gamut-compressed and clipped, like the lab's files.
        "fitted": render.render(film, scanner, row.ev, space="sRGB"),
    }
    return {k: (fit.hue_error(v, real), fit.delta_e(v, real)) for k, v in sims.items()}


def floors(film_type: str) -> str:
    """Hue error between the real scans themselves: the two scanners on one
    frame, and one scanner on two exposures."""
    rows = [r for r in charts.index() if r.film in charts.FILMS and r.type == film_type and not r.push]
    find = lambda film, scanner, ev: next((r for r in rows if (r.film, r.scanner, r.exposure) == (film, scanner, ev)), None)
    pairs = {"scanners": [], "exposures": []}
    for r in rows:
        if r.scanner == "Frontier":
            pairs["scanners"].append((r, find(r.film, "Noritsu", r.exposure)))
        if r.exposure == "+0EV":
            pairs["exposures"].append((r, find(r.film, r.scanner, "+1EV")))
    cells = []
    for k in ("scanners", "exposures"):
        v = [fit.hue_error(fit.real(a), fit.real(b)) for a, b in pairs[k]
             if b is not None and fit.real(a) is not None and fit.real(b) is not None]
        cells.append(f"{np.nanmean(v):.1f}°")
    return " | ".join(cells)


def wedge(film: str, scanner: str, film_type: str) -> float:
    """The largest OKLab chroma ×100 of the chart's neutral patches through
    the fitted look, from −6 to +6 EV (B&W: their spread from the mean tint)."""
    n = fit.neutral_mask()
    worst = 0.0
    for ev in WEDGE_EVS:
        out = fit.oklab(render.render(film, scanner, ev, space="sRGB"))[n]
        ab = out[:, 1:]
        if film_type == "bw":
            ab = ab - ab.mean(0)
        worst = max(worst, float(np.hypot(ab[:, 0], ab[:, 1]).max() * 100))
    return worst


def main():
    warnings.filterwarnings("ignore", category=RuntimeWarning)
    rows, summary = [], defaultdict(lambda: defaultdict(list))
    for scanner in ("frontier", "noritsu"):
        for film_type in ("colour_negative", "slide", "bw"):
            for row, train in fit.frames(scanner, film_type):
                real = fit.real(row)
                if real is None:
                    rows.append((scanner, film_type, row, not train, None))
                    continue
                s = scores(row, scanner, not train, real)
                rows.append((scanner, film_type, row, not train, s))
                for k, v in s.items():
                    summary[(scanner, film_type, "held out" if not train else "training")][k].append(v)
                print(scanner, row.film, row.exposure, {k: f"{h:.1f}° {d:.1f}" for k, (h, d) in s.items()}, flush=True)

    out = ["# Lab scan accuracy", "",
           "Written by `scripts/lab_scan/report.py` against Color Precision's studio scans of the",
           "ColorChecker Digital SG (140 patches). Hue error in degrees (lower is better), after",
           "per-channel normalisation on the neutrals; ΔE is OKLab ×100 after one luminance scale.",
           "The old direct scan shows a negative uninverted, so it is scored on slides only.",
           "B&W is scored on ΔE alone (it has no hue). Renders are sRGB, as the lab's files are.",
           "Training: 0 and +1 EV. Held out: −1 and +2 EV, and all of Portra 800 and UltraMax 400.",
           f"The aim is a held-out mean hue error of {AIM:.0f}° or less per scanner and film type.", "",
           "## Summary", "",
           "| Scanner | Type | Split | Frames | Direct scan | Hand-set look | Fitted look | Aim |",
           "|---|---|---|---|---|---|---|---|"]
    for (scanner, film_type, split), d in sorted(summary.items()):
        def cell(k):
            if not d[k]:
                return "n/a"
            hue = "–" if film_type == "bw" else f"{np.nanmean([h for h, _ in d[k]]):.1f}°"
            return f"{hue} / {np.mean([e for _, e in d[k]]):.1f}"
        fitted = np.nanmean([h for h, _ in d["fitted"]]) if film_type != "bw" else np.nan
        aim = "" if split == "training" or film_type == "bw" else ("met" if fitted <= AIM else "**missed**")
        out.append(f"| {scanner} | {film_type} | {split} | {len(d['fitted'])} | {cell('direct')} | {cell('hand-set')} | {cell('fitted')} | {aim} |")

    out += ["", "## How far apart the real scans are", "",
            "The same metric between real scans, as a floor for the numbers above.", "",
            "| Type | Frontier vs Noritsu, same frame | 0 vs +1 EV, same film and scanner |", "|---|---|---|"]
    for film_type in ("colour_negative", "slide"):
        out.append(f"| {film_type} | {floors(film_type)} |")
    out += ["", "## Grey wedge", "",
            "Largest OKLab chroma ×100 of the chart's neutrals through the fitted look, −6 to +6 EV",
            "(B&W: spread around its own tint).", "",
            "| Film | Frontier | Noritsu |", "|---|---|---|"]
    for name, film in charts.FILMS.items():
        t = charts.film_type(name)
        out.append(f"| {name} | {wedge(film, 'frontier', t):.1f} | {wedge(film, 'noritsu', t):.1f} |")

    out += ["", "## Every frame", "",
            "| Scanner | Film | EV | Held out | Direct | Hand-set | Fitted |", "|---|---|---|---|---|---|---|"]
    for scanner, film_type, row, held, s in rows:
        if s is None:
            out.append(f"| {scanner} | {row.film} | {row.exposure} | {'yes' if held else ''} | chart not found | | |")
            continue
        c = lambda k: f"{s[k][0]:.1f}° / {s[k][1]:.1f}" if k in s else "n/a"
        out.append(f"| {scanner} | {row.film} | {row.exposure} | {'yes' if held else ''} | {c('direct')} | {c('hand-set')} | {c('fitted')} |")
    path = charts.REPO / "docs/lab-scan-accuracy.md"
    path.write_text("\n".join(out) + "\n")
    print(path)


if __name__ == "__main__":
    main()
