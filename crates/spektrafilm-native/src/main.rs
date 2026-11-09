//! Private, serial JSON-lines protocol for the native macOS client.
//! stdout is protocol-only; diagnostics go to stderr. EOF releases all caches.
use anyhow::{Context, Result, bail, ensure};
use serde::Deserialize;
use serde_json::{Value, json};
use spektrafilm_core::{
    image_size,
    lab_scan::balance::Balance,
    params::RuntimeParams,
    pipeline::Pipeline,
    post::{PostParams, PostProcess},
    presets,
    preview::*,
    profile,
};
use spektrafilm_gpu::ComputeBackend;
use spektrafilm_io::{
    border::{BorderOptions, BorderStyle, add_border, extend_for_instagram},
    crop::Crop,
    encoding::Encoding,
    resize::{self, Fit},
};
use spektrafilm_core::stages::scanning::convert_output;
use spektrafilm_math::{colorspace::RgbColourspace, image::ImageBuf, precision::to_f32};
use std::{
    io::{BufRead, Write},
    path::{Path, PathBuf},
    time::Instant,
};

mod pipelines;

/// EditorModel.readPreview rejects larger preview buffers.
const DISPLAY_MAX_DIM: usize = 8192;

#[derive(Deserialize)]
struct Request {
    id: u64,
    #[serde(flatten)]
    command: Command,
}

#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum Command {
    /// The enlarger M/Y filter shifts that print a mid-grey neutral with
    /// these settings (upstream's print balance); image-independent.
    BalancePrint {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
    },
    Catalog,
    ExportLut {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        size: u32,
        output: PathBuf,
    },
    /// Unprocessed, identically framed source for the Windows original view.
    /// This does not replace the retained film render used by Save.
    /// A preset file's text (Python spektrafilm's GUI state) as the stocks
    /// and params to apply over `params`, which keeps what a preset doesn't
    /// carry (see `spektrafilm_core::presets::KEPT`). Without `params`, over
    /// the defaults: enough to check a file.
    PresetImport {
        text: String,
        #[serde(default)]
        params: Option<Box<RuntimeParams>>,
        /// Apply the preset's optional Finish section too.
        #[serde(default)]
        include_finish: bool,
    },
    /// The settings as a preset file's text.
    PresetExport {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        /// Write the optional Finish section.
        #[serde(default)]
        include_finish: bool,
    },
    /// A reading of the open photograph against the zones: where the area
    /// prints now, in L\*, and the stops of exposure that print it at each
    /// target. The corners are fractions of the uncropped photograph from its
    /// top left.
    ZoneReadout {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
        targets: Vec<f64>,
    },
    /// The Custom RAW white balance that makes an area of the photograph
    /// neutral: the area's mean, from the RAW developed at the neutral base.
    /// The corners are fractions of the uncropped photograph from its top left;
    /// equal corners pick the few pixels around a point.
    WbPick {
        input: PathBuf,
        params: Box<RuntimeParams>,
        x0: f64,
        y0: f64,
        x1: f64,
        y1: f64,
    },
    Original {
        input: PathBuf,
        params: Box<RuntimeParams>,
        limit_preview: bool,
        preview_path: PathBuf,
    },
    /// The colour space a RAW's camera preview says it's in, for the Mac's
    /// Match camera brightness reference (`spektrafilm_io::brightness::
    /// preview_colour_space`): "srgb", "adobe_rgb", "other" or null.
    PreviewColourSpace {
        input: PathBuf,
    },
    /// A colour-managed camera/original reference for clients without a
    /// native colour-managed extractor. Independent of retained render state.
    BrightnessReference {
        input: PathBuf,
        reference_path: PathBuf,
        expected_width: u32,
        expected_height: u32,
    },
    /// Fit the graded exposure to an embedded camera-preview reference without
    /// replacing the current render or changing the decoded source.
    PlaceExposure {
        input: PathBuf,
        source_generation: u64,
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        reference_path: PathBuf,
    },
    Render {
        input: PathBuf,
        #[serde(default)]
        source_generation: u64,
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        limit_preview: bool,
        preview_path: PathBuf,
        /// While a slider moves: render at this fraction of the photograph's
        /// size (the canvas resolution), a preview that is never saved.
        #[serde(default)]
        interactive_scale: Option<f32>,
        /// The crop, sent with an Image Size target only: the target describes
        /// the cropped photograph, so its extent sets the working size. The
        /// render itself is never cropped.
        #[serde(default)]
        crop: Option<Crop>,
    },
    /// A small render of the current source with another film/paper or a
    /// preset, for the stock and preset previews. Independent of the main render: it never replaces the
    /// retained output (Save) nor the cached main pipeline.
    Thumbnail {
        input: PathBuf,
        #[serde(default)]
        source_generation: u64,
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        /// The thumbnail's long edge in pixels.
        long_side: u32,
        /// Read a RAW no larger than this on its long side, where the decoder
        /// can, for a helper that only makes small frames. 0 reads all of it.
        #[serde(default)]
        decode_long_side: u32,
        preview_path: PathBuf,
        /// The photograph's crop. The whole frame is developed, as for the
        /// main preview, then cut, so grain and halation keep their scale.
        #[serde(default)]
        crop: Option<Crop>,
        /// A preset file's text, applied over `params` as `preset_import`
        /// applies it; its film and paper replace `film` and `paper`.
        #[serde(default)]
        preset: Option<String>,
        /// Apply the preset's optional Finish section too.
        #[serde(default)]
        include_finish: bool,
    },
    /// Frees the thumbnails' caches (the previews were turned off).
    ReleaseThumbnails,
    /// The tone graph's curve: `count` greys through film → print → scan
    /// (`spektrafilm_core::tone_curve`). Image-independent.
    ToneCurve {
        film: String,
        paper: String,
        params: Box<RuntimeParams>,
        #[serde(default)]
        count: Option<usize>,
    },
    Save {
        render_id: u64,
        output: PathBuf,
        #[serde(default)]
        save_options: spektrafilm_io::save::SaveOptions,
        /// Match the displayed preview and CLI: adjust before interpolating a
        /// straightened crop. Older clients retain their existing save order.
        #[serde(default)]
        crop_after_post: bool,
        #[serde(default)]
        border: Option<BorderStyle>,
        #[serde(default)]
        border_options: BorderOptions,
        /// Extend the border to Instagram's 3:4.
        #[serde(default)]
        instagram: bool,
        #[serde(default)]
        crop: Option<Crop>,
        /// Clockwise quarter turns. The preview is never rotated, so turning
        /// the photograph doesn't need a new render.
        #[serde(default)]
        rotate_cw: i32,
        /// Resample the saved file to this edge, after the border.
        #[serde(default)]
        fit: Option<Fit>,
    },
}

/// The mean colour of an area, leaving out pixels near clipping, which would
/// pull it towards the clipped channel; all of them if nothing else is left.
fn area_colour(image: &ImageBuf, corners: [(f64, f64); 2]) -> Option<[f64; 3]> {
    let (width, height) = (f64::from(image.width), f64::from(image.height));
    let to_px = |v: f64, size: f64| (v.clamp(0.0, 1.0) * size).min(size - 1.0).max(0.0) as u32;
    let (mut x0, mut x1) = (to_px(corners[0].0, width), to_px(corners[1].0, width));
    let (mut y0, mut y1) = (to_px(corners[0].1, height), to_px(corners[1].1, height));
    if x0 > x1 { std::mem::swap(&mut x0, &mut x1) }
    if y0 > y1 { std::mem::swap(&mut y0, &mut y1) }
    // A click: the few pixels around it.
    if x1 - x0 < 3 && y1 - y0 < 3 {
        (x0, x1) = (x0.saturating_sub(2), (x1 + 2).min(image.width - 1));
        (y0, y1) = (y0.saturating_sub(2), (y1 + 2).min(image.height - 1));
    }
    let area = f64::from(x1 - x0 + 1) * f64::from(y1 - y0 + 1);
    let stride = (area / 250_000.0).sqrt().ceil().max(1.0) as usize;
    let mean = |skip_clipped: bool| {
        let (mut sum, mut count) = ([0.0f64; 3], 0u32);
        for y in (y0..=y1).step_by(stride) {
            for x in (x0..=x1).step_by(stride) {
                let px = image.get(x, y).map(|v| f64::from(to_f32(v)));
                if skip_clipped && px.iter().any(|&v| v >= 0.95) {
                    continue;
                }
                for c in 0..3 { sum[c] += px[c]; }
                count += 1;
            }
        }
        (count > 0).then(|| sum.map(|v| v / f64::from(count)))
    };
    mean(true).or_else(|| mean(false))
}

#[derive(Default)]
struct Session {
    source_generation: u64,
    backend: Option<Box<dyn ComputeBackend>>,
    source: Option<Source>,
    /// The source resized to the working/preview dimensions, so edits that
    /// don't change the size skip a full-resolution resample.
    scaled: Option<((u32, u32), ImageBuf)>,
    /// The same for interactive renders, kept beside `scaled` so a drag
    /// after a full-size render doesn't resample the source again.
    interactive: Option<((u32, u32), ImageBuf)>,
    /// Prep's output for the photograph-size and the interactive frame (see
    /// `Pipeline::with_prepared_frame`): each slot only ever sees its frame's
    /// one resample of `source` per size, and is replaced with the source.
    prepared_photo: spektrafilm_core::prep::PreparedFrame,
    prepared_interactive: spektrafilm_core::prep::PreparedFrame,
    /// The lab route's developed film for the same two frames (see
    /// `Pipeline::with_developed_frame`), so the scanner and its keys
    /// re-scan it instead of developing it again.
    developed_photo: spektrafilm_core::pipeline::DevelopedFrame,
    developed_interactive: spektrafilm_core::pipeline::DevelopedFrame,
    /// The source's auto-exposure metering frame. Every render of the source,
    /// at any preview or working size, meters it, as the exporter does, so
    /// the preview's exposure is the export's.
    metering: Option<ImageBuf>,
    /// Calibrated pipelines for every command that renders (ticket 29).
    pipelines: pipelines::Pipelines,
    output: Option<Rendered>,
    /// A small copy of the RAW developed at the neutral base, for picking
    /// white balance: the file and lens correction it was read with.
    wb_base: Option<(PathBuf, spektrafilm_io::LensCorrection, ImageBuf)>,
    /// The source reduced for stock and preset thumbnails.
    thumbnail_source: Option<((u32, u32), ImageBuf)>,
    /// Reduced sources for preset thumbnails whose RAW white balance isn't
    /// the main source's, most recent last.
    thumbnail_wb_sources: Vec<WbSource>,
    /// The metering frame's film exposure in stops for the tone graph's
    /// histogram, keyed by the source and the render pipeline.
    film_stops: Option<(String, Vec<[f32; 3]>)>,
    /// The photograph's lab-scanner balance, metered on `metering` as auto
    /// exposure is, keyed by what it reads ([`lab_balance_key`]).
    lab_balance: Option<(String, Balance)>,
}

