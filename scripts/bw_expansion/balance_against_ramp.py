#!/usr/bin/env python3
"""Balance a prepared profile so a grey ramp renders neutral.

Upstream's `correct.py` fits this with the simulation in the loop, and for a
positive it subtracts the mean across channels before fitting, so it corrects
colour *balance* at each exposure rather than overall density. This does the
same against the real engine: render an 18.4% grey at several stops, fit a
per-channel density scale and an R/B exposure shift, and write the result back
into the profile's density model.

The correction is fitted, not measured. It is recorded in the preparation
report so a reader can see how far the source curves had to be moved.

Needs a built or installed `spektrafilm` CLI; pass it with --cli.
"""
import argparse
import copy
import json
import subprocess
import tempfile
from pathlib import Path

import numpy as np
import OpenImageIO as oiio
from scipy.optimize import least_squares

ROOT = Path(__file__).resolve().parents[2]
MIDGREY = 0.184


class Unrenderable(Exception):
    """The engine refused a trial profile the fit asked it to render."""


def write_ramp(path, ev):
    values = MIDGREY * 2.0 ** np.asarray(ev, dtype=float)
    image = np.tile(values[None, :, None], (1, 1, 3)).astype("float32")
    spec = oiio.ImageSpec(len(values), 1, 3, "float")
    out = oiio.ImageOutput.create(str(path))
    out.open(str(path), spec)
    out.write_image(image)
    out.close()


def render(cli, data_dir, profile_path, ramp, work, n, scan_film=True):
    """Render the ramp through one profile; return linear RGB per step.

    A positive is scanned directly. A negative is printed first, as upstream's
    correct_negative_curves_with_gray_ramp does: what has to come out neutral
    is the print, not the negative, and the orange mask guarantees the
    negative itself never will.
    """
    raw = work / "ramp.bin"
    command = [str(cli), "process", str(ramp), "-o", str(work / "ramp_out.tiff"),
               "--film", profile_path.stem, "--raw-out", str(raw),
               "--data-dir", str(data_dir), "--input-colour", "sRGB",
               "--input-linear"]
    if scan_film:
        command.append("--scan-film")
    done = subprocess.run(command, capture_output=True, text=True)
    if done.returncode:
        raise Unrenderable(done.stderr.strip().splitlines()[-1] if done.stderr else
                           f"exit {done.returncode}")
    return np.fromfile(raw, dtype="<f8").reshape(n, 3)


def corrected(profile, scale, shift):
    """Apply a density scale and exposure shift to the density model."""
    out = copy.deepcopy(profile)
    model = out["data"]["density_curves_model"]
    model["amplitudes"] = [[a * scale[ch] for a in row]
                           for ch, row in enumerate(model["amplitudes"])]
    model["centers"] = [[c + shift[ch] for c in row]
                        for ch, row in enumerate(model["centers"])]
    # The engine rebuilds density_curves from the model, but keep the sampled
    # arrays consistent for any reader that trusts them.
    log_e = np.array(out["data"]["log_exposure"], dtype=float)
    centers = np.array(model["centers"], dtype=float)
    amplitudes = np.array(model["amplitudes"], dtype=float)
    sigmas = np.array(model["sigmas"], dtype=float)
    sign = -1.0 if out["info"]["type"] == "positive" else 1.0
    from scipy.special import ndtr
    curves = np.stack([
        np.sum(ndtr(sign * (log_e[:, None] - centers[ch]) / sigmas[ch])
               * amplitudes[ch], axis=1)
        for ch in range(centers.shape[0])], axis=1)
    out["data"]["density_curves"] = np.round(curves, 10).tolist()
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    parser.add_argument("--cli", type=Path,
                        default=Path("/Applications/Negs.app/Contents/MacOS/spektrafilm"))
    parser.add_argument("--ev", type=float, nargs="+", default=[-2, -1, 0, 1, 2])
    parser.add_argument("--trust", type=float, default=0.5,
                        help="bias toward leaving the source curves alone; "
                             "1.0 is the smallest correction, 0.0 the largest")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    source = json.loads(args.profile.read_text())
    scan_film = source["info"].get("type") == "positive"
    stem = args.profile.stem
    work = Path(tempfile.mkdtemp(prefix="ramp-"))
    staging = work / "data"
    staging.mkdir()
    for child in args.data_dir.iterdir():
        (staging / child.name).symlink_to(child)
    (staging / "profiles").unlink()
    (staging / "profiles").mkdir()
    for child in (args.data_dir / "profiles").iterdir():
        (staging / "profiles" / child.name).symlink_to(child)
    ramp = work / "ramp.tif"
    write_ramp(ramp, args.ev)
    live = staging / "profiles" / f"{stem}.json"

    refused = []

    def neutrality(x):
        scale, shift = x[:3], [x[3], 0.0, x[4]]
        if live.is_symlink() or live.exists():
            live.unlink()
        live.write_text(json.dumps(corrected(source, scale, shift)))
        try:
            rgb = render(args.cli, staging, live, ramp, work, len(args.ev),
                         scan_film=scan_film)
        except Unrenderable as why:
            # Some trial corrections the fit proposes are ones the engine
            # cannot render at all - Pro 1000 PMZ drives its blur solve to a
            # NaN sigma. That is an infeasible point, not a failure of the
            # run: hand the optimiser a large residual so it steps back, and
            # record it so the result can say how often it happened.
            refused.append((np.round(np.asarray(x), 4).tolist(), str(why)))
            return np.full(2 * len(args.ev) + 3, 10.0)
        ratios = np.column_stack([rgb[:, 0]/rgb[:, 1], rgb[:, 2]/rgb[:, 1]])
        return np.concatenate([(ratios - 1.0).ravel(),
                               args.trust * 2.0 * (np.asarray(scale) - 1.0)])

    before = np.abs(neutrality([1, 1, 1, 0, 0])[:2*len(args.ev)]).max()
    fit = least_squares(neutrality, [1., 1., 1., 0., 0.], diff_step=0.02,
                        xtol=1e-8, ftol=1e-8)
    scale, shift = fit.x[:3], [fit.x[3], 0.0, fit.x[4]]
    after = np.abs(neutrality(fit.x)[:2*len(args.ev)]).max()

    result = corrected(source, scale, shift)
    result["metadata"]["datasource"] += (
        f" Density curves balanced against a rendered {len(args.ev)}-stop grey ramp "
        f"by scripts/bw_expansion/balance_against_ramp.py (upstream's "
        f"correct_positive_curves_with_gray_ramp): density scale "
        f"{np.round(scale, 4).tolist()}, log-exposure shift "
        f"{np.round(shift, 4).tolist()}, data_trustability {args.trust}. Worst "
        f"channel deviation from neutral across the ramp {before*100:.1f}% before, "
        f"{after*100:.1f}% after. This correction is fitted against the engine, "
        f"not measured from the datasheet."
        + (f" The engine refused {len(refused)} trial correction(s) during the fit "
           f"({refused[0][1]}); those points were treated as infeasible."
           if refused else ""))
    out = args.output or args.profile
    out.write_text(json.dumps(result, indent=2, allow_nan=False) + "\n")
    print(json.dumps(dict(profile=str(out), density_scale=scale.tolist(),
                          log_exposure_shift=shift, ev=args.ev,
                          worst_neutral_deviation_before=float(before),
                          worst_neutral_deviation_after=float(after),
                          data_trustability=args.trust), indent=2))


if __name__ == "__main__":
    main()
