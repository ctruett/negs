//! A developed film's density as a lab scanner's Status M sensor reads it.

use std::path::Path;

use rayon::prelude::*;
use serde::Deserialize;
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::from_f64;
use spektrafilm_math::tetra3d::tetrahedral_interp;

use crate::params::{OutputRoute, RuntimeParams};
use crate::profile::Profile;
use crate::stages::scanning::{build_lut_grid, scanner_lut_bounds};

const N_WL: usize = 81;
const WL_MIN: f64 = 380.0;
const WL_STEP: f64 = 5.0;

#[derive(Deserialize)]
struct Row {
    start_nm: f64,
    step_nm: f64,
    log_product: Vec<f64>,
    slope_below: f64,
    slope_above: f64,
}

#[derive(Deserialize)]
struct StatusM {
    blue: Row,
    green: Row,
    red: Row,
}

impl Row {
    /// log10 product at `nm`: linear in log inside the table, the stated
    /// slope outside it.
    fn log_at(&self, nm: f64) -> f64 {
        let last = self.log_product.len() - 1;
        let end = self.start_nm + self.step_nm * last as f64;
        if nm <= self.start_nm {
            self.log_product[0] + self.slope_below * (nm - self.start_nm)
        } else if nm >= end {
            self.log_product[last] + self.slope_above * (nm - end)
        } else {
            let t = (nm - self.start_nm) / self.step_nm;
            let i = (t.floor() as usize).min(last - 1);
            let f = t - i as f64;
            self.log_product[i] * (1.0 - f) + self.log_product[i + 1] * f
        }
    }

    fn weights(&self) -> [f64; N_WL] {
        let mut w = [0.0; N_WL];
        for (i, v) in w.iter_mut().enumerate() {
            *v = 10f64.powf(self.log_at(WL_MIN + WL_STEP * i as f64));
        }
        let sum: f64 = w.iter().sum();
        w.iter_mut().for_each(|v| *v /= sum);
        w
    }
}

/// The scanner's R, G, B spectral weights on 380-780 nm in 5 nm steps,
/// each row summing to 1.
pub struct Sensitivity {
    pub weights: [[f64; N_WL]; 3],
}

impl Sensitivity {
    /// Load ISO 5-3 Status M from `<data_dir>/scanners/status_m.json`.
    pub fn load(data_dir: &Path) -> Result<Sensitivity, String> {
        let path = data_dir.join("scanners").join("status_m.json");
        let text = std::fs::read_to_string(&path)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        let t: StatusM = serde_json::from_str(&text)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        Ok(Sensitivity { weights: [t.red.weights(), t.green.weights(), t.blue.weights()] })
    }
}

/// Scanner density above the film base as a function of dye density (cmy),
/// tabulated on a LUT grid.
pub struct DensityLut {
    table: Vec<f64>,
    steps: usize,
    data_min: [f64; 3],
    data_max: [f64; 3],
    inv: [f64; 3],
}

/// `-log10 Σ 10^(-D(λ))·w_c(λ)` per channel for `cmy` dye on `base`.
fn scanner_density(
    cmy: [f64; 3],
    channel_density: &[[f64; 3]],
    base: &[f64],
    sens: &Sensitivity,
) -> [f64; 3] {
    let mut signal = [0.0f64; 3];
    for i in 0..N_WL {
        let cd = &channel_density[i];
        let d = cmy[0] * cd[0] + cmy[1] * cd[1] + cmy[2] * cd[2] + base[i];
        // NaN (no data at this wavelength) passes no light, as in the film scan.
        let t = 10f64.powf(-d);
        let t = if t.is_nan() { 0.0 } else { t };
        for (s, w) in signal.iter_mut().zip(&sens.weights) {
            *s += t * w[i];
        }
    }
    signal.map(|s| -s.log10())
}

impl DensityLut {
    pub fn new(film: &Profile, params: &RuntimeParams, sens: &Sensitivity) -> DensityLut {
        let channel_density: Vec<[f64; 3]> = film
            .data
            .channel_density
            .iter()
            .map(|r| [0, 1, 2].map(|c| r.get(c).copied().unwrap_or(0.0)))
            .collect();
        let base = crate::bases::film_base_density(film, params);
        let bare = scanner_density([0.0; 3], &channel_density, &base, sens);

        // The film is the scanned subject, whatever the route says.
        let mut film_params = params.clone();
        film_params.io.output_route = OutputRoute::LabScan;
        let (data_min, data_max) = scanner_lut_bounds(film, &film_params);
        let steps = params.settings.lut_resolution as usize;
        let grid = build_lut_grid(steps, data_min, data_max);
        let mut table = vec![0.0f64; grid.data.len()];
        table
            .par_chunks_exact_mut(3)
            .zip(grid.data.par_chunks_exact(3))
            .for_each(|(out, g)| {
                let d = scanner_density(
                    [g[0] as f64, g[1] as f64, g[2] as f64],
                    &channel_density,
                    &base,
                    sens,
                );
                for c in 0..3 {
                    out[c] = d[c] - bare[c];
                }
            });
        let scale = (steps - 1) as f64;
        let inv = [0, 1, 2].map(|c| scale / (data_max[c] - data_min[c]));
        let mut lut = DensityLut { table, steps, data_min, data_max, inv };
        // Interpolation error means the grid can miss zero by a hair; pin the
        // bare base to exactly zero net density.
        let z = lut.net([0.0; 3]);
        lut.table.chunks_exact_mut(3).for_each(|n| (0..3).for_each(|c| n[c] -= z[c]));
        lut
    }

    /// The table (`steps`³ × 3, cyan slowest), its origin and the nodes per
    /// unit of density, for a GPU pass that interpolates as [`Self::net`] does.
    pub fn grid(&self) -> (&[f64], usize, [f64; 3], [f64; 3]) {
        (&self.table, self.steps, self.data_min, self.inv)
    }

    /// The CMY density range the grid covers; outside it, values clamp.
    pub fn bounds(&self) -> ([f64; 3], [f64; 3]) {
        (self.data_min, self.data_max)
    }

    /// The RGB scanner density above the film base.
    pub fn net(&self, cmy: [f64; 3]) -> [f64; 3] {
        let q = [0, 1, 2].map(|c| (cmy[c] - self.data_min[c]) * self.inv[c]);
        tetrahedral_interp(&self.table, self.steps, q[0], q[1], q[2])
    }

    /// `net` for every pixel of a cmy density image.
    pub fn apply(&self, img: &ImageBuf) -> ImageBuf {
        let mut out = img.clone();
        out.data.par_chunks_exact_mut(3).for_each(|px| {
            let d = self.net([px[0] as f64, px[1] as f64, px[2] as f64]);
            for c in 0..3 {
                px[c] = from_f64(d[c]);
            }
        });
        out
    }
}