/// What a photograph's lab-scanner balance depends on: the source and every
/// param but the Post adjustments, the size and the operator's keys, which
/// come after it, and the exposure edits, which the meter leaves out. A key,
/// a resize or a Zone Shift doesn't meter the photograph again.
fn lab_balance_key(input: &Path, source_generation: u64, film: &str, params: &RuntimeParams) -> String {
    let mut params = params.clone();
    params.post = Default::default();
    params.camera.exposure_compensation_ev = 0.0;
    params.prep.exposure_ev = 0.0;
    params.settings.serial_grain = false;
    image_size::clear(&mut params);
    let scanner = &mut params.scanner;
    (scanner.density_key, scanner.cyan_key, scanner.magenta_key, scanner.yellow_key, scanner.contrast_key) = (0.0, 0.0, 0.0, 0.0, 0.0);
    json!({"input": input, "source_generation": source_generation, "film": film, "params": params}).to_string()
}

/// The balance under `key`, metered with `pipeline` on `metering` if `cache`
/// holds another's.
fn cached_lab_balance(cache: &mut Option<(String, Balance)>, key: String, pipeline: &Pipeline, metering: &ImageBuf) -> Balance {
    match cache {
        Some((cached, balance)) if *cached == key => *balance,
        _ => {
            let balance = pipeline.lab_balance(metering);
            *cache = Some((key, balance));
            balance
        }
    }
}

/// The source decoded with another RAW white balance, reduced to the largest
/// frame a thumbnail develops (`THUMBNAIL_FRAME_MAX`).
struct WbSource {
    /// Effective (`RawWhiteBalance::effective`).
    wb: spektrafilm_io::RawWhiteBalance,
    colour: spektrafilm_io::InputColour,
    image: ImageBuf,
    /// The auto-exposure metering frame of this decode.
    metering: ImageBuf,
}

/// The longest frame developed for a cropped thumbnail.
const THUMBNAIL_FRAME_MAX: u32 = 1280;
/// White balances kept for preset thumbnails (few presets differ).
const THUMBNAIL_WB_SOURCES: usize = 4;

/// The frame developed for a thumbnail: large enough that the crop fills
/// `long_side`, within a bound (a tight crop then gets fewer pixels).
fn thumbnail_dimensions((width, height): (u32, u32), long_side: u32, crop: Option<&Crop>) -> (u32, u32) {
    let (fraction_w, fraction_h) = crop.map_or((1.0, 1.0), |c| (c.width, c.height));
    let cropped_long = (width as f64 * fraction_w).max(height as f64 * fraction_h).max(1.0);
    let frame_long = (width.max(height) as f64 * long_side as f64 / cropped_long).min(THUMBNAIL_FRAME_MAX as f64);
    let scale = frame_long / width.max(height) as f64;
    if scale >= 1.0 {
        (width, height)
    } else {
        (((width as f64 * scale).round() as u32).max(1), ((height as f64 * scale).round() as u32).max(1))
    }
}

/// The decoded input, and what it was decoded with: a RAW's white balance
/// and a non-RAW file's interpretation each need a new decode.
struct Source {
    path: PathBuf,
    /// The limit it was read with, in pixels on the long side; 0 is all of it.
    decode_limit: u32,
    wb: spektrafilm_io::RawWhiteBalance,
    lens: spektrafilm_io::LensCorrection,
    lens_correction_supported: bool,
    interpretation: spektrafilm_io::InputInterpretation,
    colour: spektrafilm_io::InputColour,
    image: ImageBuf,
}

impl Source {
    fn current(
        &self,
        path: &Path,
        wb: spektrafilm_io::RawWhiteBalance,
        lens: spektrafilm_io::LensCorrection,
        interpretation: &spektrafilm_io::InputInterpretation,
    ) -> bool {
        self.path == path
            && if spektrafilm_io::is_raw(path) {
                self.wb == wb && self.lens == lens
            } else {
                &self.interpretation == interpretation
            }
    }
}

/// The last render. `image` is the scan before the post adjustments, so a
/// post-only edit reuses it; `key` is everything else the render depended on.
struct Rendered {
    id: u64,
    key: Value,
    /// The response to the render, reused when only the post adjustments change.
    response: Value,
    source: PathBuf,
    film: String,
    /// The render's output space and encoding: the preview space. Post, the
    /// border and resizing work in it; a save to another space converts.
    encoding: Encoding,
    post: PostParams,
    image: ImageBuf,
}

fn catalog(data: &Path) -> Result<Value> {
    let mut stocks = Vec::new();
    for entry in std::fs::read_dir(data.join("profiles"))? {
        let path = entry?.path();
        if path.extension().and_then(|x| x.to_str()) != Some("json") {
            continue;
        }
        stocks.push(path.file_stem().unwrap().to_string_lossy().into_owned());
    }
    let mut catalog = spektrafilm_core::catalog::catalog(data, stocks)?;
    ensure!(
        !catalog["profiles"].as_array().is_some_and(Vec::is_empty),
        "No profiles found in {}",
        data.display()
    );
    catalog["protocol"] = json!(1);
    catalog["capabilities"] = json!({"save_options": true, "crop_after_post": true, "color_space": true, "presets": true, "input_interpretation": true, "preview_color_space": true, "tone_curve": true, "place_exposure": true, "brightness_reference": true});
    // What a preset leaves as it is: a preset's thumbnail changes only with these.
    catalog["preset_kept"] = json!(presets::KEPT);
    Ok(catalog)
}

impl Session {
    /// Decodes `input` unless the session already holds it with these settings.
    fn load_source(
        &mut self,
        input: &Path,
        source_generation: u64,
        wb: spektrafilm_io::RawWhiteBalance,
        lens: spektrafilm_io::LensCorrection,
        interpretation: spektrafilm_io::InputInterpretation,
        decode_limit: u32,
    ) -> Result<()> {
        let reload = self.source_generation != source_generation
            || self.source.as_ref().is_none_or(|source| source.decode_limit != decode_limit || !source.current(input, wb, lens, &interpretation));
        if reload {
            // Release the last source's caches before decoding the next.
            self.source = None;
            self.scaled = None;
            self.interactive = None;
            self.prepared_photo = Default::default();
            self.prepared_interactive = Default::default();
            self.developed_photo = Default::default();
            self.developed_interactive = Default::default();
            self.metering = None;
            self.thumbnail_source = None;
            self.thumbnail_wb_sources = Vec::new();
            self.film_stops = None;
            self.lab_balance = None;
            let loaded = spektrafilm_io::load_image_colour_limited(
                input,
                spektrafilm_io::Formats::Any,
                wb,
                lens,
                &interpretation,
                decode_limit,
            )?;
            self.source = Some(Source {
                path: input.to_path_buf(),
                decode_limit,
                wb,
                lens,
                lens_correction_supported: loaded.lens_correction_supported,
                interpretation,
                colour: loaded.colour,
                image: loaded.image,
            });
            self.source_generation = source_generation;
        }
        Ok(())
    }

