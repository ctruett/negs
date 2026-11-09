"""The Digital SG is found and sampled on the studio frames.

Needs the studio scans (see README.md); skipped without them.
"""
import numpy as np
import pytest

import charts

FRAMES = [
    # (film, scanner, exposure): one per frame size, colour and B&W
    ("Kodak Portra 400", "Frontier", "+0EV"),         # 3244 x 2010
    ("Fujifilm 200", "Noritsu", "+0EV"),              # 2778 x 1894
    ("Fujifilm Neopan Acros 100 II", "Frontier", "+1EV"),  # 2846 x 1940, B&W
    ("Kodak Ektachrome E100", "Frontier", "+0EV"),    # slide, 3244 x 2014
    # Frames where the last refinement once slid the grid off the chart
    ("Kodak UltraMax 400", "Frontier", "+0EV"),
    ("Kodak Portra 160", "Noritsu", "+0EV"),
    ("Kodak Portra 400", "Noritsu", "-1EV"),
]

pytestmark = pytest.mark.skipif(not charts.STUDIO.exists(), reason="studio scans not present")


def frame(film, scanner, exposure):
    row = next(r for r in charts.index() if (r.film, r.scanner, r.exposure) == (film, scanner, exposure))
    return charts.load(row)


def test_frame_without_the_sg_is_missing():
    # This frame's left half didn't take the light: the SG isn't on it.
    assert charts.locate(frame("Kodak Ektachrome E100", "Noritsu", "-1EV")) is None


@pytest.mark.parametrize("film,scanner,exposure", FRAMES)
def test_locate_finds_the_sg(film, scanner, exposure):
    img = frame(film, scanner, exposure)
    centres = charts.locate(img)
    assert centres is not None
    assert centres.shape == (140, 2)
    assert charts.score(img, centres) > 0.93
    rgb = charts.sample(img, centres)
    y = rgb @ [0.2126, 0.7152, 0.0722]
    names = charts.SG_NAMES
    white, grey, black = (y[names.index(n)] for n in ("A1", "B1", "C1"))
    assert white > grey > black, (white, grey, black)
    # On the patch grid every sample is flat: little spread inside a patch,
    # much between patches.
    spread = charts.sample_spread(img, centres)
    assert np.median(spread) < 0.1 * np.std(y), (np.median(spread), np.std(y))


def test_sg_reference_is_published_d50():
    lab = charts.sg_lab()
    assert lab.shape == (140, 3)
    a1 = lab[charts.SG_NAMES.index("A1")]
    assert a1[0] > 95 and abs(a1[1]) < 2 and abs(a1[2]) < 3


def test_film_map_holds_the_specs_films():
    assert len(charts.FILMS) == 12
    assert charts.FILMS["Kodak TRI-X 400"] == "kodak_trix400_d76_8min"
    assert {charts.film_type(f) for f in charts.FILMS} == {"colour_negative", "slide", "bw"}
