// Post adjustments in the display pass: `PostProcess::apply_rgb`
// (crates/spektrafilm-core/src/post.rs) with the same tables and the same
// f32 arithmetic, so a presented frame matches the CPU's adjusted scan.
// Appended to the display shaders, which declare `post` (a `Post`) and
// `post_tables` (decode, encode, tone, channel and levels, `POST_LUT` values
// each) at their
// own bindings.

const POST_LUT: u32 = 4096u;

struct Post {
    on: u32,
    encoded: u32,
    // The chroma scale on OKLab a and b.
    saturation: f32,
    _pad: u32,
    luma: vec4<f32>,
    // to_work, from_work, to_lms, from_lms, m2, m2_inv; three rows each.
    matrices: array<vec4<f32>, 18>,
}

// `lookup` in post.rs: linear interpolation in table `t` (0 decode,
// 1 encode, 2 tone, 3 channel, 4 levels), sampled on [0, 1].
fn post_lookup(t: u32, x: f32) -> f32 {
    let at = clamp(x, 0.0, 1.0) * f32(POST_LUT - 1u);
    let i = min(u32(at), POST_LUT - 2u);
    let f = at - f32(i);
    let a = post_tables[t * POST_LUT + i];
    let b = post_tables[t * POST_LUT + i + 1u];
    return a + (b - a) * f;
}

// `mul` in post.rs: matrix `m` of `matrices` times `c`, summed in the same order.
fn post_mul(m: u32, c: vec3<f32>) -> vec3<f32> {
    let r0 = post.matrices[m * 3u].xyz;
    let r1 = post.matrices[m * 3u + 1u].xyz;
    let r2 = post.matrices[m * 3u + 2u].xyz;
    return vec3<f32>(
        r0.x * c.x + r0.y * c.y + r0.z * c.z,
        r1.x * c.x + r1.y * c.y + r1.z * c.z,
        r2.x * c.x + r2.y * c.y + r2.z * c.z,
    );
}

// `luminance_through`: luminance through table `t`, the channels scaled together.
fn post_luminance(t: u32, c: vec3<f32>) -> vec3<f32> {
    let y = post.luma.r * c.r + post.luma.g * c.g + post.luma.b * c.b;
    let y2 = post_lookup(t, sqrt(max(y, 0.0)));
    if y <= 1e-9 {
        return vec3<f32>(y2);
    }
    let s = c * (y2 / y);
    // Above white, give up saturation rather than luminance or hue.
    let top = max(s.r, max(s.g, s.b));
    if top > 1.0 {
        let k = (1.0 - y2) / (top - y2);
        return y2 + (s - y2) * k;
    }
    return s;
}

// Contrast on one working-space channel: mirrored below zero, left alone past one.
fn post_channel(v: f32) -> f32 {
    let a = abs(v);
    if a > 1.0 {
        return v;
    }
    return sign(v) * post_lookup(3u, sqrt(a));
}

fn post_oklab(c: vec3<f32>) -> vec3<f32> {
    let lms = post_mul(2u, c);
    return post_mul(4u, vec3<f32>(post_cbrt(lms.x), post_cbrt(lms.y), post_cbrt(lms.z)));
}

fn post_from_oklab(lab: vec3<f32>) -> vec3<f32> {
    let l = post_mul(5u, lab);
    return post_mul(3u, l * l * l);
}

// f32::cbrt, sign kept.
fn post_cbrt(v: f32) -> f32 {
    return sign(v) * pow(abs(v), 1.0 / 3.0);
}

fn post_in_gamut(c: vec3<f32>) -> bool {
    return all(c >= vec3<f32>(-1e-6)) && all(c <= vec3<f32>(1.0 + 1e-6));
}

// A scan pixel, NaN-free and clipped to [0, 1], adjusted; in the scan's
// encoding, clipped too.
fn post_rgb(rgb: vec3<f32>) -> vec3<f32> {
    if post.on == 0u {
        return rgb;
    }
    var c = rgb;
    if post.encoded == 1u {
        c = vec3<f32>(post_lookup(0u, c.r), post_lookup(0u, c.g), post_lookup(0u, c.b));
    }
    c = post_luminance(2u, c);
    let w = post_mul(0u, c);
    c = post_mul(1u, vec3<f32>(post_channel(w.x), post_channel(w.y), post_channel(w.z)));
    c = post_luminance(4u, c);
    let k = post.saturation;
    if k != 1.0 {
        let lab = post_oklab(c);
        c = post_from_oklab(vec3<f32>(lab.x, lab.yz * k));
        if !post_in_gamut(c) {
            // Back off to the gamut boundary, keeping lightness and hue.
            var lo = 1.0;
            var hi = k;
            for (var i = 0u; i < 12u; i++) {
                let mid = 0.5 * (lo + hi);
                if post_in_gamut(post_from_oklab(vec3<f32>(lab.x, lab.yz * mid))) {
                    lo = mid;
                } else {
                    hi = mid;
                }
            }
            c = post_from_oklab(vec3<f32>(lab.x, lab.yz * lo));
        }
    }
    c = clamp(c, vec3<f32>(0.0), vec3<f32>(1.0));
    if post.encoded == 1u {
        c = vec3<f32>(post_lookup(1u, sqrt(c.r)), post_lookup(1u, sqrt(c.g)), post_lookup(1u, sqrt(c.b)));
    }
    return c;
}
