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
OUTLIER_FIT = 0.002  # above this, refit without the worst-fitting pair
SNAP_FRACTION = 0.15  # of a gridline spacing: how far a label may sit from its tick
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


def overline_rules(page):
    """Negation overbars some sheets hand to the font instead of drawing: a
    '_' / '¯' / '‾' glyph centred above a digit (e.g. E-113 sensitivity axes).
    Return each as (x0, x1, y) so labels() can treat it exactly like a rule."""
    out = []
    for block in page.get_text("dict")["blocks"]:
        for line in block.get("lines", []):
            for span in line["spans"]:
                text = span["text"].strip()
                if len(text) == 1 and text in ("_", "\u203e", "\u00af", "\u02c9"):
                    bx0, by0, bx1, by1 = span["bbox"]
                    out.append((bx0, bx1, (by0 + by1) / 2))
    return out


def labels(page, frame, xticks, yticks, rules):
    """Numeric labels along the bottom and left edges, with their values."""
    x0, y0, x1, y1 = frame
    xs, ys = np.array(sorted(xticks)), np.array(sorted(yticks))
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
                    # Assign it to the axis whose tick it lies closest to, in
                    # absolute points. Normalising by tick spacing mis-fires
                    # when one axis carries gridlines and its spacing collapses
                    # (e.g. the '0.0' shared by the density and log-exposure
                    # axes on Elite Chrome 200).
                    in_x = np.min(np.abs(xs - cx)) <= np.min(np.abs(ys - cy))
                    in_y = not in_x
                (xlab if in_x else ylab if in_y else []).append(
                    (cx if in_x else cy, value))
    return xlab, ylab


def robust_line(at, value, drop_outliers=True):
    """Least squares through position -> value, dropping outlying pairs.

    One mis-paired label tilts a least-squares fit across the whole axis, so
    drop the worst-fitting pair and refit while that keeps paying, as long as
    four pairs remain. A clean axis is untouched: every pair already lies on
    the line.

    Only where the labels are the same width on the page. Where they are not,
    a label's own centring offset looks exactly like an outlier - the Fuji T64
    characteristic axis runs "-3.0" to "1.0" - and dropping one tilts the fit
    rather than straightening it.
    """
    span = float(value.max() - value.min())
    slope, intercept = np.polyfit(at, value, 1)
    worst = float(np.max(np.abs(np.polyval([slope, intercept], at) - value)))
    while drop_outliers and len(at) > 4 and worst > OUTLIER_FIT * span:
        drop = int(np.argmax(np.abs(np.polyval([slope, intercept], at) - value)))
        trial_at, trial_value = np.delete(at, drop), np.delete(value, drop)
        trial_slope, trial_intercept = np.polyfit(trial_at, trial_value, 1)
        trial_worst = float(np.max(np.abs(
            np.polyval([trial_slope, trial_intercept], trial_at) - trial_value)))
        if trial_worst >= worst:
            break
        at, value = trial_at, trial_value
        slope, intercept, worst = trial_slope, trial_intercept, trial_worst
    return slope, intercept, worst, len(at), span


