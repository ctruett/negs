"""Grain statistics of a scan or a render: the "signature" the fitter matches.

Grain is random, so a scan and a render can only be compared statistically.
The signature measures, on flat patches of the image:

- sigma: the per-channel standard deviation of the grain at each tone level
  (encoded output values, 0..1), i.e. how strong the grain is and how its
  strength follows the tone;
- rho1/rho2: the per-channel autocorrelation at lags 1 and 2 px, i.e. how
  big the grain is relative to the pixel;
- corr: the correlation between the channels' grain (rg, rb, gb), i.e. how
  colourful (low) or neutral (high) the grain looks;
- nps: the radially averaged noise power spectrum of the luminance grain,
  normalised to unit variance, i.e. the full shape of the grain spectrum.

Flat patches of a real scan are found automatically: the image is cut into
tiles, each tile has its best-fit plane removed, and a tile is kept when the
remainder is grain rather than structure (a Gaussian low-pass keeps a small
fraction of grain's variance but most of an edge's or texture's) and it isn't
clipped. Tiles are grouped by tone level. A render of a wedge passes its
patch tiles explicitly, one group per patch.
"""

from __future__ import annotations

import math

import numpy as np
from scipy.ndimage import gaussian_filter

LUMA = np.array([0.2126, 0.7152, 0.0722])
TILE = 32
N_LEVEL_BINS = 16
NPS_BINS = 12
# A tile is grain when its low-passed remainder keeps less than this fraction
# of the remainder's standard deviation. Grain with a correlation length of a
# few pixels keeps about 0.1-0.2 at sigma 3; edges and texture keep most.
FLATNESS_MAX = 0.3
LOWPASS_SIGMA = 3.0
CLIP_LO, CLIP_HI = 1.5 / 255, 253.5 / 255
MIN_TILES = 4


def load_image(path):
    """An image file as float64 HxWx3 in 0..1, with its bit depth and, for a
    JPEG, its quantisation tables and chroma subsampling (to degrade a render
    the same way)."""
    from PIL import Image, JpegImagePlugin

    info: dict = {"path": str(path)}
    if str(path).lower().endswith((".tif", ".tiff")):
        # Pillow reads 16-bit RGB as 8-bit; the renders are 16-bit TIFFs.
        import tifffile

        raw = tifffile.imread(path)
        info.update(format="TIFF", bits=8 * raw.dtype.itemsize)
        a = raw.astype(np.float64) / float(np.iinfo(raw.dtype).max)
    else:
        im = Image.open(path)
        info.update(format=im.format, bits=8)
        if im.format == "JPEG":
            info["jpeg_qtables"] = {int(k): list(v) for k, v in getattr(im, "quantization").items()}
            info["jpeg_subsampling"] = JpegImagePlugin.get_sampling(im)
        a = np.asarray(im.convert("RGB"), dtype=np.float64) / 255.0
    if a.ndim == 2:
        a = np.repeat(a[..., None], 3, axis=2)
    return a[..., :3], info


def _plane_detrend(tile):
    """`tile` (T x T x C) minus each channel's least-squares plane."""
    t = tile.shape[0]
    y, x = np.mgrid[0:t, 0:t]
    a = np.stack([np.ones(t * t), x.ravel(), y.ravel()], axis=1)
    flat = tile.reshape(t * t, -1)
    coef, *_ = np.linalg.lstsq(a, flat, rcond=None)
    return (flat - a @ coef).reshape(tile.shape)


def _lag_corr(r, lag):
    """Autocorrelation of a T x T residual at `lag` px, averaged over x and y."""
    v = (r * r).mean()
    if v <= 0:
        return 0.0
    cx = (r[:, lag:] * r[:, :-lag]).mean()
    cy = (r[lag:, :] * r[:-lag, :]).mean()
    return float(0.5 * (cx + cy) / v)


def _nps_radial(r):
    """Radial NPS of one detrended tile (Hann window), NPS_BINS bins on
    0..0.5 cycles/px; unnormalised."""
    t = r.shape[0]
    win = np.outer(np.hanning(t), np.hanning(t))
    p = np.abs(np.fft.fft2((r - r.mean()) * win)) ** 2 / (win**2).sum()
    f = np.fft.fftfreq(t)
    rad = np.hypot(*np.meshgrid(f, f))
    idx = np.minimum((rad / 0.5 * NPS_BINS).astype(int), NPS_BINS)
    sums = np.bincount(idx.ravel(), p.ravel(), NPS_BINS + 1)[:NPS_BINS]
    counts = np.bincount(idx.ravel(), None, NPS_BINS + 1)[:NPS_BINS]
    return sums / np.maximum(counts, 1)


