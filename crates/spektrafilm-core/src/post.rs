//! Post adjustments: finishing edits on the scanned photograph, as an editor
//! would make them to a lab scan. They run on the scan clipped to [0, 1]
//! (`pipeline::clip_to_display`), as an integer file holds it, so they shape
//! the tones the film produced but cannot recover a clipped highlight; that
//! belongs to camera and print exposure.
//!
//! Pixels are decoded with the output space's own transfer function and
//! luminance is that space's Y, so the same settings make the same change in
//! every output space. Tones are shaped on that luminance in sRGB-encoded
//! (perceptual) space. Brightness and the levels keep each pixel's colour
//! ratios; Contrast bends each channel, as RPP's does, so a tone it darkens
//! gets richer rather than duller.
//!
//! The arithmetic is f32 even in the f64 build: the tables already limit
//! accuracy to about 2e-7, far below a 16-bit output step, and the f64
//! build's purpose, parity with the Python reference, doesn't cover Post.
use rayon::prelude::*;
use std::collections::BTreeMap;
use serde::{Deserialize, Serialize};
use spektrafilm_math::colorspace::{self, RgbColourspace};
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::{from_f32, to_f32};

/// Each control runs from -100 to 100; 0 leaves the photograph unchanged.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PostParams {
    /// Lifts or darkens the midtones, keeping black and white.
    #[serde(default)]
    pub brightness: f32,
    /// An S-curve about middle grey, on each channel.
    #[serde(default)]
    pub contrast: f32,
    /// Moves the white point: up clips the brightest tones to white, down dims white.
    #[serde(default)]
    pub whites: f32,
    /// Moves the black point: down crushes the darkest tones, up lifts black.
    #[serde(default)]
    pub blacks: f32,
    /// Scales chroma in OKLab, keeping lightness and hue; -100 is monochrome.
    #[serde(default)]
    pub saturation: f32,
    /// Local contrast on lightness, 0 to 100 (see [`crate::local_contrast`]).
    #[serde(default)]
    pub local_contrast: f32,
    /// Tones this print pins, as L\* after the knobs above → printed L\*: a
    /// curve that can set the black and white points (see [`AnchorCurve`]).
    #[serde(default)]
    pub tone_anchors: Vec<ToneAnchor>,
    /// The pins bend the scene's exposure before the film (Prep's zone curve,
    /// see [`crate::zones`]) rather than this curve, which keeps only the
    /// points set by hand. Off for edits made before, whose pins keep bending
    /// this curve until one is placed, moved or removed.
    #[serde(default)]
    pub pins_before_film: bool,
}

/// One pin of the tone curve, in CIE Lab lightness.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ToneAnchor {
    /// The tone as [`measured_lstar`] read it, L\* 0…100.
    pub input: f32,
    /// Where it should print, L\* 0…100.
    pub target: f32,
    /// Where the tone was measured, for the app to outline; the pipeline
    /// never reads it.
    #[serde(default)]
    pub source: Option<AnchorSource>,
}

/// The circle on the uncropped photograph that a pin averaged.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct AnchorSource {
    /// The circle's centre, in fractions of the width and height, from the
    /// top left.
    #[serde(default)]
    pub x: f32,
    #[serde(default)]
    pub y: f32,
    /// Its radius, as a fraction of the photograph's shorter side.
    #[serde(default)]
    pub radius: f32,
}

impl PostParams {
    pub fn is_identity(&self) -> bool {
        *self == Self::default()
    }
}

/// sRGB-encoded middle grey (18% reflectance), the contrast pivot.
const PIVOT: f64 = 0.461_356;
/// How far Whites and Blacks at ±100 move their end point.
const LEVELS_RANGE: f64 = 0.15;
const LUT_SIZE: usize = 4096;

/// Luminance weights of an output colour space: the Y row of its RGB → XYZ
/// matrix. Unknown names fall back to sRGB, as the scan's output does.
pub(crate) fn luminance_weights(color_space: &str) -> [f32; 3] {
    RgbColourspace::output(color_space).rgb_to_xyz[1].map(|v| v as f32)
}

fn srgb_encode(x: f64) -> f64 {
    if x <= 0.003_130_8 {
        12.92 * x
    } else {
        1.055 * x.powf(1.0 / 2.4) - 0.055
    }
}

fn srgb_decode(x: f64) -> f64 {
    if x <= 0.040_45 {
        x / 12.92
    } else {
        ((x + 0.055) / 1.055).powf(2.4)
    }
}

/// An output space's transfer function, with sRGB's exactly as before.
pub(crate) struct Transfer(pub(crate) &'static RgbColourspace);

impl Transfer {
    pub(crate) fn decode(&self, v: f64) -> f64 {
        if self.0.name == "sRGB" { srgb_decode(v) } else { self.0.cctf.decode(v) }
    }
    pub(crate) fn encode(&self, v: f64) -> f64 {
        if self.0.name == "sRGB" { srgb_encode(v) } else { self.0.cctf.encode(v) }
    }
}

/// Brightness on encoded luminance, [0, 1] → [0, 1], non-decreasing: a
/// rational curve with finite slope at both ends, so lifting the midtones
/// doesn't amplify the grain in the deepest shadows.
fn brightness(params: &PostParams, e: f64) -> f64 {
    let k = 2f64.powf(1.25 * params.brightness as f64 / 100.0);
    k * e / (1.0 + (k - 1.0) * e)
}

/// Contrast on one encoded channel, as RPP bends each channel
/// (`out = v^((−log v)^(B−1))`), pivoted at middle grey: `PIVOT^((ln e / ln
/// PIVOT)^B)`. It keeps 0 and 1, rises for any `B > 0`, and its slope at the
/// pivot is `B`: 2 at +100 and 0.25 at −100. Bent per channel, a tone made
/// darker spreads its channels apart and gets richer, as on a contrastier paper.
fn contrast_curve(contrast: f32, e: f64) -> f64 {
    let c = contrast as f64 / 100.0;
    let b = if c < 0.0 { 1.0 + 0.75 * c } else { 1.0 + c };
    if e <= 0.0 {
        return 0.0;
    }
    if e >= 1.0 {
        return 1.0;
    }
    PIVOT.powf((e.ln() / PIVOT.ln()).powf(b))
}

/// The working space Contrast bends the channels of: wide enough for any
/// scan, and the same whatever the output space.
fn contrast_space() -> &'static RgbColourspace {
    RgbColourspace::find("ITU-R BT.2020").expect("BT.2020 is a colour space")
}

fn matrix_f32(m: [[f64; 3]; 3]) -> [[f32; 3]; 3] {
    m.map(|row| row.map(|v| v as f32))
}

fn mul(m: &[[f32; 3]; 3], c: [f32; 3]) -> [f32; 3] {
    m.map(|row| row[0] * c[0] + row[1] * c[1] + row[2] * c[2])
}

/// RPP's saturation as a scale on OKLab chroma: `C / (C − 2s)` with
/// `C = 248.4375`, its curve gentle at first and rising faster. The slider is
/// scaled so +100 gives 2, the reach Saturation had; below zero it falls
/// linearly to 0, so −100 is grey, as RPP's monochrome mode is.
fn chroma_scale(saturation: f32) -> f32 {
    const C: f64 = 248.4375;
    if saturation <= 0.0 {
        return (1.0 + saturation / 100.0).max(0.0);
    }
    let s = saturation as f64 * C / 400.0;
    (C / (C - 2.0 * s)) as f32
}

/// Björn Ottosson's OKLab: XYZ (D65) → LMS, and LMS^⅓ → Lab.
const OKLAB_M1: [[f64; 3]; 3] = [
    [0.818_933_010_1, 0.361_866_742_4, -0.128_859_713_7],
    [0.032_984_543_6, 0.929_311_871_5, 0.036_145_638_7],
    [0.048_200_301_8, 0.264_366_269_1, 0.633_851_707_0],
];
pub(crate) const OKLAB_M2: [[f32; 3]; 3] = [
    [0.210_454_255_3, 0.793_617_785_0, -0.004_072_046_8],
    [1.977_998_495_1, -2.428_592_205_0, 0.450_593_709_9],
    [0.025_904_037_1, 0.782_771_766_2, -0.808_675_766_0],
];

