//! A scanner's colour rendering for one film type: per-channel tone curves on
//! the balanced log signal, then a 3x3 matrix in log space, then (B&W only)
//! a tint. Read from `<data>/scanners/<model>.toml`.

use std::path::Path;

use serde::Deserialize;

use super::balance::FilmType;
use crate::params::ScannerModel;

#[derive(Deserialize)]
struct Table {
    curve_knots: Vec<f64>,
    curve: [Vec<f64>; 3],
    matrix: [[f64; 3]; 3],
    default_offset: [f64; 3],
    #[serde(default)]
    cast: [f64; 3],
}

#[derive(Deserialize)]
struct File {
    colour_negative: Table,
    slide: Table,
    bw: Table,
}

/// One scanner's look for one film type.
#[derive(Debug, Clone, PartialEq)]
pub struct Look {
    knots: Vec<f64>,
    curve: [Vec<f64>; 3],
    /// Fritsch–Carlson tangents at each knot, per channel.
    tangents: [Vec<f64>; 3],
    matrix: [[f64; 3]; 3],
    /// The type's balance for a frame too thin to meter.
    pub default_offset: [f64; 3],
    cast: [f64; 3],
}

/// Rows of the look's matrix sum to 1 within this, so it keeps greys.
const ROW_SUM_TOLERANCE: f64 = 1e-6;

