//! Status M scanner densities of a developed film.

use std::path::Path;

use spektrafilm_core::lab_scan::density::{DensityLut, Sensitivity};
use spektrafilm_core::params::RuntimeParams;
use spektrafilm_core::profile;

fn data_dir() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data")
}

fn lut_for(stock: &str) -> DensityLut {
    let film = profile::load_profile_by_name(&data_dir(), stock).unwrap();
    let params = RuntimeParams::default();
    let sens = Sensitivity::load(&data_dir()).unwrap();
    DensityLut::new(&film, &params, &sens)
}

#[test]
fn sensitivity_rows_are_normalised_and_peak_where_tabulated() {
    let sens = Sensitivity::load(&data_dir()).unwrap();
    for (row, peak_nm) in sens.weights.iter().zip([640.0, 540.0, 450.0]) {
        assert_eq!(row.len(), 81);
        assert!((row.iter().sum::<f64>() - 1.0).abs() < 1e-12);
        let argmax = (0..81)
            .max_by(|&a, &b| row[a].partial_cmp(&row[b]).unwrap())
            .unwrap();
        assert_eq!(380.0 + 5.0 * argmax as f64, peak_nm);
    }
}

#[test]
fn base_has_zero_net_density() {
    let net = lut_for("kodak_portra_400").net([0.0; 3]);
    for c in net {
        assert!(c.abs() < 1e-6, "{net:?}");
    }
}

#[test]
fn density_rises_with_dye() {
    let lut = lut_for("kodak_portra_400");
    let hi = lut.net([0.5; 3]);
    let lo = lut.net([0.25; 3]);
    for c in 0..3 {
        assert!(hi[c] > lo[c], "channel {c}: {hi:?} vs {lo:?}");
    }
}

#[test]
fn bw_film_reads_near_neutral() {
    let net = lut_for("kodak_trix").net([1.0; 3]);
    let spread = net.iter().cloned().fold(f64::MIN, f64::max)
        - net.iter().cloned().fold(f64::MAX, f64::min);
    assert!(spread < 0.08, "{net:?}");
}

#[test]
fn apply_matches_net_per_pixel() {
    use spektrafilm_math::image::ImageBuf;
    let lut = lut_for("kodak_portra_400");
    let mut img = ImageBuf::new(2, 1);
    img.set(0, 0, [0.3, 0.6, 0.9]);
    img.set(1, 0, [0.0, 0.1, 0.2]);
    let out = lut.apply(&img);
    for x in 0..2 {
        let p = img.get(x, 0);
        let want = lut.net([p[0] as f64, p[1] as f64, p[2] as f64]);
        let got = out.get(x, 0);
        for c in 0..3 {
            assert!((got[c] as f64 - want[c]).abs() < 1e-4);
        }
    }
}

/// A 16x16 gradient with some colour, rendered on the Paper-print route.
fn paper_print_render() -> Vec<u8> {
    use spektrafilm_core::pipeline::Pipeline;
    use spektrafilm_gpu::cpu_backend::CpuBackend;
    use spektrafilm_math::{image::ImageBuf, precision::from_f64};
    let data = data_dir();
    let mut params = RuntimeParams::default();
    params.film_render.grain.active = false;
    params.film_render.halation.active = false;
    let film = profile::load_profile_by_name(&data, "kodak_portra_400").unwrap();
    let print = profile::load_profile_by_name(&data, "kodak_portra_endura").unwrap();
    let pipeline = Pipeline::new_with_spectral(film, print, params, &data).unwrap();
    let pixels = (0..16 * 16 * 3)
        .map(|i| {
            let (px, c) = (i / 3, i % 3);
            let (x, y) = ((px % 16) as f64 / 15.0, (px / 16) as f64 / 15.0);
            from_f64(0.02 + 0.9 * [x, y, (x + y) / 2.0][c])
        })
        .collect();
    let out = pipeline.process(ImageBuf::from_data(16, 16, pixels), &CpuBackend);
    out.data.iter().flat_map(|&v| (v as f32).to_le_bytes()).collect()
}

#[test]
fn paper_print_unchanged() {
    let got = paper_print_render();
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/paper_print_golden.bin");
    if std::env::var("WRITE_GOLDEN").is_ok() {
        std::fs::write(&path, &got).unwrap();
    }
    assert_eq!(got, std::fs::read(&path).unwrap(), "Paper-print render changed");
}

// ---- Frame auto correction ----

