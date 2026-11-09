//! The zone system on the light the film receives. A reading is an area of
//! the photograph; [`readout`] finds the change of Prep's exposure, in stops,
//! that prints it at each zone, running its colours through the real film and
//! paper one pixel at a time, as the LUT export does. Prep's exposure is a
//! plain gain before the film that the print doesn't make up for, so the
//! film's toe and shoulder and the paper's render the placed tone like any
//! other.
//!
//! [`ZoneCurve`] is the curve on the scene's exposure that earlier versions
//! bent with their zone pins. Prep still applies it, so their edits develop
//! the same from the command line, but nothing makes a new one.
use std::path::Path;

use rayon::prelude::*;
use serde::{Deserialize, Serialize};
use spektrafilm_gpu::cpu_backend::CpuBackend;
use spektrafilm_math::{
    colorspace::{Cctf, RgbColourspace},
    image::ImageBuf,
    precision::{from_f64, to_f32, to_f64},
};

use crate::{
    lab_scan::balance::Balance,
    lut_export::per_pixel_params,
    params::RuntimeParams,
    pipeline::Pipeline,
    post::{printed_lstar, PostProcess},
    prep::{PrepParams, EXPOSURE_RANGE},
    profile,
};

/// Middle grey, the curve's 0 stops.
const GREY: f64 = 0.18;
/// At most one knot per zone, 0 to VII.
pub const MAX_KNOTS: usize = 8;
/// How much the curve may compress or stretch the scene, in stops out per
/// stop in: the same limits as the soft pins on the tone curve
/// ([`crate::post::SOFT_SLOPE`]). Past them a gradient shows steps, or tones merge.
pub const SLOPE: (f64, f64) = crate::post::SOFT_SLOPE;
/// The furthest a pin may move its tone, in stops either way.
pub const MAX_SHIFT: f64 = 8.0;

/// A rising curve on the scene's log exposure, as knots of (stops from middle
/// grey, the change in stops there), applied to each pixel by its luminance,
/// keeping its colour. Between knots it is a monotone cubic on the exposure
/// out (Fritsch and Butland's tangents); beyond them the change holds, so one
/// knot is a plain exposure change. Empty, it leaves every bit alone.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(into = "Vec<[f32; 2]>", try_from = "Vec<[f32; 2]>")]
pub struct ZoneCurve {
    knots: [[f32; 2]; MAX_KNOTS],
    count: u8,
}

impl From<ZoneCurve> for Vec<[f32; 2]> {
    fn from(curve: ZoneCurve) -> Self {
        curve.knots[..curve.count as usize].to_vec()
    }
}

impl TryFrom<Vec<[f32; 2]>> for ZoneCurve {
    type Error = String;
    fn try_from(knots: Vec<[f32; 2]>) -> Result<Self, String> {
        Self::from_knots(&knots.iter().map(|k| (f64::from(k[0]), f64::from(k[1]))).collect::<Vec<_>>())
    }
}

impl ZoneCurve {
    /// Knots as (stops, change), rising in both the stops and the exposure out.
    pub fn from_knots(knots: &[(f64, f64)]) -> Result<Self, String> {
        if knots.len() > MAX_KNOTS {
            return Err(format!("A zone curve has at most {MAX_KNOTS} knots"));
        }
        let mut curve = Self::default();
        for (i, &(x, s)) in knots.iter().enumerate() {
            if !x.is_finite() || !s.is_finite() || x.abs() > 24.0 || s.abs() > MAX_SHIFT + 1e-3 {
                return Err("Invalid zone curve knot".into());
            }
            curve.knots[i] = [x as f32, s as f32];
        }
        curve.count = knots.len() as u8;
        for pair in curve.points().windows(2) {
            let ((x0, y0), (x1, y1)) = (pair[0], pair[1]);
            if x1 - x0 < 1e-3 || y1 <= y0 {
                return Err("A zone curve's knots must rise".into());
            }
        }
        Ok(curve)
    }

