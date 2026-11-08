//! Local Contrast: RPP's unsharp mask on lightness (`lab-stages.md` §8), on
//! OKLab L of the finished scan. Chroma and hue are left alone. Detail lighter
//! than its surroundings is lifted at 3/7 the strength of darker detail,
//! which is what keeps it from building bright halos. As in RPP, a stronger
//! setting also widens the blur, so it brings out larger shapes too; the
//! radius is a share of the picture, so the preview and the export match.
use rayon::prelude::*;
use spektrafilm_math::colorspace::RgbColourspace;
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::{from_f32, to_f32};

use crate::post::{lms_matrices, oklab_from, oklab_m2_inv, oklab_to, Transfer};

/// The blur radius at 100, as a share of the picture's shorter side.
const RADIUS_AT_FULL: f64 = 0.02;
/// Lighter-than-surroundings detail is scaled by this, as RPP's is.
const LIGHT_DETAIL: f32 = 3.0 / 7.0;

/// Applies Local Contrast at `amount` (0 to 100) to a scan clipped to [0, 1],
/// encoded with its output space's curve if `encoded`.
pub fn apply(image: &mut ImageBuf, amount: f32, encoded: bool, color_space: &str) {
    if amount <= 0.0 || image.width == 0 || image.height == 0 {
        return;
    }
    let (w, h) = (image.width as usize, image.height as usize);
    let transfer = Transfer(RgbColourspace::output(color_space));
    let (to_lms, from_lms) = lms_matrices(color_space);
    let m2_inv = oklab_m2_inv();
    let lab: Vec<[f32; 3]> = image
        .data
        .par_chunks_exact(3)
        .map(|px| {
            let c = [0, 1, 2].map(|i| {
                let v = to_f32(px[i]).clamp(0.0, 1.0);
                if encoded { transfer.decode(v as f64) as f32 } else { v }
            });
            oklab_from(&to_lms, c)
        })
        .collect();
    let lightness: Vec<f32> = lab.iter().map(|c| c[0]).collect();
    let radius = ((amount as f64 / 100.0) * RADIUS_AT_FULL * w.min(h) as f64).round().max(1.0) as usize;
    let blurred = blur(&lightness, w, h, radius);
    let k = amount / 100.0 + 0.1;
    image.data.par_chunks_exact_mut(3).zip(lab.par_iter().zip(&blurred)).for_each(|(px, (c, b))| {
        let mut d = c[0] - b;
        if d > 0.0 {
            d *= LIGHT_DETAIL;
        }
        let rgb = oklab_to(&from_lms, &m2_inv, [c[0] + k * d, c[1], c[2]]);
        for i in 0..3 {
            let v = rgb[i].clamp(0.0, 1.0);
            px[i] = from_f32(if encoded { transfer.encode(v as f64) as f32 } else { v });
        }
    });
}

/// Three box passes each way: close to a Gaussian, at any radius.
fn blur(plane: &[f32], w: usize, h: usize, radius: usize) -> Vec<f32> {
    let mut a = plane.to_vec();
    let mut b = vec![0.0; a.len()];
    for _ in 0..3 {
        b.par_chunks_mut(w).zip(a.par_chunks(w)).for_each(|(out, row)| box_line(row, out, radius));
        let mut columns = vec![0.0; a.len()];
        // Columns as rows of the transposed plane.
        columns.par_chunks_mut(h).enumerate().for_each(|(x, out)| {
            let column: Vec<f32> = (0..h).map(|y| b[y * w + x]).collect();
            box_line(&column, out, radius);
        });
        for x in 0..w {
            for y in 0..h {
                a[y * w + x] = columns[x * h + y];
            }
        }
    }
    a
}

/// A running-sum box of `radius` along `line`, its ends held.
fn box_line(line: &[f32], out: &mut [f32], radius: usize) {
    let n = line.len() as isize;
    let r = radius as isize;
    let at = |i: isize| line[i.clamp(0, n - 1) as usize] as f64;
    let mut sum: f64 = (-r..=r).map(at).sum();
    let width = (2 * r + 1) as f64;
    for i in 0..n {
        out[i as usize] = (sum / width) as f32;
        sum += at(i + r + 1) - at(i - r);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use spektrafilm_math::image::ImageBuf;
    use spektrafilm_math::precision::{from_f32, to_f32};

    fn flat(w: u32, h: u32, v: f32) -> ImageBuf {
        ImageBuf::from_data(w, h, vec![from_f32(v); (w * h * 3) as usize])
    }

    /// A vertical step from 0.3 to 0.7, encoded, after `apply`: how far the
    /// dark side dips below 0.3 and the light side rises past 0.7, as shares
    /// of the step.
    fn edge_overshoots(w: u32, h: u32, amount: f32) -> (f32, f32) {
        let data = (0..w * h).flat_map(|i| [if i % w < w / 2 { 0.3 } else { 0.7 }; 3]).map(from_f32).collect();
        let mut img = ImageBuf::from_data(w, h, data);
        apply(&mut img, amount, true, "sRGB");
        let mut dark = 0.0f32;
        let mut light = 0.0f32;
        for i in 0..(w * h) as usize {
            let v = to_f32(img.data[i * 3 + 1]);
            if (i as u32 % w) < w / 2 { dark = dark.max(0.3 - v) } else { light = light.max(v - 0.7) }
        }
        (dark / 0.4, light / 0.4)
    }

    #[test]
    fn a_flat_field_is_untouched_at_any_size() {
        for (w, h) in [(3, 2), (40, 30)] {
            let mut img = flat(w, h, 0.4);
            let before = img.data.clone();
            apply(&mut img, 100.0, true, "sRGB");
            assert!(img.data.iter().zip(&before).all(|(a, b)| (to_f32(*a) - to_f32(*b)).abs() < 1e-5));
        }
    }

    #[test]
    fn dark_detail_is_lifted_more_than_light_detail() {
        let (dark, light) = edge_overshoots(200, 100, 60.0);
        assert!(light > 0.0 && dark > 1.8 * light, "{dark} {light}");
    }

    #[test]
    fn the_effect_scales_with_the_picture() {
        let full = edge_overshoots(400, 200, 60.0);
        let half = edge_overshoots(200, 100, 60.0);
        assert!((full.0 - half.0).abs() < 0.15 * full.0, "{full:?} {half:?}");
    }

    #[test]
    fn nothing_happens_at_zero() {
        let (dark, light) = edge_overshoots(60, 20, 0.0);
        assert_eq!((dark, light), (0.0, 0.0));
    }
}