use spektrafilm_core::lab_scan::balance::{meter, FilmType};
use spektrafilm_math::image::ImageBuf;
use spektrafilm_math::precision::from_f64;

fn uniform(rgb: [f64; 3]) -> ImageBuf {
    let px = (0..16).flat_map(|_| rgb.map(from_f64)).collect();
    ImageBuf::from_data(4, 4, px)
}

fn spread(v: [f64; 3]) -> [f64; 3] {
    let m = (v[0] + v[1] + v[2]) / 3.0;
    v.map(|x| x - m)
}

#[test]
fn grey_frame_balances_neutral() {
    let lut = lut_for("kodak_portra_400");
    let net = lut.apply(&uniform([0.18; 3]));
    let n = net.get(0, 0).map(|v| v as f64);
    let b = meter(&net, FilmType::ColourNegative, [0.0; 3]);
    let (got, want) = (spread(b.offset), spread(n));
    for c in 0..3 {
        assert!((got[c] - want[c]).abs() < 1e-6, "{got:?} vs {want:?}");
    }
}

#[test]
fn red_frame_stays_finite_and_bounded() {
    let lut = lut_for("kodak_portra_400");
    let cmy = uniform([0.9, 0.05, 0.05]);
    let b = meter(&lut.apply(&cmy), FilmType::ColourNegative, [0.0; 3]);
    let s = spread(b.offset);
    for c in 0..3 {
        assert!(b.offset[c].is_finite());
        assert!(s[c].abs() <= 0.6 + 1e-9, "{:?}", b.offset);
    }
}

#[test]
fn black_frame_falls_back() {
    let net = ImageBuf::from_data(4, 4, vec![from_f64(0.0); 48]);
    let d = [0.01, -0.02, 0.03];
    let b = meter(&net, FilmType::ColourNegative, d);
    assert_eq!(b.offset, d);
}

#[test]
fn bw_keeps_tint() {
    let lut = lut_for("kodak_trix");
    let b = meter(&lut.apply(&uniform([0.8, 0.7, 0.9])), FilmType::BlackAndWhite { positive: true }, [0.0; 3]);
    assert!(b.offset[0].is_finite());
    assert_eq!(b.offset[0], b.offset[1]);
    assert_eq!(b.offset[1], b.offset[2]);
}

#[test]
fn slide_is_metered_with_inverted_sign() {
    let lut = lut_for("fujifilm_provia_100f");
    let net = lut.apply(&uniform([0.6; 3]));
    let neg = meter(&net, FilmType::ColourNegative, [0.0; 3]).offset;
    let sl = meter(&net, FilmType::Slide, [0.0; 3]).offset;
    for c in 0..3 {
        assert!((neg[c] + sl[c]).abs() < 1e-9);
    }
}

#[test]
fn bw_reversal_is_metered_with_inverted_sign() {
    let load = |s: &str| profile::load_profile_by_name(&data_dir(), s).unwrap();
    let net = lut_for("kodak_doublex").apply(&uniform([0.6; 3]));
    let neg = meter(&net, FilmType::of(&load("kodak_doublex")), [0.0; 3]).offset;
    let rev = meter(&net, FilmType::of(&load("kodak_trix")), [0.0; 3]).offset;
    assert!(neg[0].abs() > 0.01, "{neg:?}");
    for c in 0..3 {
        assert!((neg[c] + rev[c]).abs() < 1e-9, "{neg:?} vs {rev:?}");
    }
}

#[test]
fn balance_ignores_render_size() {
    use spektrafilm_core::pipeline::Pipeline;
    let data = data_dir();
    let make = |film_mm: f32| {
        let mut params = RuntimeParams::default();
        params.io.output_route = spektrafilm_core::params::OutputRoute::LabScan;
        params.camera.film_format_mm = film_mm;
        let film = profile::load_profile_by_name(&data, "kodak_portra_400").unwrap();
        let print = profile::load_profile_by_name(&data, "kodak_portra_endura").unwrap();
        Pipeline::new_with_spectral(film, print, params, &data).unwrap()
    };
    let preview = ImageBuf::from_data(
        8,
        8,
        (0..8 * 8 * 3).map(|i| from_f64(0.1 + 0.8 * ((i * 37 % 101) as f64 / 100.0))).collect(),
    );
    let a = make(35.0).lab_balance(&preview);
    let b = make(70.0).lab_balance(&preview);
    assert_eq!(a.offset, b.offset);
    assert!(a.offset.iter().all(|v| v.is_finite()));
}