    /// The smooth rising curve that comes closest to `shifts`, (stops, change)
    /// pairs in any order, all counting alike; see [`Self::fit_weighted`].
    pub fn fit(shifts: &[(f64, f64)]) -> Self {
        Self::fit_weighted(&shifts.iter().map(|&(x, s)| (x, s, 1.0)).collect::<Vec<_>>())
    }

    /// The smooth rising curve that comes closest to `shifts`, (stops, change,
    /// weight) in any order: knots nearer than a tenth of a stop are one, and
    /// each stretch is kept within [`SLOPE`], moving the changes as little as
    /// that needs, by weighted least squares. Weighted by how far a stop moves a
    /// knot's print, squared, a miss is shared in L\* rather than in stops, so a
    /// tone in the film's shoulder, where a stop moves little, gives way more.
    pub fn fit_weighted(shifts: &[(f64, f64, f64)]) -> Self {
        let mut sorted: Vec<(f64, f64, f64)> = shifts
            .iter()
            .copied()
            .filter(|(x, s, w)| x.is_finite() && s.is_finite() && w.is_finite())
            .map(|(x, s, w)| (x.clamp(-20.0, 20.0), s.clamp(-MAX_SHIFT, MAX_SHIFT), w.max(1e-3)))
            .collect();
        sorted.sort_by(|a, b| a.0.total_cmp(&b.0));
        // Sums of x, x + s and the weight, weighted, and the count.
        let mut merged: Vec<(f64, f64, f64, f64)> = Vec::new();
        for (x, s, w) in sorted {
            match merged.last_mut() {
                Some(last) if x - last.0 / last.3 < 0.1 => *last = (last.0 + x, last.1 + w * (x + s), last.2 + w, last.3 + 1.0),
                _ => merged.push((x, w * (x + s), w, 1.0)),
            }
        }
        merged.truncate(MAX_KNOTS);
        let xs: Vec<f64> = merged.iter().map(|m| m.0 / m.3).collect();
        let weights: Vec<f64> = merged.iter().map(|m| m.2).collect();
        let targets: Vec<f64> = merged.iter().map(|m| m.1 / m.2).collect();
        if xs.is_empty() {
            return Self::default();
        }
        // The nearest point, in the weighted norm, within every stretch's limits:
        // Dykstra's projections onto each stretch's limits in turn.
        let (flat, steep) = SLOPE;
        let mut y = targets.clone();
        let mut increments = vec![[0.0f64; 2]; xs.len().saturating_sub(1)];
        for _ in 0..2000 {
            let mut moved = 0.0f64;
            for i in 0..increments.len() {
                let z = [y[i] + increments[i][0], y[i + 1] + increments[i][1]];
                let d = xs[i + 1] - xs[i];
                let rise = z[1] - z[0];
                let excess = rise - rise.clamp(flat * d, steep * d);
                let (wa, wb) = (weights[i], weights[i + 1]);
                let projected = [z[0] + excess * wb / (wa + wb), z[1] - excess * wa / (wa + wb)];
                increments[i] = [z[0] - projected[0], z[1] - projected[1]];
                moved = moved.max((projected[0] - y[i]).abs()).max((projected[1] - y[i + 1]).abs());
                y[i] = projected[0];
                y[i + 1] = projected[1];
            }
            if moved < 1e-10 {
                break;
            }
        }
        let fitted: Vec<(f64, f64)> =
            xs.iter().zip(&y).map(|(&x, &y)| (x, (y - x).clamp(-MAX_SHIFT, MAX_SHIFT))).collect();
        // Clamping the change can only break the rise at the extremes; drop
        // what no longer rises rather than fail.
        let mut kept: Vec<(f64, f64)> = Vec::with_capacity(fitted.len());
        for knot in fitted {
            if kept.last().is_none_or(|&(x, s)| knot.0 - x >= 1e-3 && knot.0 + knot.1 > x + s) {
                kept.push(knot);
            }
        }
        Self::from_knots(&kept).unwrap_or_default()
    }

