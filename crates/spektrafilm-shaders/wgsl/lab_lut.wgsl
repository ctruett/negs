// Lab scanner: developed film density CMY → output RGB, as the CPU's
// `lab_scan::ScanPixel::scan` computes it, step for step:
//   1. Status M net density: the film's density LUT, tetrahedral, as
//      spektrafilm_math::tetra3d interpolates it (same grid, same branches).
//   2. The look's input: net × a + b per channel (the film's sign, the
//      frame's balance, the contrast key, the operator's keys, the look's gain).
//   3. The look's monotone cubic per channel (Fritsch–Carlson tangents from the
//      CPU), straight on with the end slope beyond the knots.
//   4. The look's matrix and cast, 10^x, then linear Rec. 2020 to the output
//      space, unclipped.
//   5. The highlight shoulder per channel (lab_scan::shoulder).
// Gamut compression, the scanner's blur and sharpening and the encoding
// follow as for any scan.

struct Params {
    width: u32,
    height: u32,
    size: u32,
    n_knots: u32,
    lo: vec4<f32>,
    inv: vec4<f32>,
    a: vec4<f32>,
    b: vec4<f32>,
    tint: vec4<f32>,
    // The look's matrix and the conversion to the output space, by columns.
    matrix: mat3x3<f32>,
    to_output: mat3x3<f32>,
}

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> density_cmy: array<f32>;       // [H*W*3]
@group(0) @binding(2) var<storage, read> net_lut: array<f32>;           // [size^3*3], c slowest
@group(0) @binding(3) var<storage, read> curve: array<f32>;             // knots[n], values[3][n], tangents[3][n]
@group(0) @binding(4) var<storage, read_write> output_rgb: array<f32>;  // [H*W*3]

override WORKGROUP_SIZE: u32 = 1024u;

fn at(i: u32, j: u32, k: u32, c: u32) -> f32 {
    let n = params.size;
    return net_lut[((i * n + j) * n + k) * 3u + c];
}

// spektrafilm_math::pchip3d::cubic_base_fraction
fn base_fraction(coord: f32) -> vec2<f32> {
    let upper = f32(params.size - 1u);
    let c = clamp(coord, 0.0, upper);
    if c >= upper {
        return vec2<f32>(f32(params.size - 2u), 1.0);
    }
    let base = floor(c);
    return vec2<f32>(base, c - base);
}

// spektrafilm_math::tetra3d::tetrahedral_interp, one channel.
fn tetra(i: u32, j: u32, k: u32, fr: f32, fg: f32, fb: f32, c: u32) -> f32 {
    let c000 = at(i, j, k, c);
    let c111 = at(i + 1u, j + 1u, k + 1u, c);
    if fr > fg {
        if fg > fb {
            let c100 = at(i + 1u, j, k, c);
            let c110 = at(i + 1u, j + 1u, k, c);
            return c000 + fr * (c100 - c000) + fg * (c110 - c100) + fb * (c111 - c110);
        } else if fr > fb {
            let c100 = at(i + 1u, j, k, c);
            let c101 = at(i + 1u, j, k + 1u, c);
            return c000 + fr * (c100 - c000) + fb * (c101 - c100) + fg * (c111 - c101);
        }
        let c001 = at(i, j, k + 1u, c);
        let c101 = at(i + 1u, j, k + 1u, c);
        return c000 + fb * (c001 - c000) + fr * (c101 - c001) + fg * (c111 - c101);
    } else if fb > fg {
        let c001 = at(i, j, k + 1u, c);
        let c011 = at(i, j + 1u, k + 1u, c);
        return c000 + fb * (c001 - c000) + fg * (c011 - c001) + fr * (c111 - c011);
    } else if fb > fr {
        let c010 = at(i, j + 1u, k, c);
        let c011 = at(i, j + 1u, k + 1u, c);
        return c000 + fg * (c010 - c000) + fb * (c011 - c010) + fr * (c111 - c011);
    }
    let c010 = at(i, j + 1u, k, c);
    let c110 = at(i + 1u, j + 1u, k, c);
    return c000 + fg * (c010 - c000) + fr * (c110 - c010) + fb * (c111 - c110);
}

// lab_scan::look::Look::curve_at for channel `c`.
fn curve_at(c: u32, x: f32) -> f32 {
    let n = params.n_knots;
    let v0 = n + c * n;          // values
    let m0 = 4u * n + c * n;     // tangents
    let last = n - 1u;
    if x <= curve[0] {
        return curve[v0] + curve[m0] * (x - curve[0]);
    }
    if x >= curve[last] {
        return curve[v0 + last] + curve[m0 + last] * (x - curve[last]);
    }
    var i = 0u;
    loop {
        if i + 1u >= last || curve[i + 1u] > x { break; }
        i += 1u;
    }
    let h = curve[i + 1u] - curve[i];
    let t = (x - curve[i]) / h;
    let t2 = t * t;
    let t3 = t2 * t;
    return (2.0 * t3 - 3.0 * t2 + 1.0) * curve[v0 + i]
        + (t3 - 2.0 * t2 + t) * h * curve[m0 + i]
        + (-2.0 * t3 + 3.0 * t2) * curve[v0 + i + 1u]
        + (t3 - t2) * h * curve[m0 + i + 1u];
}

// lab_scan::shoulder: straight to the knee, then a roll-off toward the ceiling.
const SHOULDER_KNEE: f32 = 0.75;
const SHOULDER_CEILING: f32 = 0.985;

fn shoulder(v: f32) -> f32 {
    if !(v > SHOULDER_KNEE) {
        return v;
    }
    let room = SHOULDER_CEILING - SHOULDER_KNEE;
    let t = (v - SHOULDER_KNEE) / room;
    return SHOULDER_KNEE + room * (1.0 - 1.0 / (1.0 + t));
}

@compute @workgroup_size(WORKGROUP_SIZE)
fn main(
    @builtin(global_invocation_id) gid: vec3<u32>,
    @builtin(num_workgroups) groups: vec3<u32>,
) {
    let pixel_idx = gid.y * groups.x * WORKGROUP_SIZE + gid.x;
    if pixel_idx >= params.width * params.height {
        return;
    }
    let base = pixel_idx * 3u;
    let d = vec3<f32>(density_cmy[base], density_cmy[base + 1u], density_cmy[base + 2u]);
    // A NaN density stays NaN, as on the CPU.
    if any(d != d) {
        let nan = bitcast<f32>(0x7fc00000u);
        output_rgb[base] = nan;
        output_rgb[base + 1u] = nan;
        output_rgb[base + 2u] = nan;
        return;
    }
    let q = (d - params.lo.xyz) * params.inv.xyz;
    let r = base_fraction(q.x);
    let g = base_fraction(q.y);
    let b = base_fraction(q.z);
    let i = u32(r.x);
    let j = u32(g.x);
    let k = u32(b.x);
    let net = vec3<f32>(
        tetra(i, j, k, r.y, g.y, b.y, 0u),
        tetra(i, j, k, r.y, g.y, b.y, 1u),
        tetra(i, j, k, r.y, g.y, b.y, 2u),
    );
    let x = net * params.a.xyz + params.b.xyz;
    let y = vec3<f32>(curve_at(0u, x.x), curve_at(1u, x.y), curve_at(2u, x.z));
    let log_rgb = params.matrix * y + params.tint.xyz;
    let rgb = params.to_output * pow(vec3<f32>(10.0), log_rgb);
    output_rgb[base] = shoulder(rgb.x);
    output_rgb[base + 1u] = shoulder(rgb.y);
    output_rgb[base + 2u] = shoulder(rgb.z);
}
