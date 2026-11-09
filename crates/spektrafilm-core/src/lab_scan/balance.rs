//! Per-frame auto colour correction: what a lab scanner's metering does to
//! make the frame's neutral land on the look's reference.

use spektrafilm_math::image::ImageBuf;

use crate::profile::Profile;

/// How a film is balanced and how its density reads as light: a negative
/// inverts, a positive (slide or B&W reversal) does not, and B&W is balanced
/// for density only.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FilmType {
    ColourNegative,
    Slide,
    BlackAndWhite { positive: bool },
}

impl FilmType {
    /// From the profile's `info.type` and channel model.
    pub fn of(film: &Profile) -> FilmType {
        if film.is_bw() {
            FilmType::BlackAndWhite { positive: film.is_positive() }
        } else if film.is_positive() {
            FilmType::Slide
        } else {
            FilmType::ColourNegative
        }
    }

    /// The sign that turns net density into a signal rising with the
    /// scene's light: +1 for a negative, -1 for a positive (slide or B&W
    /// reversal).
    pub fn sign(self) -> f64 {
        match self {
            FilmType::Slide | FilmType::BlackAndWhite { positive: true } => -1.0,
            FilmType::ColourNegative | FilmType::BlackAndWhite { positive: false } => 1.0,
        }
    }
}

/// The log10 value subtracted per channel, in the signed log signal space
/// ([`FilmType::sign`] times net: `+net` for negatives, `-net` for slides and
/// B&W reversal).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Balance {
    pub offset: [f64; 3],
}

/// Each channel's offset stays within this of the three channels' mean.
const MAX_CAST_LOG10: f64 = 0.6;
/// A pixel counts as exposed above this net density.
const THIN_DENSITY: f64 = 0.02;
/// Fewer exposed pixels than this fraction and the frame is too thin to judge.
const THIN_FRACTION: f64 = 0.01;

/// Meter `net`, the scanner density above film base of the frame.
/// `default_offset` is the type's trained mean, used when the frame is too
/// thin to judge.
pub fn meter(net: &ImageBuf, film_type: FilmType, default_offset: [f64; 3]) -> Balance {
    let sign = film_type.sign();
    let mut chans: [Vec<f64>; 3] = [Vec::new(), Vec::new(), Vec::new()];
    let mut total = 0usize;
    let mut exposed = 0usize;
    for px in net.data.chunks_exact(3) {
        total += 1;
        let v = [px[0] as f64, px[1] as f64, px[2] as f64];
        if !v.iter().all(|x| x.is_finite()) {
            continue;
        }
        if v.iter().cloned().fold(f64::MIN, f64::max) > THIN_DENSITY {
            exposed += 1;
        }
        for c in 0..3 {
            chans[c].push(sign * v[c]);
        }
    }
    if total == 0 || (exposed as f64) < THIN_FRACTION * total as f64 || exposed == 0 {
        return Balance { offset: default_offset };
    }
    let mut offset = [0.0; 3];
    for c in 0..3 {
        offset[c] = trimmed_mean(&mut chans[c]);
    }
    let mean = (offset[0] + offset[1] + offset[2]) / 3.0;
    match film_type {
        FilmType::BlackAndWhite { .. } => offset = [mean; 3],
        _ => offset.iter_mut().for_each(|o| {
            *o = mean + (*o - mean).clamp(-MAX_CAST_LOG10, MAX_CAST_LOG10);
        }),
    }
    Balance { offset }
}

/// Mean of the 5th to 95th percentile of `v`.
fn trimmed_mean(v: &mut [f64]) -> f64 {
    v.sort_by(|a, b| a.total_cmp(b));
    let n = v.len();
    let lo = (n as f64 * 0.05).floor() as usize;
    let hi = ((n as f64 * 0.95).ceil() as usize).clamp(lo + 1, n);
    let s = &v[lo..hi];
    s.iter().sum::<f64>() / s.len() as f64
}