    pub fn is_identity(&self) -> bool {
        self.count == 0
    }

    /// The knots as (stops, change).
    pub fn knots(&self) -> Vec<(f64, f64)> {
        self.knots[..self.count as usize].iter().map(|k| (f64::from(k[0]), f64::from(k[1]))).collect()
    }

    /// The knots as (stops in, stops out).
    fn points(&self) -> Vec<(f64, f64)> {
        self.knots().into_iter().map(|(x, s)| (x, x + s)).collect()
    }

    /// The change in stops for a tone `stops` from middle grey; minus infinity
    /// (black) takes the darkest knot's.
    pub fn shift(&self, stops: f64) -> f64 {
        let points = self.points();
        let Some(&first) = points.first() else { return 0.0 };
        let last = points[points.len() - 1];
        if stops.is_nan() || stops <= first.0 {
            return first.1 - first.0;
        }
        if stops >= last.0 {
            return last.1 - last.0;
        }
        let tangents = Self::tangents(&points);
        let i = points.partition_point(|&(x, _)| x <= stops) - 1;
        let ((x0, y0), (x1, y1)) = (points[i], points[i + 1]);
        let (m0, m1) = (tangents[i], tangents[i + 1]);
        let h = x1 - x0;
        let t = (stops - x0) / h;
        let (t2, t3) = (t * t, t * t * t);
        let y = (2.0 * t3 - 3.0 * t2 + 1.0) * y0 + (t3 - 2.0 * t2 + t) * h * m0
            + (-2.0 * t3 + 3.0 * t2) * y1 + (t3 - t2) * h * m1;
        y.clamp(y0, y1) - stops
    }

    /// Shape-preserving slopes. The ends meet the unchanged slope beyond them
    /// as nearly as a monotone cubic allows.
    fn tangents(points: &[(f64, f64)]) -> Vec<f64> {
        let n = points.len();
        let secants: Vec<f64> = points.windows(2).map(|p| (p[1].1 - p[0].1) / (p[1].0 - p[0].0)).collect();
        let mut tangents = vec![1.0; n];
        if n < 2 {
            return tangents;
        }
        tangents[0] = 1.0f64.min(3.0 * secants[0]);
        tangents[n - 1] = 1.0f64.min(3.0 * secants[n - 2]);
        for i in 1..n - 1 {
            let (h0, h1) = (points[i].0 - points[i - 1].0, points[i + 1].0 - points[i].0);
            let (w0, w1) = (2.0 * h1 + h0, h1 + 2.0 * h0);
            tangents[i] = (w0 + w1) / (w0 / secants[i - 1] + w1 / secants[i]);
        }
        tangents
    }

    /// Bends linear pixels in `input_color_space` by their luminance.
    pub fn apply(&self, image: &mut ImageBuf, input_color_space: &str) -> Result<(), String> {
        if self.is_identity() {
            return Ok(());
        }
        let luma = RgbColourspace::input(input_color_space).rgb_to_xyz[1];
        let finite = image
            .data
            .par_chunks_exact_mut(3)
            .map(|px| {
                let rgb = [to_f64(px[0]), to_f64(px[1]), to_f64(px[2])];
                let y = luma[0] * rgb[0] + luma[1] * rgb[1] + luma[2] * rgb[2];
                let stops = if y > 0.0 { (y / GREY).log2() } else { f64::NEG_INFINITY };
                let gain = self.shift(stops).exp2();
                for c in 0..3 {
                    px[c] = from_f64(rgb[c] * gain);
                }
                px.iter().all(|v| v.is_finite())
            })
            .reduce(|| true, |a, b| a && b);
        if finite { Ok(()) } else { Err("The zone curve produced a non-finite result".into()) }
    }
}