def calibrate(tickpos, found, axis_name):
    """Snap each label to its nearest tick and fit position -> value."""
    if len(tickpos) < 2 or len(found) < 3:
        return None
    pos = np.array(sorted(tickpos))

    def snap(step):
        """Pair each label with the gridline it sits on, or with nothing."""
        out = {}
        for at, value in found:
            tick = pos[np.argmin(np.abs(pos - at))]
            if abs(tick - at) > step:
                continue
            if out.setdefault(tick, value) != value:
                return None
            out[tick] = value
        return out

    # Judge the snap against the typical tick spacing, not the smallest: one
    # spurious tick collapses the minimum and then every real label looks far
    # away. A label whose nearest tick is a third of a step off is a label
    # whose own tick was missed, so drop it rather than pair it wrongly.
    tick_step = (float(np.median(np.diff(pos))) if len(pos) > 2
                 else float(np.diff(pos)[0]))
    pairs = snap(0.3 * tick_step)

    # When that pairs almost nothing, the ticks themselves are the problem and
    # their spacing is not a spacing: the Pro Films characteristic panels list
    # eighteen and twenty-nine ticks over five gridlines, most of them
    # hundredths of a point apart, so the median collapses and no label
    # reaches its own gridline. The labels know better. Their own spacing on
    # the page, times the step in value from one to the next, is what a
    # gridline spacing actually is, and no stray stroke can corrupt it. A
    # label centre is measured here to sit 0.07 to 0.9 points from its
    # gridline, a few per cent of a spacing, so the second pass stays tight.
    fallback = False
    if (pairs is None or len(pairs) < 3) and len(found) >= 3:
        ordered = sorted(found)
        label_at = np.array([a for a, _ in ordered])
        label_value = np.array([v for _, v in ordered])
        value_step = float(np.median(np.abs(np.diff(label_value))))
        label_slope = float(np.polyfit(label_at, label_value, 1)[0])
        if value_step <= 0 or label_slope == 0:
            return None
        pairs = snap(SNAP_FRACTION * abs(value_step / label_slope))
        fallback = True
    def direct_pairs(found):
        # No usable ticks: a label's own centre is its axis coordinate, and
        # (centre -> value) is linear for a monotonic axis. Round to a hundredth
        # of a point so two labels collapse only when they share a position.
        out = {}
        for a, v in sorted(found):
            key = round(float(a), 2)
            if key in out and out[key] != v:
                return None
            out[key] = v
        return out

    if pairs is None:
        return None
    if len(pairs) < 3:
        pairs = direct_pairs(found)
    if pairs is None or len(pairs) < 3:
        return None


    # Same width on the page means same sign and same digit count for these
    # sheets: a label's position is its text's centre, so "-3.0" and "1.0" on
    # one axis sit off their gridlines by different amounts, and a residual
    # that looks like an outlier is really that offset. Wavelength axes,
    # labelled 250 to 750, are uniform; a log-exposure axis is not.
    uniform = (all(v >= 0 for _, v in found)
               and len({len(f"{v:g}") for _, v in found}) == 1)

    def line_through(mapping):
        at = np.array(sorted(mapping))
        value = np.array([mapping[p] for p in at])
        if not (np.all(np.diff(value) > 0) or np.all(np.diff(value) < 0)):
            return None
        return robust_line(at, value, drop_outliers=uniform)

    fit = line_through(pairs)
    if fit is None:
        # The snapped mapping was non-monotonic: labels rode on sparse,
        # misaligned ticks (a spectral panel prints 11 wavelength labels over a
        # handful of drawn gridlines). Their own centres are monotonic, so fit
        # on those instead; the LABEL_FIT gate below still applies.
        pairs = direct_pairs(found)
        if pairs is None or len(pairs) < 3:
            return None
        fit = line_through(pairs)
    if fit is None:
        return None
    # The second pass only earns its keep when the pairing it finds is
    # genuinely collinear. Where the ticks are so poor that even the labels'
    # own spacing cannot pair them - the Pro 100 and Pro 100T sensitivity
    # panels, whose only honest ticks are their frame edges - it lands several
    # nanometres out while still inside the loose acceptance below. Better
    # than letting the panel fail is the direct label-centre fit, which is
    # accurate and needs no ticks at all.
    if fallback and fit[2] > OUTLIER_FIT * fit[4]:
        pairs = direct_pairs(found)
        if pairs is None or len(pairs) < 3:
            return None
        fit = line_through(pairs)
        fallback = False
        if fit is None:
            return None

    slope, intercept, worst, kept, span = fit
    if worst > LABEL_FIT * span:
        # The tick-snapped fit is poor (labels rode on misaligned sparse ticks).
        # The labels' own centres are accurate; fit on them directly and keep
        # the LABEL_FIT gate on that result.
        pairs = direct_pairs(found)
        if pairs is None or len(pairs) < 3:
            return None
        fit = line_through(pairs)
        if fit is None:
            return None
        slope, intercept, worst, kept, span = fit
        if worst > LABEL_FIT * span:
            return None
    # Same convention as extract_sources.py's hand-measured entries: points
    # per unit is positive on both axes, and PDF y grows downward.
    return dict(axis=axis_name, pt_per_unit=float(abs(1 / slope)),
                zero_pdf_pt=float(-intercept / slope),
                labels=kept, worst_label_error=worst)


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


