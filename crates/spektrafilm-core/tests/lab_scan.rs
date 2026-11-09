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

// ---- The lab-scan route ----

use spektrafilm_core::lab_scan::balance::Balance;
use spektrafilm_core::params::{OutputRoute, ScannerModel};
use spektrafilm_core::pipeline::Pipeline;
use spektrafilm_gpu::cpu_backend::CpuBackend;

/// Lab-scan params with the pixel-pitch and random effects off, so a
/// uniform patch stays uniform.
fn lab_params(model: ScannerModel) -> RuntimeParams {
    let mut params = RuntimeParams::default();
    params.io.output_route = OutputRoute::LabScan;
    params.scanner.model = model;
    params.film_render.grain.active = false;
    params.film_render.halation.active = false;
    params.io.input_cctf_decoding = false;
    params
}

fn lab_pipeline(stock: &str, params: RuntimeParams) -> Pipeline {
    let data = data_dir();
    let film = profile::load_profile_by_name(&data, stock).unwrap();
    let print = profile::load_profile_by_name(&data, "kodak_portra_endura").unwrap();
    Pipeline::new_with_spectral(film, print, params, &data).unwrap()
}

fn render(stock: &str, params: RuntimeParams, image: ImageBuf) -> ImageBuf {
    lab_pipeline(stock, params).process(image, &CpuBackend)
}

fn px(image: &ImageBuf, x: u32, y: u32) -> [f64; 3] {
    image.get(x, y).map(|v| v as f64)
}

/// Left half `a`, right half `b`, 16x16.
fn two_patches(a: [f64; 3], b: [f64; 3]) -> ImageBuf {
    let data = (0..16 * 16)
        .flat_map(|i| if i % 16 < 8 { a } else { b }.map(from_f64))
        .collect();
    ImageBuf::from_data(16, 16, data)
}

#[test]
fn negative_is_inverted() {
    let out = render("kodak_portra_400", lab_params(ScannerModel::Frontier), two_patches([0.05; 3], [0.4; 3]));
    let (dark, bright) = (px(&out, 3, 8), px(&out, 12, 8));
    for c in 0..3 {
        assert!(bright[c] > dark[c] + 0.05, "channel {c}: {dark:?} vs {bright:?}");
    }
}

/// B&W keeps its tint: a grey card scans as the look's cast on 18%, in
/// Rec. 2020, where the look works.
#[test]
fn bw_grey_card_carries_the_looks_tint() {
    use spektrafilm_core::lab_scan::{balance::FilmType, look::Look};
    for model in [ScannerModel::Frontier, ScannerModel::Noritsu] {
        let mut params = lab_params(model);
        params.io.output_cctf_encoding = false;
        params.io.output_color_space = "ITU-R BT.2020".into();
        let v = px(&render("kodak_doublex", params, uniform([0.18; 3])), 1, 1);
        let look = Look::load(&data_dir(), model, FilmType::BlackAndWhite { positive: false }).unwrap();
        let want = look.apply([0.0; 3]).map(|v| 10f64.powf(v));
        for c in 0..3 {
            assert!((v[c] / want[c] - 1.0).abs() < 0.005, "{model:?}: {v:?} vs {want:?}");
        }
    }
}

/// Colour films scan a grey card neutral, at 18%.
#[test]
fn grey_card_is_neutral() {
    for stock in ["kodak_portra_400", "fujifilm_provia_100f"] {
        for model in [ScannerModel::Frontier, ScannerModel::Noritsu] {
            let mut params = lab_params(model);
            params.io.output_cctf_encoding = false;
            let out = render(stock, params, uniform([0.18; 3]));
            let v = px(&out, 1, 1);
            let (lo, hi) = (v.iter().cloned().fold(f64::MAX, f64::min), v.iter().cloned().fold(f64::MIN, f64::max));
            assert!(hi - lo <= 0.005 * hi, "{stock} {model:?}: {v:?}");
            // The look's reference grey: an 18% card scans as 18%.
            assert!((v[1] - 0.18).abs() < 1e-3, "{stock} {model:?}: {v:?}");
        }
    }
}

#[test]
fn keys_move_the_scan() {
    let grey = |edit: &dyn Fn(&mut RuntimeParams)| {
        let mut params = lab_params(ScannerModel::Frontier);
        params.io.output_cctf_encoding = false;
        edit(&mut params);
        px(&render("kodak_portra_400", params, uniform([0.18; 3])), 1, 1)
    };
    let plain = grey(&|_| {});
    let darker = grey(&|p| p.scanner.density_key = 4.0);
    for c in 0..3 {
        assert!(darker[c] < plain[c] * 0.95, "{plain:?} vs {darker:?}");
    }
    let yellow = grey(&|p| p.scanner.yellow_key = 4.0);
    let warmth = |v: [f64; 3]| (v[0] + v[1]) / 2.0 / v[2];
    assert!(warmth(yellow) > warmth(plain) * 1.05, "{plain:?} vs {yellow:?}");
}

