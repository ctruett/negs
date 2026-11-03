# Kodak Ektachrome 64 EPR source record — 3 November 2026

The first colour preparation here, and the first stock whose datasheet
publishes everything needed without a donor: **Kodak Ektachrome 64
Professional (EPR), publication E-8**, page 5. See
[recipe.json](recipe.json) for the document hash, derived PDF coordinates,
axis transforms, conditions and assumptions, and read
[the APX 25 record](../agfa-apx25/README.md) for the extraction method, which
is shared.

| Panel | Traces | Range used |
|---|---|---|
| Characteristic Curves | 3; 132–135 points each in `epr-characteristic-{r,g,b}.csv` | log exposure −2.510 to +0.360; status-A density 0.190–3.685 |
| Spectral-Sensitivity Curves | 3; 87–130 points in `epr-sensitivity-{b,g,r}.csv` | peaks at 420.2, 550.5 and 650.8 nm; each trace used only over its own span |
| Spectral-Dye-Density Curves | 4; 105–129 points in `epr-dye-{y,m,neutral,c}.csv` | 400–700 nm; peaks at 439.6, 549.0, 558.8 (visual neutral) and 652.3 nm |

Traces are named by sorting: spectral panels by peak wavelength,
characteristic by maximum density, which reproduces the sheet's own `B G R`
ordering. The visual-neutral trace lands between magenta and cyan, as the
recipe predicts, which is a check on the sort rather than a coincidence.

**Why this stock is different.** Portra-style sheets publish only D-min and a
midscale neutral, so the shipped profiles borrow per-dye C, M and Y curves
from a donor — historically `generic_a`, which the research record traces to
*Digital Color Management* page 112 rather than to any measurement of that
film. E-8 plots the three dyes separately. Nothing here is borrowed.

**Unmixing is the step B&W does not need.** A characteristic curve is a
densitometer reading: the red channel sees some magenta and some yellow. The
crosstalk matrix comes from the status-A responsivities and the dyes' own
absorption, and is inverted to recover per-dye amounts — the method recovered
from the deleted `agx_emulsion/profiles/factory.py`
(`compute_densitometer_crosstalk_matrix`, `unmix_density_curves`) at
spektrafilm `e418a25^`, along with the responsivity data now in
`data/densitometer`. The matrix this sheet gives, rows R/G/B, columns C/M/Y:

```
1.000  0.140  0.040
0.161  1.000  0.074
0.066  0.180  1.000
```

Dye spectra are first rescaled so one unit of a dye reads unit density in its
own channel, which puts amounts and spectra on one scale.

**Positives fit mirrored.** The engine evaluates a positive's model with a
negated argument (`sign = -1` in `refresh_density_curves_from_model`), so each
channel is fitted against mirrored log exposure and the centres negated back.
The engine rebuilds `density_curves` from the model, so the model is
authoritative.

**Assumptions.** Base density is a flat 0.10 — not on the sheet, which
normalises its dye panel to a visual neutral of 1.0 and plots no D-min; 0.10
sits inside the 0.09–0.13 the shipped positives carry. Per-channel minima
(0.210, 0.190, 0.190) are read off the characteristic curves and subtracted
before unmixing. Engine log exposure zero is placed where each layer's total
density equals 0.735, which is −log10(0.184): the density that transmits this
repository's 18.4% reference grey. The panel's own "Density: 1.0" is a
sensitivity criterion, not a mid-tone, and anchoring there renders about half
a stop dark.

**Agreement.** Maximum residual on the unmixed dye amounts is 0.0163 against a
0.02 gate, about 0.8% of the 2.5–2.8 unit range. The gate is on amounts rather
than plotted density because this sheet's panels calibrate to 0.0001 — the
binding uncertainty is the unmixing, not the tracing.

**What is missing, and what it costs.** Three calibration steps the shipped
colour profiles have and this does not, all recorded in `recipe.json` under
`known_gaps`:

- **No iterated neutral balance.** Channels are scaled so the reference grey
  gives unit raw exposure and each layer is anchored to mid-grey, but neither
  iterates on a *rendered* neutral the way upstream's `balance_sensitivity`
  does. A rendered grey still comes out about 8% green.
- **No couplers.** Masking and DIR couplers are what upstream's README calls
  the difference between datasheet curves and a convincing look. Without them
  this renders more saturated than the shipped slides: mean chroma 88 against
  71 for Ektachrome 100 and 66 for Kodachrome 64 on the same frame.
- **No `hanatos2025` adaptation parameters.** Stripping them from a shipped
  profile changes its render by 5.4/255 mean, 30/255 at the 99th percentile,
  so this is a quality gap rather than a blocker. Nothing in any repository's
  history ever wrote these.

So this profile is honest about its curves and incomplete about its chemistry.
It is labelled experimental for that reason.

```sh
python scripts/bw_expansion/prepare_colour_film.py --source kodak-ektachrome64-epr --output-dir target/colour-profiles
python scripts/bw_expansion/extract_graphs.py --source kodak-ektachrome64-epr --pdf /path/to/e8-Ektachrome_64_EPR.pdf
```

New extraction, preparation and profile: spektrafilm-rs contributors,
Claude-assisted, 2026; new profile/preparation data under CC BY-SA 4.0.
Manufacturer graph excerpts retain Eastman Kodak rights; no manufacturer's
endorsement or laboratory comparison is claimed.