/// A pin: colours from under it as the film is given them, after Prep but
/// before the camera's and auto exposure's scaling (the pipeline applies
/// those), and the L\* their average should print at. Each colour goes through
/// the film on its own, so a textured spot prints as its pixels do, not as
/// their average colour would.
#[derive(Debug, Clone, PartialEq)]
pub struct ZoneSample {
    pub pixels: Vec<[f64; 3]>,
    pub target: f64,
}

/// The most pixels a reading is taken from.
pub const PIN_PIXELS: usize = 49;

/// Colours from a rectangle, its corners (x, y) fractions of the uncropped
/// photograph, read as [`pin_colours`] reads a circle: up to [`PIN_PIXELS`],
/// evenly spread. None outside the photograph.
pub fn area_colours(
    image: &ImageBuf,
    params: &RuntimeParams,
    autoexposure_ev: f64,
    corners: [(f64, f64); 2],
) -> Result<Option<Vec<[f64; 3]>>, String> {
    let mut params = params.clone();
    params.prep.zone_curve = ZoneCurve::default();
    let scale = (autoexposure_ev + f64::from(params.camera.exposure_compensation_ev)).exp2();
    if params.prep.is_identity() {
        let cctf = RgbColourspace::input(&params.io.input_color_space).cctf;
        let decode = params.io.input_cctf_decoding && cctf != Cctf::Linear;
        return Ok(rect_pixels(image, corners, |v| if decode { cctf.decode(v) } else { v }));
    }
    let prepared = crate::stages::filming::prepare_input_from(image, &params, autoexposure_ev)?;
    Ok(rect_pixels(&prepared, corners, |v| v / scale))
}

/// `f` of the pixels in a rectangle, about [`PIN_PIXELS`] of them evenly spread.
fn rect_pixels(image: &ImageBuf, corners: [(f64, f64); 2], f: impl Fn(f64) -> f64) -> Option<Vec<[f64; 3]>> {
    let inside = |v: f64| (0.0..=1.0).contains(&v);
    if image.width == 0 || image.height == 0 || !corners.iter().all(|&(x, y)| inside(x) && inside(y)) {
        return None;
    }
    let to_px = |v: f64, size: u32| ((v * f64::from(size)) as u32).min(size - 1);
    let (xa, xb) = (to_px(corners[0].0, image.width), to_px(corners[1].0, image.width));
    let (ya, yb) = (to_px(corners[0].1, image.height), to_px(corners[1].1, image.height));
    let ((x0, x1), (y0, y1)) = ((xa.min(xb), xa.max(xb)), (ya.min(yb), ya.max(yb)));
    let area = f64::from(x1 - x0 + 1) * f64::from(y1 - y0 + 1);
    let stride = (area / PIN_PIXELS as f64).sqrt().max(1.0);
    let steps = |from: u32, to: u32| {
        let count = ((f64::from(to - from) + 1.0) / stride).ceil().max(1.0) as u32;
        (0..count).map(move |i| (f64::from(from) + (f64::from(i) + 0.5) * stride) as u32).filter(move |&v| v <= to)
    };
    let mut pixels = Vec::new();
    for py in steps(y0, y1) {
        for px in steps(x0, x1) {
            let value = image.get(px, py);
            pixels.push([0, 1, 2].map(|c| f(to_f64(value[c]))));
        }
    }
    Some(pixels)
}

/// The photograph's film and paper one pixel at a time, without the zone
/// curve, through to the printed L\* after Post.
struct Pointwise {
    pipeline: Pipeline,
    post: PostProcess,
}

