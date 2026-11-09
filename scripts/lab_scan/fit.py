"""Fit a lab scanner's look for one film type to the studio chart scans.

    fit.py --scanner frontier --type colour_negative

Each frame's look input (the balanced log signal) is rendered once through
the CLI and cached; the look itself is evaluated here, as `Look::apply`
does, so the fit needs no render per step. The fitted table is written into
`data/scanners/<scanner>.toml`.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import numpy as np
from scipy.optimize import least_squares

import charts
import render

KNOTS = np.array([-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0])
CENTRE = 4  # KNOTS[CENTRE] == 0, pinned at the reference grey
HELD_OUT_FILMS = {"Kodak Portra 800", "Kodak UltraMax 400"}
TRAIN_EVS = {"+0EV", "+1EV"}
CACHE = charts.REPO / "target/lab_scan"

# ---- Colour ----

M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
               [0.2119034982, 0.6806995451, 0.1073969566],
               [0.0883024619, 0.2817188376, 0.6299787005]])
M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
               [1.9779984951, -2.4285922050, 0.4505937099],
               [0.0259040371, 0.7827717662, -0.8086757660]])
SRGB_TO_XYZ = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
XYZ_TO_SRGB = np.linalg.inv(SRGB_TO_XYZ)
REC2020_TO_SRGB = XYZ_TO_SRGB @ render.REC2020_TO_XYZ


def oklab(srgb_linear: np.ndarray) -> np.ndarray:
    return np.cbrt(np.clip(srgb_linear, 1e-9, None) @ M1.T) @ M2.T


def neutral_mask() -> np.ndarray:
    lab = charts.sg_lab()
    return np.hypot(lab[:, 1], lab[:, 2]) < 4.0


def luminance_matched(sim: np.ndarray, real: np.ndarray) -> np.ndarray:
    """`sim` scaled so its neutral patches' mean luminance is the real's."""
    n = neutral_mask()
    y = np.array([0.2126, 0.7152, 0.0722])
    return sim * (real[n] @ y).mean() / (sim[n] @ y).mean()


def per_channel_matched(p: np.ndarray) -> np.ndarray:
    """The plan's hue normalisation: each channel scaled on the neutrals."""
    n = neutral_mask()
    return p / p[n].mean(0) * p[n].mean()


def hue_error(sim: np.ndarray, real: np.ndarray) -> float:
    s, r = oklab(per_channel_matched(sim)), oklab(per_channel_matched(real))
    keep = np.hypot(r[:, 1], r[:, 2]) > 0.02
    if not keep.any():
        return float("nan")
    h = lambda c: np.degrees(np.arctan2(c[:, 2], c[:, 1]))
    return float(np.abs((h(s[keep]) - h(r[keep]) + 180) % 360 - 180).mean())


def delta_e(sim: np.ndarray, real: np.ndarray) -> float:
    return float(np.linalg.norm(oklab(luminance_matched(sim, real)) - oklab(real), axis=1).mean() * 100)


# ---- The look, as look.rs evaluates it ----

def fritsch_carlson(x: np.ndarray, y: np.ndarray) -> np.ndarray:
    n = len(x)
    d = np.diff(y) / np.diff(x)
    m = np.zeros(n)
    m[0], m[-1] = d[0], d[-1]
    for i in range(1, n - 1):
        m[i] = 0.0 if d[i - 1] * d[i] <= 0 else (d[i - 1] + d[i]) / 2
    for i in range(n - 1):
        if d[i] == 0:
            m[i] = m[i + 1] = 0.0
            continue
        a, b = m[i] / d[i], m[i + 1] / d[i]
        s = a * a + b * b
        if s > 9:
            tau = 3 / np.sqrt(s)
            m[i], m[i + 1] = tau * a * d[i], tau * b * d[i]
    return m


def curve_at(knots, values, x):
    m = fritsch_carlson(knots, values)
    out = np.empty_like(x)
    lo, hi = x <= knots[0], x >= knots[-1]
    out[lo] = values[0] + m[0] * (x[lo] - knots[0])
    out[hi] = values[-1] + m[-1] * (x[hi] - knots[-1])
    mid = ~(lo | hi)
    xm = x[mid]
    i = np.searchsorted(knots, xm, side="right") - 1
    h = knots[i + 1] - knots[i]
    t = (xm - knots[i]) / h
    t2, t3 = t * t, t * t * t
    out[mid] = ((2 * t3 - 3 * t2 + 1) * values[i] + (t3 - 2 * t2 + t) * h * m[i]
                + (-2 * t3 + 3 * t2) * values[i + 1] + (t3 - t2) * h * m[i + 1])
    return out


