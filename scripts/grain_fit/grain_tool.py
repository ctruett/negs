# /// script
# requires-python = ">=3.11"
# dependencies = ["numpy", "scipy", "pillow", "tifffile"]
# ///
"""Analyze film grain in scans and fit the engine's grain parameters to it.

    uv run scripts/grain_fit/grain_tool.py analyze SCAN... [-o SIG.json]
    uv run scripts/grain_fit/grain_tool.py survey [--index experimental/studio/index.csv]
    uv run scripts/grain_fit/grain_tool.py render --film F [--scanner S] [--params P] --like SCAN
    uv run scripts/grain_fit/grain_tool.py fit SCAN... [--film F] [--free rms,uniformity,...]
    uv run scripts/grain_fit/grain_tool.py compare SCAN [--film F] [--params P] -o OUT.png
    uv run scripts/grain_fit/grain_tool.py selftest [--film F]

See scripts/grain_fit/README.md for the method.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import re
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import engine  # noqa: E402
import grainstats as gs  # noqa: E402

OUT_DIR = engine.ROOT / "target/grain_fit"
STUDIO_RE = re.compile(r"studio/(?P<stock>[^/]+)/(?P<scanner>frontier|noritsu)/daylight_(?P<ev>[-+0-9.]+)\.")


class Scan:
    """A scan file, its signature and how to render the engine like it."""

    def __init__(self, path, film=None, scanner=None, frame_mm=36.0, um_per_px=None):
        self.path = Path(path)
        self.img, self.info = gs.load_image(self.path)
        m = STUDIO_RE.search(str(self.path.resolve()))
        self.stock = m["stock"] if m else None
        self.scanner = scanner if scanner is not None else (m["scanner"] if m else None)
        self.ev = float(m["ev"]) if m else None
        self.film = film or (engine.STUDIO_TO_PROFILE.get(self.stock, self.stock) if self.stock else None)
        # The scans don't record their pixel pitch: a 135 frame's long side
        # (36 mm) over the file's long side, unless given.
        self.um_per_px = um_per_px or frame_mm * 1000.0 / max(self.img.shape[:2])
        self.sig = gs.analyze_image(self.img, source=self.describe())

    def describe(self):
        return {k: v for k, v in {
            "path": str(self.path), "stock": self.stock, "film": self.film, "scanner": self.scanner,
            "ev": self.ev, "um_per_px": self.um_per_px, "format": self.info.get("format"),
            "bits": self.info.get("bits"), "size": list(self.img.shape[:2]),
        }.items() if v is not None}


def load_scans(paths, args):
    scans = [Scan(p, film=args.film, scanner=args.scanner, frame_mm=args.frame_mm, um_per_px=args.um_per_px)
             for p in paths]
    for s in scans:
        if not s.film or not (engine.ROOT / "data/profiles" / f"{s.film}.json").exists():
            sys.exit(f"{s.path}: no engine profile '{s.film}'; pass --film with one of data/profiles")
    return scans


def print_signature(sig, label=""):
    print(f"{label}{sig['n_tiles']} flat tiles, {len(sig['groups'])} tone groups")
    print("  level  tiles   sigma R/G/B (8-bit codes)   rho1 R/G/B         corr rg/rb/gb")
    for g in sig["groups"]:
        print(f"  {g['level']:.3f} {g['n_tiles']:6d}   "
              + " ".join(f"{x * 255:6.2f}" for x in g["sigma"]) + "      "
              + " ".join(f"{x:5.2f}" for x in g["rho1"]) + "   "
              + " ".join(f"{x:5.2f}" for x in g["corr"]))


def base_params(film, params_path=None):
    """The engine's resolved grain for `film`, with a params file's
    `film_render.grain` and `scanner.unsharp_mask` (a fit result) over it."""
    grain = engine.engine_grain(film)
    usm = list(engine.SCANNER_USM_DEFAULT)
    if params_path:
        p = json.loads(Path(params_path).read_text())
        grain.update(p.get("film_render", {}).get("grain", {}))
        usm = p.get("scanner", {}).get("unsharp_mask", usm)
        grain.pop("active", None)
    return grain, usm


# `pack`/`unpack` map each free parameter to unbounded coordinates (log or
# logit), so Nelder-Mead can't leave the engine's valid range.
def _logit(u, lo, hi):
    return math.log((u - lo) / (hi - u))


def _sigm(x, lo, hi):
    return lo + (hi - lo) / (1.0 + math.exp(-x))


FREE = {
    "rms": "rms_granularity per channel (one value for B&W): grain strength",
    "uniformity": "uniformity, shared by the channels: how strength follows density",
    "blur": "grain pixel blur sigma (px)",
    "dye": "blur_dye_clouds_um: dye-cloud size",
    "micro": "micro_structure clump size (nm)",
    "usm": "mult_usm_amount: the grain's multiplicative unsharp mask",
    "scanner_usm": "scanner.unsharp_mask amount: the lab scanner's sharpening",
}


def pack(grain, usm, free, bw):
    x = []
    for name in free:
        if name == "rms":
            x += [math.log(v) for v in grain["rms_granularity"][: 1 if bw else 3]]
        elif name == "uniformity":
            x.append(_logit(float(np.mean(grain["uniformity"])), 0.3, 0.999))
        elif name == "blur":
            x.append(math.log(max(grain["blur"], 1e-3)))
        elif name == "dye":
            x.append(math.log(max(grain["blur_dye_clouds_um"], 1e-3)))
        elif name == "micro":
            x.append(math.log(max(grain["micro_structure"][1], 1e-3)))
        elif name == "usm":
            x.append(_logit(min(max(grain["mult_usm_amount"], 0.01), 3.99), 0.0, 4.0))
        elif name == "scanner_usm":
            x.append(_logit(min(max(usm[1], 0.01), 2.99), 0.0, 3.0))
    return np.array(x)


def unpack(x, grain, usm, free, bw):
    grain = json.loads(json.dumps(grain))
    usm = list(usm)
    it = iter(x)
    for name in free:
        if name == "rms":
            v = [math.exp(next(it)) for _ in range(1 if bw else 3)]
            grain["rms_granularity"] = v * 3 if bw else v
        elif name == "uniformity":
            grain["uniformity"] = [_sigm(next(it), 0.3, 0.999)] * 3
        elif name == "blur":
            grain["blur"] = math.exp(next(it))
        elif name == "dye":
            grain["blur_dye_clouds_um"] = math.exp(next(it))
        elif name == "micro":
            grain["micro_structure"] = [grain["micro_structure"][0], math.exp(next(it))]
        elif name == "usm":
            grain["mult_usm_amount"] = _sigm(next(it), 0.0, 4.0)
        elif name == "scanner_usm":
            usm[1] = _sigm(next(it), 0.0, 3.0)
    return grain, usm


def params_json(grain, usm):
    return {"film_render": {"grain": grain}, "scanner": {"unsharp_mask": usm}}


def render_like(scan, grain, usm, paper=None, cache=None):
    """The wedge rendered like `scan` (its film, scanner and pixel pitch),
    stored like its file, and its signature."""
    key = (scan.film, scan.scanner, round(scan.um_per_px, 4), json.dumps(grain, sort_keys=True), tuple(usm))
    if cache is not None and key in cache:
        img, tiles = cache[key]
    else:
        img, tiles = engine.render_wedge(scan.film, grain, scan.um_per_px, scanner=scan.scanner,
                                         paper=paper, scanner_usm=usm)
        if cache is not None:
            cache[key] = (img, tiles)
    stored = engine.degrade_like(img, scan.info)
    return stored, tiles, engine.wedge_signature(stored, tiles, source={"film": scan.film, "scanner": scan.scanner})


def evaluate(scans, grain, usm, args, cache=None):
    dists = []
    for s in scans:
        _, _, sim = render_like(s, grain, usm, paper=args.paper, cache=cache)
        dists.append(gs.distance(sim, s.sig, channels=(0,) if engine.is_bw(s.film) else (0, 1, 2)))
    total = math.sqrt(sum(d["total"] ** 2 for d in dists) / len(dists))
    return total, dists


def cmd_analyze(args):
    sigs = []
    for p in args.scans:
        img, info = gs.load_image(p)
        sig = gs.analyze_image(img, source={"path": str(p), "format": info.get("format"), "bits": info.get("bits")})
        print_signature(sig, f"{p}: ")
        sigs.append(sig)
    if args.output:
        Path(args.output).write_text(json.dumps(sigs if len(sigs) > 1 else sigs[0], indent=1))
        print(f"wrote {args.output}")


def cmd_survey(args):
    """Signatures of every scan in the studio index, and one CSV row per scan
    with its grain at three tone levels."""
    index = Path(args.index)
    out = Path(args.out_dir)
    (out / "signatures").mkdir(parents=True, exist_ok=True)
    rows = []
    with index.open() as f:
        entries = list(csv.DictReader(f))
    for e in entries:
        path = index.parent / e["file"]
        if not path.exists():
            continue
        img, info = gs.load_image(path)
        sig = gs.analyze_image(img, source=dict(e, format=info.get("format"), bits=info.get("bits")))
        name = e["file"].replace("/", "__").rsplit(".", 1)[0]
        (out / "signatures" / f"{name}.json").write_text(json.dumps(sig))
        row = {"file": e["file"], "film": e["film"], "type": e["type"], "push": e["push"],
               "exposure": e["exposure"], "scanner": e["scanner"], "format": info.get("format"),
               "flat_tiles": sig["n_tiles"], "groups": len(sig["groups"])}
        for lv in (0.25, 0.5, 0.75):
            near = min(sig["groups"], key=lambda g: abs(g["level"] - lv), default=None)
            ok = near is not None and abs(near["level"] - lv) < 0.1
            row[f"sigma_lum@{lv}"] = round(near["sigma_lum"] * 255, 3) if ok else ""
        g = sig["groups"]
        row["rho1_lum"] = round(float(np.median([np.mean(x["rho1"]) for x in g])), 3) if g else ""
        row["corr_mean"] = round(float(np.median([np.mean(x["corr"]) for x in g])), 3) if g else ""
        rows.append(row)
        print(f"{e['file']}: {sig['n_tiles']} tiles, {len(g)} groups")
    with (out / "survey.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    print(f"wrote {out / 'survey.csv'} ({len(rows)} scans) and {out / 'signatures'}/")


def cmd_render(args):
    scans = load_scans([args.like], args)
    grain, usm = base_params(scans[0].film, args.params)
    _, _, sim = render_like(scans[0], grain, usm, paper=args.paper)
    print_signature(sim, f"engine {scans[0].film} / {scans[0].scanner or 'print'}: ")
    d = gs.distance(sim, scans[0].sig)
    print(f"distance to {args.like}: {d['total']:.4f} {json.dumps(d['parts'])}")
    if args.output:
        Path(args.output).write_text(json.dumps(sim, indent=1))


RMS_RANGE = (0.05, 300.0)


def solve_rms(scans, grain, usm, args, cache, bw, iters=10):
    """`grain` with rms_granularity solved, per channel, so the render's
    grain strength matches the scans' on average (mean log sigma ratio a =
    0); the shape of sigma over the tones is left to the other parameters.

    a rises with log rms, roughly with slope 1, but not monotonically: very
    coarse grain (few particles per pixel) loses sigma again, most of all
    for blurred B&W grain. So each channel takes secant steps (at most a
    factor e) until a changes sign, then bisects the bracket; a step that
    finds a falling slope is undone halfway. The best point seen is kept."""
    grain = json.loads(json.dumps(grain))
    chans = (0,) if bw else (0, 1, 2)
    prev, lo, hi, best = {}, {}, {}, {}
    for _ in range(iters):
        logs = {ch: [] for ch in chans}
        for s in scans:
            _, _, sim = render_like(s, grain, usm, paper=args.paper, cache=cache)
            for ch, v in gs.sigma_log_ratios(sim, s.sig, channels=chans).items():
                if v is not None:
                    logs[ch].append(v)
        adj = {ch: float(np.mean(v)) for ch, v in logs.items() if v}
        rms = list(grain["rms_granularity"])
        for ch, a in adj.items():
            x = math.log(rms[ch])
            if ch not in best or abs(a) < abs(best[ch][1]):
                best[ch] = (x, a)
            if a < 0:
                lo[ch] = x
            else:
                hi[ch] = x
        if not adj or all(abs(a) < 0.005 for a in adj.values()):
            break
        for ch, a in adj.items():
            x = math.log(rms[ch])
            if ch in lo and ch in hi:
                nx = 0.5 * (lo[ch] + hi[ch])
            elif ch in prev and abs(x - prev[ch][0]) > 1e-6 and (a - prev[ch][1]) / (x - prev[ch][0]) <= 0:
                nx = 0.5 * (x + prev[ch][0])
            else:
                slope = 1.0
                if ch in prev and abs(x - prev[ch][0]) > 1e-6:
                    slope = min(max((a - prev[ch][1]) / (x - prev[ch][0]), 0.2), 2.0)
                nx = x + min(max(-a / slope, -1.0), 1.0)
            prev[ch] = (x, a)
            rms[ch] = min(max(math.exp(nx), RMS_RANGE[0]), RMS_RANGE[1])
        grain["rms_granularity"] = [rms[0]] * 3 if bw else rms
    rms = list(grain["rms_granularity"])
    for ch, (x, _) in best.items():
        rms[ch] = math.exp(x)
    grain["rms_granularity"] = [rms[0]] * 3 if bw else rms
    return grain


def fit_params(scans, grain0, usm0, free, bw, args, maxfev, cache):
    """Fit the free parameters: rms_granularity by `solve_rms` inside every
    step, the shape parameters by Nelder-Mead around it. Returns the best
    (distance, grain, usm, per-scan distances)."""
    from scipy.optimize import minimize

    shape = [f for f in free if f != "rms"]
    best: dict = {"f": math.inf, "grain": grain0, "usm": usm0}
    steps = [0]

    def objective(x):
        grain, usm = unpack(x, grain0, usm0, shape, bw)
        if "rms" in free:
            grain = solve_rms(scans, grain, usm, args, cache, bw)
        f, dists = evaluate(scans, grain, usm, args, cache)
        steps[0] += 1
        if f < best["f"]:
            best.update(f=f, grain=grain, usm=usm, dists=dists)
            rms = ", ".join(f"{v:.2f}" for v in grain["rms_granularity"][: 1 if bw else 3])
            print(f"  step {steps[0]:4d} ({len(cache)} renders): distance {f:.4f}  rms [{rms}]  "
                  f"u {np.mean(grain['uniformity']):.3f}  blur {grain['blur']:.2f}  "
                  f"dye {grain['blur_dye_clouds_um']:.2f}  micro {grain['micro_structure'][1]:.1f}  "
                  f"usm {grain['mult_usm_amount']:.2f}  scan-usm {usm[1]:.2f}", flush=True)
        return f

    x0 = pack(grain0, usm0, shape, bw)
    f_best = objective(x0)
    # A coarse scan both ways along each shape parameter first: Nelder-Mead's
    # first simplex only steps one way, and where a strength can't be reached
    # (blurred B&W grain saturates) it would follow the wrong slope.
    best_x = x0
    for i in range(len(shape)):
        start = best_x
        for d in (-0.8, -0.4, 0.4, 0.8):
            x = start.copy()
            x[i] += d
            f = objective(x)
            if f < f_best:
                f_best, best_x = f, x
    x0 = best_x
    if shape:
        # Every step solves rms from the preset's, not from the best so far:
        # the objective then depends on x alone, and a solve can't start on
        # the falling side of sigma's peak in rms that an earlier step found.
        simplex = np.vstack([x0] + [x0 + 0.4 * np.eye(len(x0))[i] for i in range(len(x0))])
        minimize(objective, x0, method="Nelder-Mead",
                 options={"maxfev": maxfev, "initial_simplex": simplex, "xatol": 2e-3, "fatol": 1e-4})
    return best


def cmd_fit(args):
    scans = load_scans(args.scans, args)
    films = {s.film for s in scans}
    if len(films) != 1:
        sys.exit(f"fit one film at a time; got {sorted(films)}")
    film = films.pop()
    bw = engine.is_bw(film)
    free = [f for f in args.free.split(",") if f]
    unknown = set(free) - set(FREE)
    if unknown:
        sys.exit(f"unknown --free {sorted(unknown)}; choose from {sorted(FREE)}")
    for s in scans:
        print_signature(s.sig, f"{s.path}: ")
    grain0, usm0 = base_params(film, args.params)
    cache = {}
    f0, d0 = evaluate(scans, grain0, usm0, args, cache)
    print(f"engine preset: distance {f0:.4f}")
    best = fit_params(scans, grain0, usm0, free, bw, args, args.maxfev, cache)
    result = {
        "film": film,
        "scans": [s.describe() for s in scans],
        "free": free,
        "renders": len(cache),
        "preset": {"distance": f0, "parts": [d["parts"] for d in d0], "params": params_json(grain0, usm0)},
        "fitted": {"distance": best["f"], "parts": [d["parts"] for d in best["dists"]],
                   "params": params_json(best["grain"], best["usm"])},
    }
    out = Path(args.output or OUT_DIR / f"fit_{film}.json")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=1))
    params_out = out.with_name(out.stem + ".params.json")
    params_out.write_text(json.dumps(result["fitted"]["params"], indent=1))
    print(f"preset distance {f0:.4f} -> fitted {best['f']:.4f} after {len(cache)} renders")
    print(f"wrote {out} and {params_out} (pass the latter to `spektrafilm process --params`)")


def cmd_compare(args):
    """Side by side: the scan's flat tiles and the engine's wedge tiles at
    the same tone levels, magnified so the grain is visible."""
    from PIL import Image

    scan = load_scans([args.scan], args)[0]
    grain, usm = base_params(scan.film, args.params)
    stored, tiles, sim = render_like(scan, grain, usm, paper=args.paper)
    d = gs.distance(sim, scan.sig, channels=(0,) if engine.is_bw(scan.film) else (0, 1, 2))
    print(f"distance {d['total']:.4f} {json.dumps(d['parts'])}")
    t, z = gs.TILE * 2, args.zoom
    flat = [(s["level"], x, y) for s, x, y in _flat_tile_positions(scan.img, t)]
    by_patch = {}
    for i, x, y in tiles:
        by_patch.setdefault(i, (x, y))
    patches = [(float((stored[y:y + gs.TILE, x:x + gs.TILE] @ gs.LUMA).mean()), x, y) for x, y in by_patch.values()]
    pairs = []
    for lv in np.linspace(0.08, 0.92, args.rows):
        real = min(flat, key=lambda f: abs(f[0] - lv), default=None)
        sim_p = min(patches, key=lambda p: abs(p[0] - lv))
        if real is None or abs(real[0] - lv) > 0.06 or abs(sim_p[0] - real[0]) > 0.08:
            continue
        pairs.append((real, sim_p))
    if not pairs:
        sys.exit("no tone level where both the scan and the render have a flat patch")
    canvas = np.ones((len(pairs) * (t * z + 8), 2 * t * z + 24, 3))
    for k, (real, simp) in enumerate(pairs):
        y0 = k * (t * z + 8)
        a = scan.img[real[2]:real[2] + t, real[1]:real[1] + t]
        b = _crop_pad(stored, simp[1] - gs.TILE // 2, simp[2] - gs.TILE // 2, t)
        canvas[y0:y0 + t * z, 0:t * z] = np.kron(a, np.ones((z, z, 1)))
        canvas[y0:y0 + t * z, t * z + 24:] = np.kron(b, np.ones((z, z, 1)))
    out = Path(args.output)
    Image.fromarray((np.clip(canvas, 0, 1) * 255).astype(np.uint8)).save(out)
    print(f"wrote {out}: left the scan, right the engine, {len(pairs)} tone levels, x{z}")


def _crop_pad(img, x, y, t):
    x = min(max(x, 0), img.shape[1] - t)
    y = min(max(y, 0), img.shape[0] - t)
    return img[y:y + t, x:x + t]


def _flat_tile_positions(img, t):
    for y in range(0, img.shape[0] - t + 1, t):
        for x in range(0, img.shape[1] - t + 1, t):
            s = gs.tile_stats(img[y:y + t, x:x + t])
            if s is not None and s["flatness"] <= gs.FLATNESS_MAX:
                yield s, x, y


def cmd_selftest(args):
    """Recover known parameters: render the engine with perturbed grain,
    treat that render as the "scan", and fit back from the preset."""
    film = args.film
    bw = engine.is_bw(film)
    grain0, usm0 = base_params(film)
    truth = json.loads(json.dumps(grain0))
    truth["rms_granularity"] = [v * 1.6 for v in grain0["rms_granularity"]]
    truth["blur"] = grain0["blur"] * 0.6
    um = 36000.0 / 3244
    img, tiles = engine.render_wedge(film, truth, um, scanner=args.scanner or "frontier", scanner_usm=usm0)
    stored = engine.degrade_like(img, {"bits": 8})
    target = engine.wedge_signature(stored, tiles)

    from types import SimpleNamespace

    s = SimpleNamespace(film=film, scanner=args.scanner or "frontier", um_per_px=um, info={"bits": 8}, sig=target)
    args.paper = None
    cache = {}
    best = fit_params([s], grain0, usm0, ["rms", "blur"], bw, args, args.maxfev, cache)
    got = best["grain"]
    n = 1 if bw else 3
    err_rms = max(abs(got["rms_granularity"][c] / truth["rms_granularity"][c] - 1) for c in range(n))
    err_blur = abs(got["blur"] / truth["blur"] - 1)
    print(f"truth rms {truth['rms_granularity'][:n]} blur {truth['blur']:.3f}")
    print(f"fit   rms {[round(v, 3) for v in got['rms_granularity'][:n]]} blur {got['blur']:.3f} "
          f"(distance {best['f']:.5f}, {len(cache)} renders)")
    print(f"max relative error: rms {err_rms:.1%}, blur {err_blur:.1%}")
    ok = err_rms < 0.1 and err_blur < 0.15
    print("SELFTEST", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def scan_opts(p):
        p.add_argument("--film", help="engine profile (default: from the studio path)")
        p.add_argument("--scanner", choices=["frontier", "noritsu"], help="lab scanner (default: from the path)")
        p.add_argument("--paper", help="print on this paper instead of a lab scan (with no --scanner)")
        p.add_argument("--frame-mm", type=float, default=36.0, help="the film frame's long side (default 36)")
        p.add_argument("--um-per-px", type=float, help="scan pixel pitch on the film, overrides --frame-mm")

    p = sub.add_parser("analyze", help="measure the grain signature of scans")
    p.add_argument("scans", nargs="+")
    p.add_argument("-o", "--output")
    p.set_defaults(fn=cmd_analyze)

    p = sub.add_parser("survey", help="analyze every scan in the studio index")
    p.add_argument("--index", default=str(engine.ROOT / "experimental/studio/index.csv"))
    p.add_argument("--out-dir", default=str(OUT_DIR / "survey"))
    p.set_defaults(fn=cmd_survey)

    p = sub.add_parser("render", help="the engine's grain signature, rendered like a scan")
    p.add_argument("--like", required=True, help="scan whose film, scanner, pitch and file format to match")
    p.add_argument("--params", help="params JSON (e.g. a fit's .params.json)")
    p.add_argument("-o", "--output")
    scan_opts(p)
    p.set_defaults(fn=cmd_render)

    p = sub.add_parser("fit", help="fit the engine's grain parameters to scans of one film")
    p.add_argument("scans", nargs="+")
    p.add_argument("--free", default="rms,uniformity,blur,dye,micro",
                   help="parameters to fit: " + "; ".join(f"{k} = {v}" for k, v in FREE.items()))
    p.add_argument("--params", help="start from this params JSON instead of the preset")
    p.add_argument("--maxfev", type=int, default=150, help="engine renders at most")
    p.add_argument("-o", "--output")
    scan_opts(p)
    p.set_defaults(fn=cmd_fit)

    p = sub.add_parser("compare", help="side-by-side image of scan grain and engine grain")
    p.add_argument("scan")
    p.add_argument("--params")
    p.add_argument("-o", "--output", required=True)
    p.add_argument("--rows", type=int, default=6)
    p.add_argument("--zoom", type=int, default=3)
    scan_opts(p)
    p.set_defaults(fn=cmd_compare)

    p = sub.add_parser("selftest", help="fit back known parameters from an engine render")
    p.add_argument("--film", default="kodak_portra_400")
    p.add_argument("--scanner", choices=["frontier", "noritsu"])
    p.add_argument("--maxfev", type=int, default=60)
    p.set_defaults(fn=cmd_selftest)

    args = ap.parse_args()
    return args.fn(args) or 0


if __name__ == "__main__":
    sys.exit(main())