/// The scanner's density is locked against the photographer's exposure:
/// Camera exposure and Zone Shift are metered out, so they reach the scan.
#[test]
fn exposure_edits_pass_through_the_balance() {
    let preview = two_patches([0.05; 3], [0.4; 3]);
    let balance = |edit: &dyn Fn(&mut RuntimeParams)| {
        let mut params = lab_params(ScannerModel::Frontier);
        edit(&mut params);
        lab_pipeline("kodak_portra_400", params).lab_balance(&preview).offset
    };
    let plain = balance(&|_| {});
    assert_eq!(balance(&|p| p.prep.exposure_ev = 1.0), plain);
    assert_eq!(balance(&|p| p.camera.exposure_compensation_ev = -1.0), plain);

    let grey = |ev: f32| {
        let mut params = lab_params(ScannerModel::Frontier);
        params.io.output_cctf_encoding = false;
        params.prep.exposure_ev = ev;
        px(&render("kodak_portra_400", params, uniform([0.18; 3])), 1, 1)
    };
    let (plain, brighter) = (grey(0.0), grey(1.0));
    for c in 0..3 {
        assert!(brighter[c] > plain[c] * 1.3, "{plain:?} vs {brighter:?}");
    }
}

#[test]
fn lab_scan_skips_resident_chain() {
    let image = ImageBuf::from_data(
        32,
        32,
        (0..32 * 32 * 3).map(|i| from_f64(0.02 + 0.8 * ((i * 37 % 101) as f64 / 100.0))).collect(),
    );
    let params = lab_params(ScannerModel::Frontier);
    let pipeline = lab_pipeline("kodak_portra_400", params.clone());
    let backend = spektrafilm_gpu::select_backend();
    assert!(pipeline.process_resident_borrowed(&image, backend.as_ref()).is_none());
    let default = pipeline.process(image.clone(), backend.as_ref());
    let cpu = pipeline.process(image.clone(), &CpuBackend);
    for (a, b) in default.data.iter().zip(&cpu.data) {
        assert!((*a as f64 - *b as f64).abs() <= 1.0 / 255.0, "{} vs {}", a, b);
    }
    // And it is the lab scanner's, not the upstream film scan's.
    let mut upstream = params;
    upstream.settings.upstream_film_scan = true;
    let old = render("kodak_portra_400", upstream, image);
    let differs = old.data.iter().zip(&cpu.data).any(|(a, b)| (*a as f64 - *b as f64).abs() > 0.02);
    assert!(differs, "the lab scan rendered the upstream film scan");
}

#[test]
fn zone_readout_uses_photo_balance() {
    let data = data_dir();
    let image = two_patches([0.06, 0.05, 0.04], [0.45, 0.4, 0.3]);
    let params = lab_params(ScannerModel::Noritsu);
    let pipeline = lab_pipeline("kodak_portra_400", params.clone());
    let preview = spektrafilm_core::stages::filming::metering_preview(&image);
    let ae = pipeline.autoexposure_ev(&preview);
    let balance: Balance = pipeline.lab_balance(&preview);
    let out = pipeline.with_lab_balance(balance).process(image.clone(), &CpuBackend);
    let lstar = |v: [f64; 3]| {
        let lin = v.map(|e| if e <= 0.04045 { e / 12.92 } else { ((e + 0.055) / 1.055).powf(2.4) });
        let y = 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
        if y > 216.0 / 24389.0 { 116.0 * y.cbrt() - 16.0 } else { y * 24389.0 / 27.0 }
    };
    for (x, corners) in [(3, [(0.1, 0.3), (0.35, 0.7)]), (12, [(0.6, 0.3), (0.9, 0.7)])] {
        let rendered = lstar(px(&out, x, 8));
        let reading = spektrafilm_core::zones::readout(
            &data, "kodak_portra_400", "kodak_portra_endura", &params, Some(ae), Some(balance), &image, corners, &[],
        )
        .unwrap();
        assert!((reading.printed - rendered).abs() < 0.5, "x {x}: read {} vs rendered {rendered}", reading.printed);
    }
}

