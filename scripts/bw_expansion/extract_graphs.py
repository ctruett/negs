#!/usr/bin/env python3
"""Extract a datasheet's plotted curves, calibrating the axes from the page.

Where extract_sources.py reads a hand-measured drawing index and axis
transform out of its recipe, this finds both: plot frames from the long
strokes, tick positions from the short ones and the gridlines, and the
mapping to data coordinates by snapping the printed axis labels to those
ticks. The derived calibration is written back into the recipe so the
extraction stays reviewable and reproducible.

Requires PyMuPDF and NumPy. The PDF is supplied explicitly and gated on the
SHA-256 in the recipe; nothing is downloaded or guessed.
"""
import argparse
import csv
import hashlib
import json
import re
from pathlib import Path

import numpy as np
import pymupdf

ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = ROOT / "data/profile-sources"

MIN_AXIS = 80.0      # pt, shortest stroke taken for an axis
TICK_MAX = 12.0      # pt, longest stroke taken for a tick
CORNER_TOL = 2.0     # pt, corner matching when closing a frame
LABEL_FIT = 0.02     # worst label error allowed, as a fraction of axis range
BEZIER_STEPS = 33    # matches extract_sources.py

# Agfa sets its minus signs as en dashes.
DASHES = {0x2010: "-", 0x2011: "-", 0x2012: "-", 0x2013: "-",
          0x2014: "-", 0x2015: "-", 0x2212: "-", 0x00AD: "-"}
NUMBER = re.compile(r"^[-+]?\d+(\.\d+)?$")


def as_number(text):
    t = text.strip().translate(DASHES).replace(" ", "")
    return float(t) if NUMBER.match(t) else None


def segments(page):
    """Every straight edge on the page, as (start, end) points."""
    out = []
    for drawing in page.get_drawings():
        for item in drawing["items"]:
            if item[0] == "l":
                out.append((item[1], item[2]))
            elif item[0] == "re":
                r = item[1]
                corners = [(r.x0, r.y0), (r.x1, r.y0), (r.x1, r.y1), (r.x0, r.y1)]
                for i in range(4):
                    out.append((pymupdf.Point(*corners[i]),
                                pymupdf.Point(*corners[(i + 1) % 4])))
            elif item[0] == "qu":
                q = item[1]
                pts = [q.ul, q.ur, q.lr, q.ll]
                for i in range(4):
                    out.append((pts[i], pts[(i + 1) % 4]))
    return out


def frames(segs):
    """Axis boxes: two long horizontals closed by two long verticals."""
    hor = [(p.y, min(p.x, q.x), max(p.x, q.x)) for p, q in segs
           if abs(q.y - p.y) < 0.5 and abs(q.x - p.x) > MIN_AXIS]
    ver = [(p.x, min(p.y, q.y), max(p.y, q.y)) for p, q in segs
           if abs(q.x - p.x) < 0.5 and abs(q.y - p.y) > MIN_AXIS]
    found = []
    for i, (ytop, hx0, hx1) in enumerate(hor):
        for ybot, gx0, gx1 in hor[i + 1:]:
            if abs(hx0 - gx0) > CORNER_TOL or abs(hx1 - gx1) > CORNER_TOL:
                continue
            top, bot = min(ytop, ybot), max(ytop, ybot)
            if bot - top < MIN_AXIS:
                continue
            closed = [[v for v in ver if abs(v[0] - edge) < CORNER_TOL
                       and v[1] < top + CORNER_TOL and v[2] > bot - CORNER_TOL]
                      for edge in (hx0, hx1)]
            if all(closed):
                found.append((hx0, top, hx1, bot))
    return found


def ticks(frame, segs):
    """Tick positions along the bottom and left edges, corners included."""
    x0, y0, x1, y1 = frame
    xs, ys = [x0, x1], [y0, y1]
    for p, q in segs:
        dx, dy = abs(q.x - p.x), abs(q.y - p.y)
        if dx < 0.6 and 1.0 < dy < TICK_MAX:
            if abs(min(p.y, q.y) - y1) < TICK_MAX and x0 < p.x < x1:
                xs.append(p.x)
        elif dy < 0.6 and 1.0 < dx < TICK_MAX:
            if abs(max(p.x, q.x) - x0) < TICK_MAX and y0 < p.y < y1:
                ys.append(p.y)
        # A gridded plot has no separate ticks: the gridlines are the ticks.
        elif dx < 0.5 and dy > 0.8 * (y1 - y0) and x0 < p.x < x1:
            xs.append(p.x)
        elif dy < 0.5 and dx > 0.8 * (x1 - x0) and y0 < p.y < y1:
            ys.append(p.y)
    return sorted(set(np.round(xs, 2))), sorted(set(np.round(ys, 2)))


def minus_rules(segs):
    """Short horizontal rules, which is how some sheets draw a minus sign."""
    return [(min(p.x, q.x), max(p.x, q.x), p.y) for p, q in segs
            if abs(p.y - q.y) < 0.6 and 1.0 < abs(q.x - p.x) < 7.0]


