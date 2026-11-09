"""The studio scans and the ColorChecker Digital SG on them.

Each studio frame (Color Precision's film scans, `experimental/studio`, not
in the repository) holds a Digital SG on the left. `locate` finds its 140
patch centres, `sample` reads them, and `sg_lab` gives the published D50
values the simulation renders.
"""
from __future__ import annotations

import csv
import os
import subprocess
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path

import cv2
import imageio.v3 as iio
import numpy as np
from scipy.optimize import minimize

REPO = Path(__file__).resolve().parents[2]


def _studio() -> Path:
    if env := os.environ.get("LAB_SCAN_STUDIO"):
        return Path(env)
    # A worktree shares the main checkout's untracked studio folder.
    common = subprocess.run(
        ["git", "rev-parse", "--path-format=absolute", "--git-common-dir"],
        cwd=REPO, capture_output=True, text=True,
    ).stdout.strip()
    for root in (REPO, Path(common).parent if common else REPO):
        if (root / "experimental/studio/index.csv").exists():
            return root / "experimental/studio"
    return REPO / "experimental/studio"


STUDIO = _studio()

# The studio films Negs has a profile for (the spec's 12).
FILMS = {
    "Kodak Portra 160": "kodak_portra_160",
    "Kodak Portra 400": "kodak_portra_400",
    "Kodak Portra 800": "kodak_portra_800",
    "Kodak Ektar 100": "kodak_ektar_100",
    "Kodak Gold 200": "kodak_gold_200",
    "Kodak UltraMax 400": "kodak_ultramax_400",
    "Fujifilm C200": "fujifilm_c200",
    "Fujifilm Pro 400H": "fujifilm_pro_400h",
    "Fujifilm Provia 100F": "fujifilm_provia_100f",
    "Kodak Ektachrome E100": "kodak_ektachrome_100",
    "Kodak TRI-X 400": "kodak_trix400_d76_8min",
    "Kodak Eastman Double-X 5222": "kodak_doublex",
}

TYPES = {
    "Color Negative (C-41)": "colour_negative",
    "Color Slide (E-6)": "slide",
    "Black & White": "bw",
}


@dataclass(frozen=True)
class Row:
    film: str
    type: str       # colour_negative, slide or bw
    push: str
    exposure: str   # as index.csv has it: "+0EV", "-1EV"
    scanner: str    # Frontier or Noritsu
    path: Path

    @property
    def ev(self) -> float:
        return float(self.exposure.removesuffix("EV"))


@lru_cache(maxsize=1)
def index() -> tuple[Row, ...]:
    rows = []
    with open(STUDIO / "index.csv", newline="") as f:
        for r in csv.DictReader(f):
            # index.csv says .jpg for some frames kept as .png. (Not
            # with_suffix: "daylight_+0.0" would lose its ".0".)
            stem = str(STUDIO / r["file"].rsplit(".", 1)[0])
            path = next((Path(stem + e) for e in (".png", ".jpg") if Path(stem + e).exists()), None)
            if path is None:
                continue
            rows.append(Row(r["film"], TYPES[r["type"]], r["push"], r["exposure"], r["scanner"], path))
    return tuple(rows)


def film_type(film: str) -> str:
    return next(r.type for r in index() if r.film == film)


def srgb_to_linear(v):
    return np.where(v <= 0.04045, v / 12.92, ((v + 0.055) / 1.055) ** 2.4)


def load(row: Row) -> np.ndarray:
    """The frame as linear sRGB, float, H x W x 3."""
    img = iio.imread(row.path)[..., :3]
    scale = 65535.0 if img.dtype == np.uint16 else 255.0
    return srgb_to_linear(img.astype(np.float64) / scale)


# ---- The chart ----

COLS, ROWS = 14, 10
SG_NAMES = [f"{c}{r}" for r in range(1, ROWS + 1) for c in "ABCDEFGHIJKLMN"]