    fn thumbnail(
        &mut self,
        input: PathBuf,
        source_generation: u64,
        mut film: String,
        mut paper: String,
        mut params: Box<RuntimeParams>,
        long_side: u32,
        decode_long_side: u32,
        preview_path: PathBuf,
        crop: Option<Crop>,
        preset: Option<String>,
        include_finish: bool,
        data: &Path,
    ) -> Result<Value> {
        let started = Instant::now();
        ensure!((16..=THUMBNAIL_FRAME_MAX).contains(&long_side), "Invalid thumbnail size");
        let preset_applied = preset.is_some();
        if let Some(text) = preset {
            let preset = presets::import(&text, data).map_err(anyhow::Error::msg)?;
            params = Box::new(presets::apply_with_finish(&preset, &params, include_finish));
            (film, paper) = (preset.film, preset.paper);
        }
        if let Some(crop) = &crop {
            crop.validate()?;
        }
        ensure!(
            RgbColourspace::find(&params.io.output_color_space).is_some(),
            "Unknown output colour space: {}",
            params.io.output_color_space
        );
        params.io.raw_white_balance.validate()?;
        params.settings.serial_grain = false;
        let post = std::mem::take(&mut params.post);
        let interpretation = params.io.input_interpretation.clone();
        interpretation.validate()?;
        let (wb, lens) = (params.io.raw_white_balance, params.io.lens_correction);
        // A preset whose RAW white balance isn't the photograph's needs a
        // decode of its own. It gets a reduced copy here, so the main render
        // keeps its decoded source. (A preset keeps the lens correction and
        // the interpretation, so only the white balance can differ.)
        let own_decode = preset_applied
            && spektrafilm_io::is_raw(&input)
            && self.source_generation == source_generation
            && self.source.as_ref().is_some_and(|s| s.path == input && s.wb.effective() != wb.effective());
        if !own_decode {
            self.load_source(&input, source_generation, wb, lens, interpretation.clone(), decode_long_side)?;
        }
        let decoded = started.elapsed();
        let source = &self.source.as_ref().unwrap().image;
        // The thumbnail is the whole frame; Image Size describes the export.
        image_size::clear(&mut params);
        let full = (source.width, source.height);
        let dimensions = thumbnail_dimensions(full, long_side, crop.as_ref());
        let (working, metering) = if own_decode {
            let index = match self.thumbnail_wb_sources.iter().position(|s| s.wb == wb.effective()) {
                Some(index) => index,
                None => {
                    let loaded = spektrafilm_io::load_image_colour(
                        &input, spektrafilm_io::Formats::Any, wb, lens, &interpretation,
                    )?;
                    let metering = spektrafilm_core::stages::filming::metering_preview(&loaded.image);
                    // The largest frame any thumbnail develops, so a new crop
                    // reduces this copy instead of decoding again.
                    let largest = thumbnail_dimensions(full, THUMBNAIL_FRAME_MAX, None);
                    let image = if largest == (loaded.image.width, loaded.image.height) {
                        loaded.image
                    } else {
                        downsample_area(&loaded.image, largest)
                    };
                    if self.thumbnail_wb_sources.len() >= THUMBNAIL_WB_SOURCES {
                        self.thumbnail_wb_sources.remove(0);
                    }
                    self.thumbnail_wb_sources.push(WbSource { wb: wb.effective(), colour: loaded.colour, image, metering });
                    self.thumbnail_wb_sources.len() - 1
                }
            };
            let entry = self.thumbnail_wb_sources.remove(index);
            params.io.apply_input_colour(&entry.colour);
            let working = if dimensions == (entry.image.width, entry.image.height) {
                entry.image.clone()
            } else {
                downsample_area(&entry.image, dimensions)
            };
            let metering = Some(entry.metering.clone());
            self.thumbnail_wb_sources.push(entry);
            (working, metering)
        } else {
            let Source { image: source, colour, .. } = self.source.as_ref().unwrap();
            params.io.apply_input_colour(colour);
            if (params.camera.auto_exposure || params.lab_scan()) && self.metering.is_none() {
                self.metering = Some(spektrafilm_core::stages::filming::metering_preview(source));
            }
            let working = working_source(source, &mut self.thumbnail_source, dimensions, downsample_area).clone();
            (working, self.metering.clone())
        };
        let resampled = started.elapsed();
        let key = preview_pipeline_cache_key(&film, &paper, &params);
        let (calibrated, cached) =
            self.pipelines.get_or_build(&key, false, || build_pipeline(data, &film, &paper, &params))?;
        let mut pipeline = calibrated.clone().with_params((*params).clone());
        if let Some(metering) = metering {
            pipeline = pipeline.with_metering_preview(metering);
        }
        let built = started.elapsed();
        let backend = self.backend.get_or_insert_with(spektrafilm_gpu::select_backend);
        let (output, used_backend) = pipeline.process_with_backend(working, backend.as_ref());
        let cropped = crop.map(|crop| crop.apply(&output));
        let output = cropped.as_ref().unwrap_or(&output);
        let processed = started.elapsed();
        let encoding = Encoding::new(&params.io.output_color_space, params.io.output_cctf_encoding);
        let (width, height) = write_display(output, encoding, &post, &preview_path)?;
        let ms = |d: std::time::Duration| d.as_secs_f64() * 1000.0;
        Ok(json!({
            "width": width, "height": height, "backend": used_backend,
            "display_color_space": DisplaySpace::of(encoding).name(),
            "elapsed_ms": ms(started.elapsed()), "cached_pipeline": cached,
            "timing_ms": {"decode": ms(decoded), "resample": ms(resampled - decoded),
                "pipeline": ms(built - resampled), "process": ms(processed - built),
                "write": ms(started.elapsed() - processed)},
        }))
    }

    /// What the photograph meters at, as the last render applied it, with
    /// auto exposure on.
    fn autoexposure_ev(&self, film: &str, paper: &str, params: &RuntimeParams) -> Option<f64> {
        if !params.camera.auto_exposure {
            return None;
        }
        let calibrated = self.pipelines.peek(&preview_pipeline_cache_key(film, paper, params))?;
        Some(calibrated.clone().with_params(params.clone()).frame_autoexposure_ev(self.metering.as_ref()?))
    }

    /// The photograph's lab-scanner balance, as the last render metered it
    /// (or metered now with its pipeline), on the Lab-scan route. `params`
    /// as the app sends them: the source's colour applies, as for a render.
    fn lab_balance(&mut self, film: &str, paper: &str, params: &RuntimeParams) -> Option<Balance> {
        if !params.lab_scan() {
            return None;
        }
        let source = self.source.as_ref()?;
        let mut params = params.clone();
        params.io.apply_input_colour(&source.colour);
        let params = &params;
        let key = lab_balance_key(&source.path, self.source_generation, film, params);
        if let Some((cached, balance)) = &self.lab_balance
            && *cached == key
        {
            return Some(*balance);
        }
        let calibrated = self.pipelines.peek(&preview_pipeline_cache_key(film, paper, params))?;
        let pipeline = calibrated.clone().with_params(params.clone());
        let metering = self.metering.get_or_insert_with(|| spektrafilm_core::stages::filming::metering_preview(&source.image));
        Some(cached_lab_balance(&mut self.lab_balance, key, &pipeline, metering))
    }