def labels(page, frame, xticks, yticks, rules):
    """Numeric labels along the bottom and left edges, with their values."""
    x0, y0, x1, y1 = frame
    xs, ys = np.array(sorted(xticks)), np.array(sorted(yticks))
    xgap = np.min(np.diff(xs)) if len(xs) > 1 else 1.0
    ygap = np.min(np.diff(ys)) if len(ys) > 1 else 1.0
    xlab, ylab = [], []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            for span in line["spans"]:
                value = as_number(span["text"])
                if value is None:
                    continue
                bx0, by0, bx1, by1 = span["bbox"]
                if value > 0 and any(by0 - 5 < ry < by1 + 2 and bx0 - 10 < rx0
                                     and rx1 < (bx0 + bx1) / 2
                                     for rx0, rx1, ry in rules):
                    value = -value
                cx, cy = (bx0 + bx1) / 2, (by0 + by1) / 2
                in_x = y1 - 4 < by0 < y1 + 22 and x0 - 25 < cx < x1 + 25
                in_y = x0 - 40 < bx1 < x0 + 4 and y0 - 8 < cy < y1 + 8
                if in_x and in_y:   # the label at the origin sits in both
                    in_x = (np.min(np.abs(xs - cx)) / xgap
                            <= np.min(np.abs(ys - cy)) / ygap)
                    in_y = not in_x
                (xlab if in_x else ylab if in_y else []).append(
                    (cx if in_x else cy, value))
    return xlab, ylab


def calibrate(tickpos, found, axis_name):
    """Snap each label to its nearest tick and fit position -> value."""
    if len(tickpos) < 2 or len(found) < 3:
        return None
    pos = np.array(sorted(tickpos))
    pairs = {}
    for at, value in found:
        tick = pos[np.argmin(np.abs(pos - at))]
        if abs(tick - at) > 0.5 * np.min(np.diff(pos)) + 6:
            continue
        if pairs.setdefault(tick, value) != value:
            return None
    if len(pairs) < 3:
        return None
    at = np.array(sorted(pairs))
    value = np.array([pairs[p] for p in at])
    if not (np.all(np.diff(value) > 0) or np.all(np.diff(value) < 0)):
        return None
    slope, intercept = np.polyfit(at, value, 1)
    worst = float(np.max(np.abs(np.polyval([slope, intercept], at) - value)))
    if worst > LABEL_FIT * (value.max() - value.min()):
        return None
    # Same convention as extract_sources.py's hand-measured entries: points
    # per unit is positive on both axes, and PDF y grows downward.
    return dict(axis=axis_name, pt_per_unit=float(abs(1 / slope)),
                zero_pdf_pt=float(-intercept / slope),
                labels=len(pairs), worst_label_error=worst)


def flatten(items):
    """Path items to polylines in page coordinates.

    One drawing often holds several traces — a colour sheet draws all three
    layers in a single path, moving the pen between them — so a break in
    continuity starts a new polyline.
    """
    polylines, current = [], []

    def start(point):
        nonlocal current
        if current and (abs(current[-1][0] - point[0]) > 0.3
                        or abs(current[-1][1] - point[1]) > 0.3):
            polylines.append(current)
            current = []
        if not current:
            current = [point]

    for item in items:
        kind, *vertices = item
        if kind not in ("l", "c"):
            return []            # frames and fills, not plotted data
        p = [np.array([v.x, v.y]) for v in vertices]
        start(p[0])
        if kind == "l":
            current.append(p[1])
        else:
            for t in np.linspace(0, 1, BEZIER_STEPS)[1:]:
                current.append((1-t)**3*p[0] + 3*(1-t)**2*t*p[1]
                               + 3*(1-t)*t*t*p[2] + t**3*p[3])
    if current:
        polylines.append(current)
    return [np.array(p) for p in polylines if len(p) >= 8]


def curves_in(page, frame, pad=1.5):
    """Every plotted trace that stays inside the frame."""
    x0, y0, x1, y1 = frame
    out = []
    for drawing in page.get_drawings():
        for points in flatten(drawing["items"]):
            if not (np.all(points[:, 0] > x0 - pad) and np.all(points[:, 0] < x1 + pad)
                    and np.all(points[:, 1] > y0 - pad)
                    and np.all(points[:, 1] < y1 + pad)):
                continue
            if np.ptp(points[:, 0]) < 0.1 * (x1 - x0):
                continue
            on_edge = (np.minimum(np.abs(points[:, 0] - x0),
                                  np.abs(points[:, 0] - x1)) < 1.0) | \
                      (np.minimum(np.abs(points[:, 1] - y0),
                                  np.abs(points[:, 1] - y1)) < 1.0)
            if on_edge.all():    # the axis box or a gridline, not a trace
                continue
            out.append((points, drawing.get("width")))
    return out