fn mat_mul(a: &[[f64; 3]; 3], b: &[[f64; 3]; 3]) -> [[f64; 3]; 3] {
    std::array::from_fn(|i| std::array::from_fn(|j| (0..3).map(|k| a[i][k] * b[k][j]).sum()))
}

fn mat_inv(m: &[[f64; 3]; 3]) -> [[f64; 3]; 3] {
    let c = |r: usize, k: usize| m[(r + 1) % 3][(k + 1) % 3] * m[(r + 2) % 3][(k + 2) % 3] - m[(r + 1) % 3][(k + 2) % 3] * m[(r + 2) % 3][(k + 1) % 3];
    let det = (0..3).map(|k| m[0][k] * c(0, k)).sum::<f64>();
    std::array::from_fn(|i| std::array::from_fn(|j| c(j, i) / det))
}

/// An output space's linear RGB → OKLab's LMS, through sRGB's D65 XYZ so a
/// D50 space like ProPhoto keeps its greys grey; and back. Each row is
/// normalised, so white is LMS (1, 1, 1) and OKLab L 1.
pub(crate) fn lms_matrices(color_space: &str) -> ([[f32; 3]; 3], [[f32; 3]; 3]) {
    let srgb = RgbColourspace::output("sRGB");
    let to_srgb = colorspace::icc_rgb_to_rgb(RgbColourspace::output(color_space), srgb);
    let mut to_lms = mat_mul(&OKLAB_M1, &mat_mul(&srgb.rgb_to_xyz, &to_srgb));
    // The space's white lands exactly on OKLab's neutral axis, whatever small
    // difference there is between this D65 and Ottosson's.
    for row in &mut to_lms {
        let sum: f64 = row.iter().sum();
        row.iter_mut().for_each(|v| *v /= sum);
    }
    (matrix_f32(to_lms), matrix_f32(mat_inv(&to_lms)))
}

pub(crate) fn oklab_from(to_lms: &[[f32; 3]; 3], c: [f32; 3]) -> [f32; 3] {
    mul(&OKLAB_M2, mul(to_lms, c).map(f32::cbrt))
}

/// OKLab's Lab → LMS^⅓, the inverse of [`OKLAB_M2`].
pub(crate) fn oklab_m2_inv() -> [[f32; 3]; 3] {
    matrix_f32(mat_inv(&OKLAB_M2.map(|r| r.map(f64::from))))
}

pub(crate) fn oklab_to(from_lms: &[[f32; 3]; 3], m2_inv: &[[f32; 3]; 3], lab: [f32; 3]) -> [f32; 3] {
    mul(from_lms, mul(m2_inv, lab).map(|v| v * v * v))
}

/// Whites and Blacks on encoded luminance: levels on the end points.
fn levels(params: &PostParams, e: f64) -> f64 {
    let black = -LEVELS_RANGE * params.blacks as f64 / 100.0;
    let white = 1.0 - LEVELS_RANGE * params.whites as f64 / 100.0;
    ((e - black) / (white - black)).clamp(0.0, 1.0)
}

/// The whole curve a grey takes, encoded: Brightness, Contrast, then levels.
#[cfg(test)]
fn tone(params: &PostParams, e: f64) -> f64 {
    levels(params, contrast_curve(params.contrast, brightness(params, e)))
}

/// Linear interpolation in a table sampled on [0, 1].
fn lookup(table: &[f32], x: f32) -> f32 {
    let t = x.clamp(0.0, 1.0) * (table.len() - 1) as f32;
    let i = (t as usize).min(table.len() - 2);
    let f = t - i as f32;
    table[i] + (table[i + 1] - table[i]) * f
}

/// The L\* a scan's pixel prints at, after `post`: as [`measured_lstar`] reads a
/// tone, with whatever curve `post` holds.
pub(crate) fn printed_lstar(post: &PostProcess, rgb: [f32; 3], encoded: bool, color_space: &str) -> f64 {
    let transfer = Transfer(RgbColourspace::output(color_space));
    let luma = luminance_weights(color_space);
    let (lo, hi) = crate::pipeline::display_range(encoded);
    let out = post.apply_rgb(rgb.map(|v| v.clamp(to_f32(lo), to_f32(hi))));
    let linear = out.map(|v| if encoded { transfer.decode(f64::from(v)) } else { f64::from(v) });
    lstar_of((0..3).map(|c| f64::from(luma[c]) * linear[c]).sum())
}

/// CIE Lab lightness of a linear luminance, and its inverse.
fn lstar_of(y: f64) -> f64 {
    if y > 216.0 / 24389.0 {
        116.0 * y.cbrt() - 16.0
    } else {
        y * 24389.0 / 27.0
    }
}

fn luminance_of(value: f64) -> f64 {
    if value > 8.0 {
        ((value + 16.0) / 116.0).powi(3)
    } else {
        value * 27.0 / 24389.0
    }
}

/// The pins as a smooth rising curve in L\*. Pins on one target are averaged:
/// that average prints as the target. The average aimed at 0 is the black point
/// and the one aimed at 100 the white point; the others bend the curve between
/// them. Tones outside the
/// ends clamp, which is what setting a black or white point means, and the curve
/// flattens into a point it sets, so there's no corner there. With no pins it is
/// the identity.
///
/// A pin measured on the photograph is soft: it pulls the curve towards its
/// target, within [`SOFT_SLOPE`], so pins close together blend rather than
/// stretching some tones and crushing others, which is what posterizes. Pins with
/// room land exactly, as does a point set by hand, which has no `source`.
///
/// Between the knots it is a monotone cubic (Fritsch and Butland's tangents):
/// the slope has no corners, and it never overshoots or turns back between two.
#[derive(Debug, Clone, Default)]
pub struct AnchorCurve {
    black: f64,
    white: f64,
    /// Interior pins, strictly between the ends and rising, where they print.
    points: Vec<(f64, f64)>,
    /// What's moved from its target, by [`target_key`], and where it printed.
    moved: BTreeMap<i64, f64>,
    /// The slope at each knot: the black point, the pins, the white point.
    tangents: Vec<f64>,
    /// The anchors the curve can't honour, as indices into those it was given.
    ignored: Vec<usize>,
}

/// Two curves are equal if they map tones alike, whichever pins they dropped.
impl PartialEq for AnchorCurve {
    fn eq(&self, other: &Self) -> bool {
        (self.black, self.white) == (other.black, other.white) && self.points == other.points
    }
}

/// How steep or flat soft pins may make the curve, as L\* out per L\* in. Past
/// about 2 a gradient starts to show steps and grain; near 0 tones merge.
/// The app's `ToneCurve` has the same numbers.
pub const SOFT_SLOPE: (f64, f64) = (0.35, 1.8);

/// Targets are read to the half L\*, so pins on one are one reading.
fn target_key(target: f32) -> i64 {
    (f64::from(target.clamp(0.0, 100.0)) * 2.0).round() as i64
}

impl AnchorCurve {
    pub fn new(anchors: &[ToneAnchor]) -> Self {
        Self::build(anchors, false)
    }

    /// The curve an edit's Post uses: when its pins bend the exposure before the
    /// film, they're left out, and only the points set by hand bend it.
    pub fn for_post(post: &PostParams) -> Self {
        Self::build(&post.tone_anchors, post.pins_before_film)
    }

