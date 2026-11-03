# Draft question for upstream — not sent

A message to Andrea Volpato about the spectral adaptation parameters. **Nothing
here has been posted or sent.** The likely venue is the
[tech discussion thread](https://discuss.pixls.us/t/spektrafilm-tech-discussions/57512)
or the [digitisation campaign thread](https://discuss.pixls.us/t/2026-q2-data-sheets-digitization-campaign/58032);
a GitHub issue would work too but the threads are where this kind of detail has
been discussed before.

The research record's section 9 suggested asking for four things: the current
creator, the B&W exposure-normalisation and fitting recipes, the raw digitised
points, and whether source PDFs would be useful to contribute. The draft below
narrows that to the one blocker actually hit, leads with work already done so
the ask is cheap to answer, and offers something back.

Edit freely — particularly the tone, which is mine and not yours.

---

**Subject: `hanatos2025_adaptation_*` — how are the window and surface fitted?**

Hi Andrea,

I've been building film profiles from manufacturer datasheets, working from
the spektrafilm format, and I've hit one thing I can't reconstruct. Before the
question, some context so it's clear what I've already tried.

I wrote an extractor that reads the plotted curves straight out of vector
datasheet PDFs — it finds the plot frames, the tick marks and the axis labels,
and derives the axis transform from the page rather than having anyone measure
it. On Kodak E-4050 it reproduces your own digitised Portra 400 points to an
RMS of 0.002 density on the characteristic curves and 0.002–0.004 on the dye
density. Across a library of 251 sheets it calibrates at least one plot on 155
of them.

One thing fell out of that which you may want regardless of the rest: on the
spectral sensitivity curves, my extraction and your digitised points differ by
a consistent **4.1 nm** — +3.9, +4.1 and +4.3 nm on the three channels. I
checked my own axis independently of your data: the wavelength gridlines on
that panel are evenly spaced to 0.1%, and mapping from only the two end
gridlines predicts every intermediate label to within 0.08 nm. The density
panel on the same page needs no shift at all, and both the 2016 and the earlier
edition of E-4050 give the same answer. So I think the shipped Portra 400
sensitivities carry a small wavelength offset from the digitising step. It's
minor, but it would propagate to anything derived from them.

**The question.** I can't work out how
`hanatos2025_adaptation_window_params` (the four erf bandpass numbers) and
`hanatos2025_adaptation_surface_params` (the 3×15 polynomial) are produced. I
can see how they're *consumed*, but consumption gives the parameterisation and
not the objective, and nothing in the public history ever writes them. I
checked whether they're a function of each stock's own spectral sensitivity —
across the 20 shipped profiles that carry them, they clearly aren't; Ektachrome
100's UV edge sits at 456 nm where Provia's is at 397, with near-identical
sensitivity extents.

They matter more than I first assumed. I built a control: your own digitised
Ektachrome 100 source points, put through my preparation. It renders at mean
chroma 86.1 where the shipped profile from those same points renders at 71.1.
Grafting that stock's adaptation parameters onto my control takes it to 74.6 —
about three quarters of the gap, in one step. My first reading had called them
a minor quality term because I measured the difference as mean RGB (5.4/255);
that statistic hides them, because what they act on is saturation.

So, whichever is easiest for you:

1. What is the fit's objective? If it's matching film exposures between
   reconstructed and measured spectra over a reflectance dataset, I can
   implement that — I just don't want to guess at the target.
2. Are the reflectance datasets the fit uses available anywhere? The profile
   metadata names Otsu, Munsell, the NIST skin set, forest and Japan colours,
   but only the reconstruction LUTs ship, not the measurements.
3. Is the fitting code something you'd be willing to share, even unpolished? I
   saw your June note that a public suite needed documentation and maintenance
   before release; I'm happy to work with something rough.

A related smaller question: do the shipped profiles go through
`correct.py`'s gray-ramp correction before release? I ask because a grey ramp
through my prepared curves comes out 38% off neutral at the ends of five
stops, where shipped Ektachrome 100 is 2.0%, Kodachrome 64 6.5% and Velvia 100
13.3%. That pattern reads like the shipped profiles are corrected and raw
datasheet curves aren't, which would also mean a rebuilt profile can never be
expected to match a shipped one array-for-array. If that's right it would be
worth stating somewhere, because it's an easy thing to assume otherwise.

**What I can offer back.** The extractor, if it's useful — it removes the
manual axis measurement, and the datasheet library is 251 sheets across Agfa,
Fuji, Ilford, Kodak, Konica, Maco, Polaroid and Rollei. I've prepared four
stocks with it so far (Agfapan APX 25/100/400 and Ektachrome 64 EPR), each with
a source record giving the document hash, the derived axis transform, and the
assumptions made where the sheet is silent. Happy to contribute any of it in
whatever form suits you, or to leave it be.

Thanks for the project, and for making the format legible enough to build on.

---

## Notes before sending

- The 4 nm finding is a claim about his work. It's well evidenced, but it may
  land better as its own message than bundled with a request.
- Ask three questions at most; the list above is already at the limit.
- If posting publicly, the thread convention is to link the specific commit or
  file being discussed rather than describe it.