def to_data(points, xcal, ycal):
    x = (points[:, 0] - xcal["zero_pdf_pt"]) / xcal["pt_per_unit"]
    y = (ycal["zero_pdf_pt"] - points[:, 1]) / ycal["pt_per_unit"]
    data = np.column_stack([x, y, points])
    data = data[np.argsort(data[:, 0])]
    keep = np.r_[True, np.diff(data[:, 0]) > 1e-9]
    data = data[keep]
    if np.any(np.diff(data[:, 0]) <= 0):
        raise ValueError("Curve is not single-valued")
    return data


def write_csv(path, header, rows):
    with path.open("w", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(header)
        writer.writerows([[f"{v:.9f}" for v in row] for row in rows])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True,
                        help="directory name under data/profile-sources")
    parser.add_argument("--pdf", type=Path, required=True)
    args = parser.parse_args()
    sources = SOURCE_ROOT / args.source
    recipe = json.loads((sources / "recipe.json").read_text())
    source = recipe["source"]
    actual = hashlib.sha256(args.pdf.read_bytes()).hexdigest()
    if actual != source["sha256"]:
        raise ValueError(f"PDF revision mismatch: {actual}")

    page = pymupdf.open(args.pdf)[recipe["page_1based"] - 1]
    segs = segments(page)
    rules = minus_rules(segs)
    calibrated = []
    for frame in frames(segs):
        xt, yt = ticks(frame, segs)
        xlab, ylab = labels(page, frame, xt, yt, rules)
        xcal, ycal = calibrate(xt, xlab, "x"), calibrate(yt, ylab, "y")
        if xcal and ycal:
            calibrated.append((frame, xcal, ycal))
    # Gridlines make boxes of their own; keep the largest in each region.
    calibrated.sort(key=lambda f: (f[0][2]-f[0][0])*(f[0][3]-f[0][1]), reverse=True)
    kept = []
    for frame, xcal, ycal in calibrated:
        if any(frame[0] < k[0][2] and k[0][0] < frame[2]
               and frame[1] < k[0][3] and k[0][1] < frame[3] for k in kept):
            continue
        kept.append((frame, xcal, ycal))

    written = {}
    for name, spec in recipe["graphs"].items():
        wanted = spec["x_range"]
        match = [(f, xc, yc) for f, xc, yc in kept
                 if abs((f[0]-xc["zero_pdf_pt"])/xc["pt_per_unit"] - wanted[0]) < spec["x_tolerance"]
                 and abs((f[2]-xc["zero_pdf_pt"])/xc["pt_per_unit"] - wanted[1]) < spec["x_tolerance"]]
        if len(match) != 1:
            raise ValueError(f"{name}: matched {len(match)} frames, expected 1")
        frame, xcal, ycal = match[0]
        found = curves_in(page, frame)
        if len(found) != spec["curves"]:
            raise ValueError(f"{name}: found {len(found)} curves, expected {spec['curves']}")
        traces = [(to_data(points, xcal, ycal), stroke) for points, stroke in found]
        # A multi-curve panel needs its traces named. Spectral panels sort by
        # where each peaks, characteristic panels by how high each climbs;
        # the recipe says which, and what the sorted traces are called.
        names = spec.get("curve_names") or [None]
        if len(names) > 1:
            key = {"peak_x": lambda t: t[0][int(np.argmax(t[0][:, 1])), 0],
                   "max_y": lambda t: t[0][:, 1].max()}[spec["curve_order"]]
            traces.sort(key=key)
        spec["derived"] = dict(frame_pdf_pt=[round(v, 3) for v in frame],
                               x=xcal, y=ycal, traces={})
        for suffix, (data, stroke) in zip(names, traces):
            stem = name if suffix is None else f"{name}-{suffix}"
            write_csv(sources / f"{stem}.csv",
                      [spec["x_label"], spec["y_label"], "pdf_x_pt", "pdf_y_pt"], data)
            spec["derived"]["traces"][stem] = dict(
                points=len(data),
                # How thick the printed line is in plotted units: the floor on
                # how precisely any trace of it can be read.
                stroke_pdf_pt=round(float(stroke), 4) if stroke else None,
                stroke_in_y_units=(round(float(stroke) / ycal["pt_per_unit"], 5)
                                   if stroke else None),
                x_extent=[round(float(data[0, 0]), 6), round(float(data[-1, 0]), 6)],
                y_extent=[round(float(data[:, 1].min()), 6),
                          round(float(data[:, 1].max()), 6)],
                peak_x=round(float(data[int(np.argmax(data[:, 1])), 0]), 3))
            written[stem] = len(data)

    (sources / "recipe.json").write_text(json.dumps(recipe, indent=2) + "\n")
    for spec in recipe["graphs"].values():
        d = spec["derived"]
        for stem, t in d["traces"].items():
            print(f"{stem}: {t['points']} points, "
                  f"x {t['x_extent'][0]:.3f}..{t['x_extent'][1]:.3f}, "
                  f"peak at {t['peak_x']:.2f}, "
                  f"worst label error x {d['x']['worst_label_error']:.4f} "
                  f"y {d['y']['worst_label_error']:.4f}")


if __name__ == "__main__":
    main()
