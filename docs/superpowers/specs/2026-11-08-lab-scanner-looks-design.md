# Lab scanner looks (Frontier and Noritsu): design

Date: 2026-11-08. Branch: `claude/inspector-redesign`.

## Intent

The user wants a developed film to come out the way a real lab scan does,
from either of the two lab scanners most film is scanned on today: a Fuji
Frontier or a Noritsu. They pick one; every scan goes through one of them.

Today, Negs either prints a negative on simulated paper, or "scans film
directly", which outputs the colour of the film itself. For a negative that
means an orange, uninverted image. Neither matches what people see from a
lab, where the scanner inverts the negative and applies its own colour
processing, with no paper involved.

## Data

`experimental/studio/` (not in the repository) holds Color Precision's studio
scans. There are 51 films, each at −1, 0, +1 and +2 EV (Provia has −2, not
+2), each on both a Frontier and a Noritsu: about 400 frames. `index.csv`
gives the film, push, exposure, scanner, file and source URL. Every frame
holds:

- an X-Rite ColorChecker Digital SG (140 patches), left
- a ColorChecker Passport (24 colours plus a grey card), right

All of it was shot in daylight in the same studio. 17 of the films also
come pushed.

## Goals

- A **Scanner** choice of Frontier or Noritsu. Every scan goes through one;
  there is no "None".
- For **negatives**, the scanner replaces the paper print. The film is
  scanned and inverted the way the lab does it. Printing on paper stays
  available as a separate route, for an optical print look.
- For **slides**, the film goes through the scanner, with no inversion.
- Each scanner's look is **learned from the data**, as one transform per
  scanner shared by every film. It describes the machine, not any one stock,
  and so works on films that have no scans.
- The result is **measured**: a hue error and a colour distance against the
  real scans, per film and per scanner, on held-out frames.

## Non-goals

- Re-fitting individual films' couplers. That is project 2, which needs
  this scanner model to fit against.
- New film profiles (project 3).
- Pushed development (later).
- Tungsten and other lights. This data is all daylight.
- Imitating a scanner's sharpening, grain handling or dust removal. This is
  colour and tone only.

## Anti-goals

- Fitting each film's frames separately, so a scanner "look" turns out to
  be a pile of per-film corrections. The look has to be one transform per
  scanner.
- Breaking greys. A neutral grey card must come out neutral on both
  scanners, as it does on the real scans.
- Losing what exists: the paper print route, edits made with it, and
  presets keep working.

## How a lab scan works, and the model

A lab scanner:

1. reads the film's transmittance through its own RGB sensor
2. inverts a negative per channel, subtracting the orange mask (the film
   base) and normalising each channel
3. sets the frame's density and colour balance automatically (both
   machines auto-correct each frame, which is why the real scans hold steady
   across −1 to +2 EV)
4. applies its colour rendering: tone curves and a colour matrix or table

Negs's model mirrors that:

- **Auto colour correction (the user's call): full auto, as the labs do.**
  Every frame is balanced automatically for density and colour, which is
  why the real scans hold steady across exposures. It also neutralises
  deliberate casts (sunsets, tungsten warmth). So the user gets lab
  operator style corrections on top: density, and cyan/magenta/yellow keys.
  During fitting, the auto correction meters each simulated frame exactly as
  it will in the app.
- **Steps 1–3, physical and per frame.** From the developed film's spectral
  densities (the existing scan stage's spectral integration), read RGB
  densities through a scanner sensitivity (Status M as the starting point,
  since it is close to what lab scanners use). Subtract the film's base
  density, the orange mask. Then normalise each channel so the frame's
  neutral sits at a fixed level: the scanner's auto density and balance,
  driven by the frame's own metering. For slides, the same without the
  inversion. Negs's existing auto exposure and print-balance logic can
  serve as the frame metering.
- **Step 4, learned per scanner and film type.** Real lab scanners process
  negatives, slides and black and white differently, so each scanner has:
  - **a colour negative look,**
  - **a slide look,**
  - **a black and white look.**

  The colour looks are a per-channel tone curve followed by a 3×3 matrix in
  log or density space. They stay low-parameter on purpose, so they can't
  absorb individual films' profile errors; those are project 2's job.

  The black and white look is a tone curve plus a small per-scanner colour
  cast. **Black and white lab scans keep their tint**, as the real scans do
  (the user's call); they are not forced to neutral grey.

  Each look is shared by every film of its type. Black and white frames
  train only the black and white look.

## Fitting and validation

- **Films:** only films with a Negs profile can be simulated. That leaves
  12 of the 51:
  - Portra 160, 400 and 800, Ektar 100, Gold 200, UltraMax 400, C200 and
    Pro 400H (colour negative)
  - Provia 100F and Ektachrome E100, which is Negs's `kodak_ektachrome_100`
    (slide)
  - Tri-X and Double-X (black and white)

  Velvia 50 has no exact profile (Negs has Velvia 100) and is only a rough
  check. The slide look rests on two films, so it gets the fewest free
  parameters.
- **Training:** for each scanner, those films at 0 and +1 EV.
- **Held out:** −1 and +2 EV for every film, plus two whole colour
  negatives held out entirely (Portra 800 and UltraMax 400), to check the
  look generalises to films it never saw.
- **Target:** on held-out frames, beat the current route, and aim for a
  mean hue error of 6° or less per scanner and film type. Every film and
  scanner is reported.
- **Reference values:** the scans' patches, sampled with the chart
  located automatically per frame. Both charts sit in fixed places, and the
  frames are consistent.
- **Simulation:** each scanned film that Negs has a profile for renders the
  same charts. Their reflectances are the published values of the Digital
  SG and the Passport, under the studio's daylight, with exposure matching
  the frame. Films without a profile are used only for checks that don't
  need a simulation.
- **Report:** a mean hue error and a colour distance (OKLab) per film, per
  scanner and per exposure, before and after. It gets written to a
  committed report.

## The app

- **Output:** a choice of **Lab scan** (the default) or **Paper print**.
  They don't overlap (the user's call):
  - **Lab scan** shows the **Scanner** control (Frontier, the default, or
    Noritsu) and the density and colour keys, and never uses paper.
  - **Paper print** renders exactly as today, with the Paper card and the
    print controls. It has no scanner and no scanner look.

  "Scan film directly" folds into Lab scan.
- **Old edits:** an edit that printed on paper keeps printing on paper. An
  edit that scanned film directly becomes a lab scan on Frontier. Paper
  edits render exactly as before.
- **Engine:** new parameters `scanner.model` (frontier or noritsu) and
  `io.output_route` (lab_scan or paper_print). They are presets-aware, and
  exported in presets as Negs's own keys.

## What's left to the builder

- The exact form of the learned transform: tone curve parametrisation,
  matrix space, whether a correction table is needed. Choose by held-out
  error.
- The chart reference values: the Digital SG and Passport published
  L\*a\*b\* (D50), converted for the simulation.
- Where in the pipeline the scanner stage sits. It replaces the
  print-and-scan stages on the lab scan route; the GPU display path follows
  as for Post.
- Migration details for old presets.
- Licensing: the scans are Color Precision's. Fitted numbers derived from
  them ship in Negs; the images themselves stay out of the repository.