    fn handle(&mut self, request: Request, data: &Path) -> Result<Value> {
        match request.command {
            Command::Catalog => catalog(data),
            Command::BalancePrint { film, paper, params } => {
                let started = Instant::now();
                let (m, y) = spektrafilm_core::print_balance::solve_neutral_filter_shifts(
                    profile::load_profile_by_name(data, &film)?,
                    profile::load_profile_by_name(data, &paper)?,
                    &params,
                    data,
                    spektrafilm_core::print_balance::MIDGRAY,
                )
                .map_err(anyhow::Error::msg)?;
                Ok(json!({"m_filter_shift": m, "y_filter_shift": y,
                          "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0}))
            }
            Command::ExportLut { film, paper, params, size, output } => {
                let started = Instant::now();
                let cube = spektrafilm_core::lut_export::cube(data, &film, &paper, *params, size)
                    .map_err(anyhow::Error::msg)?;
                std::fs::write(&output, cube)?;
                Ok(json!({"size": size, "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0}))
            }
            Command::PresetImport { text, params, include_finish } => {
                let preset = presets::import(&text, data).map_err(anyhow::Error::msg)?;
                let params = presets::apply_with_finish(&preset, &params.unwrap_or_default(), include_finish);
                Ok(json!({"film": preset.film, "paper": preset.paper, "params": params}))
            }
            Command::PresetExport { film, paper, params, include_finish } => {
                let text = presets::export_with_finish(&film, &paper, &params, data, include_finish)
                    .map_err(anyhow::Error::msg)?;
                Ok(json!({"text": text}))
            }
            Command::WbPick { input, params, x0, y0, x1, y1 } => {
                let started = Instant::now();
                ensure!(spektrafilm_io::is_raw(&input), "White balance can be picked on RAW files");
                let lens = params.io.lens_correction;
                let current = self.wb_base.as_ref().is_some_and(|(path, l, _)| *path == input && *l == lens);
                if !current {
                    let loaded = spektrafilm_io::load_image_colour_limited(
                        &input, spektrafilm_io::Formats::Any, spektrafilm_io::NEUTRAL_BASE, lens,
                        &params.io.input_interpretation, 1600,
                    )?;
                    self.wb_base = Some((input.clone(), lens, loaded.image));
                }
                let image = &self.wb_base.as_ref().expect("just read").2;
                let colour = area_colour(image, [(x0, y0), (x1, y1)]).context("That area is outside the photograph")?;
                let (picked, exact) = spektrafilm_io::neutral_white_balance(colour)
                    .context("That area has no light in one of its colours; pick something grey or white")?;
                Ok(json!({"temperature": picked.temperature, "tint": picked.tint, "exact": exact,
                          "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0}))
            }
            Command::ZoneReadout { film, paper, params, x0, y0, x1, y1, targets } => {
                let started = Instant::now();
                let autoexposure_ev = self.autoexposure_ev(&film, &paper, &params);
                let lab_balance = self.lab_balance(&film, &paper, &params);
                let source = self.source.as_ref().context("No photograph to read")?;
                let image = match &self.scaled {
                    Some((_, scaled)) if !params.prep.is_identity() => scaled,
                    _ => &source.image,
                };
                let reading = spektrafilm_core::zones::readout(
                    data, &film, &paper, &params, autoexposure_ev, lab_balance, image, [(x0, y0), (x1, y1)], &targets,
                )
                .map_err(anyhow::Error::msg)?;
                Ok(json!({"printed": reading.printed, "shifts": reading.shifts,
                          "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0}))
            }
            Command::Original { input, params, limit_preview, preview_path } => {
                ensure!(input != preview_path, "Choose a different preview path to preserve the source");
                ensure!(params.io.upscale_factor.is_finite()
                    && (0.1..=1.0).contains(&params.io.upscale_factor), "Invalid working resolution");
                params.io.raw_white_balance.validate()?;
                params.io.input_interpretation.validate()?;
                let loaded = spektrafilm_io::load_image_colour(
                    &input, spektrafilm_io::Formats::Any, params.io.raw_white_balance,
                    params.io.lens_correction, &params.io.input_interpretation,
                )?;
                let source = loaded.image;
                // Never enlarged: an Image Size target is ignored, and the
                // canvas fits the original to the developed photograph.
                let factor = if params.io.photo_long_side_px.is_some() { 1.0 } else { params.io.upscale_factor };
                let dimensions = preview_dimensions(source.width, source.height, factor, limit_preview);
                let resized = (dimensions != (source.width, source.height))
                    .then(|| rescale_preview_input_fast(&source, dimensions));
                let working = resized.as_ref().unwrap_or(&source);
                let (encoding, converted) = original_encoding(&params, &loaded.colour, working);
                let working = converted.as_ref().unwrap_or(working);
                let (width, height) = write_display(working, encoding, &PostParams::default(), &preview_path)?;
                Ok(json!({"width": width, "height": height, "input_colour": loaded.colour,
                          "display_color_space": DisplaySpace::of(encoding).name()}))
            }
            Command::Thumbnail { input, source_generation, film, paper, params, long_side, decode_long_side, preview_path, crop, preset, include_finish } => {
                self.thumbnail(input, source_generation, film, paper, params, long_side, decode_long_side, preview_path, crop, preset, include_finish, data)
            }
            Command::ToneCurve { film, paper, params, count } => {
                let started = Instant::now();
                // On a lab scan, the photograph's balance, as its render has it.
                let balance = self.lab_balance(&film, &paper, &params);
                let params = spektrafilm_core::tone_curve::tone_params(&params);
                let key = preview_pipeline_cache_key(&film, &paper, &params);
                let (calibrated, cached) =
                    self.pipelines.get_or_build(&key, false, || build_pipeline(data, &film, &paper, &params))?;
                let mut pipeline = calibrated.clone().with_params(params);
                if let Some(balance) = balance {
                    pipeline = pipeline.with_lab_balance(balance);
                }
                let built = started.elapsed();
                let curve = spektrafilm_core::tone_curve::tone_curve(&pipeline, count.unwrap_or(256));
                let ms = |d: std::time::Duration| d.as_secs_f64() * 1000.0;
                Ok(json!({
                    "stops": spektrafilm_core::tone_curve::STOPS,
                    "film": curve.film, "paper": curve.paper, "rgb": curve.rgb,
                    "cached_pipeline": cached,
                    "timing_ms": {"pipeline": ms(built), "curve": ms(started.elapsed() - built)},
                    "elapsed_ms": ms(started.elapsed()),
                }))
            }
            Command::ReleaseThumbnails => {
                self.thumbnail_source = None;
                self.pipelines.release_unpinned();
                self.thumbnail_wb_sources = Vec::new();
                Ok(json!({}))
            }
            Command::PreviewColourSpace { input } => {
                use spektrafilm_io::brightness::{Declared, preview_colour_space};
                let file = std::fs::read(&input).with_context(|| format!("Couldn't read {}", input.display()))?;
                let space = preview_colour_space(&file).map(|declared| match declared {
                    Declared::Srgb => "srgb",
                    Declared::AdobeRgb => "adobe_rgb",
                    Declared::Other => "other",
                });
                Ok(json!({ "colour_space": space }))
            }
            Command::BrightnessReference { input, reference_path, expected_width, expected_height } => {
                ensure!(expected_width > 0 && expected_height > 0,
                    "The brightness reference needs the photograph's dimensions");
                ensure!(input != reference_path
                    && !std::fs::canonicalize(&reference_path).ok().is_some_and(|output|
                        std::fs::canonicalize(&input).ok().as_ref() == Some(&output)),
                    "The brightness reference must not replace the original photograph");
                match spektrafilm_io::brightness::reference(&input, (expected_width, expected_height)) {
                    Ok(reference) => {
                        spektrafilm_io::brightness::write_reference(&reference, &reference_path)?;
                        Ok(json!({"usable": true, "reference_path": reference_path,
                            "width": reference.width(), "height": reference.height()}))
                    }
                    Err(error) => {
                        if let Some(spektrafilm_io::brightness::Unusable(reason)) = error.downcast_ref::<spektrafilm_io::brightness::Unusable>() {
                            Ok(json!({"usable": false, "reason": reason, "for_photo": true}))
                        } else {
                            Err(error)
                        }
                    }
                }
            }
            Command::PlaceExposure { input, source_generation, film, paper, mut params, reference_path } => {
                let started = Instant::now();
                params.prep.validate().map_err(anyhow::Error::msg)?;
                params.io.raw_white_balance.validate()?;
                params.io.input_interpretation.validate()?;
                ensure!(params.io.upscale_factor.is_finite()
                    && (0.1..=1.0).contains(&params.io.upscale_factor), "Invalid working resolution");
                ensure!(RgbColourspace::find(&params.io.output_color_space).is_some(),
                    "Unknown output colour space: {}", params.io.output_color_space);
                let source = self.source.as_ref().context("Open a photograph and wait for its preview before placing exposure")?;
                ensure!(self.source_generation == source_generation
                    && source.current(&input, params.io.raw_white_balance, params.io.lens_correction,
                                      &params.io.input_interpretation),
                    "The photograph or RAW settings changed; wait for its current preview and try again");
                let reference = placement_reference(&reference_path, &source.image)?;
                params.io.apply_input_colour(&source.colour);
                ensure!(RgbColourspace::find(&params.io.input_color_space).is_some(),
                    "Unknown input colour space: {}", params.io.input_color_space);
                image_size::clear(&mut params);
                let key = preview_pipeline_cache_key(&film, &paper, &params);
                // Borrow the calibrated look when possible, but keep all
                // placement work local. Save must still see the last preview.
                let mut pipeline = match self.pipelines.peek(&key) {
                    Some(pipeline) => pipeline.clone().with_params((*params).clone()),
                    None => build_pipeline(data, &film, &paper, &params)?,
                };
                if let Some(metering) = &self.metering {
                    pipeline = pipeline.with_metering_preview(metering.clone());
                }
                let backend = self.backend.get_or_insert_with(spektrafilm_gpu::select_backend);
                let placement = spektrafilm_core::exposure_placement::place_exposure(
                    &pipeline, &source.image, &reference, backend.as_ref(),
                ).map_err(anyhow::Error::msg)?;
                let mut result = serde_json::to_value(placement)?;
                result["elapsed_ms"] = json!(started.elapsed().as_secs_f64() * 1000.0);
                Ok(result)
            }
            Command::Save {
                render_id,
                output,
                save_options,
                crop_after_post,
                border,
                border_options,
                instagram,
                crop,
                rotate_cw,
                fit,
            } => {
                let Rendered {
                    id,
                    source,
                    film,
                    encoding,
                    post,
                    image,
                    ..
                } = self.output.as_mut().context("No preview to save")?;
                let (encoding, encoded) = (*encoding, encoding.encoded);
                ensure!(
                    *id == render_id,
                    "The preview changed; wait for the current render and try again"
                );
                ensure!(
                    source != &output,
                    "Choose a different output path to preserve the source"
                );
                if let Some(crop) = &crop {
                    crop.validate()?;
                }
                save_options.check(&output)?;
                let metadata = spektrafilm_io::read_metadata(source);
                // The render is the unclipped scan; Post, crop, border and resize
                // work on it as the file will hold it. Clipping in place keeps
                // memory flat, and the display clips the same way.
                spektrafilm_core::pipeline::clip_to_display(image, encoded);
                let image = &*image;
                // Local Contrast on the whole picture, before any crop, as the preview has it.
                let local = local_contrast(image, encoding, post);
                let image = local.as_ref().unwrap_or(image);
                let adjusted_before = (crop_after_post && !post.is_identity())
                    .then(|| PostProcess::new(post, encoded, encoding.space.name).applied(image));
                let image = adjusted_before.as_ref().unwrap_or(image);
                // Crop in the unrotated orientation, then rotate, then add the border.
                let cropped = crop.map(|crop| crop.apply(image));
                let image = cropped.as_ref().unwrap_or(image);
                let adjusted = (!crop_after_post && !post.is_identity())
                    .then(|| PostProcess::new(post, encoded, encoding.space.name).applied(image));
                let image = adjusted.as_ref().unwrap_or(image);
                let rotated =
                    (rotate_cw.rem_euclid(4) != 0).then(|| image.clone().rotated_cw(rotate_cw));
                let image = rotated.as_ref().unwrap_or(image);
                let bordered = match border {
                    Some(style) => {
                        let bordered =
                            add_border(image, style, &border_options, film, encoding, data)?;
                        Some(if instagram {
                            extend_for_instagram(&bordered, style, &border_options, encoding)
                        } else {
                            bordered
                        })
                    }
                    None => None,
                };
                let image = bordered.as_ref().unwrap_or(image);
                let resized = fit.and_then(|fit| resize::fit(image, fit, encoding));
                let image = resized.as_ref().unwrap_or(image);
                // Saved in the preview's space, the file holds the render's
                // values. Another space gets the preview's colours, clipped to
                // the smaller of the two gamuts (relative colorimetric).
                let space = RgbColourspace::find(&save_options.color_space)
                    .with_context(|| format!("Unknown colour space: {}", save_options.color_space))?;
                let converted = (space.name != encoding.space.name).then(|| {
                    let mut converted = image.clone();
                    convert_output(&mut converted, encoding.space.name, space.name, encoded);
                    converted
                });
                let image = converted.as_ref().unwrap_or(image);
                let save_options = spektrafilm_io::save::SaveOptions { linear: !encoded, ..save_options };
                spektrafilm_io::save::save_image_with_options(image, &output, metadata.as_ref(), &save_options)?;
                Ok(json!({"saved": output}))
            }
            Command::Render {
                input,
                source_generation,
                film,
                paper,
                mut params,
                limit_preview,
                preview_path,
                interactive_scale,
                crop,
            } => {
                let started = Instant::now();
                ensure!(
                    params.io.upscale_factor.is_finite()
                        && (0.1..=1.0).contains(&params.io.upscale_factor),
                    "Invalid working resolution"
                );
                ensure!(
                    interactive_scale.is_none_or(|s| s.is_finite() && s > 0.0),
                    "Invalid interactive scale"
                );
                // The preview space: the app sends the export's colour space,
                // so the preview judges the export's gamut.
                ensure!(
                    RgbColourspace::find(&params.io.output_color_space).is_some(),
                    "Unknown output colour space: {}",
                    params.io.output_color_space
                );
                params.io.raw_white_balance.validate()?;
                params.settings.serial_grain = false;
                params.prep.validate().map_err(anyhow::Error::msg)?;
                // Applied to the display and on save, so the pipeline runs without them.
                let post = std::mem::take(&mut params.post);
                let wb = params.io.raw_white_balance;
                let lens = params.io.lens_correction;
                let interpretation = params.io.input_interpretation.clone();
                interpretation.validate()?;
                self.load_source(&input, source_generation, wb, lens, interpretation, 0)?;
                let Source { image: source, colour: input_colour, lens_correction_supported, .. } =
                    self.source.as_ref().unwrap();
                // RAW and decoded files are the engine's linear sRGB; manual
                // pass-through keeps the params' input fields, as 0.8 did.
                params.io.apply_input_colour(input_colour);
                if (params.camera.auto_exposure || params.lab_scan()) && self.metering.is_none() {
                    self.metering = Some(spektrafilm_core::stages::filming::metering_preview(source));
                }
                let (source_width, source_height) = (source.width, source.height);
                // The uncapped frame an export develops, and the photograph the
                // crop cuts from it; an invalid or too-large request fails here,
                // before anything is allocated at that size.
                let size = image_size::resolve(&params, (source_width, source_height), crop.as_ref())?;
                image_size::clear(&mut params);
                // The photograph's preview, at most 12 MP if limited; an
                // interactive render is a smaller frame of it that never
                // enlarges the source.
                let photo_dimensions = preview_cap(size.working, limit_preview);
                let dimensions = match interactive_scale.filter(|&s| s < 1.0) {
                    Some(s) => interactive_dimensions(photo_dimensions, s, (source_width, source_height)),
                    None => photo_dimensions,
                };
                // The resolved size, not the crop: panning a crop, or any crop
                // with the same working size, reuses the render.
                let render_key = json!({
                    "input": input, "source_generation": source_generation, "film": film,
                    "paper": paper, "params": params, "limit_preview": limit_preview,
                    "interactive_scale": interactive_scale, "working": size.working,
                });
                let reused = self.output.take().filter(|last| last.key == render_key);
                if let Some(last) = reused {
                    write_display(&last.image, last.encoding, &post, &preview_path)?;
                    let mut response = last.response.clone();
                    // Edge rounding moves the crop's pixels with its position.
                    response["photo_crop_width"] = json!(size.photo.0);
                    response["photo_crop_height"] = json!(size.photo.1);
                    response["elapsed_ms"] = json!(started.elapsed().as_secs_f64() * 1000.0);
                    self.output = Some(Rendered {
                        id: request.id,
                        post,
                        ..last
                    });
                    return Ok(response);
                }
                let key = preview_pipeline_cache_key(&film, &paper, &params);
                let before_build = started.elapsed();
                let (calibrated, cached_pipeline) =
                    self.pipelines.get_or_build(&key, true, || build_pipeline(data, &film, &paper, &params))?;
                let mut pipeline = calibrated.clone().with_params((*params).clone());
                let pipeline_ms = (started.elapsed() - before_build).as_secs_f64() * 1000.0;
                if let Some(metering) = &self.metering {
                    pipeline = pipeline.with_metering_preview(metering.clone());
                }
                // The tone graph's histogram: the photograph's film exposure,
                // from the metering frame (the whole frame, before spatial effects).
                // Prep's exposure is a uniform gain, so it shifts the stops like
                // the camera's; its other controls reshape them, so then the
                // frame goes through Prep and is counted as exposed.
                let histogram = {
                    let metering = self
                        .metering
                        .get_or_insert_with(|| spektrafilm_core::stages::filming::metering_preview(source));
                    let ae = if params.camera.auto_exposure { pipeline.metering_film_raw(metering).1 } else { 0.0 };
                    let reshaped = !spektrafilm_core::prep::PrepParams { exposure_ev: 0.0, ..params.prep }.is_identity();
                    let mut stops_key = format!("{}|{source_generation}|{}", input.display(), key);
                    if reshaped {
                        stops_key += &format!("|{:?}|{ae}|{}", params.prep, params.camera.exposure_compensation_ev);
                    }
                    if self.film_stops.as_ref().is_none_or(|(old, _)| old != &stops_key) {
                        let raw = if reshaped {
                            pipeline.metering_film_raw_prepared(metering, ae).map_err(anyhow::Error::msg)?
                        } else {
                            pipeline.metering_film_raw(metering).0
                        };
                        self.film_stops = Some((stops_key, spektrafilm_core::tone_curve::raw_stops(&raw)));
                    }
                    let ev = if reshaped { 0.0 } else { ae + params.camera.exposure_compensation_ev as f64 + params.prep.exposure_ev as f64 };
                    let counts = spektrafilm_core::tone_curve::film_histogram(&self.film_stops.as_ref().unwrap().1, ev, 128);
                    json!({"stops": spektrafilm_core::tone_curve::STOPS, "ev": ev, "counts": counts})
                };
                // The lab scanner's auto correction, metered once per photograph
                // with auto exposure, on the same frame.
                if params.lab_scan() {
                    let metering = self
                        .metering
                        .get_or_insert_with(|| spektrafilm_core::stages::filming::metering_preview(source));
                    let key = lab_balance_key(&input, source_generation, &film, &params);
                    let balance = cached_lab_balance(&mut self.lab_balance, key, &pipeline, metering);
                    pipeline = pipeline.with_lab_balance(balance);
                }
                let working = if dimensions == photo_dimensions {
                    pipeline = pipeline
                        .with_prepared_frame(self.prepared_photo.clone())
                        .with_developed_frame(self.developed_photo.clone());
                    working_source(
                        source,
                        &mut self.scaled,
                        dimensions,
                        rescale_preview_input_fast,
                    )
                } else {
                    pipeline = pipeline
                        .with_prepared_frame(self.prepared_interactive.clone())
                        .with_developed_frame(self.developed_interactive.clone());
                    working_source(source, &mut self.interactive, dimensions, downsample_area)
                };
                let backend = self
                    .backend
                    .get_or_insert_with(spektrafilm_gpu::select_backend);
                let (output, used_backend) = if pipeline.params.scans_film() && pipeline.film.is_positive() {
                    pipeline.process_with_backend(working.clone(), backend.as_ref())
                } else {
                    pipeline
                        .process_resident_borrowed(working, backend.as_ref())
                        .map(|output| (output, backend.name()))
                        .unwrap_or_else(|| pipeline.process_with_backend(working.clone(), backend.as_ref()))
                };
                let encoding = Encoding::new(&params.io.output_color_space, params.io.output_cctf_encoding);
                let (width, height) = write_display(&output, encoding, &post, &preview_path)?;
                // At the uncapped working size the output is byte-identical to
                // a Fast (GPU) export, so the app can save it instead of
                // rendering again. The display proxy's limit doesn't matter:
                // Save uses this float output.
                let export_resolution = (output.width, output.height) == size.working;
                let response = json!({
                    "width": width, "height": height, "output_width": output.width, "output_height": output.height,
                    "photo_width": photo_dimensions.0, "photo_height": photo_dimensions.1,
                    "working_width": size.working.0, "working_height": size.working.1,
                    "photo_crop_width": size.photo.0, "photo_crop_height": size.photo.1,
                    "source_width": source_width, "source_height": source_height,
                    "export_resolution": export_resolution,
                    "raw": spektrafilm_io::is_raw(&input), "backend": used_backend,
                    "input_colour": input_colour,
                    "lens_correction_supported": lens_correction_supported,
                    "output_color_space": encoding.space.name,
                    "display_color_space": DisplaySpace::of(encoding).name(),
                    "elapsed_ms": started.elapsed().as_secs_f64() * 1000.0,
                    "film_histogram": histogram,
                    "cached_pipeline": cached_pipeline, "pipeline_ms": pipeline_ms,
                });
                self.output = Some(Rendered {
                    id: request.id,
                    key: render_key,
                    response: response.clone(),
                    source: input,
                    film,
                    encoding,
                    post,
                    image: output,
                });
                Ok(response)
            }
        }
    }
}

/// References are small, upright, complete camera frames. Decode their ICC/
/// transfer metadata through the same colour-managed loader as other images;
/// the solver receives linear sRGB, never encoded PNG samples mistaken for light.
fn placement_reference(path: &Path, source: &ImageBuf) -> Result<ImageBuf> {
    let metadata = std::fs::metadata(path).context("Reading camera-preview reference")?;
    ensure!(metadata.is_file() && metadata.len() <= 32 * 1024 * 1024,
        "The camera-preview reference must be a PNG smaller than 32 MB");
    let reader = image::ImageReader::open(path)?.with_guessed_format()?;
    ensure!(reader.format() == Some(image::ImageFormat::Png), "The camera-preview reference must be a PNG");
    let (width, height) = reader.into_dimensions()?;
    ensure!((2..=2048).contains(&width) && (2..=2048).contains(&height),
        "The camera-preview reference must be between 2 and 2048 pixels on each side");
    let reference = spektrafilm_io::load_image(path, spektrafilm_io::Formats::Any)?;
    let aspect = reference.width as f64 / reference.height as f64;
    let source_aspect = source.width as f64 / source.height as f64;
    ensure!((aspect / source_aspect - 1.0).abs() <= 0.02,
        "The camera-preview reference must show the whole photograph with matching orientation");
    ensure!(reference.data.iter().all(|v| v.is_finite()), "The camera-preview reference contains invalid pixels");
    Ok(reference)
}

/// A request line. Params from before `io.input_interpretation` keep the
/// meaning of their input fields; see `infer_input_interpretation`.
fn parse_request(line: &str) -> Result<Request> {
    let mut value: Value = serde_json::from_str(line)?;
    if let Some(params) = value.get_mut("params") {
        spektrafilm_core::params::infer_input_interpretation(params);
    }
    Ok(serde_json::from_value(value)?)
}

/// Writes the preview for the app as raw RGBA, avoiding PNG compression on
/// every slider edit. Save keeps the float output, independent of this proxy.
/// The bytes are in `DisplaySpace::of(encoding)`.
/// `image` clipped as the display clips it, with `post`'s Local Contrast;
/// none when it's off.
fn local_contrast(image: &ImageBuf, encoding: Encoding, post: &PostParams) -> Option<ImageBuf> {
    (post.local_contrast > 0.0).then(|| {
        let mut local = image.clone();
        spektrafilm_core::pipeline::clip_to_display(&mut local, encoding.encoded);
        spektrafilm_core::local_contrast::apply(&mut local, post.local_contrast, encoding.encoded, encoding.space.name);
        local
    })
}

fn write_display(
    image: &ImageBuf,
    encoding: Encoding,
    post: &PostParams,
    path: &Path,
) -> Result<(usize, usize)> {
    // Local Contrast needs the whole picture, so it goes on a clipped copy
    // before the display's per-pixel Post.
    let local = local_contrast(image, encoding, post);
    let image = local.as_ref().unwrap_or(image);
    let post = (!post.is_identity()).then(|| PostProcess::new(post, encoding.encoded, encoding.space.name));
    let (width, height, bytes) =
        display_rgba_with_post(image, DISPLAY_MAX_DIM, encoding, post.as_ref());
    std::fs::write(path, bytes).context("Writing preview buffer")?;
    Ok((width, height))
}

/// A calibrated pipeline for `film` printed on `paper` (or scanned).
fn build_pipeline(data: &Path, film: &str, paper: &str, params: &RuntimeParams) -> Result<Pipeline> {
    let film_profile = profile::load_profile_by_name(data, film)?;
    let print_profile = profile::load_profile_by_name(data, if params.scans_film() { film } else { paper })?;
    Pipeline::new_with_spectral(film_profile, print_profile, params.clone(), data).map_err(anyhow::Error::msg)
}

/// The source at `dimensions`. A resampled copy is kept until the source or
/// the size changes, so ordinary edits don't resample the full image again.
fn working_source<'a>(
    source: &'a ImageBuf,
    scaled: &'a mut Option<((u32, u32), ImageBuf)>,
    dimensions: (u32, u32),
    resample: fn(&ImageBuf, (u32, u32)) -> ImageBuf,
) -> &'a ImageBuf {
    if dimensions == (source.width, source.height) {
        *scaled = None;
        return source;
    }
    if scaled.as_ref().is_none_or(|(size, _)| *size != dimensions) {
        *scaled = None; // release the previous size before allocating
        *scaled = Some((dimensions, resample(source, dimensions)));
    }
    &scaled.as_ref().unwrap().1
}

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 || args[1] != "--data-dir" {
        bail!("Usage: spektrafilm-native --data-dir PATH");
    }
    let data = PathBuf::from(&args[2]);
    let mut session = Session::default();
    let mut stdout = std::io::stdout().lock();
    for line in std::io::stdin().lock().lines() {
        let line = line?;
        let id = serde_json::from_str::<Value>(&line)
            .ok()
            .and_then(|v| v["id"].as_u64())
            .unwrap_or(0);
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Value> {
            session.handle(parse_request(&line)?, &data)
        }))
        .unwrap_or_else(|_| {
            // A panicked GPU/decoder may have invalidated its cached state.
            session = Session::default();
            Err(anyhow::anyhow!(
                "The image engine failed. Try a different image or settings."
            ))
        });
        let response = match result {
            Ok(result) => json!({"id": id, "result": result}),
            Err(error) => json!({"id": id, "error": format!("{error:#}")}),
        };
        serde_json::to_writer(&mut stdout, &response)?;
        writeln!(stdout)?;
        stdout.flush()?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn brightness_reference_is_independent_and_refuses_to_replace_the_photo() {
        let dir = std::env::temp_dir().join(format!("negs-reference-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.png");
        let source = ImageBuf::from_data(4, 2, [0.2, 0.5, 0.8].repeat(8));
        spektrafilm_io::save_image(&source, &input, None).unwrap();
        let before = std::fs::read(&input).unwrap();
        let mut session = Session {
            source_generation: 31,
            output: Some(Rendered { id: 7, key: Value::Null, response: Value::Null,
                source: input.clone(), film: "kodak_gold_200".into(), encoding: Encoding::from(true),
                post: PostParams::default(), image: source.clone() }),
            ..Default::default()
        };
        let output = dir.join("reference.png");
        let command = |reference_path| Command::BrightnessReference {
            input: input.clone(), reference_path, expected_width: 4, expected_height: 2,
        };
        let result = session.handle(Request { id: 8, command: command(output.clone()) }, Path::new(".")).unwrap();
        assert_eq!((result["usable"].as_bool(), result["width"].as_u64(), result["height"].as_u64()),
            (Some(true), Some(4), Some(2)));
        assert!(session.source.is_none() && !session.pipelines.has_main());
        assert_eq!(session.source_generation, 31);
        let retained = session.output.as_ref().unwrap();
        assert_eq!(retained.id, 7);
        assert_eq!(retained.image.data, source.data);
        let reference = placement_reference(&output, &source).unwrap();
        assert_eq!(reference.width, 4);
        let error = session.handle(Request { id: 9, command: command(input.clone()) }, Path::new(".")).unwrap_err();
        assert!(error.to_string().contains("must not replace"));
        assert_eq!(std::fs::read(&input).unwrap(), before);
        let alpha = dir.join("alpha.png");
        image::RgbaImage::from_pixel(4, 2, image::Rgba([128, 128, 128, 255])).save(&alpha).unwrap();
        let unsuitable = session.handle(Request { id: 10, command: Command::BrightnessReference {
            input: alpha, reference_path: output, expected_width: 4, expected_height: 2,
        } }, Path::new(".")).unwrap();
        assert_eq!(unsuitable["usable"], false);
        assert_eq!(unsuitable["for_photo"], true);
        assert_eq!(unsuitable["reason"], "Transparent images can’t be matched.");
        std::fs::remove_dir_all(dir).unwrap();
    }
    #[test]
    fn bw_expansion_catalog_keeps_negative_reversal_and_paper_distinct() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let result = catalog(&data).unwrap();
        let profiles = result["profiles"].as_array().unwrap();
        let stock = |id: &str| profiles.iter().find(|p| p["id"] == id).unwrap();
        let film = stock("kodak_trix400_d76_8min");
        let paper = stock("ilford_mgrc_deluxe_grade2");
        assert_eq!(film["paper"], false);
        assert_eq!(film["positive"], false);
        assert_eq!(film["target_print"], paper["id"]);
        assert_eq!(paper["paper"], true);
        assert_eq!(paper["bw"], true);
        assert_eq!(stock("kodak_trix")["positive"], true);
    }
    #[test]
    fn presets_import_over_the_current_params_and_export() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let mut session = Session::default();
        let mut current = RuntimeParams::default();
        current.io.photo_long_side_px = Some(2400);
        current.camera.exposure_compensation_ev = 1.0;
        let text = r#"{"simulation": {"film_stock": "kodak_portra_400", "route": "input > film > scan"},
                       "couplers": {"langmuir_donor_k_rgb": [Infinity, 1.0, 1.0]}}"#;
        let imported = session.handle(Request { id: 1, command: Command::PresetImport {
            text: text.into(), params: Some(Box::new(current)), include_finish: false,
        } }, &data).unwrap();
        assert_eq!(imported["film"], "kodak_portra_400");
        assert_eq!(imported["params"]["io"]["photo_long_side_px"], 2400);
        assert_eq!(imported["params"]["io"]["output_route"], "lab_scan");
        assert_eq!(imported["params"]["camera"]["exposure_compensation_ev"], 0.0);
        assert_eq!(imported["params"]["film_render"]["dir_couplers"]["langmuir_donor_k_rgb"][0], Value::Null);
        let params: RuntimeParams = serde_json::from_value(imported["params"].clone()).unwrap();
        let exported = session.handle(Request { id: 2, command: Command::PresetExport {
            film: "kodak_portra_400".into(), paper: "kodak_supra_endura".into(), params: Box::new(params),
            include_finish: false,
        } }, &data).unwrap();
        let text = exported["text"].as_str().unwrap();
        assert!(text.contains("Infinity"), "{text}");
        let refused = session.handle(Request { id: 3, command: Command::PresetImport {
            text: r#"{"simulation": {"film_stock": "kodak_unknown"}}"#.into(), params: None,
            include_finish: false,
        } }, &data).unwrap_err();
        assert!(refused.to_string().contains("kodak_unknown"), "{refused}");
    }

    /// A preset's thumbnail is the thumbnail of what `preset_import` makes of
    /// it over the current params, and it leaves the main render alone.
    #[test]
    fn preset_thumbnails_apply_the_preset_like_preset_import() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("negs-preset-thumbnail-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.png");
        let pixels = (0..48 * 32 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(48, 32, pixels), &input, None).unwrap();
        let text = r#"{"simulation": {"film_stock": "kodak_portra_400", "print_paper": "kodak_portra_endura"},
                       "camera": {"exposure_compensation_ev": 1.5}}"#;
        let mut current = RuntimeParams::default();
        current.io.output_color_space = "Display P3".into();
        current.camera.exposure_compensation_ev = -1.0;
        let mut session = Session::default();
        let thumbnail = |session: &mut Session, film: &str, paper: &str, params: RuntimeParams, preset: Option<&str>, name: &str| {
            let preview = dir.join(name);
            let response = session.handle(Request { id: 1, command: Command::Thumbnail {
                input: input.clone(), source_generation: 1, film: film.into(), paper: paper.into(),
                params: Box::new(params), long_side: 24, decode_long_side: 0, preview_path: preview.clone(), crop: None,
                preset: preset.map(str::to_string), include_finish: false,
            } }, &data).unwrap();
            (response, std::fs::read(preview).unwrap())
        };
        let (response, with_preset) =
            thumbnail(&mut session, "kodak_gold_200", "kodak_supra_endura", current.clone(), Some(text), "preset.rgba");
        assert_eq!((response["width"].as_u64(), response["height"].as_u64()), (Some(24), Some(16)));
        // The photograph's colour space stays; the preset's look comes in.
        assert_eq!(response["display_color_space"], DisplaySpace::Rec2020SrgbTransfer.name());
        let imported = session.handle(Request { id: 2, command: Command::PresetImport {
            text: text.into(), params: Some(Box::new(current.clone())), include_finish: false,
        } }, &data).unwrap();
        assert_eq!(imported["params"]["camera"]["exposure_compensation_ev"], 1.5);
        let params: RuntimeParams = serde_json::from_value(imported["params"].clone()).unwrap();
        let film = imported["film"].as_str().unwrap();
        let paper = imported["paper"].as_str().unwrap();
        let (_, applied) = thumbnail(&mut session, film, paper, params, None, "applied.rgba");
        assert_eq!(with_preset, applied);
        let (_, plain) = thumbnail(&mut session, "kodak_gold_200", "kodak_supra_endura", current, None, "plain.rgba");
        assert_ne!(with_preset, plain);
        assert!(session.output.is_none() && !session.pipelines.has_main());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn linear_display_is_encoded_without_mutating_output() {
        let image = ImageBuf::from_data(1, 1, vec![0.0, 0.18, 1.0]);
        assert_eq!(
            display_rgba(&image, DISPLAY_MAX_DIM, false).2,
            vec![0, 118, 255, 255]
        );
        assert_eq!(
            display_rgba(&image, DISPLAY_MAX_DIM, true).2,
            vec![0, 46, 255, 255]
        );
        assert_eq!(image.data[1], 0.18);
    }
    #[test]
    fn original_keeps_the_render_available_for_save() {
        let dir = std::env::temp_dir().join(format!("negs-original-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("input.png");
        let preview = dir.join("original.rgba");
        let source = ImageBuf::from_data(2, 1, vec![0.0, 0.5, 1.0, 1.0, 0.5, 0.0]);
        spektrafilm_io::save_image(&source, &input, None).unwrap();
        let mut session = Session {
            output: Some(Rendered { id: 7, key: Value::Null, response: Value::Null,
                source: input.clone(), film: "kodak_gold_200".into(), encoding: Encoding::from(true),
                post: PostParams::default(), image: source.clone() }),
            ..Default::default()
        };
        let params = Box::new(RuntimeParams::default());
        let response = session.handle(Request { id: 8, command: Command::Original {
            input: input.clone(), params, limit_preview: false, preview_path: preview.clone(),
        } }, Path::new(".")).unwrap();
        assert_eq!(response["width"], 2);
        assert_eq!(response["height"], 1);
        assert_eq!(std::fs::read(preview).unwrap().len(), 8);
        let retained = session.output.as_ref().unwrap();
        assert_eq!(retained.id, 7);
        assert_eq!(retained.image.data, source.data);
        let saved = dir.join("saved.png");
        session.handle(Request { id: 9, command: Command::Save {
            render_id: 7, output: saved.clone(), save_options: Default::default(), crop_after_post: false, border: None,
            border_options: BorderOptions::default(), instagram: false,
            crop: None, rotate_cw: 0, fit: None,
        } }, Path::new(".")).unwrap();
        assert_eq!(std::fs::read(input).unwrap(), std::fs::read(saved).unwrap());
        // Another colour space converts the sRGB render and carries its profile.
        let wide = dir.join("wide.png");
        let save_options = spektrafilm_io::save::SaveOptions {
            bit_depth: Some(16), color_space: "Display P3".into(), ..Default::default()
        };
        session.handle(Request { id: 10, command: Command::Save {
            render_id: 7, output: wide.clone(), save_options, crop_after_post: false, border: None,
            border_options: BorderOptions::default(), instagram: false,
            crop: None, rotate_cw: 0, fit: None,
        } }, Path::new(".")).unwrap();
        let mut decoder = image::ImageReader::open(&wide).unwrap().into_decoder().unwrap();
        let icc = image::ImageDecoder::icc_profile(&mut decoder).unwrap().unwrap();
        let p3 = RgbColourspace::find("Display P3").unwrap();
        assert_eq!(icc, spektrafilm_io::icc::profile(p3, false));
        let pixels = image::DynamicImage::from_decoder(decoder).unwrap().to_rgb16().into_raw();
        // sRGB's (0, 0.5, 1) and (1, 0.5, 0) lie inside Display P3's primaries.
        assert!(pixels[0] > 0 && pixels[2] < 65535, "{pixels:?}");
        assert!(pixels[3] < 65535 && pixels[5] > 0, "{pixels:?}");
        std::fs::remove_dir_all(dir).unwrap();
    }
    /// A Display P3 preview renders in P3 and shows through the Rec. 2020
    /// proxy; saving it as P3 writes the render's own values, and saving it
    /// as sRGB converts them. The original view shares the preview space.
    #[test]
    fn wide_preview_space_renders_and_saves_without_reconverting() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("negs-wide-preview-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        let pixels = (0..24 * 16 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(24, 16, pixels), &input, None).unwrap();
        let mut session = Session::default();
        let Command::Render { mut params, .. } = render(&input, &preview, None, None, None) else { unreachable!() };
        params.io.output_color_space = "Display P3".into();
        params.settings.serial_grain = false;
        let command = |params: Box<RuntimeParams>| Command::Render {
            input: input.clone(), source_generation: 1, film: "kodak_portra_400".into(),
            paper: "kodak_portra_endura".into(), params, limit_preview: false,
            preview_path: preview.clone(), interactive_scale: None, crop: None,
        };
        let response = session.handle(Request { id: 1, command: command(params.clone()) }, &data).unwrap();
        assert_eq!(response["output_color_space"], "Display P3");
        assert_eq!(response["display_color_space"], DisplaySpace::Rec2020SrgbTransfer.name());
        let rendered = session.output.as_ref().unwrap();
        assert_eq!(rendered.encoding, Encoding::new("Display P3", true));
        let mut clipped = rendered.image.clone();
        spektrafilm_core::pipeline::clip_to_display(&mut clipped, true);

        let save = |session: &mut Session, name: &str, space: &str| {
            let output = dir.join(name);
            let save_options = spektrafilm_io::save::SaveOptions {
                bit_depth: Some(16), color_space: space.into(), ..Default::default()
            };
            session.handle(Request { id: 2, command: Command::Save {
                render_id: 1, output: output.clone(), save_options, crop_after_post: false, border: None,
                border_options: BorderOptions::default(), instagram: false, crop: None, rotate_cw: 0, fit: None,
            } }, &data).unwrap();
            image::open(&output).unwrap().to_rgb16().into_raw()
        };
        let p3 = save(&mut session, "p3.png", "Display P3");
        for (saved, want) in p3.iter().zip(&clipped.data) {
            assert!((f64::from(*saved) / 65535.0 - f64::from(*want)).abs() <= 0.5 / 65535.0 + 1e-6);
        }
        let srgb = save(&mut session, "srgb.png", "sRGB");
        let mut converted = clipped.clone();
        convert_output(&mut converted, "Display P3", "sRGB", true);
        for (saved, want) in srgb.iter().zip(&converted.data) {
            assert!((f64::from(*saved) / 65535.0 - f64::from(*want)).abs() <= 0.5 / 65535.0 + 1e-6);
        }
        assert_ne!(p3, srgb);

        let original = session.handle(Request { id: 3, command: Command::Original {
            input: input.clone(), params, limit_preview: false, preview_path: dir.join("original.rgba"),
        } }, &data).unwrap();
        assert_eq!(original["display_color_space"], DisplaySpace::Rec2020SrgbTransfer.name());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Local Contrast reaches the preview and the saved file, as the rest of
    /// Post does, though it needs the whole picture.
    #[test]
    fn local_contrast_reaches_the_preview_and_the_save() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("negs-local-contrast-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        // A step edge, so Local Contrast has something to do.
        let pixels = (0..64 * 32).flat_map(|i| [if i % 64 < 32 { 0.15 } else { 0.6 }; 3]).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(64, 32, pixels), &input, None).unwrap();
        let shot = |amount: f32, name: &str| {
            let mut session = Session::default();
            let Command::Render { mut params, .. } = render(&input, &preview, None, None, None) else { unreachable!() };
            params.settings.serial_grain = false;
            params.film_render.grain.active = false;
            params.post.local_contrast = amount;
            session.handle(Request { id: 1, command: Command::Render {
                input: input.clone(), source_generation: 1, film: "kodak_portra_400".into(),
                paper: "kodak_portra_endura".into(), params, limit_preview: false,
                preview_path: preview.clone(), interactive_scale: None, crop: None,
            } }, &data).unwrap();
            let shown = std::fs::read(&preview).unwrap();
            let output = dir.join(name);
            session.handle(Request { id: 2, command: Command::Save {
                render_id: 1, output: output.clone(), save_options: spektrafilm_io::save::SaveOptions { bit_depth: Some(16), ..Default::default() },
                crop_after_post: false, border: None, border_options: BorderOptions::default(), instagram: false,
                crop: None, rotate_cw: 0, fit: None,
            } }, &data).unwrap();
            (shown, image::open(&output).unwrap().to_rgb16().into_raw())
        };
        let (plain_shown, plain_saved) = shot(0.0, "plain.png");
        let (lc_shown, lc_saved) = shot(80.0, "lc.png");
        assert_ne!(plain_shown, lc_shown, "the preview shows it");
        assert_ne!(plain_saved, lc_saved, "the file has it");
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn render(input: &Path, preview: &Path, target: Option<u32>, crop: Option<Crop>, interactive_scale: Option<f32>) -> Command {
        let mut params = RuntimeParams::default();
        params.io.photo_long_side_px = target;
        Command::Render {
            input: input.into(), source_generation: 1, film: "kodak_portra_400".into(),
            paper: "kodak_portra_endura".into(), params: Box::new(params), limit_preview: false,
            preview_path: preview.into(), interactive_scale, crop,
        }
    }

    /// A lab scan meters its balance once per photograph: the operator's
    /// keys re-render without metering again, and the scanner reuses the
    /// calibrated pipeline. The zone readout reads with that balance.
    #[test]
    fn lab_scan_meters_its_balance_once_per_photograph() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("negs-lab-balance-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        let pixels = (0..48 * 32 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(48, 32, pixels), &input, None).unwrap();
        let lab = |edit: &dyn Fn(&mut RuntimeParams)| {
            let Command::Render { mut params, .. } = render(&input, &preview, None, None, None) else { unreachable!() };
            params.io.output_route = spektrafilm_core::params::OutputRoute::LabScan;
            edit(&mut params);
            (*params).clone()
        };
        let command = |params: &RuntimeParams| Command::Render {
            input: input.clone(), source_generation: 1, film: "kodak_portra_400".into(),
            paper: "kodak_portra_endura".into(), params: Box::new(params.clone()), limit_preview: false,
            preview_path: preview.clone(), interactive_scale: None, crop: None,
        };
        let mut session = Session::default();
        session.handle(Request { id: 1, command: command(&lab(&|_| {})) }, &data).unwrap();
        let plain = session.output.as_ref().unwrap().image.data.clone();
        let metered = session.lab_balance.clone().expect("metered");

        let keyed = lab(&|p| p.scanner.density_key = 3.0);
        session.handle(Request { id: 2, command: command(&keyed) }, &data).unwrap();
        assert_ne!(session.output.as_ref().unwrap().image.data, plain, "the key re-renders");
        assert_eq!(session.lab_balance.as_ref(), Some(&metered), "without metering again");
        let steeper = lab(&|p| p.scanner.contrast_key = 3.0);
        session.handle(Request { id: 2, command: command(&steeper) }, &data).unwrap();
        assert_ne!(session.output.as_ref().unwrap().image.data, plain, "the contrast key re-renders");
        assert_eq!(session.lab_balance.as_ref(), Some(&metered), "and isn't metered");
        let shifted = lab(&|p| { p.prep.exposure_ev = 1.0; p.camera.exposure_compensation_ev = 0.5 });
        session.handle(Request { id: 2, command: command(&shifted) }, &data).unwrap();
        assert_eq!(session.lab_balance.as_ref(), Some(&metered), "an exposure edit isn't metered");

        let noritsu = lab(&|p| p.scanner.model = spektrafilm_core::params::ScannerModel::Noritsu);
        let response = session.handle(Request { id: 3, command: command(&noritsu) }, &data).unwrap();
        assert_eq!(response["cached_pipeline"], true, "the scanner needs no new pipeline");
        assert!(session.developed_photo.reuses() + session.developed_interactive.reuses() >= 1, "nor a new develop");
        assert_ne!(session.lab_balance.as_ref().map(|b| &b.0), Some(&metered.0));

        let balance = session.lab_balance.as_ref().unwrap().1;
        assert_eq!(session.lab_balance("kodak_portra_400", "kodak_portra_endura", &noritsu), Some(balance));
        let reading = session.handle(Request { id: 4, command: Command::ZoneReadout {
            film: "kodak_portra_400".into(), paper: "kodak_portra_endura".into(), params: Box::new(noritsu.clone()),
            x0: 0.2, y0: 0.2, x1: 0.4, y1: 0.4, targets: vec![],
        } }, &data).unwrap();
        assert!(reading["printed"].as_f64().is_some_and(f64::is_finite));

        // The tone graph draws the scan with the photograph's balance, as the render has it.
        let graph = session.handle(Request { id: 5, command: Command::ToneCurve {
            film: "kodak_portra_400".into(), paper: "kodak_portra_endura".into(), params: Box::new(noritsu.clone()), count: Some(16),
        } }, &data).unwrap();
        let tone = spektrafilm_core::tone_curve::tone_params(&noritsu);
        let pipeline = build_pipeline(&data, "kodak_portra_400", "kodak_portra_endura", &tone).unwrap()
            .with_params(tone).with_lab_balance(balance);
        let want = spektrafilm_core::tone_curve::tone_curve(&pipeline, 16);
        assert_eq!(graph["rgb"], json!(want.rgb));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// The app renders a film change at canvas size first (ticket 28): the
    /// export-size render that follows matches one made without that step,
    /// in the kept output and in the display buffer.
    #[test]
    fn a_quick_frame_before_a_film_change_leaves_its_settled_render_unchanged() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("negs-quick-frame-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        let pixels = (0..96 * 64 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(96, 64, pixels), &input, None).unwrap();
        let with_film = |film: &str, interactive_scale: Option<f32>| {
            let Command::Render { mut params, .. } = render(&input, &preview, None, None, None) else { unreachable!() };
            params.settings.serial_grain = false;
            Command::Render {
                input: input.clone(), source_generation: 1, film: film.into(), paper: "kodak_portra_endura".into(),
                params, limit_preview: false, preview_path: preview.clone(), interactive_scale, crop: None,
            }
        };
        let settled = |quick_first: bool| {
            let mut session = Session::default();
            session.handle(Request { id: 1, command: with_film("kodak_portra_400", None) }, &data).unwrap();
            if quick_first {
                let quick = session.handle(Request { id: 2, command: with_film("kodak_gold_200", Some(0.5)) }, &data).unwrap();
                assert_eq!(quick["output_width"].as_u64(), Some(48));
                assert_eq!(quick["export_resolution"].as_bool(), Some(false));
            }
            let response = session.handle(Request { id: 3, command: with_film("kodak_gold_200", None) }, &data).unwrap();
            assert_eq!(response["export_resolution"].as_bool(), Some(true));
            (session.output.unwrap().image.data, std::fs::read(&preview).unwrap())
        };
        let (direct, direct_display) = settled(false);
        let (after_quick, after_quick_display) = settled(true);
        assert!(direct == after_quick, "the settled render differs after a quick frame");
        assert!(direct_display == after_quick_display, "the display buffer differs after a quick frame");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn image_size_renders_report_sizes_reuse_pans_and_keep_drags_within_the_source() {
        let data = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../data");
        let dir = std::env::temp_dir().join(format!("negs-image-size-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (input, preview) = (dir.join("input.png"), dir.join("preview.rgba"));
        let pixels = (0..40 * 30 * 3).map(|i| ((i * 37) % 255) as spektrafilm_math::Scalar / 255.0).collect();
        spektrafilm_io::save_image(&ImageBuf::from_data(40, 30, pixels), &input, None).unwrap();
        let mut session = Session::default();
        let mut send = |id, command| session.handle(Request { id, command }, &data);

        // A centred half-extent crop at 60 px develops the whole frame at 120 × 90.
        let centre = Crop { x: 0.25, y: 0.25, width: 0.5, height: 0.5, angle: 0.0 };
        let full = send(1, render(&input, &preview, Some(60), Some(centre), None)).unwrap();
        assert_eq!((full["working_width"].as_u64(), full["working_height"].as_u64()), (Some(120), Some(90)));
        assert_eq!((full["photo_crop_width"].as_u64(), full["photo_crop_height"].as_u64()), (Some(60), Some(45)));
        assert_eq!((full["output_width"].as_u64(), full["source_width"].as_u64()), (Some(120), Some(40)));
        assert_eq!(full["export_resolution"], true);
        drop(send);
        let image = session.output.as_ref().unwrap().image.data.as_ptr();

        // Panning the crop reuses the simulation and reports its own pixels.
        let mut send = |id, command| session.handle(Request { id, command }, &data);
        let panned = Crop { x: 0.2, y: 0.3, ..centre };
        let reused = send(2, render(&input, &preview, Some(60), Some(panned), None)).unwrap();
        assert_eq!(reused["photo_crop_width"].as_u64(), Some(60));
        assert_eq!(reused["output_width"].as_u64(), Some(120));
        drop(send);
        let retained = session.output.as_ref().unwrap();
        assert_eq!((retained.id, retained.image.data.as_ptr()), (2, image));

        // Zoomed past fit on a 3x enlargement, a drag frame stays inside the
        // source and is never saved as an export.
        let mut send = |id, command| session.handle(Request { id, command }, &data);
        let drag = send(3, render(&input, &preview, Some(120), None, Some(0.6))).unwrap();
        assert_eq!((drag["output_width"].as_u64(), drag["output_height"].as_u64()), (Some(40), Some(30)));
        assert_eq!(drag["export_resolution"], false);
        assert_eq!(drag["working_width"].as_u64(), Some(120));

        // Too large a request fails before allocation and keeps the last render.
        let speck = Crop { x: 0.5, y: 0.5, width: 0.002, height: 0.002, angle: 0.0 };
        let error = send(4, render(&input, &preview, Some(65_535), Some(speck), None)).unwrap_err().to_string();
        assert!(error.contains("MP limit"), "{error}");
        let mixed = {
            let Command::Render { mut params, .. } = render(&input, &preview, Some(60), None, None) else { unreachable!() };
            params.io.upscale_factor = 0.5;
            Command::Render { input: input.clone(), source_generation: 1, film: "kodak_portra_400".into(),
                paper: "kodak_portra_endura".into(), params, limit_preview: false, preview_path: preview.clone(),
                interactive_scale: None, crop: None }
        };
        assert!(send(5, mixed).unwrap_err().to_string().contains("factor must be 1"));
        // Original never enlarges, whatever the target.
        let original = send(6, Command::Original { input: input.clone(), params: {
            let mut params = RuntimeParams::default(); params.io.photo_long_side_px = Some(400); Box::new(params)
        }, limit_preview: false, preview_path: preview.clone() }).unwrap();
        assert_eq!((original["width"].as_u64(), original["height"].as_u64()), (Some(40), Some(30)));
        drop(send);
        assert_eq!(session.output.as_ref().unwrap().id, 3);
        assert_ne!(session.output.as_ref().unwrap().image.data.as_ptr(), image);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn working_source_is_resampled_once_per_size() {
        let source = ImageBuf::from_data(4, 2, vec![0.5; 24]);
        let mut scaled = None;
        let first = working_source(&source, &mut scaled, (2, 1), rescale_preview_input_fast)
            .data
            .as_ptr();
        assert_eq!(
            working_source(&source, &mut scaled, (2, 1), rescale_preview_input_fast)
                .data
                .as_ptr(),
            first
        );
        assert_eq!(
            working_source(&source, &mut scaled, (1, 1), rescale_preview_input_fast).width,
            1
        );
        let full = working_source(&source, &mut scaled, (4, 2), rescale_preview_input_fast);
        assert_eq!(full.data.as_ptr(), source.data.as_ptr());
        assert!(scaled.is_none());
    }
    #[test]
    fn save_reads_the_apps_border_options() {
        use spektrafilm_io::border::Rgb;
        // As `saveCommand` in the app's EditorModel writes it.
        let request: Request = serde_json::from_str(
            r##"{"id": 1, "command": "save", "render_id": 1, "output": "out.png", "rotate_cw": 0,
                "border": "white", "instagram": true,
                "border_options": {"width": 0.05, "line": 0.004, "color": "#1f2a44", "line_color": "#000000"}}"##,
        )
        .unwrap();
        let Command::Save {
            border,
            border_options,
            instagram,
            save_options,
            crop_after_post,
            ..
        } = request.command
        else {
            panic!("not a save")
        };
        assert_eq!(border, Some(BorderStyle::Solid));
        assert!(instagram);
        assert_eq!(save_options.jpeg_quality, 95);
        assert!(save_options.copy_metadata);
        assert_eq!(save_options.bit_depth, None);
        assert_eq!(save_options.color_space, "sRGB");
        assert!(!crop_after_post, "existing clients retain their original Post/crop order");
        assert_eq!(
            border_options,
            BorderOptions {
                width: Some(0.05),
                color: Rgb([0x1f, 0x2a, 0x44]),
                ..Default::default()
            }
        );
    }

    #[test]
    fn stale_preview_cannot_be_saved() {
        let mut session = Session {
            output: Some(Rendered {
                id: 2,
                key: Value::Null,
                response: Value::Null,
                source: "source.png".into(),
                film: "kodak_gold_200".into(),
                encoding: Encoding::from(true),
                post: PostParams::default(),
                image: ImageBuf::from_data(1, 1, vec![0.0; 3]),
            }),
            ..Default::default()
        };
        let request = Request {
            id: 3,
            command: Command::Save {
                render_id: 1,
                output: "unused.png".into(),
                save_options: Default::default(),
                crop_after_post: false,
                border: None,
                border_options: BorderOptions::default(),
                instagram: false,
                crop: None,
                rotate_cw: 0,
                fit: None,
            },
        };
        assert!(
            session
                .handle(request, Path::new("."))
                .unwrap_err()
                .to_string()
                .contains("preview changed")
        );
    }
}
