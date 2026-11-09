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
/// about the metered grey grows 10% (the app's ±10 clicks: about 0.39× to
/// 2.6×). At 4% a click made a change of about 1/255, too little to see.
pub const CONTRAST_STEP: f64 = 1.10;

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

/// The lab scan of one pixel's dye densities, before gamut compression:
/// net Status M density, signed so it rises with the scene's light, minus
/// the frame's balance, steepened by the contrast key, plus the operator's
/// keys, through the look, then `10^x` as linear Rec. 2020, converted to the
/// output space unclipped. The CPU scan and the GPU's LUT both use it.
pub struct ScanPixel<'a> {
    lut: DensityLut,
    look: &'a Look,
    sign: f64,
    offset: [f64; 3],
    gain: f64,
    keys: [f64; 3],
    to_output: Option<[[f64; 3]; 3]>,
}

impl<'a> ScanPixel<'a> {
    pub fn new(film: &Profile, params: &RuntimeParams, balance: &Balance, scanner: &'a Scanner) -> Self {
        // Linear Rec. 2020 to the output space, as `stages::scanning::convert_output`
        // converts (ICC, Bradford between whites), but unclipped, so the gamut
        // compression after still sees the colours outside the output space.
        let rec2020 = RgbColourspace::output("ITU-R BT.2020");
        let output = RgbColourspace::output(&params.io.output_color_space);
        ScanPixel {
            lut: DensityLut::new(film, params, &scanner.sensitivity),
            look: scanner.look(params.scanner.model),
            sign: FilmType::of(film).sign(),
            offset: balance.offset,
            gain: contrast_gain(params),
            keys: key_offsets(params),
            to_output: (output != rec2020).then(|| icc_rgb_to_rgb(rec2020, output)),
        }
    }

    pub fn scan(&self, cmy: [f64; 3]) -> [f64; 3] {
        let lin = self.log_scan(cmy).map(|v| 10f64.powf(v));
        let m = self.to_output();
        [0, 1, 2].map(|r| m[r][0] * lin[0] + m[r][1] * lin[1] + m[r][2] * lin[2])
    }

    /// The look's output, log10 linear Rec. 2020: smooth in the density, so
    /// it's what the GPU's LUT holds.
    pub fn log_scan(&self, cmy: [f64; 3]) -> [f64; 3] {
        let net = self.lut.net(cmy);
        let x = [0, 1, 2].map(|c| (self.sign * net[c] - self.offset[c]) * self.gain + self.keys[c]);
        self.look.apply(x)
    }

    /// Linear Rec. 2020 to the output space.
    pub fn to_output(&self) -> [[f64; 3]; 3] {
        self.to_output.unwrap_or([[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]])
    }

    /// What the GPU's lab pass needs to compute [`Self::scan`] itself.
    pub fn gpu(&self) -> GpuScan {
        let (net, size, lo, inv) = self.lut.grid();
        let (knots, values, tangents, matrix, cast, look_gain) = self.look.parts();
        let mut curve: Vec<f32> = knots.iter().map(|&v| v as f32).collect();
        curve.extend(values.iter().flatten().map(|&v| v as f32));
        curve.extend(tangents.iter().flatten().map(|&v| v as f32));
        // x = ((sign·net − offset)·gain + keys)·look_gain = net·a + b
        let a = [0, 1, 2].map(|_| self.sign * self.gain * look_gain);
        let b = [0, 1, 2].map(|c| (self.keys[c] - self.offset[c] * self.gain) * look_gain);
        let f = |v: [f64; 3]| v.map(|x| x as f32);
        GpuScan {
            net: net.iter().map(|&v| v as f32).collect(),
            size: size as u32,
            lo: f(lo),
            inv: f(inv),
            a: f(a),
            b: f(b),
            curve,
            n_knots: knots.len() as u32,
            matrix: matrix.map(f),
            cast: f(cast),
            to_output: self.to_output().map(f),
        }
    }
}

/// [`ScanPixel`] for the GPU; see `spektrafilm_gpu::LabLutGpu`.
pub struct GpuScan {
    pub net: Vec<f32>,
    pub size: u32,
    pub lo: [f32; 3],
    pub inv: [f32; 3],
    pub a: [f32; 3],
    pub b: [f32; 3],
    pub curve: Vec<f32>,
    pub n_knots: u32,
    pub matrix: [[f32; 3]; 3],
    pub cast: [f32; 3],
    pub to_output: [[f32; 3]; 3],
}

impl GpuScan {
    pub fn params(&self) -> spektrafilm_gpu::LabLutGpu<'_> {
        spektrafilm_gpu::LabLutGpu {
            size: self.size,
            lo: self.lo,
            inv: self.inv,
            net: &self.net,
            a: self.a,
            b: self.b,
            curve: &self.curve,
            n_knots: self.n_knots,
            matrix: self.matrix,
            cast: self.cast,
            to_output: self.to_output,
        }
    }
}

/// Scan `filmed`, the developed film's dye densities, on the lab scanner
/// ([`ScanPixel`]), then gamut-compress, sharpen and encode as the film scan
/// finishes.
pub fn process(
    filmed: ImageBuf,
    film: &Profile,
    params: &RuntimeParams,
    balance: &Balance,
    scanner: &Scanner,
    backend: &dyn ComputeBackend,
    gamut: &crate::gamut_compression::OutputGamutCompress,
) -> ImageBuf {
    let pixel = ScanPixel::new(film, params, balance, scanner);
    let compress = gamut.is_active();
    let mut rgb = filmed;
    rgb.data.par_chunks_exact_mut(3).for_each(|px| {
        let mut out = pixel.scan([px[0] as f64, px[1] as f64, px[2] as f64]);
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
