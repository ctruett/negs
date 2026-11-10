"""Rendering grain with the Negs engine for the fitter.

The engine is run through the release CLI (`target/release/spektrafilm`) on a
synthetic grey wedge: flat patches from 6 stops under to 5 over a mid grey,
developed by the film, then scanned on the lab scanner the scan came from
(`--scan-film --scanner`) or printed. The wedge is rendered at the scan's
micrometres per pixel (through `camera.film_format_mm`), so the grain has
the scan's size in pixels, and is then degraded like the scan's file (8-bit
quantisation, the JPEG's own quantisation tables and subsampling).

Halation is off: on a flat patch it only shifts the level, and near the
patch edges it would bleed into the measured interior. Auto exposure is off
so each patch keeps its exposure.
"""

from __future__ import annotations

import io
import json
import os
import subprocess
import tempfile
import tomllib
from pathlib import Path

import numpy as np

import grainstats as gs

ROOT = Path(__file__).resolve().parents[2]
CLI = Path(os.environ.get("NEGS_CLI", ROOT / "target/release/spektrafilm"))

WEDGE_STOPS = np.linspace(-6.0, 5.0, 16)
WEDGE_COLS = 4
PATCH = 192
MARGIN = 16
MID_GREY = 0.184

# Studio stock names (experimental/studio/<stock>) that differ from the
# engine's profile names, or that only have a near relative in the engine.
STUDIO_TO_PROFILE = {
    "kodak_tri_x_400": "kodak_trix400_d76_8min",
    "kodak_ektachrome_e100": "kodak_ektachrome_100",
    "kodak_eastman_double_x_5222": "kodak_doublex",
    "fujifilm_velvia_50": "fujifilm_velvia_100",
    "fujifilm_400": "fujifilm_xtra_400",
}

# Upstream GrainParams schema defaults (crates/spektrafilm-core/src/grain.rs).
SCHEMA = {
    "rms_granularity": [6.0, 8.0, 10.0],
    "density_min": [0.03, 0.03, 0.03],
    "uniformity": [0.97, 0.97, 0.97],
    "particle_scale_sublayers": [1.0, 0.5, 0.25],
}
GRAIN_DEFAULTS = {
    "blur": 0.89,
    "mult_usm_sigma": 0.7,
    "mult_usm_amount": 1.5,
    "blur_dye_clouds_um": 2.0,
    "micro_structure": [0.2, 30.0],
}
SCANNER_USM_DEFAULT = [0.7, 0.7]


def profile_info(film):
    return json.loads((ROOT / "data/profiles" / f"{film}.json").read_text())["info"]


def is_bw(film):
    return profile_info(film).get("channel_model") == "bw"


def engine_grain(film):
    """The film's grain parameters as the engine resolves them with no
    overrides: `grain::grain_settings` (stock table over the class defaults,
    else the schema defaults; B&W broadcast from channel 0)."""
    presets = tomllib.loads((ROOT / "data/presets/grain.toml").read_text())
    info = profile_info(film)
    bw = info.get("channel_model") == "bw"
    out: dict = {k: list(v) for k, v in SCHEMA.items()}
    stock = presets.get(info.get("stock") or film)
    if stock is not None:
        cls = presets["defaults"]["bw" if bw else "color"][info.get("type", "negative")]
        for k in SCHEMA:
            v = stock.get(k, cls.get(k))
            if v is not None:
                out[k] = [float(x) for x in v] + [float(v[-1])] * (3 - len(v))
    if bw:
        for k in ("rms_granularity", "density_min", "uniformity"):
            out[k] = [out[k][0]] * 3
    out.update({k: (list(v) if isinstance(v, list) else v) for k, v in GRAIN_DEFAULTS.items()})
    return out


def wedge():
    """The linear grey wedge and, per patch, the interior tile origins."""
    rows = -(-len(WEDGE_STOPS) // WEDGE_COLS)
    img = np.zeros((rows * PATCH, WEDGE_COLS * PATCH, 3), np.float32)
    tiles = []
    for i, s in enumerate(WEDGE_STOPS):
        r, c = divmod(i, WEDGE_COLS)
        img[r * PATCH:(r + 1) * PATCH, c * PATCH:(c + 1) * PATCH] = MID_GREY * 2.0**s
        inner = PATCH - 2 * MARGIN
        for ty in range(0, inner - gs.TILE + 1, gs.TILE):
            for tx in range(0, inner - gs.TILE + 1, gs.TILE):
                tiles.append((i, c * PATCH + MARGIN + tx, r * PATCH + MARGIN + ty))
    return img, tiles


def render_wedge(film, grain, um_per_px, scanner=None, paper=None, scanner_usm=None, grain_on=True):
    """Render the wedge through the engine; returns (encoded image 0..1, tiles)."""
    import tifffile

    img, tiles = wedge()
    params = {
        "camera": {"auto_exposure": False, "film_format_mm": um_per_px * max(img.shape[:2]) / 1000.0},
        "film_render": {"halation": {"active": False}, "grain": dict(grain, active=grain_on)},
    }
    if scanner_usm is not None:
        params["scanner"] = {"unsharp_mask": list(scanner_usm)}
    with tempfile.TemporaryDirectory(prefix="negs-grain-") as tmp:
        tmp = Path(tmp)
        tifffile.imwrite(tmp / "wedge.tif", img)
        (tmp / "params.json").write_text(json.dumps(params))
        cmd = [str(CLI), "process", str(tmp / "wedge.tif"), "-o", str(tmp / "out.tif"), "--bit-depth", "16",
               "--film", film, "--input-colour", "sRGB", "--input-linear", "--no-metadata",
               "--params", str(tmp / "params.json"), "--data-dir", str(ROOT / "data")]
        if scanner:
            cmd += ["--scan-film", "--scanner", scanner]
        elif paper:
            cmd += ["--paper", paper]
        env = dict(os.environ, SPEKTRAFILM_BACKEND=os.environ.get("SPEKTRAFILM_BACKEND", "cpu"))
        run = subprocess.run(cmd, capture_output=True, text=True, env=env)
        if run.returncode != 0:
            raise RuntimeError(f"engine failed ({run.returncode}): {' '.join(cmd)}\n{run.stderr[-2000:]}")
        out = tifffile.imread(tmp / "out.tif").astype(np.float64) / 65535.0
    return out[..., :3], tiles


def degrade_like(img, info):
    """`img` (0..1) stored the way the scan's file was: 8-bit, and for a JPEG
    re-encoded with the scan's own quantisation tables and subsampling."""
    if info.get("format") == "JPEG":
        from PIL import Image

        q = np.clip(np.round(img * 255.0), 0, 255).astype(np.uint8)
        buf = io.BytesIO()
        tables = [info["jpeg_qtables"][k] for k in sorted(info["jpeg_qtables"], key=int)]
        Image.fromarray(q).save(buf, "JPEG", qtables=tables, subsampling=info.get("jpeg_subsampling", 0))
        return np.asarray(Image.open(buf).convert("RGB"), np.float64) / 255.0
    if info.get("bits", 8) == 8:
        return np.round(np.clip(img, 0, 1) * 255.0) / 255.0
    return img


def wedge_signature(img, tiles, source=None):
    stats, groups = [], []
    for i, x, y in tiles:
        s = gs.tile_stats(img[y:y + gs.TILE, x:x + gs.TILE])
        if s is not None:
            stats.append(s)
            groups.append(i)
    return gs.signature_from_tiles(stats, groups, source=source)