class Look:
    def __init__(self, curve, matrix, cast=(0.0, 0.0, 0.0)):
        self.curve = np.asarray(curve, float)    # 3 x 9
        self.matrix = np.asarray(matrix, float)  # 3 x 3
        self.cast = np.asarray(cast, float)
        self.default_offset = np.zeros(3)

    @classmethod
    def identity(cls):
        return cls(np.tile(KNOTS + render.REF, (3, 1)), np.eye(3))

    def apply(self, x: np.ndarray) -> np.ndarray:
        """log10 linear Rec.2020 for an N x 3 signal."""
        y = np.stack([curve_at(KNOTS, self.curve[c], x[:, c]) for c in range(3)], 1)
        return y @ self.matrix.T + self.cast

    def srgb(self, x: np.ndarray) -> np.ndarray:
        return (10 ** self.apply(x)) @ REC2020_TO_SRGB.T

    def toml(self, comment: str) -> str:
        f = lambda v: "[" + ", ".join(repr(float(a)) for a in v) + "]"
        lines = [comment, f"curve_knots = {f(KNOTS)}", "curve = ["]
        lines += [f"    {f(row)}," for row in self.curve]
        lines += ["]", f"matrix = [{', '.join(f(r) for r in self.matrix)}]", f"default_offset = {f(self.default_offset)}"]
        if np.any(self.cast):
            lines.append(f"cast = {f(self.cast)}")
        return "\n".join(lines) + "\n"


def curve_from(steps: np.ndarray) -> np.ndarray:
    """A rising curve from 8 log-steps, pinned at the reference grey."""
    inc = np.exp(steps) * np.diff(KNOTS)
    below, above = inc[:CENTRE][::-1], inc[CENTRE:]
    return np.concatenate([render.REF - np.cumsum(below)[::-1], [render.REF], render.REF + np.cumsum(above)])


def matrix_from(off: np.ndarray) -> np.ndarray:
    """Rows summing to 1 from the six off-diagonal terms."""
    m = np.zeros((3, 3))
    m[~np.eye(3, dtype=bool)] = off
    m[np.diag_indices(3)] = 1 - m.sum(1)
    return m


def look_from(theta: np.ndarray, film_type: str) -> Look:
    if film_type == "colour_negative":
        curves = [curve_from(theta[8 * c:8 * c + 8]) for c in range(3)]
        return Look(curves, matrix_from(theta[24:30]))
    if film_type == "slide":
        return Look([curve_from(theta[:8])] * 3, matrix_from(theta[8:14]))
    cast = np.array([theta[8], theta[9], -theta[8] - theta[9]])
    return Look([curve_from(theta[:8])] * 3, np.eye(3), cast)


def n_params(film_type: str) -> int:
    return {"colour_negative": 30, "slide": 14, "bw": 10}[film_type]


# ---- Data ----

def frames(scanner: str, film_type: str):
    """Every unpushed frame of the profiled films, with whether it trains."""
    for row in charts.index():
        if row.film in charts.FILMS and row.type == film_type and row.scanner.lower() == scanner and not row.push:
            yield row, row.film not in HELD_OUT_FILMS and row.exposure in TRAIN_EVS


def _cache_path(kind: str, row: charts.Row) -> Path:
    key = re.sub(r"[^A-Za-z0-9+.-]+", "_", f"{kind}_{row.film}_{row.scanner}_{row.exposure}")
    return CACHE / f"{key}.npy"


def _cached(kind: str, row: charts.Row, make, stamp: float) -> np.ndarray | None:
    path = _cache_path(kind, row)
    if path.exists() and path.stat().st_mtime > stamp:
        v = np.load(path)
        return None if np.isnan(v).all() else v
    CACHE.mkdir(parents=True, exist_ok=True)
    v = make()
    np.save(path, np.full((140, 3), np.nan) if v is None else v)
    return v