def tile_stats(tile):
    """Statistics of one T x T x 3 tile, or None when it isn't flat grain."""
    if (tile <= CLIP_LO).mean() > 0.005 or (tile >= CLIP_HI).mean() > 0.005:
        return None
    r = _plane_detrend(tile)
    lum = r @ LUMA
    s = lum.std()
    if s <= 0:
        return None
    flatness = float(gaussian_filter(lum, LOWPASS_SIGMA, mode="reflect").std() / s)
    var = r.reshape(-1, 3).var(axis=0)
    c = np.corrcoef(r.reshape(-1, 3).T) if np.all(var > 0) else np.eye(3)
    return {
        "level": float((tile @ LUMA).mean()),
        "mean": tile.reshape(-1, 3).mean(axis=0),
        "var": var,
        "var_lum": float(s * s),
        "rho1": np.array([_lag_corr(r[..., ch], 1) for ch in range(3)]),
        "rho2": np.array([_lag_corr(r[..., ch], 2) for ch in range(3)]),
        "corr": np.array([c[0, 1], c[0, 2], c[1, 2]]),
        "nps": _nps_radial(lum),
        "flatness": flatness,
    }


def scan_tiles(img, tile=TILE, flatness_max=FLATNESS_MAX, roi=None):
    """Statistics of every flat, unclipped, non-overlapping tile of `img`
    (optionally within roi = (x, y, w, h) in pixels)."""
    x0, y0, w, h = roi if roi else (0, 0, img.shape[1], img.shape[0])
    out = []
    for y in range(y0, y0 + h - tile + 1, tile):
        for x in range(x0, x0 + w - tile + 1, tile):
            s = tile_stats(img[y:y + tile, x:x + tile])
            if s is not None and s["flatness"] <= flatness_max:
                out.append(s)
    return out


def _group(stats, key):
    n = len(stats)
    var = np.median([s["var"] for s in stats], axis=0)
    nps = np.mean([s["nps"] / max(s["var_lum"], 1e-30) for s in stats], axis=0)
    return {
        "key": key,
        "n_tiles": n,
        "level": float(np.median([s["level"] for s in stats])),
        "mean_rgb": np.median([s["mean"] for s in stats], axis=0).tolist(),
        "sigma": np.sqrt(var).tolist(),
        "sigma_lum": float(math.sqrt(np.median([s["var_lum"] for s in stats]))),
        "rho1": np.median([s["rho1"] for s in stats], axis=0).tolist(),
        "rho2": np.median([s["rho2"] for s in stats], axis=0).tolist(),
        "corr": np.median([s["corr"] for s in stats], axis=0).tolist(),
        "nps": nps.tolist(),
    }


def signature_from_tiles(stats, groups=None, source=None):
    """Group tile statistics into a signature. `groups` maps each tile to a
    group key (a wedge patch); by default tiles are binned by tone level."""
    if groups is None:
        groups = [min(int(s["level"] * N_LEVEL_BINS), N_LEVEL_BINS - 1) for s in stats]
    by = {}
    for s, g in zip(stats, groups):
        by.setdefault(g, []).append(s)
    out = [_group(v, k) for k, v in sorted(by.items()) if len(v) >= MIN_TILES]
    out.sort(key=lambda g: g["level"])
    allnps = [s["nps"] / max(s["var_lum"], 1e-30) for s in stats]
    return {
        "format": "negs-grain-signature",
        "version": 1,
        "source": source or {},
        "tile": TILE,
        "n_tiles": len(stats),
        "nps_freq": ((np.arange(NPS_BINS) + 0.5) * 0.5 / NPS_BINS).tolist(),
        "nps": np.mean(allnps, axis=0).tolist() if allnps else [],
        "groups": out,
    }


def analyze_image(img, source=None, roi=None, flatness_max=FLATNESS_MAX):
    return signature_from_tiles(scan_tiles(img, roi=roi, flatness_max=flatness_max), source=source)


# --- comparison --------------------------------------------------------------


