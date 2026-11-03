#!/usr/bin/env python3
"""Prepare a three-layer colour film profile from extracted source points.

The step a B&W preparation does not need is unmixing. A datasheet's
characteristic curves are densitometer readings: each channel sees some of
every dye. Converting them into per-dye amounts needs the densitometer's
spectral responsivities and the dyes' own absorption curves, which give a
crosstalk matrix to invert. That is the method recovered from the deleted
`agx_emulsion/profiles/factory.py` (`compute_densitometer_crosstalk_matrix`,
`unmix_density_curves`) at spektrafilm `e418a25^`.

What this does not do, and the shipped colour profiles do: reconstruct dye
curves a sheet omits, model masking or DIR couplers, or fit the
`hanatos2025` adaptation parameters. Profiles from here are honest about
their curves and incomplete about the chemistry.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from scipy.interpolate import PchipInterpolator
from scipy.optimize import least_squares
from scipy.special import ndtr

sys.path.insert(0, str(Path(__file__).resolve().parent))
from prepare import reference_gray_spectrum, write_json  # noqa: E402

import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SOURCE_ROOT = ROOT / "data/profile-sources"
REVIEW_ROOT = ROOT / "docs/profile-sources-review"
WAVELENGTHS = np.arange(380, 781, 5)


def read_points(sources, name):
    return np.loadtxt(sources / f"{name}.csv", delimiter=",", skiprows=1)[:, :2]


def on_grid(points, grid=WAVELENGTHS):
    """Resample a spectral trace onto the engine grid; NaN where unmeasured."""
    out = np.full(len(grid), np.nan)
    inside = (grid >= points[0, 0]) & (grid <= points[-1, 0])
    out[inside] = PchipInterpolator(points[:, 0], points[:, 1])(grid[inside])
    return out


def densitometer(data_dir, status):
    """Status responsivities on the engine grid, each normalised to sum 1."""
    out = np.zeros((len(WAVELENGTHS), 3))
    for i, channel in enumerate("rgb"):
        path = data_dir / f"densitometer/status_{status}/responsivity_{channel}.csv"
        points = np.loadtxt(path, delimiter=",")
        points = points[np.argsort(points[:, 0])]
        out[:, i] = np.nan_to_num(on_grid(points), nan=0.0)
    out[out < 0] = 0
    return out / out.sum(axis=0)


def crosstalk(responsivity, dye_density):
    """How much density each dye shows in each densitometer channel.

    factory.py's compute_densitometer_crosstalk_matrix: the density the
    instrument reads through a unit amount of one dye.
    """
    transmittance = 10 ** (-np.nan_to_num(dye_density, nan=0.0))
    matrix = np.zeros((3, 3))
    for i in range(3):
        for j in range(3):
            matrix[i, j] = -np.log10(
                np.nansum(responsivity[:, i] * transmittance[:, j])
                / np.nansum(responsivity[:, i]))
    return matrix


def fit_positive(log_exposure, amounts, n=4):
    """Fit one channel's dye amount as the engine will evaluate it.

    A positive is evaluated with `sign = -1` (see the Rust
    refresh_density_curves_from_model), so the mixture is fitted against
    mirrored exposure and the centres are negated back.
    """
    x, y = -log_exposure[::-1], amounts[::-1]
    ceiling = float(y.max())
    initial = np.r_[np.linspace(x[0], x[-1], n), np.full(n, ceiling/n), np.full(n, .5)]
    lower = np.r_[np.full(n, x[0]-4), np.full(n, .001), np.full(n, .035)]
    upper = np.r_[np.full(n, x[-1]+4), np.full(n, 4), np.full(n, 4)]

    def evaluate(v, at):
        return np.sum(ndtr((np.asarray(at)[..., None]-v[:n])/v[2*n:])*v[n:2*n], axis=-1)

    result = least_squares(lambda v: np.r_[evaluate(v, x)-y,
                                           10*(sum(v[n:2*n])-ceiling)],
                           initial, bounds=(lower, upper), max_nfev=4000,
                           ftol=1e-12, xtol=1e-12, gtol=1e-12)
    if not result.success:
        raise ValueError(f"channel fit did not converge: {result.message}")
    v = result.x
    v[n:2*n] *= ceiling/sum(v[n:2*n])
    order = np.argsort(-v[:n])
    return ([-c for c in v[:n][order]], list(v[n:2*n][order]), list(v[2*n:][order]),
            lambda at: evaluate(v, -np.asarray(at)))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True)
    parser.add_argument("--output-dir", type=Path, default=ROOT / "target/colour-profiles")
    parser.add_argument("--data-dir", type=Path, default=ROOT / "data")
    args = parser.parse_args()
    sources = SOURCE_ROOT / args.source
    figures = REVIEW_ROOT / args.source
    recipe = json.loads((sources / "recipe.json").read_text())
    cfg = recipe["film"]
    graphs = recipe["graphs"]
    char = next(k for k, v in graphs.items() if v["role"] == "characteristic")
    sens = next(k for k, v in graphs.items() if v["role"] == "sensitivity")
    dye = next(k for k, v in graphs.items() if v["role"] == "dye")

    # --- dye spectra: profile channels r, g, b are the c, m, y dyes ---
    dye_raw = np.column_stack([on_grid(read_points(sources, f"{dye}-{c}"))
                               for c in ("c", "m", "y")])
    responsivity = densitometer(args.data_dir, cfg["densitometer"].replace("status_", ""))

    # The sheet plots a visual neutral alongside the three dyes. Solve for the
    # dye mixture that reproduces it and rescale by that, normalised to green:
    # factory.py's find_midscale_neutral_coefficients / rescale_dye_density_using_neutral.
    neutral = on_grid(read_points(sources, f"{dye}-neutral"))
    usable = np.all(np.isfinite(np.column_stack([dye_raw, neutral])), axis=1)
    mix = np.linalg.lstsq(dye_raw[usable], neutral[usable], rcond=None)[0]
    mix = mix / mix[1]
    neutral_residual = float(np.max(np.abs(dye_raw[usable] @ mix * mix[1] - neutral[usable])))
    dye_raw = dye_raw * mix

    # Put the dyes on a scale where one unit of a dye reads one density in its
    # own channel, so unmixed amounts and dye spectra share a scale.
    scale = np.ones(3)
    for _ in range(8):
        matrix = crosstalk(responsivity, dye_raw * scale)
        scale = scale / np.diag(matrix)
    channel_density = dye_raw * scale
    matrix = crosstalk(responsivity, channel_density)

    # --- characteristic curves: status density -> per-dye amounts ---
    curves = [read_points(sources, f"{char}-{c}") for c in "rgb"]
    lo = max(c[0, 0] for c in curves)
    hi = min(c[-1, 0] for c in curves)
    source_x = np.linspace(lo, hi, 600)
    read = np.column_stack([PchipInterpolator(c[:, 0], c[:, 1])(source_x) for c in curves])
    dmin = read.min(axis=0)
    amounts = np.clip(np.linalg.solve(matrix, (read - dmin).T).T, 0, None)

    # --- exposure anchor: where a mid-grey subject lands, per channel ---
    # Anchoring each layer separately is what balancing a reversal film to
    # neutral means: a grey subject must read the same density in all three.
    anchor = np.array([float(np.interp(-cfg["midgray_total_density"],
                                       -read[:, ch], source_x)) for ch in range(3)])
    sample = recipe["sampling"]
    log_e = np.linspace(sample["log_exposure_min"], sample["log_exposure_max"],
                        sample["count"])

    centers, amplitudes, sigmas, fitted = [], [], [], []
    for ch in range(3):
        c, a, s, f = fit_positive(source_x - anchor[ch], amounts[:, ch])
        centers.append(c)
        amplitudes.append(a)
        sigmas.append(s)
        fitted.append(f)
    model = dict(model_type="norm_cdfs", centers=centers,
                 amplitudes=amplitudes, sigmas=sigmas)
    density_curves = np.column_stack([f(log_e) for f in fitted])

    # --- sensitivity: each trace over its own span, grey-balanced ---
    sensitivity = np.column_stack([on_grid(read_points(sources, f"{sens}-{c}"))
                                   for c in "rgb"])
    linear = np.where(np.isnan(sensitivity), 0.0, 10.0**np.nan_to_num(sensitivity))
    gray = reference_gray_spectrum(args.data_dir)
    balance = gray @ linear
    linear = linear / balance

    profile = dict(
        metadata=dict(
            version=recipe["version_tag"], created=recipe["created"],
            copyright="New preparation: spektrafilm-rs contributors (Claude-assisted), 2026. Manufacturer source rights retained.",
            license="New preparation and profile: CC BY-SA 4.0, https://creativecommons.org/licenses/by-sa/4.0/ . Manufacturer graph excerpts retain their original rights.",
            citation="Spektrafilm by Andrea Volpato and contributors; https://github.com/andreavolpato/spektrafilm . New calibration, not an upstream stock profile.",
            datasource=(f"{recipe['source']['document']}; SHA256 {recipe['source']['sha256']}. "
                        "Reproduce with scripts/bw_expansion/prepare_colour_film.py; axis "
                        "calibration derived from the page by "
                        "scripts/bw_expansion/extract_graphs.py; source points, assumptions "
                        f"and conditions: data/profile-sources/{args.source}/recipe.json. "
                        + cfg["sensitivity_note"] + " " + cfg["base_density_note"])),
        info=dict(stock=cfg["id"], name=cfg["name"], type=cfg["type"], support="film",
                  stage="filming", use="still", antihalation=cfg["antihalation"],
                  target_print=recipe["print"]["target_print"], channel_model="color",
                  densitometer=cfg["densitometer"],
                  log_sensitivity_density_over_min=1.0,
                  reference_illuminant="D55", viewing_illuminant="D50"),
        data=dict(
            wavelengths=[int(w) for w in WAVELENGTHS],
            log_sensitivity=[[None if not np.isfinite(v) else round(float(v), 10)
                              for v in row]
                             for row in np.where(linear > 0, np.log10(np.where(linear > 0, linear, 1)), np.nan)],
            channel_density=[[None if not np.isfinite(v) else round(float(v), 10)
                              for v in row] for row in channel_density],
            base_density=[[round(float(cfg["base_density"]), 10)] for _ in WAVELENGTHS],
            log_exposure=np.round(log_e, 10).tolist(),
            density_curves=np.round(density_curves, 10).tolist(),
            density_curves_model=model))

    # Spectral adaptation parameters cannot be derived here: nothing in either
    # repository ever wrote them, and the measured reflectance datasets their
    # fit would need are not present. Borrow them from a named shipped stock,
    # with the same standing as a donor dye curve, and say so in the profile.
    donor = recipe.get("adaptation_donor")
    if donor:
        source_profile = json.loads(
            (args.data_dir / "profiles" / f"{donor['stock']}.json").read_text())
        for key in ("hanatos2025_adaptation_window_params",
                    "hanatos2025_adaptation_surface_params"):
            profile["data"][key] = source_profile["data"][key]
        profile["metadata"]["datasource"] += (
            f" Spectral adaptation parameters are not this stock's own: they are "
            f"borrowed from {donor['stock']}. {donor['reason']}")

    figures.mkdir(parents=True, exist_ok=True)
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.4))
    colours = ["#c0392b", "#27ae60", "#2980b9"]
    for ch, colour in enumerate(colours):
        axes[0].plot(source_x - anchor[ch], amounts[:, ch], ".", ms=2, color=colour)
        axes[0].plot(log_e, density_curves[:, ch], color=colour, lw=1.2)
    axes[0].set(title="Unmixed dye amounts (dots) and fit",
                xlabel="engine log exposure", ylabel="dye amount")
    for ch, colour in enumerate(colours):
        axes[1].plot(source_x, read[:, ch], color=colour, lw=1.2)
    axes[1].set(title="Source characteristic curves (status density)",
                xlabel="source log exposure", ylabel="density")
    for ch, colour in zip(range(3), ["#0aa3c2", "#c0399b", "#c8a415"]):
        axes[2].plot(WAVELENGTHS, channel_density[:, ch], color=colour, lw=1.4)
    axes[2].set(title="Dye spectra, rescaled to unit channel density",
                xlabel="wavelength (nm)", ylabel="density")
    for ax in axes:
        ax.grid(alpha=.2)
    fig.tight_layout()
    fig.savefig(figures / f"{cfg['id']}-validation.png", dpi=130)
    plt.close(fig)

    residual = np.abs(np.column_stack([f(source_x - anchor[ch])
                                       for ch, f in enumerate(fitted)]) - amounts)
    # Gate before writing: a profile that fails its own tolerance must not be
    # left on disk, where a later step can pick it up as if it had passed.
    if cfg["density_tolerance"] and residual.max() > cfg["density_tolerance"]:
        raise ValueError(f"fit exceeds tolerance: {residual.max()} > "
                         f"{cfg['density_tolerance']}")
    path = args.output_dir / (cfg["id"] + ".json")
    write_json(path, profile)
    report = dict(
        stock=cfg["id"], source_exposure_anchor=anchor.tolist(),
        neutral_mix=mix.tolist(), neutral_fit_residual=neutral_residual,
        crosstalk_matrix=matrix.tolist(), dye_scale=scale.tolist(),
        channel_dmin=dmin.tolist(),
        max_amount_residual=float(residual.max()),
        tolerance=cfg["density_tolerance"],
        grey_balance_applied=balance.tolist(),
        dye_amount_max=amounts.max(axis=0).tolist(),
        source_points_sha256={p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                              for p in sorted(sources.glob("*.csv"))},
        profile_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
    write_json(figures / "preparation-report.json", report)
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