def sg_lab() -> np.ndarray:
    """The published L*a*b* (D50) of the 140 patches, in SG_NAMES order."""
    import colour

    chart = colour.CCS_COLOURCHECKERS["ColorCheckerSG - After November 2014"]
    xyy = np.array([chart.data[n] for n in SG_NAMES])
    return colour.XYZ_to_Lab(colour.xyY_to_XYZ(xyy), chart.illuminant)


_GRID = np.array([[c, r] for r in range(ROWS) for c in range(COLS)], dtype=np.float64)
_GRID_CORNERS = np.array([[0, 0], [COLS - 1, 0], [0, ROWS - 1], [COLS - 1, ROWS - 1]], dtype=np.float64)


def centres_from_corners(corners: np.ndarray) -> np.ndarray:
    h = cv2.getPerspectiveTransform(_GRID_CORNERS.astype(np.float32), corners.astype(np.float32))
    return cv2.perspectiveTransform(_GRID[None].astype(np.float64), h)[0]


def _pitch(centres: np.ndarray) -> float:
    g = centres.reshape(ROWS, COLS, 2)
    return float(np.median(np.linalg.norm(np.diff(g, axis=1), axis=2)))


def _boxes(img: np.ndarray, centres: np.ndarray, frac: float):
    r = max(2, int(round(frac * _pitch(centres))))
    h, w = img.shape[:2]
    for x, y in centres:
        x, y = int(round(x)), int(round(y))
        yield img[max(0, y - r):min(h, y + r + 1), max(0, x - r):min(w, x + r + 1)]


def sample(img: np.ndarray, centres: np.ndarray, frac: float = 0.2) -> np.ndarray:
    """Mean linear RGB inside a box at each centre, 140 x 3."""
    return np.array([b.reshape(-1, 3).mean(0) for b in _boxes(img, centres, frac)])


def sample_spread(img: np.ndarray, centres: np.ndarray, frac: float = 0.2) -> np.ndarray:
    """The luminance standard deviation inside each sample box."""
    y = img @ np.array([0.2126, 0.7152, 0.0722])
    return np.array([b.std() for b in _boxes(y[..., None], centres, frac)])


def _grey(img: np.ndarray) -> np.ndarray:
    # Encoded, so darks and lights weigh alike.
    y = np.clip(img @ np.array([0.2126, 0.7152, 0.0722]), 0, 1) ** (1 / 2.2)
    return y.astype(np.float32)


def _edges(y: np.ndarray, blur: float) -> np.ndarray:
    """Gradient magnitude: the patch outlines, whatever the exposure or film."""
    gx = cv2.Sobel(y, cv2.CV_32F, 1, 0, ksize=3)
    gy = cv2.Sobel(y, cv2.CV_32F, 0, 1, ksize=3)
    return cv2.GaussianBlur(np.hypot(gx, gy), (0, 0), blur)


HALF = 0.37  # a patch's half width, in pitches


def _outline_and_inside():
    t = np.linspace(-HALF, HALF, 9)
    ring = np.concatenate([
        np.stack([t, np.full_like(t, -HALF)], 1), np.stack([t, np.full_like(t, HALF)], 1),
        np.stack([np.full_like(t, -HALF), t], 1), np.stack([np.full_like(t, HALF), t], 1),
    ])
    u = np.linspace(-0.2, 0.2, 4)
    inside = np.stack(np.meshgrid(u, u), -1).reshape(-1, 2)
    return (_GRID[:, None] + ring).reshape(-1, 2), (_GRID[:, None] + inside).reshape(-1, 2)


_RING, _INSIDE = _outline_and_inside()


def _edge_score(edges: np.ndarray, corners: np.ndarray) -> float:
    """Edge strength on the predicted patch outlines, less that inside them."""
    h = cv2.getPerspectiveTransform(_GRID_CORNERS.astype(np.float32), corners.astype(np.float32))

    def at(points):
        xy = cv2.perspectiveTransform(points[None], h)[0].astype(np.float32)
        return cv2.remap(edges, xy[:, 0:1], xy[:, 1:2], cv2.INTER_LINEAR, borderValue=0).mean()

    return float(at(_RING) - at(_INSIDE))


