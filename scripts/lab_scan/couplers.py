"""Fit a colour film's DIR couplers to the studio scans of it, on both scanners.

    couplers.py --film "Kodak Portra 160"        # fit, and write if it helps
    couplers.py --all                            # every profiled colour film

The scanner looks stay fixed (data/scanners/*.toml): one look per scanner
and type is shared by every film, so what's left between a film's render and
its real scans is the film's own. Its nine coupler strengths are fitted on 0
and +1 EV, both scanners at once, and kept in data/presets/couplers.toml only
if they beat the film's current couplers on the held-out −1 and +2 EV frames.
"""
from __future__ import annotations

import argparse
import re
import sys
import tomllib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np
from scipy.optimize import least_squares

import charts
import fit
import render

COUPLERS = charts.REPO / "data/presets/couplers.toml"
KEYS = [("gamma_samelayer_rgb", 3), ("gamma_interlayer_r_to_gb", 2),
        ("gamma_interlayer_g_to_rb", 2), ("gamma_interlayer_b_to_rg", 2)]
FITTED_HEADER = "# --- Negs: fitted to real film"
# The least held-out hue gain (°) for which a film's couplers are replaced.
MIN_GAIN = 0.5


def current(stock: str, film_type: str) -> np.ndarray:
    """The film's couplers now: its own section, else its class's."""
    data = tomllib.loads(COUPLERS.read_text())
    section = data.get(stock) or data["defaults"]["color"]["positive" if film_type == "slide" else "negative"]
    return np.concatenate([section[k] for k, _ in KEYS])


def as_params(theta: np.ndarray) -> dict:
    out, i = {}, 0
    for key, n in KEYS:
        out[key] = [float(v) for v in theta[i:i + n]]
        i += n
    return {"film_render": {"dir_couplers": out}}


def looks(film_type: str) -> dict[str, fit.Look]:
    out = {}
    for scanner in ("frontier", "noritsu"):
        t = tomllib.loads((charts.REPO / f"data/scanners/{scanner}.toml").read_text())[film_type]
        look = fit.Look(t["curve"], t["matrix"], t.get("cast", [0, 0, 0]))
        look.gain = t.get("gain", 1.0)
        out[scanner] = look
    return out


def frames(film: str):
    """(ev, train, {scanner: real patches}) for each exposure of the film."""
    by_ev: dict[str, dict] = {}
    for row in charts.index():
        if row.film == film and not row.push:
            real = fit.real(row)
            if real is not None:
                by_ev.setdefault(row.exposure, {})[row.scanner.lower()] = (row.ev, real)
    for exposure, scans in sorted(by_ev.items()):
        ev = next(iter(scans.values()))[0]
        yield ev, exposure in fit.TRAIN_EVS, {s: r for s, (_, r) in scans.items()}


def residuals(theta, stock, data, film_looks):
    res = []
    for ev, _, scans in data:
        x = render.signal(stock, "frontier", ev, as_params(theta))
        for scanner, real in scans.items():
            sim = film_looks[scanner].srgb(x)
            res.append((fit.oklab(fit.luminance_matched(sim, real)) - fit.oklab(real)).ravel())
            res.append(3.0 * (fit.oklab(fit.per_channel_matched(sim))[:, 1:]
                              - fit.oklab(fit.per_channel_matched(real))[:, 1:]).ravel())
    return np.concatenate(res)


def score(theta, stock, data, film_looks):
    """Mean hue error (°) and ΔE over these frames, both scanners."""
    hue, de = [], []
    for ev, _, scans in data:
        x = render.signal(stock, "frontier", ev, as_params(theta))
        for scanner, real in scans.items():
            sim = film_looks[scanner].srgb(x)
            hue.append(fit.hue_error(sim, real))
            de.append(fit.delta_e(sim, real))
    return float(np.nanmean(hue)), float(np.mean(de))


def write(stock: str, film: str, theta: np.ndarray, before: tuple, after: tuple) -> None:
    lines = [f"[{stock}]",
             f"# Fitted in Negs on {np.datetime64('today')} to Color Precision's studio scans of {film}",
             "# (ColorChecker Digital SG, daylight, 0 and +1 EV, Frontier and Noritsu lab looks),",
             f"# scripts/lab_scan/couplers.py. Held-out (−1, +2 EV) hue {before[0]:.1f}° -> {after[0]:.1f}°,",
             f"# ΔE {before[1]:.1f} -> {after[1]:.1f}."]
    for key, values in as_params(theta)["film_render"]["dir_couplers"].items():
        lines.append(f"{key} = [{', '.join(f'{v:.4f}' for v in values)}]")
    block = "\n".join(lines) + "\n"
    text = COUPLERS.read_text()
    section = re.compile(rf"(?ms)^\[{re.escape(stock)}\]\n.*?(?=^\[|\Z)")
    if section.search(text):
        text = section.sub(lambda _: block + "\n", text, count=1)
    else:
        if FITTED_HEADER not in text:
            text = text.rstrip("\n") + f"\n\n{FITTED_HEADER}\n"
        text = text.rstrip("\n") + "\n" + block
    COUPLERS.write_text(text)


def fit_film(film: str, dry_run: bool) -> None:
    stock, film_type = charts.FILMS[film], charts.film_type(film)
    film_looks = looks(film_type)
    data = list(frames(film))
    train = [d for d in data if d[1]]
    held = [d for d in data if not d[1]]
    start = current(stock, film_type)
    before = score(start, stock, held, film_looks)
    print(f"{film}: {len(train)} training and {len(held)} held-out exposures; held out before "
          f"{before[0]:.1f}° / {before[1]:.1f}", flush=True)
    sol = least_squares(residuals, start, args=(stock, train, film_looks), bounds=(0.0, 0.9),
                        diff_step=0.05, max_nfev=60)
    after = score(sol.x, stock, held, film_looks)
    print(f"  fitted {np.round(sol.x, 4).tolist()}; held out after {after[0]:.1f}° / {after[1]:.1f} "
          f"({sol.nfev} evaluations)", flush=True)
    # Couplers also shape edges and sharpness, so a refit has to earn its place.
    if after[0] <= before[0] - MIN_GAIN and after[1] <= before[1] * 1.05:
        if not dry_run:
            write(stock, film, sol.x, before, after)
            print("  written", flush=True)
    else:
        print(f"  kept the current couplers: the fit didn't beat them by {MIN_GAIN}° on held-out frames", flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--film", action="append", default=[])
    ap.add_argument("--all", action="store_true", help="every profiled colour film but Portra 400")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()
    films = a.film or [f for f in charts.FILMS if a.all and charts.film_type(f) != "bw" and f != "Kodak Portra 400"]
    for film in films:
        fit_film(film, a.dry_run)


if __name__ == "__main__":
    main()