    fn build(anchors: &[ToneAnchor], without_pins: bool) -> Self {
        // Pins on one target are one reading of that tone: their average prints
        // there. Only the targets matter, never the order.
        let mut ignored = Vec::new();
        let mut zones: BTreeMap<i64, (f64, Vec<usize>)> = BTreeMap::new();
        for (index, anchor) in anchors.iter().enumerate() {
            if without_pins && anchor.source.is_some() {
                continue;
            }
            let input = f64::from(anchor.input);
            if !input.is_finite() || !anchor.target.is_finite() || !(0.0..100.0).contains(&input) {
                ignored.push(index);
                continue;
            }
            let zone = zones.entry(target_key(anchor.target)).or_default();
            zone.0 += input;
            zone.1.push(index);
        }
        let (mut black, mut white) = (0.0f64, 100.0f64);
        let mut white_pins = Vec::new();
        let mut interior = Vec::new();
        for (key, (sum, pins)) in zones {
            let (input, target) = (sum / pins.len() as f64, key as f64 / 2.0);
            if target <= 0.0 {
                black = input;
            } else if target >= 100.0 {
                white = input;
                white_pins = pins;
            } else {
                interior.push((input, target, pins));
            }
        }
        // A white point at or below the black point leaves no room for a curve.
        if white <= black + 0.5 {
            ignored.append(&mut white_pins);
            white = 100.0;
        }
        // Sorted by input, then by target, so ties resolve the same way whatever
        // order the pins were made in. The curve must rise, so a zone that would
        // turn it back is dropped; the lowest input is kept.
        interior.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.total_cmp(&b.1)));
        let mut points: Vec<(f64, f64)> = Vec::with_capacity(interior.len());
        let mut soft: Vec<bool> = Vec::with_capacity(interior.len());
        for (input, target, mut pins) in interior {
            let inside = input > black + 0.5 && input < white - 0.5;
            let rising = points
                .last()
                .is_none_or(|&(i, t)| input - i >= 0.5 && target - t >= 0.5);
            if inside && rising {
                points.push((input, target));
                soft.push(pins.iter().any(|&index| anchors[index].source.is_some()));
            } else {
                ignored.append(&mut pins);
            }
        }
        ignored.sort_unstable();
        let relaxed = Self::relaxed(black, white, &points, &soft);
        let moved = points.iter().zip(&relaxed)
            .filter(|(from, to)| from.1 != to.1)
            .map(|(from, to)| ((from.1 * 2.0).round() as i64, to.1))
            .collect();
        let tangents = Self::tangents(black, white, &relaxed);
        Self { black, white, points: relaxed, moved, tangents, ignored }
    }

    /// Where an anchor's target actually prints: the place a plain point has to
    /// be for the same curve.
    pub fn printed_target(&self, anchor: &ToneAnchor) -> f32 {
        self.moved.get(&target_key(anchor.target)).map_or(anchor.target, |&target| target as f32)
    }

    /// The soft pins, moved as little as keeps every stretch of the curve within
    /// [`SOFT_SLOPE`]; the ends and hard points stay. Worked from both ends and
    /// averaged, so no pin wins for being first, and the limits, being convex,
    /// still hold.
    fn relaxed(black: f64, white: f64, points: &[(f64, f64)], soft: &[bool]) -> Vec<(f64, f64)> {
        if !soft.contains(&true) {
            return points.to_vec();
        }
        let (flat, steep) = SOFT_SLOPE;
        let mut knots = Vec::with_capacity(points.len() + 2);
        knots.push((black, 0.0, false));
        knots.extend(points.iter().zip(soft).map(|(&(x, y), &s)| (x, y, s)));
        knots.push((white, 100.0, false));
        let count = knots.len();
        // What the nearest fixed knots either side allow.
        let mut bounds = vec![(0.0f64, 0.0f64); count];
        for i in 0..count {
            let (x, y, is_soft) = knots[i];
            if !is_soft {
                bounds[i] = (y, y);
                continue;
            }
            let left = knots[..i].iter().rev().find(|k| !k.2).expect("the black point is fixed");
            let right = knots[i + 1..].iter().find(|k| !k.2).expect("the white point is fixed");
            let low = (left.1 + flat * (x - left.0)).max(right.1 - steep * (right.0 - x));
            let high = (left.1 + steep * (x - left.0)).min(right.1 - flat * (right.0 - x));
            // Hard points too close for the limits leave nothing to aim for: it stays.
            let stay = y.clamp(left.1, right.1);
            bounds[i] = if low <= high { (low, high) } else { (stay, stay) };
        }
        // Within what's allowed from its neighbour too, or if nothing is, its bounds.
        let place = |y: f64, (low, high): (f64, f64), bound: (f64, f64)| {
            if low <= high { y.clamp(low, high) } else { y.clamp(bound.0, bound.1) }
        };
        let mut forward = vec![0.0; count];
        forward[0] = knots[0].1;
        for i in 1..count {
            let d = knots[i].0 - knots[i - 1].0;
            let low = bounds[i].0.max(forward[i - 1] + flat * d);
            let high = bounds[i].1.min(forward[i - 1] + steep * d);
            forward[i] = if knots[i].2 { place(knots[i].1, (low, high), bounds[i]) } else { knots[i].1 };
        }
        let mut backward = vec![0.0; count];
        backward[count - 1] = knots[count - 1].1;
        for i in (0..count - 1).rev() {
            let d = knots[i + 1].0 - knots[i].0;
            let low = bounds[i].0.max(backward[i + 1] - steep * d);
            let high = bounds[i].1.min(backward[i + 1] - flat * d);
            backward[i] = if knots[i].2 { place(knots[i].1, (low, high), bounds[i]) } else { knots[i].1 };
        }
        // Between hard points too close for the limits, it must still rise.
        let mut result: Vec<f64> = forward.iter().zip(&backward).map(|(a, b)| (a + b) / 2.0).collect();
        for i in 1..count - 1 {
            if knots[i].2 { result[i] = result[i].max(result[i - 1]).min(result[i + 1].max(result[i - 1])); }
        }
        (1..count - 1).map(|i| (knots[i].0, result[i])).collect()
    }

    /// Shape-preserving slopes for the knots. An end that's a black or white
    /// point flattens; an end at the axis's limit keeps its natural slope.
    fn tangents(black: f64, white: f64, points: &[(f64, f64)]) -> Vec<f64> {
        let mut knots = Vec::with_capacity(points.len() + 2);
        knots.push((black, 0.0));
        knots.extend_from_slice(points);
        knots.push((white, 100.0));
        let widths: Vec<f64> = knots.windows(2).map(|k| k[1].0 - k[0].0).collect();
        let slopes: Vec<f64> = knots.windows(2).zip(&widths).map(|(k, h)| (k[1].1 - k[0].1) / h).collect();
        // A one-sided, three-point estimate, held to what stays monotone.
        let end = |h0: f64, h1: f64, s0: f64, s1: f64| {
            (((2.0 * h0 + h1) * s0 - h0 * s1) / (h0 + h1)).clamp(0.0, 3.0 * s0)
        };
        let last = slopes.len() - 1;
        let mut tangents = vec![0.0; knots.len()];
        if slopes.len() == 1 {
            tangents = vec![slopes[0]; 2];
        } else {
            tangents[0] = end(widths[0], widths[1], slopes[0], slopes[1]);
            tangents[last + 1] = end(widths[last], widths[last - 1], slopes[last], slopes[last - 1]);
            for i in 1..=last {
                let (h0, h1) = (widths[i - 1], widths[i]);
                let (w0, w1) = (2.0 * h1 + h0, h1 + 2.0 * h0);
                tangents[i] = (w0 + w1) / (w0 / slopes[i - 1] + w1 / slopes[i]);
            }
            // The ends of the axis don't flatten, which would crush the deepest
            // shadows and the brightest highlights together.
            tangents[0] = tangents[0].max(slopes[0] / 2.0);
            tangents[last + 1] = tangents[last + 1].max(slopes[last] / 2.0);
        }
        if black > 0.0 { tangents[0] = 0.0; }
        if white < 100.0 { tangents[last + 1] = 0.0; }
        tangents
    }

    /// The anchors the curve can't honour: they have no effect until another
    /// pin moves out of their way.
    pub fn ignored(&self) -> &[usize] {
        &self.ignored
    }

    pub fn is_identity(&self) -> bool {
        self.black <= 0.0 && self.white >= 100.0 && self.points.is_empty()
    }

    /// The printed L\* of a measured one.
    pub fn map(&self, value: f64) -> f64 {
        if self.is_identity() {
            return value;
        }
        if !value.is_finite() || value <= self.black {
            return 0.0;
        }
        if value >= self.white {
            return 100.0;
        }
        // The segment holding the tone, then its cubic Hermite.
        let index = self.points.partition_point(|&(input, _)| input <= value);
        let knot = |i: usize| match i {
            0 => (self.black, 0.0),
            i if i > self.points.len() => (self.white, 100.0),
            i => self.points[i - 1],
        };
        let ((x0, y0), (x1, y1)) = (knot(index), knot(index + 1));
        let (m0, m1) = (self.tangents[index], self.tangents[index + 1]);
        let h = x1 - x0;
        let t = (value - x0) / h;
        let (t2, t3) = (t * t, t * t * t);
        let y = (2.0 * t3 - 3.0 * t2 + 1.0) * y0 + (t3 - 2.0 * t2 + t) * h * m0 + (-2.0 * t3 + 3.0 * t2) * y1 + (t3 - t2) * h * m1;
        y.clamp(y0, y1)
    }

    /// The same curve on a linear luminance.
    pub fn map_luminance(&self, y: f64) -> f64 {
        if self.is_identity() {
            return y;
        }
        luminance_of(self.map(lstar_of(y)).clamp(0.0, 100.0))
    }
}

