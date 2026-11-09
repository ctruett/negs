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
