#!/usr/bin/env python3
"""Prospect a datasheet PDF for extractable panels, in recipe terms.

For every page it lists the calibrated vector frames with their role
(characteristic / sensitivity / dye), data-axis ranges, curve count and axis
captions. This is the input a recipe.json `graphs` block needs. Reuses the
built extractor (extract_graphs.py); classification is advisory.
"""
import json, sys
from pathlib import Path
import numpy as np
import pymupdf

NEGS = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(NEGS / 'scripts/bw_expansion'))
import extract_graphs as eg
LIB = Path('/Volumes/storage/30-39 Photography/33 Film/Film datasheets')


def segments_from_drawings(drawings):
    out = []
    for d in drawings:
        for it in d['items']:
            if it[0] == 'l':
                out.append((it[1], it[2]))
            elif it[0] == 're':
                r = it[1]
                c = [pymupdf.Point(r.x0,r.y0), pymupdf.Point(r.x1,r.y0),
                     pymupdf.Point(r.x1,r.y1), pymupdf.Point(r.x0,r.y1)]
                for i in range(4):
                    out.append((c[i], c[(i+1)%4]))
            elif it[0] == 'qu':
                q = it[1]
                pts = [q.ul, q.ur, q.lr, q.ll]
                for i in range(4):
                    out.append((pts[i], pts[(i+1)%4]))
    return out


def count_curves(drawings, frame, pad=1.5, min_span=0.05, cap=5000):
    x0,y0,x1,y1 = frame
    n = 0
    for d in drawings:
        for p in eg.flatten(d['items']):
            if p.size == 0:
                continue
            if not (np.all(p[:,0] > x0-pad) and np.all(p[:,0] < x1+pad)):
                continue
            if not (np.all(p[:,1] > y0-pad) and np.all(p[:,1] < y1+pad)):
                continue
            if np.ptp(p[:,0]) < min_span*(x1-x0):
                continue
            on_edge = (np.minimum(np.abs(p[:,0]-x0), np.abs(p[:,0]-x1)) < 1.0) | (np.minimum(np.abs(p[:,1]-y0), np.abs(p[:,1]-y1)) < 1.0)
            if on_edge.all():
                continue
            n += 1
            if n >= cap:
                return n
    return n


def classify(xlab, ylab, xt, yt):
    xv = [v for _, v in xlab]; yv = [v for _, v in ylab]
    if len(xv) < 2 or len(yv) < 2:
        return None
    xmax = float(max(xv)); ymin = float(min(yv))
    xt = (xt or '').lower(); yt = (yt or '').lower()
    x_wl = ('wavelength' in xt) or xt.rstrip().endswith('nm')
    x_le = any(k in xt for k in ('log exposure','exposure','lux','log h','log e','relative log'))
    y_sens = 'sensitivity' in yt
    y_dens = ('densit' in yt) or ('density' in yt)
    is_wl = xmax > 100.0
    if x_wl and not x_le: is_wl = True
    elif x_le and not x_wl: is_wl = False
    if is_wl:
        if y_sens and not y_dens: return 'sensitivity'
        if y_dens and not y_sens: return 'dye'
        return 'sensitivity' if ymin < 0 else 'dye'
    return 'characteristic'


def titles(frame, spans):
    x0,y0,x1,y1 = frame
    xb, yb = (1e9, ''), (1e9, '')
    for bbox, text in spans:
        if not text or not text.strip(): continue
        bx0,by0,bx1,by1 = bbox
        if y1-2 <= by0 <= y1+40 and bx1 > x0 and bx0 < x1:
            d = abs((bx0+bx1)/2 - (x0+x1)/2)
            if d < xb[0]: xb = (d, text)
        if x0-60 <= bx1 <= x0+2 and by1 > y0 and by0 < y1:
            d = abs((by0+by1)/2 - (y0+y1)/2)
            if d < yb[0]: yb = (d, text)
    return xb[1], yb[1]


def spans(page):
    out = []
    for b in page.get_text('dict')['blocks']:
        for ln in b.get('lines', []):
            for sp in ln['spans']:
                out.append((sp['bbox'], sp['text']))
    return out


def firsttitle(page):
    t = page.get_text().strip().split('\n')
    return (t[0].strip() if t else '')[:80]


def prospect(rel):
    path = LIB / rel
    rows = []
    try:
        doc = pymupdf.open(path)
    except Exception as e:
        return [dict(pdf=str(rel), page=0, error=f'open: {e}')]
    for pn in range(doc.page_count):
        page = doc[pn]
        drawings = page.get_drawings()
        segs = segments_from_drawings(drawings)
        if not segs:
            continue
        sp = spans(page)
        rules = eg.minus_rules(segs) + eg.overline_rules(page)
        calibrated = []
        for frame in eg.frames(segs):
            xt, yt = eg.ticks(frame, segs)
            xlab, ylab = eg.labels(page, frame, xt, yt, rules)
            xcal = eg.calibrate(xt, xlab, 'x')
            ycal = eg.calibrate(yt, ylab, 'y')
            if xcal and ycal:
                calibrated.append((frame, xlab, ylab))
        calibrated.sort(key=lambda f: (f[0][2]-f[0][0])*(f[0][3]-f[0][1]), reverse=True)
        kept = []
        for frame, xlab, ylab in calibrated:
            xlo = min(v for _, v in xlab); xhi = max(v for _, v in xlab); span = xhi - xlo
            dup = False
            for kframe, kxlab, _ in kept:
                klo = min(v for _, v in kxlab); khi = max(v for _, v in kxlab)
                same_axis = abs(xlo-klo) < 0.03*span and abs(xhi-khi) < 0.03*span
                overlaps = (frame[0] < kframe[2] and kframe[0] < frame[2]
                            and frame[1] < kframe[3] and kframe[1] < frame[3])
                if same_axis and overlaps:
                    dup = True; break
            if not dup:
                kept.append((frame, xlab, ylab))
        for frame, xlab, ylab in kept:
            xt, yt = titles(frame, sp)
            role = classify(xlab, ylab, xt, yt)
            if role is None:
                continue
            rows.append(dict(
                pdf=str(rel), page=pn+1, role=role,
                x_range=[round(float(min(v for _, v in xlab)),3), round(float(max(v for _, v in xlab)),3)],
                y_range=[round(float(min(v for _, v in ylab)),3), round(float(max(v for _, v in ylab)),3)],
                curves=count_curves(drawings, frame),
                x_title=(xt or '').strip()[:60], y_title=(yt or '').strip()[:60]))
    doc.close()
    return rows


def main():
    import multiprocessing as mp
    rels = sorted(LIB.rglob('*.pdf'))
    relstrs = [p.relative_to(LIB) for p in rels]
    rows = []
    with mp.Pool(processes=10) as pool:
        for i, r in enumerate(pool.imap_unordered(prospect, relstrs, chunksize=4), 1):
            rows.extend(r)
            if i % 40 == 0:
                print(f'{i}/{len(rels)}', file=sys.stderr, flush=True)
    out = Path('/tmp/datasheet_panels.json')
    out.write_text(json.dumps(rows, indent=1))
    print(f'wrote {out} ({len(rows)} frames)')
    from collections import Counter
    print(Counter(r['role'] for r in rows))


if __name__ == '__main__':
    main()