impl Pointwise {
    /// The parameters for one pixel at a time keep every tone control the
    /// photograph has, which the LUT export leaves neutral. Prep is already in
    /// the colours. Auto exposure applies only with the photograph's own
    /// metering: left to itself it would meter the reading, and expose it as
    /// middle grey. The lab scanner's balance is the photograph's for the
    /// same reason; without it, a grey card's.
    fn new(
        data: &Path,
        film: &str,
        paper: &str,
        params: &RuntimeParams,
        autoexposure_ev: Option<f64>,
        lab_balance: Option<Balance>,
    ) -> Result<Self, String> {
        let scan = params.scans_film();
        let film_profile = profile::load_profile_by_name(data, film).map_err(|e| e.to_string())?;
        let print_profile =
            profile::load_profile_by_name(data, if scan { film } else { paper }).map_err(|e| e.to_string())?;
        let mut p = per_pixel_params(params.clone());
        let metered = params.camera.auto_exposure && autoexposure_ev.is_some();
        p.camera.auto_exposure = metered;
        p.prep = Default::default();
        p.io.input_color_space = params.io.input_color_space.clone();
        p.enlarger.y_filter_shift = params.enlarger.y_filter_shift;
        p.enlarger.m_filter_shift = params.enlarger.m_filter_shift;
        p.enlarger.preflash_exposure = params.enlarger.preflash_exposure;
        p.enlarger.preflash_y_filter_shift = params.enlarger.preflash_y_filter_shift;
        p.enlarger.preflash_m_filter_shift = params.enlarger.preflash_m_filter_shift;
        p.scanner.white_correction = params.scanner.white_correction;
        p.scanner.black_correction = params.scanner.black_correction;
        let (encoded, space) = (p.io.output_cctf_encoding, p.io.output_color_space.clone());
        let mut pipeline = Pipeline::new_with_spectral(film_profile, print_profile, p, data)?;
        let ae = if metered { autoexposure_ev.unwrap_or(0.0) } else { 0.0 };
        if metered {
            pipeline = pipeline.with_autoexposure_ev(ae);
        }
        if pipeline.params.lab_scan() {
            let balance = lab_balance.unwrap_or_else(|| pipeline.grey_card_balance());
            pipeline = pipeline.with_lab_balance(balance);
        }
        Ok(Self {
            pipeline,
            post: PostProcess::new(&params.post, encoded, &space),
        })
    }

    /// Where each colour prints, all in one pass.
    fn printed(&self, colours: &[[f64; 3]]) -> Vec<f64> {
        self.printed_through(colours, &self.post)
    }

    /// Where each group of colours prints on average, all in one pass.
    fn printed_groups(&self, groups: &[Vec<[f64; 3]>]) -> Vec<f64> {
        let flat: Vec<[f64; 3]> = groups.iter().flatten().copied().collect();
        let printed = self.printed(&flat);
        let mut start = 0;
        groups
            .iter()
            .map(|group| {
                let values = &printed[start..start + group.len()];
                start += group.len();
                values.iter().sum::<f64>() / group.len().max(1) as f64
            })
            .collect()
    }

    fn printed_through(&self, colours: &[[f64; 3]], post: &PostProcess) -> Vec<f64> {
        if colours.is_empty() {
            return Vec::new();
        }
        let mut image = ImageBuf::new(colours.len() as u32, 1);
        for (pixel, rgb) in image.pixels_mut().zip(colours) {
            for c in 0..3 {
                pixel[c] = from_f64(rgb[c]);
            }
        }
        let out = self.pipeline.process(image, &CpuBackend);
        out.pixels()
            .map(|px| printed_lstar(post, [to_f32(px[0]), to_f32(px[1]), to_f32(px[2])], true, "sRGB"))
            .collect()
    }