def clip_to_frame(points, y0, y1, pad):
    """The longest run of a trace that stays within the frame's y range.

    A curve sometimes climbs off the top of its own panel - the Supra 100 dye
    sheet plots a midscale neutral that passes 2.5 D at the left edge of a box
    that stops there - and the containment test below would throw the whole
    trace away. Trimming is opt-in per graph, because a trace that leaves the
    frame is also what a mis-identified frame looks like.
    """
    inside = (points[:, 1] > y0 - pad) & (points[:, 1] < y1 + pad)
    best, run = None, None
    for i, ok in enumerate(inside):
        if ok:
            run = i if run is None else run
            if best is None or (i - run) >= (best[1] - best[0]):
                best = (run, i)
        else:
            run = None
    if best is None:
        return points[:0]
    return points[best[0]:best[1] + 1]


def join_fragments(traces, tol=2.5):
    """Reunite polylines that are one plotted curve with the pen lifted.

    Several Kodak sheets stroke a curve in pieces - the Pro Films dye panels
    hand back three polylines for two curves, and its Pro 1000 sensitivity
    panel five for three - and the pieces meet end to end, usually within a
    tenth of a point and at worst within two. Only endpoints are considered,
    so two curves crossing each other are never merged: at a crossing neither
    has an end.
    """
    pieces = [list(t) for t in traces]
    joined = True
    while joined and len(pieces) > 1:
        joined = False
        best = None
        for i in range(len(pieces)):
            for j in range(i + 1, len(pieces)):
                for ends in ((-1, 0), (-1, -1), (0, 0), (0, -1)):
                    gap = float(np.hypot(*(pieces[i][ends[0]][:2]
                                           - pieces[j][ends[1]][:2])))
                    if gap <= tol and (best is None or gap < best[0]):
                        best = (gap, i, j, ends)
        if best is not None:
            _, i, j, ends = best
            left = pieces[i] if ends[0] == -1 else pieces[i][::-1]
            right = pieces[j] if ends[1] == 0 else pieces[j][::-1]
            pieces[i] = left + right
            pieces.pop(j)
            joined = True
    return [np.array(piece) for piece in pieces]