def _interp_curve(sim_groups, field, level, ch, x_ch=None):
    """`field[ch]` of the simulated groups at `level`, linear in level (log
    for sigma); None outside the simulated range. With `x_ch`, `level` is
    channel `x_ch`'s mean value rather than the luminance level, so a
    coloured patch meets the wedge where that channel has the same value."""
    xs = [g["level"] if x_ch is None else g["mean_rgb"][x_ch] for g in sim_groups]
    order = np.argsort(xs)
    lv = np.asarray(xs)[order]
    if len(lv) < 2 or level < lv.min() or level > lv.max():
        return None
    vals = np.array([sim_groups[i][field][ch] for i in order])
    if field == "sigma":
        return float(np.exp(np.interp(level, lv, np.log(np.maximum(vals, 1e-9)))))
    return float(np.interp(level, lv, vals))


def sigma_log_ratios(sim, meas, channels=(0, 1, 2), floor=0.5 / 255):
    """Per channel, the weighted mean log(sim sigma / scan sigma) over the
    scan levels the render covers where both stand clear of the floor; None
    for a channel with no such level."""
    sg = sorted(sim["groups"], key=lambda g: g["level"])
    out = {}
    for ch in channels:
        num = den = 0.0
        for g in meas["groups"]:
            s = _interp_curve(sg, "sigma", g["mean_rgb"][ch], ch, x_ch=ch)
            m = g["sigma"][ch]
            if s is None or s < 2 * floor or m < 2 * floor:
                continue
            w = math.sqrt(g["n_tiles"])
            num += w * math.log(s / m)
            den += w
        out[ch] = num / den if den > 0 else None
    return out


def distance(sim, meas, weights=None, nps_fmax=0.5, channels=(0, 1, 2), floor=0.5 / 255):
    """How far a render's signature is from a scan's, with its parts.

    sigma: RMS log ratio of grain strength, at the scan's tone levels the
    render covers; rho: RMS difference of the lag-1/2 autocorrelations; corr:
    RMS difference of the channel correlations; nps: RMS log ratio of the
    normalised luminance spectra up to `nps_fmax` cycles/px. A scan level the
    render doesn't reach is left out and counted in `uncovered`.

    `floor` (half an 8-bit code) is added to both sigmas before the log
    ratio: below it the grain is lost in quantisation, and a sigma that
    rounds to 0 in one file would otherwise dominate the sum. The rho and
    corr terms are weighted by sigma^2 / (sigma^2 + floor^2) for the same
    reason: they are noise where the grain is below the floor.
    """
    w = {"sigma": 1.0, "rho": 1.0, "corr": 0.5, "nps": 0.5}
    w.update(weights or {})
    sig, rho, corr, wsum = [], [], [], []
    uncovered = 0
    sg = sorted(sim["groups"], key=lambda g: g["level"])
    for g in meas["groups"]:
        wt = math.sqrt(g["n_tiles"])
        hit = False
        for ch in channels:
            x = g["mean_rgb"][ch]
            s = _interp_curve(sg, "sigma", x, ch, x_ch=ch)
            if s is None:
                continue
            hit = True
            m = g["sigma"][ch]
            sig.append((wt, math.log((s + floor) / (m + floor))))
            snr = min(s, m) ** 2 / (min(s, m) ** 2 + floor**2)
            for f in ("rho1", "rho2"):
                rho.append((wt * snr, _interp_curve(sg, f, x, ch, x_ch=ch) - g[f][ch]))
        if hit and len(channels) == 3:
            snr = min(g["sigma"]) ** 2 / (min(g["sigma"]) ** 2 + floor**2)
            for k in range(3):
                c = _interp_curve(sg, "corr", g["level"], k)
                if c is not None:
                    corr.append((wt * snr, c - g["corr"][k]))
        uncovered += 0 if hit else 1

    def rms(pairs):
        if not pairs:
            return float("nan")
        ws = sum(p[0] for p in pairs)
        if ws <= 0:
            return float("nan")
        return math.sqrt(sum(p[0] * p[1] ** 2 for p in pairs) / ws)

    f = np.array(meas["nps_freq"])
    keep = (f <= nps_fmax) & (np.array(meas["nps"]) > 0) & (np.array(sim["nps"]) > 0)
    nps = (
        float(np.sqrt(np.mean(np.log(np.array(sim["nps"])[keep] / np.array(meas["nps"])[keep]) ** 2)))
        if keep.any()
        else float("nan")
    )
    parts = {"sigma": rms(sig), "rho": rms(rho), "corr": rms(corr), "nps": nps}
    total = sum(w[k] * v**2 for k, v in parts.items() if not math.isnan(v))
    return {"total": float(math.sqrt(total)), "parts": parts, "uncovered": uncovered,
            "covered": len(meas["groups"]) - uncovered}
