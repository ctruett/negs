//! The zone pins' curve bends the scene exposure at the end of Prep, so the
//! GPU-resident chain, which runs Prep on the CPU before uploading, renders
//! it as the CPU chain does, and an empty curve leaves the GPU's own exposure
//! fold in charge.

use spektrafilm_core::{params::RuntimeParams, pipeline::Pipeline, profile, zones::ZoneCurve};
use spektrafilm_gpu::{cpu_backend::CpuBackend, wgpu_backend::WgpuBackend};
use spektrafilm_math::{image::ImageBuf, precision::from_f64};
use std::path::Path;

fn pipeline(params: RuntimeParams) -> Pipeline {
    let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
    Pipeline::new_with_spectral(
        profile::load_profile_by_name(&data, "kodak_portra_400").unwrap(),
        profile::load_profile_by_name(&data, "kodak_portra_endura").unwrap(),
        params,
        &data,
    )
    .unwrap()
}

/// A smooth ramp from deep shadow to past white, tinted.
fn image() -> ImageBuf {
    let (w, h) = (128u32, 16u32);
    let data = (0..w * h)
        .flat_map(|i| {
            let (x, y) = ((i % w) as f64 / (w - 1) as f64, (i / w) as f64 / (h - 1) as f64);
            let level = 0.18 * (-7.0 + 11.0 * x).exp2();
            [level * (0.8 + 0.3 * y), level, level * (1.1 - 0.3 * y)]
        })
        .map(from_f64)
        .collect();
    ImageBuf::from_data(w, h, data)
}

fn params(curve: ZoneCurve) -> RuntimeParams {
    let mut params = RuntimeParams::default();
    params.camera.auto_exposure = false;
    params.film_render.grain.active = false;
    params.film_render.glare.active = false;
    params.print_render.glare.active = false;
    params.prep.zone_curve = curve;
    params
}

#[test]
fn the_zone_curve_renders_alike_on_the_gpu_and_cpu() {
    let Some(gpu) = WgpuBackend::new() else {
        assert!(std::env::var_os("SPEKTRAFILM_REQUIRE_GPU").is_none(), "no GPU adapter, and SPEKTRAFILM_REQUIRE_GPU is set");
        eprintln!("no GPU adapter available; skipping");
        return;
    };
    let curve = ZoneCurve::fit(&[(-3.0, -0.6), (0.0, 0.2), (2.0, 0.4)]);
    let bent = pipeline(params(curve));
    let cpu = bent.process(image(), &CpuBackend);
    let gpu_out = bent.process(image(), &gpu);
    let max = cpu.data.iter().zip(&gpu_out.data).map(|(a, b)| (*a as f64 - *b as f64).abs()).fold(0.0, f64::max);
    eprintln!("max |gpu - cpu| {max:.3e}");
    assert!(max < 1e-4, "GPU differs from CPU by {max}");
    // And the curve did something.
    let plain = pipeline(params(ZoneCurve::default())).process(image(), &CpuBackend);
    let moved = cpu.data.iter().zip(&plain.data).map(|(a, b)| (*a as f64 - *b as f64).abs()).fold(0.0, f64::max);
    assert!(moved > 0.02, "{moved}");
}

/// The steepest curve the pins may make doesn't posterize a smooth gradient:
/// the print still rises everywhere, in no step much bigger than the film's own
/// steepest, on a ramp a two-hundredth of a stop per pixel.
#[test]
fn the_steepest_curve_keeps_a_gradient_smooth() {
    let width = 2048u32;
    let stops = |i: u32| -7.0 + 11.0 * f64::from(i) / f64::from(width - 1);
    let ramp = ImageBuf::from_data(width, 1, (0..width).flat_map(|i| [from_f64(0.18 * stops(i).exp2()); 3]).collect());
    // Two zones a stop apart asked to sit four stops apart: the slope limit binds.
    let curve = ZoneCurve::fit(&[(-1.0, -1.5), (0.0, 1.5)]);
    let lightness = |curve: ZoneCurve| -> Vec<f64> {
        let mut params = params(curve);
        params.film_render.halation.active = false;
        let out = pipeline(params).process(ramp.clone(), &CpuBackend);
        // Green of the sRGB-encoded scan, as a stand-in for lightness.
        out.data.chunks_exact(3).map(|px| f64::from(px[1] as f32)).collect()
    };
    let (plain, bent) = (lightness(ZoneCurve::default()), lightness(curve));
    let steepest = |v: &[f64]| v.windows(2).map(|w| w[1] - w[0]).fold(0.0, f64::max);
    for w in bent.windows(2) {
        assert!(w[1] >= w[0] - 1e-6, "the print turns back");
    }
    let (a, b) = (steepest(&plain), steepest(&bent));
    eprintln!("steepest step: plain {a:.2e}, bent {b:.2e}");
    assert!(b <= a * steepest_allowed() + 1e-6, "steps of {b} against the film's {a}");
}

/// The curve's steepest, in stops out per stop in, with room for the cubic.
fn steepest_allowed() -> f64 {
    spektrafilm_core::zones::SLOPE.1 * 1.25
}