def real(row: charts.Row) -> np.ndarray | None:
    """The scan's patches, linear sRGB, or None when the chart isn't found."""
    def make():
        img = charts.load(row)
        c = charts.locate(img)
        return None if c is None else charts.sample(img, c)
    return _cached("real", row, make, (Path(charts.__file__)).stat().st_mtime)


def signal(row: charts.Row, scanner: str) -> np.ndarray:
    film = charts.FILMS[row.film]
    return _cached("signal", row, lambda: render.signal(film, scanner, row.ev), render.CLI.stat().st_mtime)


def dataset(scanner: str, film_type: str):
    out = []
    for row, train in frames(scanner, film_type):
        r = real(row)
        if r is not None:
            out.append((row, train, signal(row, scanner), r))
    return out


# ---- Fitting ----

def residuals(theta, data, film_type):
    look = look_from(theta, film_type)
    res = []
    for _, _, x, r in data:
        s = look.srgb(x)
        res.append((oklab(luminance_matched(s, r)) - oklab(r)).ravel())
        # The hue the report scores: a/b with each channel matched on the
        # neutrals, so a grey cast can't be traded for hue.
        res.append(HUE[film_type] * (oklab(per_channel_matched(s))[:, 1:] - oklab(per_channel_matched(r))[:, 1:]).ravel())
    # Smooth curves: neighbouring slopes alike, so a curve carries on past
    # the data at the slope the data sets instead of bending wildly there.
    for steps in curve_steps(theta, film_type):
        res.append(SMOOTH * np.diff(steps))
    res.append(0.02 * theta)
    return np.concatenate(res)


SMOOTH = 0.3
# The hue residual's weight per type, chosen by held-out error (slides got
# worse with it, and B&W has no hue).
HUE = {"colour_negative": 3.0, "slide": 0.0, "bw": 0.0}


def curve_steps(theta, film_type):
    return [theta[8 * c:8 * c + 8] for c in range(3)] if film_type == "colour_negative" else [theta[:8]]


def fit(scanner: str, film_type: str) -> Look:
    data = [d for d in dataset(scanner, film_type) if d[1]]
    print(f"{scanner} {film_type}: {len(data)} training frames", flush=True)
    theta0 = np.zeros(n_params(film_type))
    sol = least_squares(residuals, theta0, args=(data, film_type), method="trf", x_scale="jac", max_nfev=400)
    print(f"  cost {sol.cost:.4f}, {sol.nfev} evaluations", flush=True)
    look = look_from(sol.x, film_type)
    look.default_offset = default_offset(scanner, data)
    return look


def default_offset(scanner: str, data) -> np.ndarray:
    """The trained mean of the training frames' metered balance: what a frame
    too thin to meter (a lens cap, a blown slide) takes instead, so it scans
    as such a frame does rather than as an 18% grey. For B&W, one value."""
    offsets = np.array([
        _cached("balance", row, lambda row=row: render.balance(charts.FILMS[row.film], scanner, row.ev)[None].repeat(140, 0),
                render.CLI.stat().st_mtime)[0]
        for row, _, _, _ in data
    ])
    return offsets.mean(0)


def write(scanner: str, film_type: str, look: Look) -> None:
    path = charts.REPO / "data/scanners" / f"{scanner}.toml"
    text = path.read_text()
    tables = re.split(r"(?m)^(?=\[)", text)
    head, body = tables[0], tables[1:]
    comment = {"colour_negative": "# Colour negatives.", "slide": "# Slides.", "bw": "# Black and white."}[film_type]
    comment += " Fitted by scripts/lab_scan/fit.py to the studio chart scans."
    new = [f"[{film_type}]\n" + look.toml(comment) + "\n" if t.startswith(f"[{film_type}]") else t for t in body]
    path.write_text(head + "".join(new))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scanner", choices=["frontier", "noritsu"], required=True)
    ap.add_argument("--type", choices=["colour_negative", "slide", "bw"], required=True)
    ap.add_argument("--dry-run", action="store_true", help="fit without writing the TOML")
    a = ap.parse_args()
    look = fit(a.scanner, a.type)
    if not a.dry_run:
        write(a.scanner, a.type, look)


if __name__ == "__main__":
    main()
