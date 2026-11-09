"""Render the Digital SG through Negs's lab scanner, as the studio shot it.

The chart is drawn as the patches' published reflectances under D65, in
linear Rec.2020, one square a patch on the chart's dark body. A frame's
exposure goes into the pixels (×2^EV), not into Camera exposure: the lab's
auto correction meters the light on the film, and Camera exposure is locked
out of it. The CLI renders the chart with `--scan-film --scanner`, and a
look under test reaches it as `settings.lab_look_override`.
"""
from __future__ import annotations

import json
import subprocess
import tempfile
from functools import lru_cache
from pathlib import Path

import numpy as np
import tifffile

import charts

CLI = charts.REPO / "target/release/spektrafilm"
PITCH, GAP = 32, 8   # pixels a patch, pixels of chart body between patches
BODY = 0.04          # the chart body's reflectance

# Rec.2020 from XYZ (D65)
XYZ_TO_2020 = np.array([
    [1.7166512, -0.3556708, -0.2533663],
    [-0.6666844, 1.6164812, 0.0157685],
    [0.0176399, -0.0427706, 0.9421031],
])
# 2020 to XYZ, for reading the render back
REC2020_TO_XYZ = np.linalg.inv(XYZ_TO_2020)


@lru_cache(maxsize=1)
def sg_rec2020() -> np.ndarray:
    """The 140 patches' reflectance under D65, linear Rec.2020."""
    import colour

    d50 = colour.CCS_ILLUMINANTS["CIE 1931 2 Degree Standard Observer"]["D50"]
    d65 = colour.CCS_ILLUMINANTS["CIE 1931 2 Degree Standard Observer"]["D65"]
    xyz = colour.Lab_to_XYZ(charts.sg_lab(), d50)
    xyz = colour.chromatic_adaptation(xyz, colour.xy_to_XYZ(d50), colour.xy_to_XYZ(d65), method="Von Kries", transform="Bradford")
    return xyz @ XYZ_TO_2020.T


def chart_image(ev: float) -> np.ndarray:
    step = PITCH + GAP
    img = np.full((GAP + charts.ROWS * step, GAP + charts.COLS * step, 3), BODY, np.float32)
    for (c, r), rgb in zip(charts._GRID.astype(int), sg_rec2020()):
        y, x = GAP + r * step, GAP + c * step
        img[y:y + PITCH, x:x + PITCH] = rgb
    return img * np.float32(2.0 ** ev)


def centres() -> np.ndarray:
    step = PITCH + GAP
    return (GAP + charts._GRID * step + PITCH / 2).astype(np.float64)


def render(film: str, scanner: str, ev: float, look: Path | None = None, gamut: bool = True,
           space: str = "ITU-R BT.2020") -> np.ndarray:
    """The rendered chart's patches, 140 x 3, linear in `space`, as the CLI
    writes them (16-bit, clipped); `look` a look file under test."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src, out, params = tmp / "chart.tif", tmp / "out.tif", tmp / "params.json"
        tifffile.imwrite(src, chart_image(ev))
        io = {"output_color_space": space, "output_cctf_encoding": False}
        if not gamut:
            io["output_gamut_compress"] = {"algorithm": "off"}
        p = {
            "camera": {"auto_exposure": False},
            "film_render": {"grain": {"active": False}, "halation": {"active": False}},
            "io": io,
        }
        if look is not None:
            p["settings"] = {"lab_look_override": str(look)}
        params.write_text(json.dumps(p))
        _run(film, scanner, src, out, params)
        img = tifffile.imread(out)[..., :3].astype(np.float64) / 65535.0
    return charts.sample(img, centres(), frac=0.3)


def direct(film: str, scanner: str, ev: float, space: str = "sRGB") -> np.ndarray:
    """The chart through the old direct film scan, for comparison."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src, out, params = tmp / "chart.tif", tmp / "out.tif", tmp / "params.json"
        tifffile.imwrite(src, chart_image(ev))
        params.write_text(json.dumps({
            "camera": {"auto_exposure": False},
            "film_render": {"grain": {"active": False}, "halation": {"active": False}},
            "io": {"output_color_space": space, "output_cctf_encoding": False},
            "settings": {"upstream_film_scan": True},
        }))
        _run(film, scanner, src, out, params)
        img = tifffile.imread(out)[..., :3].astype(np.float64) / 65535.0
    return charts.sample(img, centres(), frac=0.3)


REF = np.log10(0.18)  # the look's reference grey, log10


def identity_look(path: Path) -> Path:
    """A look file that passes the signal through: slope 1 through the
    reference grey, identity matrix, no cast, for every type."""
    knots = [-2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5, 2.0]
    curve = [k + REF for k in knots]
    table = (
        f"curve_knots = {knots}\ncurve = [{curve}, {curve}, {curve}]\n"
        "matrix = [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]]\n"
        "default_offset = [0.0, 0.0, 0.0]\ncast = [0.0, 0.0, 0.0]\n"
    )
    path.write_text("".join(f"[{t}]\n{table}\n" for t in ("colour_negative", "slide", "bw")))
    return path


def signal(film: str, scanner: str, ev: float) -> np.ndarray:
    """The look's input for each patch, 140 x 3: the balanced log10 signal,
    read back through an identity look, unclipped and uncompressed."""
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        src, out, raw, params = tmp / "chart.tif", tmp / "out.tif", tmp / "raw.f64", tmp / "params.json"
        img = chart_image(ev)
        tifffile.imwrite(src, img)
        params.write_text(json.dumps({
            "camera": {"auto_exposure": False},
            "film_render": {"grain": {"active": False}, "halation": {"active": False}},
            "io": {"output_color_space": "ITU-R BT.2020", "output_cctf_encoding": False,
                   "output_gamut_compress": {"algorithm": "off"}},
            "settings": {"lab_look_override": str(identity_look(tmp / "identity.toml"))},
        }))
        _run(film, scanner, src, out, params, ["--raw-out", str(raw)])
        lin = np.fromfile(raw, dtype=np.float64).reshape(img.shape[0], img.shape[1], 3)
    return np.log10(np.clip(charts.sample(lin, centres(), frac=0.3), 1e-9, None)) - REF


def _run(film, scanner, src, out, params, extra=()):
    r = subprocess.run(
        [str(CLI), "process", str(src), "-o", str(out), "--film", film, "--scan-film",
         "--scanner", scanner.lower(), "--input-colour", "ITU-R BT.2020", "--input-linear",
         "--params", str(params), "--no-metadata", "--bit-depth", "16", *extra],
        capture_output=True, text=True, cwd=charts.REPO,
    )
    if r.returncode:
        raise RuntimeError(r.stderr[-500:])
