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