def curves_in(page, frame, pad=1.5, clip=False, min_span=0.1):
    """Every plotted trace that stays inside the frame.

    `min_span`, as a fraction of the frame's width, is what separates a curve
    from a stray stroke. Lower it only when the caller is going to rejoin
    fragments afterwards and can drop whatever stays short.
    """
    x0, y0, x1, y1 = frame
    out = []
    for drawing in page.get_drawings():
        for points in flatten(drawing["items"]):
            if not (np.all(points[:, 0] > x0 - pad) and np.all(points[:, 0] < x1 + pad)):
                continue
            if clip:
                points = clip_to_frame(points, y0, y1, pad)
                if len(points) < 8:
                    continue
            elif not (np.all(points[:, 1] > y0 - pad)
                      and np.all(points[:, 1] < y1 + pad)):
                continue
            if np.ptp(points[:, 0]) < min_span * (x1 - x0):
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

    doc = pymupdf.open(args.pdf)
    scanned = {}

    def scan(page_number):
        """Calibrated frames on one page. Sheets often spread a stock's panels
        over several pages, so each graph may name its own."""
        if page_number in scanned:
            return scanned[page_number]
        page = doc[page_number - 1]
        segs = segments(page)
        rules = minus_rules(segs) + overline_rules(page)
        calibrated = []
        for frame in frames(segs):
            xt, yt = ticks(frame, segs)
            xlab, ylab = labels(page, frame, xt, yt, rules)
            xcal, ycal = calibrate(xt, xlab, "x"), calibrate(yt, ylab, "y")
            if xcal and ycal:
                calibrated.append((frame, xcal, ycal))
        # Gridlines make boxes of their own; keep one frame per panel. Two frames
        # count as the SAME panel only when they calibrate to the same x-axis
        # values AND overlap on the page; side-by-side panels that share an axis
        # stay (the recipe can then separate them with frame_near). A bare overlap
        # test used to be too aggressive and dropped distinct adjacent panels,
        # e.g. a spectral-sensitivity panel touching the characteristic or MTF
        # frame on the same sheet.
        calibrated.sort(key=lambda f: (f[0][2]-f[0][0])*(f[0][3]-f[0][1]), reverse=True)
        kept = []
        for frame, xcal, ycal in calibrated:
            lo = (frame[0] - xcal["zero_pdf_pt"]) / xcal["pt_per_unit"]
            hi = (frame[2] - xcal["zero_pdf_pt"]) / xcal["pt_per_unit"]
            span = hi - lo
            dup = False
            for kframe, kxcal, _ in kept:
                klo = (kframe[0] - kxcal["zero_pdf_pt"]) / kxcal["pt_per_unit"]
                khi = (kframe[2] - kxcal["zero_pdf_pt"]) / kxcal["pt_per_unit"]
                same_axis = (abs(lo - klo) < 0.03 * span
                             and abs(hi - khi) < 0.03 * span)
                overlaps = (frame[0] < kframe[2] and kframe[0] < frame[2]
                            and frame[1] < kframe[3] and kframe[1] < frame[3])
                if same_axis and overlaps:
                    dup = True
                    break
            if not dup:
                kept.append((frame, xcal, ycal))
        scanned[page_number] = (page, kept)
        return scanned[page_number]

    written = {}
    default_page = recipe["page_1based"]
    for name, spec in recipe["graphs"].items():
        page_number = spec.get("page_1based", default_page)
        page, kept = scan(page_number)
        wanted = spec["x_range"]

        def fits(frame, xc, yc, wanted=wanted, spec=spec):
            lo = (frame[0] - xc["zero_pdf_pt"]) / xc["pt_per_unit"]
            hi = (frame[2] - xc["zero_pdf_pt"]) / xc["pt_per_unit"]
            if (abs(lo - wanted[0]) > spec["x_tolerance"]
                    or abs(hi - wanted[1]) > spec["x_tolerance"]):
                return False
            # Some sheets put two panels on the same wavelength axis - a
            # sensitivity panel and a dye panel both running 380 to 720 - so
            # the x range alone cannot tell them apart. Their y axes differ,
            # and a recipe can say so.
            # A sheet can carry several stocks side by side, each with the
            # same panels on the same axes. Then only position separates them,
            # and the recipe gives the frame's top-left corner.
            near = spec.get("frame_near")
            if near is not None:
                reach = spec.get("frame_near_tolerance", 20.0)
                if abs(frame[0] - near[0]) > reach or abs(frame[1] - near[1]) > reach:
                    return False
            span = spec.get("y_range")
            if span is None:
                return True
            ylo = (yc["zero_pdf_pt"] - frame[3]) / yc["pt_per_unit"]
            yhi = (yc["zero_pdf_pt"] - frame[1]) / yc["pt_per_unit"]
            tol = spec.get("y_tolerance", 0.2)
            return abs(ylo - span[0]) <= tol and abs(yhi - span[1]) <= tol

        match = [(f, xc, yc) for f, xc, yc in kept if fits(f, xc, yc)]
        if len(match) != 1:
            raise ValueError(f"{name}: matched {len(match)} frames, expected 1")
        frame, xcal, ycal = match[0]
        if spec.get("join_fragments"):
            # Gather the short pieces too - the Pro Films dye panels draw a
            # curve's steep left shoulder as its own 12 to 17 point stroke -
            # then rejoin and drop whatever is still too short to be a curve.
            found = curves_in(page, frame, clip=spec.get("clip_to_frame", False),
                              min_span=0.03)
            widths = [stroke for _, stroke in found if stroke]
            width = max(widths) if widths else None
            span = frame[2] - frame[0]
            found = [(points, width)
                     for points in join_fragments([points for points, _ in found],
                                                  spec.get("join_tolerance", 2.5))
                     if np.ptp(points[:, 0]) >= 0.1 * span]
            if len(found) > spec["curves"]:
                # A few sheets stroke each real trace's steep shoulder as its
                # own 11-13 point stroke (and some carry a panel-top rule), so
                # the count overshoots. The real traces are hundreds of points;
                # an over-detected shoulder is a dozen. Keep the longest
                # `curves` of them and drop the rest.
                found.sort(key=lambda t: len(t[0]), reverse=True)
                found = found[: spec["curves"]]
        else:
            found = curves_in(page, frame, clip=spec.get("clip_to_frame", False))
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
            if "neutral" in names:
                # A dye panel's visual neutral is the broad one: it carries
                # density everywhere while each dye is a single band. Its peak
                # can sit within 2 nm of the cyan's, so sorting on peak alone
                # would be a coin toss; its mean is twice any dye's.
                neutral = max(traces, key=lambda t: t[0][:, 1].mean())
                rest = sorted((t for t in traces if t is not neutral), key=key)
                traces, rest = [], list(rest)
                for name_i in names:
                    traces.append(neutral if name_i == "neutral" else rest.pop(0))
            else:
                traces.sort(key=key)
        spec["derived"] = dict(page_1based=page_number,
                               frame_pdf_pt=[round(v, 3) for v in frame],
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