/// The fitting tool renders a look under test from its own file.
#[test]
fn look_override_replaces_the_look() {
    let text = std::fs::read_to_string(data_dir().join("scanners/frontier.toml")).unwrap();
    let brighter = text.replace("-0.744727494896694,", "-0.644727494896694,");
    assert_ne!(brighter, text);
    let path = std::env::temp_dir().join(format!("lab-look-override-{}.toml", std::process::id()));
    std::fs::write(&path, brighter).unwrap();
    let grey = |look: Option<String>| {
        let mut params = lab_params(ScannerModel::Frontier);
        params.io.output_cctf_encoding = false;
        params.settings.lab_look_override = look;
        px(&render("kodak_portra_400", params, uniform([0.18; 3])), 1, 1)
    };
    let (plain, overridden) = (grey(None), grey(Some(path.to_string_lossy().into())));
    std::fs::remove_file(&path).ok();
    for c in 0..3 {
        let ratio = overridden[c] / plain[c];
        assert!((ratio - 10f64.powf(0.1)).abs() < 0.01, "{plain:?} vs {overridden:?}");
    }
}

/// A caller that re-renders one frame keeps its developed film: the scanner
/// and its keys come after the film, so changing them scans it again
/// without developing it again. Anything before the scan develops anew.
#[test]
fn developed_frame_is_reused_for_the_scanner_only() {
    use spektrafilm_core::pipeline::DevelopedFrame;
    let image = two_patches([0.05, 0.1, 0.2], [0.4, 0.3, 0.2]);
    let slot = DevelopedFrame::default();
    let render_with = |params: RuntimeParams, slot: Option<&DevelopedFrame>| {
        let mut pipeline = lab_pipeline("kodak_portra_400", params);
        if let Some(slot) = slot {
            pipeline = pipeline.with_developed_frame(slot.clone());
        }
        pipeline.process(image.clone(), &CpuBackend).data
    };
    let frontier = lab_params(ScannerModel::Frontier);
    assert_eq!(render_with(frontier.clone(), Some(&slot)), render_with(frontier.clone(), None));
    assert_eq!(slot.reuses(), 0);

    let mut noritsu = lab_params(ScannerModel::Noritsu);
    noritsu.scanner.yellow_key = 3.0;
    assert_eq!(render_with(noritsu.clone(), Some(&slot)), render_with(noritsu.clone(), None));
    assert_eq!(slot.reuses(), 1, "the scanner and keys reuse the developed film");

    let mut exposed = noritsu.clone();
    exposed.camera.exposure_compensation_ev = 1.0;
    assert_eq!(render_with(exposed.clone(), Some(&slot)), render_with(exposed, None));
    assert_eq!(slot.reuses(), 1, "an exposure change develops the film again");

    let other = two_patches([0.3; 3], [0.1; 3]);
    let mut pipeline = lab_pipeline("kodak_portra_400", noritsu.clone()).with_developed_frame(slot.clone());
    let fresh = lab_pipeline("kodak_portra_400", noritsu).process(other.clone(), &CpuBackend).data;
    assert_eq!(pipeline.process(other, &CpuBackend).data, fresh, "another frame develops anew");
    pipeline = pipeline.with_developed_frame(slot.clone());
    drop(pipeline);
    assert_eq!(slot.reuses(), 1);
}

/// A frame with too little on it to meter (a lens cap on a negative, a blown
/// slide) takes the look's trained offset: it scans dark, or light, as
/// such a frame does at the lab, not as an 18% grey.
#[test]
fn thin_frames_scan_as_what_they_are() {
    for model in [ScannerModel::Frontier, ScannerModel::Noritsu] {
        let mut params = lab_params(model);
        params.camera.auto_exposure = false;
        params.io.output_cctf_encoding = false;
        let capped = px(&render("kodak_portra_400", params.clone(), uniform([0.0; 3])), 1, 1);
        assert!(capped.iter().all(|&v| v < 0.06), "{model:?} lens cap: {capped:?}");
        let blown = px(&render("fujifilm_provia_100f", params, uniform([40.0; 3])), 1, 1);
        assert!(blown.iter().all(|&v| v > 0.5), "{model:?} blown slide: {blown:?}");
    }
}

/// The operator's contrast key steepens the scan about the metered grey: a
/// grey card stays where it is, and the patches either side move apart.
#[test]
fn contrast_key_steepens_about_the_grey() {
    let scan = |contrast: f32, image: ImageBuf| {
        let mut params = lab_params(ScannerModel::Frontier);
        params.io.output_cctf_encoding = false;
        params.scanner.contrast_key = contrast;
        render("kodak_portra_400", params, image)
    };
    let grey = |c| px(&scan(c, uniform([0.18; 3])), 1, 1);
    for (a, b) in grey(0.0).iter().zip(grey(6.0)) {
        assert!((a - b).abs() < 1e-4, "the grey card stays: {a} vs {b}");
    }
    let spread = |c| {
        let out = scan(c, two_patches([0.05; 3], [0.5; 3]));
        px(&out, 12, 8)[1] / px(&out, 3, 8)[1]
    };
    assert!(spread(6.0) > spread(0.0) * 1.2, "{} vs {}", spread(6.0), spread(0.0));
    assert!(spread(-6.0) < spread(0.0) / 1.2);
}
