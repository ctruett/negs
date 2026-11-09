"""fit.py's look is the engine's: a bent look renders, through the CLI, as
the Python port predicts from the frame's signal."""
import tempfile
from pathlib import Path

import numpy as np
import pytest

import fit
import render

pytestmark = pytest.mark.skipif(not render.CLI.exists(), reason="build the CLI first")


@pytest.mark.parametrize("film_type,film", [("colour_negative", "kodak_portra_400"), ("bw", "kodak_doublex")])
def test_port_matches_the_engine(film_type, film):
    rng = np.random.default_rng(1)
    look = fit.look_from(rng.normal(0, 0.3, fit.n_params(film_type)), film_type)
    x = render.signal(film, "Frontier", 0.0)
    predicted = fit.shoulder(10 ** look.apply(x))
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "look.toml"
        path.write_text("".join(f"[{t}]\n" + look.toml("") + "\n" for t in ("colour_negative", "slide", "bw")))
        rendered = render.render(film, "Frontier", 0.0, look=path, gamut=False)
    np.testing.assert_allclose(rendered, np.clip(predicted, 0, 1), rtol=2e-3, atol=2e-4)


def test_rows_sum_to_one_and_grey_is_pinned():
    for t in ("colour_negative", "slide", "bw"):
        look = fit.look_from(np.random.default_rng(2).normal(0, 0.5, fit.n_params(t)), t)
        np.testing.assert_allclose(look.matrix.sum(1), 1)
        assert np.all(np.diff(look.curve, axis=1) > 0)
        np.testing.assert_allclose(look.apply(np.zeros((1, 3)))[0] - look.cast, render.REF)