    /// The change in stops that prints each sample at its target: the crossing
    /// nearest no change, since printing needn't rise everywhere with exposure,
    /// or where none crosses, the closest it comes. Searched on a grid for all
    /// the samples at once, then narrowed within the bracket. With each, how
    /// far a stop moves the print there, in L\*.
    fn shifts(&self, samples: &[ZoneSample]) -> Vec<(f64, f64)> {
        const COARSE: usize = 65;
        const FINE: usize = 17;
        let grid = |low: f64, high: f64, n: usize| (0..n).map(move |i| low + (high - low) * i as f64 / (n - 1) as f64);
        let evaluate = |ranges: &[(f64, f64)], n: usize| -> Vec<Vec<(f64, f64)>> {
            let groups: Vec<Vec<[f64; 3]>> = samples
                .iter()
                .zip(ranges)
                .flat_map(|(sample, &(low, high))| {
                    grid(low, high, n).map(move |s| sample.pixels.iter().map(|rgb| rgb.map(|v| v * s.exp2())).collect())
                })
                .collect();
            let printed = self.printed_groups(&groups);
            samples
                .iter()
                .zip(ranges)
                .enumerate()
                .map(|(i, (sample, &(low, high)))| {
                    grid(low, high, n).zip(&printed[i * n..(i + 1) * n]).map(|(s, p)| (s, p - sample.target)).collect()
                })
                .collect()
        };
        let coarse = evaluate(&vec![(-MAX_SHIFT, MAX_SHIFT); samples.len()], COARSE);
        // Each sample's bracket, or None where nothing crosses: then the closest.
        let bracket = |points: &[(f64, f64)]| -> Result<(f64, f64), f64> {
            points
                .windows(2)
                .filter(|w| w[0].1.signum() != w[1].1.signum() || w[0].1 == 0.0)
                .min_by(|a, b| (a[0].0 + a[1].0).abs().total_cmp(&(b[0].0 + b[1].0).abs()))
                .map(|w| (w[0].0, w[1].0))
                .ok_or_else(|| points.iter().min_by(|a, b| a.1.abs().total_cmp(&b.1.abs())).map_or(0.0, |p| p.0))
        };
        let mut found: Vec<Result<(f64, f64), f64>> = coarse.iter().map(|p| bracket(p)).collect();
        for _ in 0..3 {
            let ranges: Vec<(f64, f64)> = found.iter().map(|f| f.unwrap_or_else(|s| (s, s))).collect();
            let fine = evaluate(&ranges, FINE);
            for (f, points) in found.iter_mut().zip(&fine) {
                if f.is_ok() {
                    *f = bracket(points);
                }
            }
        }
        // The last bracket is a few thousandths of a stop: its middle.
        let shifts: Vec<f64> = found.into_iter().map(|f| f.map_or_else(|s| s, |(a, b)| (a + b) / 2.0)).collect();
        let ranges: Vec<(f64, f64)> = shifts.iter().map(|&s| (s - 0.25, s + 0.25)).collect();
        evaluate(&ranges, 2)
            .iter()
            .zip(shifts)
            .map(|(ends, s)| (s, ((ends[1].1 - ends[0].1) / 0.5).abs()))
            .collect()
    }

}

/// A reading of the photograph against the zones.
#[derive(Debug, Clone, PartialEq)]
pub struct ZoneReadout {
    /// Where the reading prints now, in L\*.
    pub printed: f64,
    /// The change of scene exposure, in stops, that prints it at each target.
    pub shifts: Vec<f64>,
}