/// Post adjustments prepared for per-pixel use. Every curve is tabulated, so
/// applying them costs a few lookups per pixel.
pub struct PostProcess {
    /// The chroma scale Saturation applies in OKLab ([`chroma_scale`]).
    saturation: f32,
    /// Output space → OKLab's LMS, adapted to its D65 white, and back.
    to_lms: [[f32; 3]; 3],
    from_lms: [[f32; 3]; 3],
    /// [`oklab_m2_inv`], worked out once.
    m2_inv: [[f32; 3]; 3],
    /// The output space's luminance weights.
    luma: [f32; 3],
    /// Whether pixels arrive, and leave, encoded with the output space's
    /// transfer function rather than linear.
    encoded: bool,
    /// Encoded → linear.
    decode: Vec<f32>,
    /// Linear → encoded, sampled on √x for resolution near black.
    encode: Vec<f32>,
    /// Brightness: linear luminance → linear luminance, sampled on √Y.
    tone: Vec<f32>,
    /// Contrast: a linear channel → a linear channel, sampled on √x. It bends
    /// the channels of one working space, so the same edit looks the same in
    /// every output space.
    channel: Vec<f32>,
    /// Output space → the working space Contrast bends in, and back.
    to_work: [[f32; 3]; 3],
    from_work: [[f32; 3]; 3],
    /// Whites, Blacks and the tone curve's points: linear luminance → linear
    /// luminance, sampled on √Y.
    levels: Vec<f32>,
}

impl PostProcess {
    /// `encoded` and `color_space` describe the scan's output, as
    /// `io.output_cctf_encoding` and `io.output_color_space`.
    pub fn new(params: &PostParams, encoded: bool, color_space: &str) -> Self {
        let space = Transfer(RgbColourspace::output(color_space));
        let samples = |f: &dyn Fn(f64) -> f64| -> Vec<f32> {
            (0..LUT_SIZE)
                .map(|i| f(i as f64 / (LUT_SIZE - 1) as f64) as f32)
                .collect()
        };
        let (to_lms, from_lms) = lms_matrices(color_space);
        Self {
            saturation: chroma_scale(params.saturation),
            to_lms,
            from_lms,
            m2_inv: oklab_m2_inv(),
            luma: luminance_weights(color_space),
            encoded,
            decode: samples(&|v| space.decode(v)),
            encode: samples(&|s| space.encode(s * s)),
            tone: samples(&|s| srgb_decode(brightness(params, srgb_encode(s * s)))),
            channel: samples(&|s| srgb_decode(contrast_curve(params.contrast, srgb_encode(s * s)))),
            to_work: matrix_f32(colorspace::icc_rgb_to_rgb(RgbColourspace::output(color_space), contrast_space())),
            from_work: matrix_f32(colorspace::icc_rgb_to_rgb(contrast_space(), RgbColourspace::output(color_space))),
            // The pins bend what the knobs produced.
            levels: {
                let curve = AnchorCurve::for_post(params);
                samples(&|s| curve.map_luminance(srgb_decode(levels(params, srgb_encode(s * s)))))
            },
        }
    }

    /// Adjusts one pixel. Input channels are expected in [0, 1], clipped like
    /// a display; so is the result.
    pub fn apply_rgb(&self, rgb: [f32; 3]) -> [f32; 3] {
        let mut c = if self.encoded {
            rgb.map(|v| lookup(&self.decode, v))
        } else {
            rgb.map(|v| v.clamp(0.0, 1.0))
        };
        c = self.luminance_through(&self.tone, c);
        c = mul(&self.from_work, mul(&self.to_work, c).map(|v| {
            // Mirrored below zero, and left alone past one: wide colours keep going.
            let a = v.abs();
            if a > 1.0 { v } else { v.signum() * lookup(&self.channel, a.sqrt()) }
        }));
        c = self.luminance_through(&self.levels, c);
        let k = self.saturation;
        if k != 1.0 {
            let lab = self.oklab(c);
            let at = |f: f32| self.from_oklab([lab[0], lab[1] * f, lab[2] * f]);
            let inside = |c: [f32; 3]| c.iter().all(|v| (-1e-6..=1.0 + 1e-6).contains(v));
            c = at(k);
            if !inside(c) {
                // Back off to the gamut boundary, keeping lightness and hue.
                let (mut lo, mut hi) = (1.0f32, k);
                for _ in 0..12 {
                    let mid = 0.5 * (lo + hi);
                    if inside(at(mid)) { lo = mid } else { hi = mid }
                }
                c = at(lo);
            }
        }
        c = c.map(|v| v.clamp(0.0, 1.0));
        if self.encoded {
            c.map(|v| lookup(&self.encode, v.sqrt()))
        } else {
            c
        }
    }

    /// A linear colour in this output space as OKLab.
    pub(crate) fn oklab(&self, c: [f32; 3]) -> [f32; 3] {
        oklab_from(&self.to_lms, c)
    }

    pub(crate) fn from_oklab(&self, lab: [f32; 3]) -> [f32; 3] {
        oklab_to(&self.from_lms, &self.m2_inv, lab)
    }

    /// `c` with its luminance through `table`, its channels scaled together.
    fn luminance_through(&self, table: &[f32], c: [f32; 3]) -> [f32; 3] {
        let y = self.luma[0] * c[0] + self.luma[1] * c[1] + self.luma[2] * c[2];
        let y2 = lookup(table, y.max(0.0).sqrt());
        if y <= 1e-9 {
            return [y2; 3];
        }
        let c = c.map(|v| v * (y2 / y));
        // Above white, give up saturation rather than luminance or hue.
        let max = c[0].max(c[1]).max(c[2]);
        if max > 1.0 {
            let k = (1.0 - y2) / (max - y2);
            return c.map(|v| y2 + (v - y2) * k);
        }
        c
    }

    /// These adjustments for the GPU display pass, which applies them as
    /// [`Self::apply_rgb`] does.
    pub fn display(&self) -> spektrafilm_gpu::DisplayPost {
        spektrafilm_gpu::DisplayPost {
            luma: self.luma,
            saturation: self.saturation,
            encoded: self.encoded,
            decode: self.decode.clone(),
            encode: self.encode.clone(),
            tone: self.tone.clone(),
            channel: self.channel.clone(),
            levels: self.levels.clone(),
            to_work: self.to_work,
            from_work: self.from_work,
            to_lms: self.to_lms,
            from_lms: self.from_lms,
            m2: OKLAB_M2,
            m2_inv: self.m2_inv,
        }
    }