impl Look {
    /// The `film_type` table of `model`'s look file.
    pub fn load(data_dir: &Path, model: ScannerModel, film_type: FilmType) -> Result<Look, String> {
        let path = data_dir.join("scanners").join(format!("{}.toml", model.name()));
        let text = std::fs::read_to_string(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        Self::parse(&text, film_type).map_err(|e| format!("{}: {e}", path.display()))
    }

    fn parse(text: &str, film_type: FilmType) -> Result<Look, String> {
        let file: File = toml::from_str(text).map_err(|e| e.to_string())?;
        let table = match film_type {
            FilmType::ColourNegative => file.colour_negative,
            FilmType::Slide => file.slide,
            FilmType::BlackAndWhite { .. } => file.bw,
        };
        Self::from_table(table)
    }

    fn from_table(t: Table) -> Result<Look, String> {
        let n = t.curve_knots.len();
        if n < 2 || t.curve_knots.windows(2).any(|w| !(w[1] > w[0])) {
            return Err("curve_knots must be at least two rising values".into());
        }
        for row in &t.curve {
            if row.len() != n {
                return Err("each curve row needs one value per knot".into());
            }
            if row.windows(2).any(|w| !(w[1] >= w[0])) {
                return Err("the curves must not fall".into());
            }
        }
        if t.matrix.iter().any(|r| (r.iter().sum::<f64>() - 1.0).abs() > ROW_SUM_TOLERANCE) {
            return Err("each matrix row must sum to 1".into());
        }
        let all = t.curve.iter().flatten().chain(t.matrix.iter().flatten()).chain(&t.default_offset).chain(&t.cast);
        if !all.chain(&t.curve_knots).all(|v| v.is_finite()) {
            return Err("the look holds a non-finite value".into());
        }
        let tangents = [0, 1, 2].map(|c| fritsch_carlson(&t.curve_knots, &t.curve[c]));
        Ok(Look {
            knots: t.curve_knots,
            curve: t.curve,
            tangents,
            matrix: t.matrix,
            default_offset: t.default_offset,
            cast: t.cast,
        })
    }

    /// The scan's log10 linear light for a balanced, keyed log signal.
    pub fn apply(&self, log_rgb: [f64; 3]) -> [f64; 3] {
        let y = [0, 1, 2].map(|c| self.curve_at(c, log_rgb[c]));
        let m = &self.matrix;
        [0, 1, 2].map(|r| m[r][0] * y[0] + m[r][1] * y[1] + m[r][2] * y[2] + self.cast[r])
    }

    /// Channel `c`'s monotone cubic at `x`; straight on with the end slope
    /// beyond the knots.
    fn curve_at(&self, c: usize, x: f64) -> f64 {
        let (k, v, m) = (&self.knots, &self.curve[c], &self.tangents[c]);
        let last = k.len() - 1;
        if x.is_nan() {
            return x;
        }
        if x <= k[0] {
            return v[0] + m[0] * (x - k[0]);
        }
        if x >= k[last] {
            return v[last] + m[last] * (x - k[last]);
        }
        let i = k.partition_point(|&kx| kx <= x) - 1;
        let h = k[i + 1] - k[i];
        let t = (x - k[i]) / h;
        let (t2, t3) = (t * t, t * t * t);
        (2.0 * t3 - 3.0 * t2 + 1.0) * v[i]
            + (t3 - 2.0 * t2 + t) * h * m[i]
            + (-2.0 * t3 + 3.0 * t2) * v[i + 1]
            + (t3 - t2) * h * m[i + 1]
    }
}

/// Fritsch–Carlson tangents for monotone data `y` on knots `x`.
fn fritsch_carlson(x: &[f64], y: &[f64]) -> Vec<f64> {
    let n = x.len();
    let d: Vec<f64> = (0..n - 1).map(|i| (y[i + 1] - y[i]) / (x[i + 1] - x[i])).collect();
    let mut m = vec![0.0; n];
    m[0] = d[0];
    m[n - 1] = d[n - 2];
    for i in 1..n - 1 {
        m[i] = if d[i - 1] * d[i] <= 0.0 { 0.0 } else { (d[i - 1] + d[i]) / 2.0 };
    }
    for i in 0..n - 1 {
        if d[i] == 0.0 {
            m[i] = 0.0;
            m[i + 1] = 0.0;
            continue;
        }
        let (a, b) = (m[i] / d[i], m[i + 1] / d[i]);
        let s = a * a + b * b;
        if s > 9.0 {
            let tau = 3.0 / s.sqrt();
            m[i] = tau * a * d[i];
            m[i + 1] = tau * b * d[i];
        }
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../data")
    }

    const TYPES: [FilmType; 4] = [
        FilmType::ColourNegative,
        FilmType::Slide,
        FilmType::BlackAndWhite { positive: false },
        FilmType::BlackAndWhite { positive: true },
    ];

    #[test]
    fn every_scanner_and_type_loads_and_scans_the_reference_grey_at_18_percent() {
        for model in [ScannerModel::Frontier, ScannerModel::Noritsu] {
            for t in TYPES {
                let look = Look::load(&data(), model, t).unwrap();
                for v in look.apply([0.0; 3]) {
                    assert!((v - 0.18f64.log10()).abs() < 1e-12, "{model:?} {t:?}: {v}");
                }
            }
        }
    }

    #[test]
    fn the_curve_rises_and_continues_past_its_knots() {
        let look = Look::load(&data(), ScannerModel::Frontier, FilmType::ColourNegative).unwrap();
        let ys: Vec<f64> = (-40..=40).map(|i| look.apply([i as f64 * 0.1; 3])[1]).collect();
        assert!(ys.windows(2).all(|w| w[1] > w[0]));
        assert!(look.apply([f64::NAN, 0.0, 0.0])[0].is_nan(), "a NaN passes through, without a panic");
    }

    #[test]
    fn a_monotone_cubic_stays_within_its_data() {
        let t = Table {
            curve_knots: vec![0.0, 1.0, 2.0, 3.0],
            curve: [vec![0.0, 0.0, 1.0, 1.0], vec![0.0, 1.0, 2.0, 3.0], vec![0.0, 0.9, 1.0, 3.0]],
            matrix: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]],
            default_offset: [0.0; 3],
            cast: [0.0; 3],
        };
        let look = Look::from_table(t).unwrap();
        let mut prev = [f64::MIN; 3];
        for i in 0..=300 {
            let y = look.apply([i as f64 / 100.0; 3]);
            for c in 0..3 {
                assert!(y[c] >= prev[c] - 1e-12, "channel {c} falls at {i}");
            }
            assert!((0.0..=1.0).contains(&y[0]), "{y:?}");
            prev = y;
        }
    }

    #[test]
    fn a_matrix_that_tints_greys_is_refused() {
        let text = std::fs::read_to_string(data().join("scanners/frontier.toml")).unwrap();
        let bad = text.replacen("matrix = [[1.0, 0.0, 0.0]", "matrix = [[1.1, 0.0, 0.0]", 1);
        assert_ne!(bad, text);
        assert!(Look::parse(&bad, FilmType::ColourNegative).unwrap_err().contains("sum to 1"));
    }
}