def _refine(edges: np.ndarray, corners: np.ndarray, step: float) -> np.ndarray:
    """Move the four corners until the patch outlines sit on the edges."""
    simplex = corners.ravel() + np.vstack([np.zeros(8), step * np.eye(8)])
    fit = minimize(
        lambda v: -_edge_score(edges, v.reshape(4, 2)),
        corners.ravel(),
        method="Nelder-Mead",
        options={"xatol": 0.2, "fatol": 1e-7, "maxiter": 3000, "initial_simplex": simplex},
    )
    return fit.x.reshape(4, 2)


DOWN = 4  # the coarse search's downsampling


def _grid_template(pitch: float, angle: float):
    """The SG's patch outlines, drawn at `pitch` pixels and turned `angle`°."""
    pad = pitch
    w, h = int(COLS * pitch + 2 * pad), int(ROWS * pitch + 2 * pad)
    img = np.zeros((h, w), np.float32)
    r = HALF * pitch
    for c, rr in _GRID:
        x, y = pad + (c + 0.5) * pitch, pad + (rr + 0.5) * pitch
        cv2.rectangle(img, (int(x - r), int(y - r)), (int(x + r), int(y + r)), 1.0, -1)
    rot = cv2.getRotationMatrix2D((w / 2, h / 2), angle, 1.0)
    img = cv2.warpAffine(img, rot, (w, h))
    return _edges(img, 1.0), rot, pad


def _coarse(small: np.ndarray) -> np.ndarray:
    """Corners from the best scale, angle and place of a drawn grid."""
    best = None
    for pitch in np.geomspace(30 / DOWN, 80 / DOWN, 24):
        for angle in range(-10, 11, 2):
            t, rot, pad = _grid_template(pitch, angle)
            if t.shape[0] >= small.shape[0] or t.shape[1] >= small.shape[1]:
                continue
            _, score, _, loc = cv2.minMaxLoc(cv2.matchTemplate(small, t, cv2.TM_CCOEFF_NORMED))
            if best is None or score > best[0]:
                best = (score, pitch, rot, pad, loc)
    _, pitch, rot, pad, loc = best
    centres = pad + (_GRID_CORNERS + 0.5) * pitch
    turned = centres @ rot[:, :2].T + rot[:, 2]
    return (turned + np.array(loc)) * DOWN


def _hops(edges: np.ndarray, corners: np.ndarray) -> np.ndarray:
    """Try each corner a patch away in each direction: a grid can settle
    with one side a row off."""
    pitch = _pitch(centres_from_corners(corners))
    best = (_edge_score(edges, corners), corners)
    for i in range(4):
        for d in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            trial = corners.copy()
            trial[i] += np.array(d) * pitch
            s = _edge_score(edges, trial)
            if s > best[0]:
                best = (s, trial)
    return best[1]


MIN_RANK = 0.85  # below this rank correlation with the published L*, no chart


def _shift(corners: np.ndarray, dc: int, dr: int) -> np.ndarray:
    """The corners of the grid moved `dc` columns and `dr` rows."""
    h = cv2.getPerspectiveTransform(_GRID_CORNERS.astype(np.float32), corners.astype(np.float32))
    return cv2.perspectiveTransform((_GRID_CORNERS + [dc, dr])[None], h)[0]


def _lightness_rank(img: np.ndarray, centres: np.ndarray) -> float:
    """Spearman correlation of the sampled luminance with the published L*:
    near 1 on the chart, whatever the film, and low a patch off."""
    from scipy.stats import spearmanr

    h, w = img.shape[:2]
    if not ((centres >= 0).all() and (centres[:, 0] < w).all() and (centres[:, 1] < h).all()):
        return -1.0  # a grid off the frame isn't the chart
    y = sample(img, centres) @ np.array([0.2126, 0.7152, 0.0722])
    return float(spearmanr(y, sg_lab()[:, 0]).statistic)