    pub fn apply(&self, image: &mut ImageBuf) {
        image.data.par_chunks_exact_mut(3).for_each(|px| {
            let out = self.apply_rgb([to_f32(px[0]), to_f32(px[1]), to_f32(px[2])]);
            px[0] = from_f32(out[0]);
            px[1] = from_f32(out[1]);
            px[2] = from_f32(out[2]);
        });
    }

    pub fn applied(&self, image: &ImageBuf) -> ImageBuf {
        let mut image = image.clone();
        self.apply(&mut image);
        image
    }
}

/// The most pixels [`measured_lstar`] reads; a larger circle is sampled on an
/// even grid.
const MEASURE_SAMPLES: f64 = 65_536.0;

/// The mean L\* of the pixels in a circle, as the pins read it: after the
/// four knobs, before any pin. `centre` is in fractions of the image and
/// `radius` a fraction of its shorter side; 0 is the pixel under the centre.
/// None outside the image.
pub fn measured_lstar(
    image: &ImageBuf,
    post: &PostParams,
    encoded: bool,
    color_space: &str,
    centre: (f64, f64),
    radius: f64,
) -> Option<f64> {
    let (width, height) = (image.width as f64, image.height as f64);
    if !(0.0..=1.0).contains(&centre.0) || !(0.0..=1.0).contains(&centre.1) || width < 1.0 || height < 1.0 {
        return None;
    }
    let (cx, cy) = (centre.0 * width, centre.1 * height);
    let reach = radius.max(0.0) * width.min(height);
    let knobs = PostProcess::new(&PostParams { tone_anchors: Vec::new(), ..post.clone() }, encoded, color_space);
    let transfer = Transfer(RgbColourspace::output(color_space));
    let luma = luminance_weights(color_space);
    let (lo, hi) = crate::pipeline::display_range(encoded);
    let lstar = |x: u32, y: u32| {
        let rgb = knobs.apply_rgb(image.get(x, y).map(|v| to_f32(v.clamp(lo, hi))));
        let linear = rgb.map(|v| if encoded { transfer.decode(f64::from(v)) } else { f64::from(v) });
        lstar_of((0..3).map(|c| f64::from(luma[c]) * linear[c]).sum())
    };
    let last = (image.width - 1, image.height - 1);
    if reach < 0.5 {
        return Some(lstar((cx as u32).min(last.0), (cy as u32).min(last.1)));
    }
    let span = |c: f64, end: u32| ((c - reach).max(0.0) as u32, ((c + reach).ceil() as u32).min(end));
    let (x0, x1) = span(cx, last.0);
    let (y0, y1) = span(cy, last.1);
    let area = f64::from(x1 - x0 + 1) * f64::from(y1 - y0 + 1);
    let stride = (area / MEASURE_SAMPLES).sqrt().ceil().max(1.0) as usize;
    let (mut sum, mut count) = (0.0, 0u32);
    for y in (y0..=y1).step_by(stride) {
        for x in (x0..=x1).step_by(stride) {
            let (dx, dy) = (f64::from(x) + 0.5 - cx, f64::from(y) + 0.5 - cy);
            if dx * dx + dy * dy <= reach * reach {
                sum += lstar(x, y);
                count += 1;
            }
        }
    }
    (count > 0).then(|| sum / f64::from(count))
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_chroma_scale_follows_rpp() {
        assert_eq!(chroma_scale(0.0), 1.0);
        assert!((chroma_scale(100.0) - 2.0).abs() < 1e-4);
        assert_eq!(chroma_scale(-100.0), 0.0);
        assert!((chroma_scale(-50.0) - 0.5).abs() < 1e-6);
        assert!(chroma_scale(50.0) < 1.5, "gentle at first, then rising faster");
    }

    #[test]
    fn saturation_keeps_oklab_lightness_and_hue_and_stays_in_gamut() {
        for space in ["sRGB", "ProPhoto RGB"] {
            for s in [-100.0, 40.0, 100.0] {
                let post = PostProcess::new(&PostParams { saturation: s, ..Default::default() }, false, space);
                for rgb in [[0.8f32, 0.3, 0.1], [0.05, 0.6, 0.9], [0.95, 0.02, 0.9]] {
                    let out = post.apply_rgb(rgb);
                    let (before, after) = (post.oklab(rgb), post.oklab(out));
                    assert!((before[0] - after[0]).abs() < 2e-3, "{space} {s} lightness {before:?} {after:?}");
                    assert!(out.iter().all(|v| (0.0..=1.0).contains(v)), "{space} {s} {out:?}");
                    if s > -100.0 {
                        let hue = |c: [f32; 3]| c[2].atan2(c[1]);
                        assert!((hue(before) - hue(after)).abs() < 2e-3, "{space} {s} hue");
                    } else {
                        assert!(after[1].abs() < 1e-3 && after[2].abs() < 1e-3, "{space}: grey");
                    }
                }
            }
        }
    }

    #[test]
    fn contrast_keeps_its_ends_and_rises() {
        for c in [-100.0, -40.0, 0.0, 40.0, 100.0] {
            assert_eq!(contrast_curve(c, 0.0), 0.0);
            assert_eq!(contrast_curve(c, 1.0), 1.0);
            assert!((contrast_curve(c, PIVOT) - PIVOT).abs() < 1e-12);
            let mut last = 0.0;
            for i in 1..=1000 {
                let v = contrast_curve(c, i as f64 / 1000.0);
                assert!(v.is_finite() && v >= last, "{c} at {i}");
                last = v;
            }
        }
        let slope = |c| (contrast_curve(c, PIVOT + 1e-6) - contrast_curve(c, PIVOT - 1e-6)) / 2e-6;
        assert!((slope(100.0) - 2.0).abs() < 1e-3);
        assert!((slope(-100.0) - 0.25).abs() < 1e-3);
    }

    /// RPP's contrast spreads a darkened colour's channels apart.
    #[test]
    fn contrast_makes_a_darkened_colour_richer() {
        let post = PostProcess::new(&PostParams { contrast: 60.0, ..Default::default() }, false, "sRGB");
        let skin = [0.15f32, 0.09, 0.06];
        let out = post.apply_rgb(skin);
        let ratio = |c: [f32; 3]| c[0] / c[2];
        assert!(out[1] < skin[1], "darker");
        assert!(ratio(out) > ratio(skin), "the channels spread apart");
    }

    /// The same curve with pins measured on the photograph, for the app's test.
    #[test]
    fn soft_pins_match_what_the_app_draws() {
        let source = Some(AnchorSource { x: 0.5, y: 0.5, radius: 0.02 });
        let pin = |input, target| ToneAnchor { input, target, source };
        let curve = AnchorCurve::new(&[pin(30.0, 36.0), pin(34.0, 49.5), pin(50.0, 66.5), pin(75.0, 88.0)]);
        for (input, expected) in SOFT_EXPECTED {
            assert!((curve.map(input) - expected).abs() < 1e-4, "{input}: {}", curve.map(input));
        }
    }
    const SOFT_EXPECTED: [(f64, f64); 4] = [(10.0, 10.504084), (32.0, 42.77046), (60.0, 76.320166), (90.0, 96.210687)];

    /// Pins close together blend, within the limits, and the curve keeps rising
    /// and never flattens at the ends. A gentle pin lands exactly.
    #[test]
    fn soft_pins_stay_within_their_slopes() {
        let source = Some(AnchorSource { x: 0.5, y: 0.5, radius: 0.02 });
        let pin = |input, target| ToneAnchor { input, target, source };
        for pins in [
            vec![pin(30.0, 36.0), pin(34.0, 49.5), pin(50.0, 66.5), pin(75.0, 88.0)],
            vec![pin(15.0, 25.0), pin(25.0, 49.5), pin(60.0, 66.5)],
            vec![pin(10.0, 5.0), pin(55.0, 66.5), pin(70.0, 88.0)],
            vec![pin(95.0, 88.0)],
        ] {
            let curve = AnchorCurve::new(&pins);
            let mut previous = curve.map(0.0);
            for step in 1..=400 {
                let value = curve.map(f64::from(step) / 4.0);
                let slope = (value - previous) * 4.0;
                assert!(slope > 0.05, "flat at {}: {slope}", f64::from(step) / 4.0);
                assert!(slope < 2.5, "steep at {}: {slope}", f64::from(step) / 4.0);
                previous = value;
            }
        }
        let gentle = AnchorCurve::new(&[pin(45.0, 49.5)]);
        assert!((gentle.map(45.0) - 49.5).abs() < 1e-9);
    }

    /// Through to 8-bit, a grey ramp keeps more of its levels with soft pins than
    /// with the same pins forced to land exactly, and takes smaller steps.
    #[test]
    fn soft_pins_keep_a_gradient_smoother() {
        let levels = |source| {
            let pin = |input, target| ToneAnchor { input, target, source };
            let post = PostProcess::new(&PostParams {
                tone_anchors: vec![pin(30.0, 36.0), pin(34.0, 49.5), pin(50.0, 66.5), pin(75.0, 88.0)],
                ..PostParams::default()
            }, true, "sRGB");
            let out: Vec<u8> = (0..=4095)
                .map(|i| { let v = i as f32 / 4095.0; (post.apply_rgb([v, v, v])[0] * 255.0).round() as u8 })
                .collect();
            let jump = (0..=255).map(|i| (i * 4095 / 255) as usize).collect::<Vec<_>>()
                .windows(2).map(|w| out[w[1]] - out[w[0]]).max().unwrap();
            let mut distinct = out.clone();
            distinct.dedup();
            (distinct.len(), jump)
        };
        let hard = levels(None);
        let soft = levels(Some(AnchorSource { x: 0.5, y: 0.5, radius: 0.02 }));
        assert!(soft.0 >= hard.0, "levels: {soft:?} {hard:?}");
        assert!(soft.1 < hard.1, "steps: {soft:?} {hard:?}");
    }

    /// A point set by hand stays where it's put, however steep that makes it, and
    /// a pin converted to a plain point keeps the curve the same.
    #[test]
    fn hard_points_land_exactly_and_plain_targets_keep_the_curve() {
        let hard = |input, target| ToneAnchor { input, target, source: None };
        let curve = AnchorCurve::new(&[hard(30.0, 36.0), hard(34.0, 49.5)]);
        assert!((curve.map(30.0) - 36.0).abs() < 1e-9);
        assert!((curve.map(34.0) - 49.5).abs() < 1e-9);
        let source = Some(AnchorSource { x: 0.5, y: 0.5, radius: 0.02 });
        let pins = [ToneAnchor { input: 30.0, target: 36.0, source }, ToneAnchor { input: 34.0, target: 49.5, source }];
        let soft = AnchorCurve::new(&pins);
        assert!(soft.map(34.0) < 49.0, "It's moved");
        let plain: Vec<ToneAnchor> = pins.iter().map(|a| ToneAnchor { target: soft.printed_target(a), source: None, ..*a }).collect();
        let converted = AnchorCurve::new(&plain);
        for input in [10.0, 30.0, 34.0] {
            assert!((converted.map(input) - soft.map(input)).abs() < 1.0, "{input}");
        }
    }

    /// The Mac app draws this curve with its own `ToneCurve`, whose test holds
    /// it to these same numbers: change one and the other has to follow.
    #[test]
    fn the_curve_matches_what_the_app_draws() {
        let anchor = |input, target| ToneAnchor { input, target, source: None };
        let curve = AnchorCurve::new(&[anchor(25.0, 10.0), anchor(60.0, 70.0)]);
        for (input, expected) in [(10.0, 2.73521), (40.0, 32.81935), (50.0, 54.01397), (80.0, 88.388158)] {
            assert!((curve.map(input) - expected).abs() < 1e-4, "{input}: {}", curve.map(input));
        }
        let ends = AnchorCurve::new(&[anchor(20.0, 0.0), anchor(45.0, 50.0), anchor(90.0, 100.0)]);
        for (input, expected) in [(30.0, 14.075524), (60.0, 72.753173), (85.0, 99.010523)] {
            assert!((ends.map(input) - expected).abs() < 1e-4, "{input}: {}", ends.map(input));
        }
    }

    use super::*;

    fn params(f: impl FnOnce(&mut PostParams)) -> PostParams {
        let mut p = PostParams::default();
        f(&mut p);
        p
    }

    #[test]
    fn neutral_settings_keep_the_photograph() {
        let post = PostProcess::new(&PostParams::default(), true, "sRGB");
        for rgb in [
            [0.0, 0.0, 0.0],
            [1.0, 1.0, 1.0],
            [0.2, 0.5, 0.9],
            [0.8, 0.1, 0.3],
        ] {
            let out = post.apply_rgb(rgb);
            for c in 0..3 {
                assert!((out[c] - rgb[c]).abs() < 2e-4, "{rgb:?} -> {out:?}");
            }
        }
    }

    #[test]
    fn tone_curves_rise_and_keep_their_ends() {
        for (b, c) in [
            (100.0, 0.0),
            (-100.0, 0.0),
            (0.0, 100.0),
            (0.0, -100.0),
            (60.0, -40.0),
        ] {
            let p = params(|p| {
                p.brightness = b;
                p.contrast = c;
            });
            assert!(tone(&p, 0.0).abs() < 1e-12 && (tone(&p, 1.0) - 1.0).abs() < 1e-12);
            let values: Vec<f64> = (0..=100).map(|i| tone(&p, i as f64 / 100.0)).collect();
            assert!(values.windows(2).all(|w| w[1] >= w[0]), "b {b} c {c}");
        }
        assert!(tone(&params(|p| p.brightness = 50.0), PIVOT) > PIVOT);
        assert!(tone(&params(|p| p.contrast = 50.0), 0.3) < 0.3);
        assert!(tone(&params(|p| p.contrast = 50.0), 0.7) > 0.7);
    }

    #[test]
    fn whites_and_blacks_move_the_end_points() {
        assert_eq!(tone(&params(|p| p.whites = 100.0), 1.0 - LEVELS_RANGE), 1.0);
        assert!(tone(&params(|p| p.whites = -100.0), 1.0) < 0.9);
        assert_eq!(tone(&params(|p| p.blacks = -100.0), LEVELS_RANGE), 0.0);
        assert!(tone(&params(|p| p.blacks = 100.0), 0.0) > 0.1);
    }

    #[test]
    fn saturation_keeps_lightness_and_greys() {
        let mono = PostProcess::new(&params(|p| p.saturation = -100.0), false, "sRGB");
        let luma = |c: [f32; 3]| mono.oklab(c)[0];
        let out = mono.apply_rgb([0.6, 0.2, 0.1]);
        assert!((out[0] - out[1]).abs() < 1e-4 && (out[1] - out[2]).abs() < 1e-4, "{out:?}");
        assert!((luma(out) - luma([0.6, 0.2, 0.1])).abs() < 1e-3);
        let vivid = PostProcess::new(&params(|p| p.saturation = 100.0), false, "sRGB");
        assert_eq!(
            vivid.apply_rgb([0.4, 0.4, 0.4]).map(|v| (v * 1e4).round()),
            [4000.0; 3]
        );
        let out = vivid.apply_rgb([0.9, 0.3, 0.1]);
        assert!(out.iter().all(|v| (0.0..=1.0).contains(v)));
        assert!((luma(out) - luma([0.9, 0.3, 0.1])).abs() < 1e-3);
        assert!(out[0] - out[2] > 0.8);
    }

    #[test]
    fn brightening_a_bright_colour_stays_in_gamut() {
        let post = PostProcess::new(
            &params(|p| {
                p.brightness = 100.0;
                p.whites = 100.0;
            }),
            true,
            "sRGB",
        );
        let out = post.apply_rgb([1.0, 0.9, 0.2]);
        assert!(out.iter().all(|v| (0.0..=1.0).contains(v)), "{out:?}");
    }

    #[test]
    fn monochrome_follows_the_output_space() {
        // A ProPhoto primary turns the grey of its own lightness, in ProPhoto's
        // primaries and D50 white.
        let mono = PostProcess::new(&params(|p| p.saturation = -100.0), false, "ProPhoto RGB");
        for rgb in [[1.0, 0.0, 0.0], [0.0, 0.0, 1.0]] {
            let out = mono.apply_rgb(rgb);
            assert!((out[0] - out[1]).abs() < 1e-3 && (out[1] - out[2]).abs() < 1e-3, "{rgb:?} -> {out:?}");
            assert!((mono.oklab(out)[0] - mono.oklab(rgb)[0]).abs() < 1e-3, "{rgb:?} -> {out:?}");
        }
        assert_eq!(luminance_weights("unknown"), luminance_weights("sRGB"));
    }

    /// The same settings change a colour the same way whatever space it is
    /// encoded in: adjust in sRGB, or in ProPhoto RGB and convert.
    #[test]
    fn adjustments_agree_across_output_spaces() {
        use crate::stages::scanning::convert_output;
        // Tone only: a saturation boost stops at each space's own gamut
        // boundary, which is the point of a wider output space.
        let edit = params(|p| {
            p.brightness = 30.0;
            p.contrast = 25.0;
            p.whites = -10.0;
        });
        let colours = [[0.8f32, 0.3, 0.2], [0.2, 0.5, 0.7], [0.46, 0.46, 0.46], [0.9, 0.85, 0.1], [0.05, 0.04, 0.03]];
        let srgb = ImageBuf::from_data(5, 1, colours.iter().flatten().map(|&v| from_f32(v)).collect());
        let mut prophoto = srgb.clone();
        convert_output(&mut prophoto, "sRGB", "ProPhoto RGB", true);
        let a = PostProcess::new(&edit, true, "sRGB").applied(&srgb);
        let mut b = PostProcess::new(&edit, true, "ProPhoto RGB").applied(&prophoto);
        convert_output(&mut b, "ProPhoto RGB", "sRGB", true);
        for (x, y) in a.data.iter().zip(&b.data) {
            // f32 tables and arithmetic, and two conversions.
            assert!((to_f32(*x) - to_f32(*y)).abs() < 2e-3, "{:?} vs {:?}", a.data, b.data);
        }
    }
    // MARK: The pinned tone curve

    /// Pins bend the tones the four knobs produced, so a pin that holds its
    /// tone leaves a photograph with Post edits exactly as it was.
    #[test]
    fn a_holding_pin_keeps_the_knobs_edit() {
        let knobs = params(|p| p.brightness = 40.0);
        let plain = PostProcess::new(&knobs, true, "sRGB");
        let tone = measured_lstar(
            &ImageBuf::from_data(1, 1, vec![from_f32(0.4); 3]), &knobs, true, "sRGB", (0.5, 0.5), 0.0,
        )
        .unwrap() as f32;
        let mut pinned = knobs.clone();
        pinned.tone_anchors = vec![pin(tone, tone)];
        let pinned = PostProcess::new(&pinned, true, "sRGB");
        for v in [0.2f32, 0.4, 0.6, 0.8] {
            let (a, b) = (plain.apply_rgb([v; 3]), pinned.apply_rgb([v; 3]));
            assert!((a[0] - b[0]).abs() < 2e-3, "{v}: {a:?} vs {b:?}");
        }
    }

    /// A pin's input is the tone before the pins: the curve it joins must not
    /// change what it reads.
    #[test]
    fn measuring_ignores_the_pins_already_on_the_curve() {
        let image = ImageBuf::from_data(2, 1, vec![from_f32(0.2), from_f32(0.2), from_f32(0.2), from_f32(0.6), from_f32(0.6), from_f32(0.6)]);
        let mut pinned = PostParams::default();
        let before = measured_lstar(&image, &pinned, true, "sRGB", (0.25, 0.5), 0.0).unwrap();
        pinned.tone_anchors = vec![pin(70.0, 20.0)];
        let after = measured_lstar(&image, &pinned, true, "sRGB", (0.25, 0.5), 0.0).unwrap();
        assert!((before - after).abs() < 1e-6, "{before} vs {after}");
        // sRGB 0.2 is L* 21.2.
        assert!((before - 21.2).abs() < 0.2, "{before}");
    }

    #[test]
    fn measuring_averages_the_circle_and_stays_on_the_photograph() {
        let mut image = ImageBuf::new(40, 40);
        for y in 0..40 { for x in 0..40 {
            let v = from_f32(if x < 20 { 0.2 } else { 0.6 });
            image.set(x, y, [v, v, v]);
        } }
        let post = PostParams::default();
        let dark = measured_lstar(&image, &post, true, "sRGB", (0.1, 0.5), 0.0).unwrap();
        let light = measured_lstar(&image, &post, true, "sRGB", (0.9, 0.5), 0.0).unwrap();
        let both = measured_lstar(&image, &post, true, "sRGB", (0.5, 0.5), 0.25).unwrap();
        assert!((both - (dark + light) / 2.0).abs() < 1.0, "{dark} {light} {both}");
        assert!(measured_lstar(&image, &post, true, "sRGB", (1.5, 0.5), 0.0).is_none());
        assert!(measured_lstar(&image, &post, true, "sRGB", (0.5, -0.5), 0.0).is_none());
    }

    fn pin(input: f32, target: f32) -> ToneAnchor {
        ToneAnchor { input, target, source: None }
    }

    #[test]
    fn a_crossed_pair_reports_the_one_it_drops() {
        let curve = AnchorCurve::new(&[pin(25.0, 60.0), pin(50.0, 20.0)]);
        assert_eq!(curve.ignored(), &[1]);
        assert!((curve.map(25.0) - 60.0).abs() < 1e-9);
    }

    #[test]
    fn order_does_not_change_which_tone_is_kept() {
        let a = AnchorCurve::new(&[pin(25.0, 60.0), pin(50.0, 20.0)]);
        let b = AnchorCurve::new(&[pin(50.0, 20.0), pin(25.0, 60.0)]);
        assert_eq!(a, b);
        assert_eq!((a.ignored(), b.ignored()), (&[1usize][..], &[0usize][..]));
    }

    #[test]
    fn crossed_end_points_report_the_white_point() {
        let curve = AnchorCurve::new(&[pin(70.0, 0.0), pin(40.0, 100.0)]);
        assert_eq!(curve.ignored(), &[1]);
        assert_eq!(curve.map(60.0), 0.0);
        assert!((curve.map(100.0) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn a_pin_outside_the_ends_is_ignored() {
        assert_eq!(AnchorCurve::new(&[pin(30.0, 0.0), pin(20.0, 50.0)]).ignored(), &[1]);
        assert_eq!(AnchorCurve::new(&[pin(80.0, 100.0), pin(90.0, 50.0)]).ignored(), &[1]);
    }

    #[test]
    fn non_finite_pins_are_ignored() {
        assert_eq!(AnchorCurve::new(&[pin(f32::NAN, 50.0), pin(50.0, 40.0)]).ignored(), &[0]);
    }

    /// The steepest change of slope over small steps of the curve.
    fn sharpest_corner(curve: &AnchorCurve) -> f64 {
        let step = 0.05;
        let slopes: Vec<f64> = (0..2000)
            .map(|i| {
                let x = f64::from(i) * step;
                (curve.map(x + step) - curve.map(x)) / step
            })
            .collect();
        slopes.windows(2).map(|w| (w[1] - w[0]).abs()).fold(0.0, f64::max)
    }

    /// No corners at the pins: the slope changes gradually through each one.
    #[test]
    fn the_curve_has_no_corners_at_its_pins() {
        let curve = AnchorCurve::new(&[pin(20.0, 10.0), pin(50.0, 60.0), pin(70.0, 70.0)]);
        assert!(sharpest_corner(&curve) < 0.1, "{}", sharpest_corner(&curve));
    }

    /// A black or white point eases in rather than clipping at a corner.
    #[test]
    fn black_and_white_points_ease_in() {
        let curve = AnchorCurve::new(&[pin(20.0, 0.0), pin(50.0, 50.0), pin(85.0, 100.0)]);
        assert!(sharpest_corner(&curve) < 0.1, "{}", sharpest_corner(&curve));
        assert_eq!(curve.map(20.0), 0.0);
        assert_eq!(curve.map(85.0), 100.0);
        assert!(curve.map(21.0) < 1.0, "{}", curve.map(21.0));
    }

    /// Smoothing never moves a pin, overshoots between pins or turns back.
    #[test]
    fn smoothing_keeps_every_pin_exact_and_the_curve_rising() {
        let sets = [
            vec![pin(30.0, 20.0)],
            vec![pin(10.0, 40.0), pin(12.0, 41.0), pin(80.0, 42.0), pin(82.0, 90.0)],
            vec![pin(25.0, 0.0), pin(30.0, 50.0), pin(35.0, 55.0), pin(90.0, 100.0)],
        ];
        for anchors in sets {
            let curve = AnchorCurve::new(&anchors);
            for anchor in &anchors {
                assert!((curve.map(f64::from(anchor.input)) - f64::from(anchor.target)).abs() < 1e-9, "{anchor:?}");
            }
            let mut previous = -1.0;
            for i in 0..=2000 {
                let value = curve.map(f64::from(i) * 0.05);
                assert!(value >= previous - 1e-12 && (0.0..=100.0).contains(&value), "{anchors:?} at {i}: {value}");
                previous = value;
            }
            // Between two close pins with nearly equal targets it stays between them.
            if anchors.len() == 4 && anchors[1].target == 41.0 {
                let between = curve.map(50.0);
                assert!((41.0..=42.0).contains(&between), "{between}");
            }
        }
    }

    /// A pin that doesn't move its tone leaves the photograph alone.
    #[test]
    fn a_pin_on_its_own_tone_stays_the_identity() {
        let curve = AnchorCurve::new(&[pin(50.0, 50.0)]);
        for value in [0.0, 12.5, 50.0, 87.0, 100.0] {
            assert!((curve.map(value) - value).abs() < 1e-9, "{value}");
        }
    }

    /// Pins on one zone count as one reading: their average prints as the zone.
    #[test]
    fn pins_on_a_zone_average_their_readings() {
        let curve = AnchorCurve::new(&[pin(40.0, 50.0), pin(60.0, 50.0)]);
        assert!((curve.map(50.0) - 50.0).abs() < 1e-9, "{}", curve.map(50.0));
        assert!(curve.map(40.0) < 50.0 && curve.map(60.0) > 50.0);
        assert!(curve.ignored().is_empty());

        let curve = AnchorCurve::new(&[pin(40.0, 30.0), pin(60.0, 30.0), pin(20.0, 30.0)]);
        assert!((curve.map(40.0) - 30.0).abs() < 1e-9);
    }

    #[test]
    fn pins_on_black_and_white_average_too() {
        let curve = AnchorCurve::new(&[pin(10.0, 0.0), pin(30.0, 0.0), pin(70.0, 100.0), pin(90.0, 100.0)]);
        assert_eq!(curve.map(20.0), 0.0);
        assert!(curve.map(25.0) > 0.0, "The black point is the average, not the brightest");
        assert_eq!(curve.map(80.0), 100.0);
        assert!(curve.map(75.0) < 100.0, "The white point is the average, not the darkest");
        assert!(curve.ignored().is_empty());
    }

    /// A zone the curve can't honour marks every pin on it.
    #[test]
    fn a_dropped_zone_reports_all_its_pins() {
        let curve = AnchorCurve::new(&[pin(25.0, 60.0), pin(50.0, 20.0), pin(70.0, 20.0)]);
        assert_eq!(curve.ignored(), &[1, 2]);
    }

    #[test]
    fn averaging_ignores_the_order_of_the_pins() {
        let a = AnchorCurve::new(&[pin(40.0, 50.0), pin(60.0, 50.0), pin(20.0, 0.0)]);
        let b = AnchorCurve::new(&[pin(20.0, 0.0), pin(60.0, 50.0), pin(40.0, 50.0)]);
        assert_eq!(a, b);
    }

    #[test]
    fn no_pins_leave_the_tones_alone() {
        let curve = AnchorCurve::new(&[]);
        assert!(curve.is_identity());
        for value in [0.0, 5.0, 50.0, 99.0, 100.0] {
            assert_eq!(curve.map(value), value);
        }
    }

    #[test]
    fn a_pin_lands_on_its_target_without_moving_the_ends() {
        let curve = AnchorCurve::new(&[pin(50.0, 30.0)]);
        assert!((curve.map(50.0) - 30.0).abs() < 1e-9);
        assert_eq!(curve.map(0.0), 0.0);
        assert!((curve.map(100.0) - 100.0).abs() < 1e-9);
    }

    /// A pin aimed at black sets the black point, and a later pin elsewhere
    /// leaves it exactly where it was.
    #[test]
    fn a_black_point_pin_stays_put() {
        let curve = AnchorCurve::new(&[pin(30.0, 0.0), pin(60.0, 50.0)]);
        assert_eq!(curve.map(10.0), 0.0);
        assert_eq!(curve.map(30.0), 0.0);
        assert!((curve.map(60.0) - 50.0).abs() < 1e-9);
        assert!((curve.map(100.0) - 100.0).abs() < 1e-9);
    }

    #[test]
    fn a_white_point_pin_stays_put() {
        let curve = AnchorCurve::new(&[pin(80.0, 100.0), pin(40.0, 30.0)]);
        assert!((curve.map(80.0) - 100.0).abs() < 1e-9);
        assert!((curve.map(95.0) - 100.0).abs() < 1e-9);
        assert!((curve.map(40.0) - 30.0).abs() < 1e-9);
    }

    /// Only the zones matter, never the order: two pins aimed at black hold
    /// their average, whichever came first.
    #[test]
    fn pin_order_never_changes_the_curve() {
        let a = AnchorCurve::new(&[pin(30.0, 0.0), pin(10.0, 0.0), pin(60.0, 50.0)]);
        let b = AnchorCurve::new(&[pin(60.0, 50.0), pin(10.0, 0.0), pin(30.0, 0.0)]);
        assert_eq!(a, b);
        assert_eq!(a.map(20.0), 0.0, "everything under the black pins' average is black");
    }

    /// Two pins aimed at the same target make one knot, so the curve keeps rising
    /// instead of flattening.
    #[test]
    fn pins_on_one_target_make_one_knot() {
        let curve = AnchorCurve::new(&[pin(40.0, 50.0), pin(70.0, 50.0)]);
        assert!(curve.points.len() == 1);
        let mut previous = -1.0;
        for step in 0..=100 {
            let value = curve.map(step as f64);
            assert!(value >= previous, "L* {step}");
            previous = value;
        }
    }

    #[test]
    fn pins_keep_the_curve_rising_and_inside() {
        let curve = AnchorCurve::new(&[pin(25.0, 60.0), pin(50.0, 20.0), pin(75.0, 80.0)]);
        let mut previous = -1.0;
        for step in 0..=100 {
            let value = curve.map(step as f64);
            assert!((0.0..=100.0).contains(&value));
            assert!(value >= previous, "L* {step}: {value} < {previous}");
            previous = value;
        }
    }
}
