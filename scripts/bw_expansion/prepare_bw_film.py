#!/usr/bin/env python3
"""Prepare a single-channel B&W film profile from extracted source points.

Shares the fitting in prepare.py: a constrained positive normal-CDF mixture
whose components are mathematical, not measured emulsion layers. Reads the
checked-in CSVs; no PDF is needed. Outputs stay provisional unless
--output-dir explicitly points at the production profile directory.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from scipy.interpolate import PchipInterpolator
from scipy.optimize import brentq

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare import (  # noqa: E402
    film_response, fit_response, reference_gray_spectrum, write_json)

import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = ROOT / "data/profile-sources"
REVIEW_ROOT = ROOT / "docs/profile-sources-review"


def read_points(sources, name):
    return np.loadtxt(sources / f"{name}.csv", delimiter=",", skiprows=1)


def make_profile(recipe, source_dir, log_exposure, densities, base, sensitivity, model):
    cfg = recipe["film"]
    source = recipe["source"]
    info = dict(stock=cfg["id"], name=cfg["name"], type="negative",
                support="film", stage="filming", use="still",
                antihalation="strong", target_print=recipe["print"]["target_print"],
                channel_model="bw", densitometer="diffuse_visual",
                log_sensitivity_density_over_min=1.0,
                reference_illuminant="D55", viewing_illuminant="D50")
    data = dict(wavelengths=list(range(380, 781, 5)),
                log_sensitivity=[[None if v == 0 else round(float(np.log10(v)), 10)]
                                 for v in sensitivity],
                channel_density=[[1.0] for _ in range(81)],
                base_density=[[round(float(base), 10)] for _ in range(81)],
                log_exposure=np.round(log_exposure, 10).tolist(),
                density_curves=np.round(densities[:, None], 10).tolist(),
                development_time=[cfg["development_time_minutes"]],
                density_curves_model=model)
    centers, amplitudes, sigmas = [np.array(model[k][0])
                                   for k in ("centers", "amplitudes", "sigmas")]
    from scipy.special import ndtr
    data["density_curves_layers"] = (
        ndtr((log_exposure[:, None]-centers)/sigmas)*amplitudes)[:, :, None].tolist()
    return dict(metadata=dict(
        version=recipe["version_tag"], created=recipe["created"],
        copyright="New preparation: spektrafilm-rs contributors (Claude-assisted), 2026. Manufacturer source rights retained.",
        license="New preparation and profile: CC BY-SA 4.0, https://creativecommons.org/licenses/by-sa/4.0/ . Manufacturer graph excerpts retain their original rights.",
        citation="Spektrafilm by Andrea Volpato and contributors; https://github.com/andreavolpato/spektrafilm . New calibration, not an upstream stock profile.",
        datasource=(f"{source['document']}; SHA256 {source['sha256']}. "
                    "Reproduce with scripts/bw_expansion/prepare_bw_film.py; axis calibration "
                    "derived from the page by scripts/bw_expansion/extract_graphs.py; source "
                    "points, assumptions and conditions: "
                    f"data/profile-sources/{source_dir}/recipe.json. "
                    + cfg["sensitivity_note"] + " " + cfg["development_note"])),
        info=info, data=data)


def review(figures, name, points, at, fitted, xlabel, ylabel, title):
    figures.mkdir(parents=True, exist_ok=True)
    fig, ax = plt.subplots(figsize=(7, 4.6))
    ax.plot(at, fitted, color="#17666e", label="Prepared response")
    ax.scatter(points[:, 0], points[:, 1], s=7, color="#e04b22", label="Source points")
    ax.axvspan(points[0, 0], points[-1, 0], alpha=.05, color="#17666e")
    ax.set(xlabel=xlabel, ylabel=ylabel, title=title)
    ax.grid(alpha=.2)
    ax.legend(fontsize=8)
    fig.tight_layout()
    fig.savefig(figures / f"{name}-validation.png", dpi=140)
    plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True,
                        help="directory name under data/profile-sources")
    parser.add_argument("--output-dir", type=Path, default=ROOT / "target/bw-profiles")
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    args = parser.parse_args()
    sources = SOURCE_ROOT / args.source
    figures = REVIEW_ROOT / args.source
    recipe = json.loads((sources / "recipe.json").read_text())
    cfg = recipe["film"]
    graphs = recipe["graphs"]
    density_name = next(k for k, v in graphs.items() if v["role"] == "density")
    sens_name = next(k for k, v in graphs.items() if v["role"] == "sensitivity")
    density_points = read_points(sources, density_name)[:, :2]
    sens_points = read_points(sources, sens_name)[:, :2]

    base, ceiling = cfg["base_density"], cfg["assumed_total_density_ceiling"]
    total = film_response(density_points, base, ceiling)
    model, total = fit_response(density_points, total, base, ceiling, "film")
    origin = brentq(lambda x: total(x)-base-cfg["midgray_net_density"],
                    *density_points[[0, -1], 0])
    model["centers"][0] = [c-origin for c in model["centers"][0]]

    sample = recipe["sampling"]
    log_e = np.linspace(sample["log_exposure_min"], sample["log_exposure_max"],
                        sample["count"])
    net = total(log_e+origin)-base

    wavelengths = np.arange(380, 781, 5)
    measured = ((wavelengths >= cfg["sensitivity_first_nm"])
                & (wavelengths <= cfg["sensitivity_last_nm"]))
    sensitivity = np.zeros(81)
    sensitivity[measured] = 10**PchipInterpolator(
        sens_points[:, 0], sens_points[:, 1])(wavelengths[measured])
    gray = reference_gray_spectrum(args.data_dir)
    before = float(gray @ sensitivity)
    sensitivity /= before

    profile = make_profile(recipe, args.source, log_e, net, base, sensitivity, model)
    curve = np.array(profile["data"]["density_curves"])[:, 0]
    error = np.interp(density_points[:, 0]-origin, log_e, curve)+base-density_points[:, 1]
    worst = float(np.max(np.abs(error)))
    if (worst > cfg["density_tolerance"] or not np.isfinite(curve).all()
            or curve.min() < -1e-9 or np.any(np.diff(curve) < -1e-9)):
        raise ValueError(f"failed physical/source checks: max density error {worst}")

    path = args.output_dir / (profile["info"]["stock"] + ".json")
    write_json(path, profile)
    report = dict(
        stock=profile["info"]["stock"], source_exposure_origin=origin,
        sensitivity_log_shift=-np.log10(before),
        midgray_raw=float(gray @ sensitivity),
        measured_nm=[int(wavelengths[measured][0]), int(wavelengths[measured][-1])],
        max_source_density_error=worst, tolerance=cfg["density_tolerance"],
        minimum_sampled_net_density=float(curve.min()),
        maximum_sampled_net_density=float(curve.max()),
        source_points_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sorted(sources.glob("*.csv"))},
        profile_sha256=hashlib.sha256(path.read_bytes()).hexdigest())

    x = np.linspace(density_points[0, 0]-1, density_points[-1, 0]+2, 700)
    review(figures, density_name, density_points, x, total(x), "Source log exposure",
           "Total diffuse density", f"{cfg['name']} density curve")
    x = np.linspace(sens_points[0, 0], sens_points[-1, 0], 700)
    review(figures, sens_name, sens_points, x,
           PchipInterpolator(sens_points[:, 0], sens_points[:, 1])(x),
           "Wavelength (nm)", "Source log sensitivity (before common shift)",
           f"{cfg['name']} spectral sensitivity")
    write_json(figures / "preparation-report.json", report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