/// Where an area of `image` prints with `params`, its corners as
/// [`area_colours`] takes them, exposed at the photograph's `autoexposure_ev`
/// and, on the lab scan, balanced with its `lab_balance`
/// ([`Pipeline::lab_balance`]), and the change of Prep's exposure that prints
/// it at each of `targets`, in L\*. Like a pin, the reading runs through the
/// film and paper one pixel at a time. Prep's exposure is a plain gain the
/// print doesn't make up for, so scaling the pixels finds the change exactly,
/// unless Prep's other controls bend the light after it: then each change is
/// put right against the controls themselves.
pub fn readout(
    data: &Path,
    film: &str,
    paper: &str,
    params: &RuntimeParams,
    autoexposure_ev: Option<f64>,
    lab_balance: Option<Balance>,
    image: &ImageBuf,
    corners: [(f64, f64); 2],
    targets: &[f64],
) -> Result<ZoneReadout, String> {
    let ae = autoexposure_ev.unwrap_or(0.0);
    let read = |params: &RuntimeParams| -> Result<Vec<[f64; 3]>, String> {
        area_colours(image, params, ae, corners)?.ok_or_else(|| "That area is outside the photograph".to_owned())
    };
    let pixels = read(params)?;
    let chain = Pointwise::new(data, film, paper, params, autoexposure_ev, lab_balance)?;
    let printed = chain.printed_groups(std::slice::from_ref(&pixels))[0];
    let samples: Vec<ZoneSample> = targets.iter().map(|&target| ZoneSample { pixels: pixels.clone(), target }).collect();
    if samples.is_empty() {
        return Ok(ZoneReadout { printed, shifts: Vec::new() });
    }
    let base = f64::from(params.prep.exposure_ev);
    let plain = PrepParams { exposure_ev: 0.0, zone_curve: ZoneCurve::default(), ..params.prep }.is_identity();
    let shifts = chain
        .shifts(&samples)
        .into_par_iter()
        .zip(targets.par_iter())
        .map(|((mut shift, sensitivity), &target)| -> Result<f64, String> {
            if plain {
                return Ok(shift);
            }
            for _ in 0..3 {
                let mut moved = params.clone();
                moved.prep.exposure_ev = (base + shift).clamp(-EXPOSURE_RANGE, EXPOSURE_RANGE) as f32;
                let miss = target - chain.printed_groups(&[read(&moved)?])[0];
                if miss.abs() < 0.2 || sensitivity < 0.5 {
                    break;
                }
                shift = (shift + (miss / sensitivity).clamp(-1.0, 1.0)).clamp(-MAX_SHIFT, MAX_SHIFT);
            }
            Ok(shift)
        })
        .collect::<Result<Vec<_>, _>>()?;
    Ok(ZoneReadout { printed, shifts })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn data() -> std::path::PathBuf {
        std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../data")
    }

    #[test]
    fn a_readouts_shift_prints_the_reading_at_its_target() {
        let mut image = ImageBuf::new(4, 4);
        for (i, px) in image.pixels_mut().enumerate() {
            let v = GREY * if i % 2 == 0 { 0.4 } else { 0.6 };
            for c in 0..3 {
                px[c] = from_f64(v);
            }
        }
        let corners = [(0.0, 0.0), (1.0, 1.0)];
        // Plain, with Prep's own controls bending the light after its exposure,
        // and with auto exposure on the photograph's metering.
        for (shadows, metering) in [(0.0, None), (0.5, None), (0.0, Some(1.0))] {
            let mut params = RuntimeParams::default();
            params.io.input_cctf_decoding = false;
            params.camera.auto_exposure = metering.is_some();
            params.prep.shadows = shadows;
            let read = |params: &RuntimeParams| {
                readout(&data(), "kodak_portra_400", "kodak_portra_endura", params, metering, None, &image, corners, &[30.3, 57.5]).unwrap()
            };
            let before = read(&params);
            assert!(before.shifts[0] < before.shifts[1]);
            for (target, shift) in [30.3, 57.5].into_iter().zip(before.shifts.clone()) {
                params.prep.exposure_ev = shift as f32;
                let printed = read(&params).printed;
                assert!((printed - target).abs() < 0.5, "shadows {shadows}, metering {metering:?}, {target}: {printed}");
            }
        }
    }

    #[test]
    fn an_area_reads_inside_its_corners_only() {
        let mut image = ImageBuf::new(10, 10);
        for (i, px) in image.pixels_mut().enumerate() {
            let v = if i % 10 < 5 { 0.1 } else { 0.4 };
            for c in 0..3 {
                px[c] = from_f64(v);
            }
        }
        let mut params = RuntimeParams::default();
        params.io.input_cctf_decoding = false;
        let left = area_colours(&image, &params, 0.0, [(0.0, 0.0), (0.45, 1.0)]).unwrap().unwrap();
        assert!(left.iter().all(|p| (p[0] - 0.1).abs() < 1e-6));
        assert!(area_colours(&image, &params, 0.0, [(0.0, 0.0), (1.2, 1.0)]).unwrap().is_none());
    }

}