def locate(img: np.ndarray) -> np.ndarray | None:
    """The 140 patch centres (x, y) of the Digital SG on a frame, or None
    when the frame doesn't show it."""
    y = _grey(img)
    small = _edges(cv2.resize(y, None, fx=1 / DOWN, fy=1 / DOWN, interpolation=cv2.INTER_AREA), 1.0)
    corners = _coarse(small)
    # Coarse to fine: a wide blur pulls the outlines in, a narrow one seats them.
    pitch = _pitch(centres_from_corners(corners))
    wide, narrow = _edges(y, pitch / 8), _edges(y, pitch / 20)
    corners = _refine(wide, corners, pitch / 4)
    corners = _refine(narrow, corners, pitch / 10)
    for _ in range(3):
        hopped = _hops(narrow, corners)
        if hopped is corners:
            break
        corners = _refine(narrow, hopped, pitch / 10)
    # The outlines repeat every patch, so the edges can't tell the grid's
    # place a patch or two off; the patches' lightness can.
    rank, corners = max(
        ((_lightness_rank(img, centres_from_corners(c)), c)
         for c in (_shift(corners, dc, dr) for dc in range(-2, 3) for dr in range(-2, 3))),
        key=lambda t: t[0],
    )
    if rank < MIN_RANK:
        return None
    # A last seat on the edges, kept only if it stays on the chart: on a
    # low-contrast frame it can slide a patch over.
    seated = _refine(narrow, corners, pitch / 10)
    if _lightness_rank(img, centres_from_corners(seated)) >= rank:
        corners = seated
    return centres_from_corners(corners)


def score(img: np.ndarray, centres: np.ndarray) -> float:
    """How surely `centres` sit on the chart: the lightness rank correlation."""
    return _lightness_rank(img, centres)


def rectify(img: np.ndarray, centres: np.ndarray, pitch: int = 24) -> np.ndarray:
    """The chart warped straight: `pitch` pixels a patch, the same on every
    frame, so charts from different frames line up."""
    corners = centres.reshape(ROWS, COLS, 2)[[0, 0, -1, -1], [0, -1, 0, -1]].astype(np.float32)
    target = ((_GRID_CORNERS + 1) * pitch).astype(np.float32)
    h = cv2.getPerspectiveTransform(corners, target)
    return cv2.warpPerspective(img.astype(np.float32), h, ((COLS + 1) * pitch, (ROWS + 1) * pitch))


if __name__ == "__main__":
    import sys

    # Locate the chart on every frame, print the rank, or MISSING, and
    # write a contact sheet of the straightened charts to argv[1].
    tiles = []
    for row in index():
        img = load(row)
        c = locate(img)
        print(f"{row.film:32} {row.scanner:8} {row.exposure:5}", "MISSING" if c is None else f"{score(img, c):.3f}", flush=True)
        if c is not None and len(sys.argv) > 1:
            t = (np.clip(rectify(img, c), 0, 1) ** (1 / 2.2) * 255).astype(np.uint8)
            for x, y in (_GRID + 1) * 24:
                t[int(y), int(x)] = (255, 0, 0)
            cv2.putText(t, f"{row.film[:18]} {row.scanner[0]}{row.exposure}", (2, 10), cv2.FONT_HERSHEY_PLAIN, 0.7, (255, 255, 0))
            tiles.append(t)
    if tiles:
        per = 12
        tiles += [np.zeros_like(tiles[0])] * (-len(tiles) % per)
        sheet = np.vstack([np.hstack(tiles[i:i + per]) for i in range(0, len(tiles), per)])
        iio.imwrite(sys.argv[1], sheet)
