//! Lab-scanner looks: reading a developed film the way a Frontier or Noritsu
//! sensor does, through ISO 5-3 Status M, balancing each frame as the
//! scanner's auto correction does, and rendering it through the scanner's
//! look for the film's type.
pub mod balance;
pub mod density;
pub mod look;

use std::path::Path;

use rayon::prelude::*;
use spektrafilm_gpu::ComputeBackend;
use spektrafilm_math::colorspace::{icc_rgb_to_rgb, RgbColourspace};
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::from_f64;

use crate::params::{RuntimeParams, ScannerModel};
use crate::profile::Profile;
use balance::{Balance, FilmType};
use density::{DensityLut, Sensitivity};
use look::Look;

/// One click of an operator's density or colour key, in log10 density: about
/// 1/12 stop.
pub const KEY_STEP_LOG10: f64 = 0.025;

/// One click of the operator's contrast key: the balanced signal's slope
/// about the metered grey grows 4% (±20 clicks: about 0.46× to 2.2×).
pub const CONTRAST_STEP: f64 = 1.04;

/// The contrast key's gain on the balanced signal.
pub fn contrast_gain(params: &RuntimeParams) -> f64 {
    CONTRAST_STEP.powf(f64::from(params.scanner.contrast_key))
}

/// The scanner's data for one film: its sensor, and both scanners' looks for
/// the film's type. Loaded once per pipeline.
pub struct Scanner {
    pub sensitivity: Sensitivity,
    frontier: Look,
    noritsu: Look,
}

impl Scanner {
    /// `look_override`, a look file, stands in for both scanners' own.
    pub fn load(data_dir: &Path, film_type: FilmType, look_override: Option<&Path>) -> Result<Scanner, String> {
        let look = |model| match look_override {
            Some(path) => Look::load_file(path, film_type),
            None => Look::load(data_dir, model, film_type),
        };
        Ok(Scanner {
            sensitivity: Sensitivity::load(data_dir)?,
            frontier: look(ScannerModel::Frontier)?,
            noritsu: look(ScannerModel::Noritsu)?,
        })
    }

    pub fn look(&self, model: ScannerModel) -> &Look {
        match model {
            ScannerModel::Frontier => &self.frontier,
            ScannerModel::Noritsu => &self.noritsu,
        }
    }
}

/// The operator's keys in the signed log signal: a positive density key
/// darkens every channel, and a positive cyan, magenta or yellow key adds
/// that colour by taking light from red, green or blue.
pub fn key_offsets(params: &RuntimeParams) -> [f64; 3] {
    let s = &params.scanner;
    let d = f64::from(s.density_key);
    [s.cyan_key, s.magenta_key, s.yellow_key].map(|k| -(d + f64::from(k)) * KEY_STEP_LOG10)
}

/// Scan `filmed`, the developed film's dye densities, on the lab scanner:
/// net Status M density, signed so it rises with the scene's light, minus
/// the frame's `balance`, plus the operator's keys, through the look, then
/// `10^x` as linear Rec. 2020. Converted to the output space unclipped, then
/// gamut-compressed, sharpened and encoded as the film scan finishes.
pub fn process(
    filmed: ImageBuf,
    film: &Profile,
    params: &RuntimeParams,
    balance: &Balance,
    scanner: &Scanner,
    backend: &dyn ComputeBackend,
    gamut: &crate::gamut_compression::OutputGamutCompress,
) -> ImageBuf {
    let sign = FilmType::of(film).sign();
    let look = scanner.look(params.scanner.model);
    let lut = DensityLut::new(film, params, &scanner.sensitivity);
    let keys = key_offsets(params);
    let gain = contrast_gain(params);
    // Linear Rec. 2020 to the output space, as `stages::scanning::convert_output`
    // converts (ICC, Bradford between whites), but unclipped, so the gamut
    // compression below still sees the colours outside the output space.
    let rec2020 = RgbColourspace::output("ITU-R BT.2020");
    let output = RgbColourspace::output(&params.io.output_color_space);
    let to_output = (output != rec2020).then(|| icc_rgb_to_rgb(rec2020, output));
    let compress = gamut.is_active();
    let mut rgb = filmed;
    rgb.data.par_chunks_exact_mut(3).for_each(|px| {
        let net = lut.net([px[0] as f64, px[1] as f64, px[2] as f64]);
        // Balanced about the metered grey, steepened by the contrast key, keyed.
        let x = [0, 1, 2].map(|c| (sign * net[c] - balance.offset[c]) * gain + keys[c]);
        let lin = look.apply(x).map(|v| 10f64.powf(v));
        let mut out = match &to_output {
            Some(m) => [0, 1, 2].map(|r| m[r][0] * lin[0] + m[r][1] * lin[1] + m[r][2] * lin[2]),
            None => lin,
        };
        if compress {
            out = gamut.compress(out);
        }
        for c in 0..3 {
            px[c] = from_f64(out[c]);
        }
    });
    if params.scanner.lens_blur > 0.0 {
        rgb = backend.gaussian_blur_owned(rgb, params.scanner.lens_blur);
    }
    let [usm_sigma, usm_amount] = params.scanner.unsharp_mask;
    if usm_sigma > 0.0 && usm_amount > 0.0 {
        rgb = spektrafilm_model::diffusion::apply_unsharp_mask(rgb, usm_sigma, usm_amount, backend);
    }
    if params.io.output_cctf_encoding {
        crate::stages::scanning::encode_output(&mut rgb, &params.io.output_color_space);
    }
    rgb
}
