// Built-in shaders of the scene effects added after the SSAO (exec.c taa_run): TAA's motion vectors, its resolve and
// its copy back into the scene, the depth as R32F for DLSS. Kept out of shaders.c, whose text is part of the key of
// the shaders prepared on the player's PC (Makefile TRANSLATOR_SRCS: a change there prepares them all again).
// shaders.c builtin_src asks here for the names it does not know.
#include <string.h>
#include "../maxwell/shader.h"

const char *fx_builtin_src(const char *name, int *stage) {
    // Camera motion vectors: each pixel's position, rebuilt from its depth, taken to the previous frame by m = previous
    // view-projection x inverse of this one (the game's matrices, GL style). a.x = 1: depth stored as (z_ndc + 1) / 2;
    // a.y = the sign of NDC y at the bottom of the viewport. v = the scene's viewport in the depth's pixels (Sword's
    // dynamic resolution draws into part of its targets). Out (RGBA16F): xy = this uv - the previous frame's, in uv of
    // the whole texture; z = the pixel's distance in the previous frame / its distance now (disocclusion).
    if (!strcmp(name, "taa_mv.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D dep;\n"
               "layout(push_constant) uniform P { mat4 m; vec4 a; vec4 v; } pc;\n"
               "layout(location = 0) out vec4 o;\n"
               "void main() {\n"
               "  ivec2 sz = textureSize(dep, 0), p = ivec2(gl_FragCoord.xy);\n"
               "  float d = texelFetch(dep, p, 0).r;\n"
               "  vec2 uv = (vec2(p) + 0.5 - pc.v.xy) / pc.v.zw;\n"
               "  vec2 n = uv * 2.0 - 1.0;\n"
               "  n.y *= pc.a.y;\n"
               "  vec4 q = pc.m * vec4(n, pc.a.x > 0.5 ? d * 2.0 - 1.0 : d, 1.0);\n"
               "  vec2 pn = q.xy / q.w;\n"
               "  pn.y *= pc.a.y;\n"
               "  vec2 pu = pn * 0.5 + 0.5;\n"
               "  o = vec4((uv - pu) * pc.v.zw / vec2(sz), q.w, 1.0);\n"
               "}\n";
    }
    // TAA (Let's Go Recomp's), on the game's HDR scene before its bloom: t = this frame (jittered), h = the history
    // (rgb, a = its distance), mv = the motion vectors, dep = depth. a = the projection (P00, P11, A, B), b = (reset,
    // history weight, depth mode, 0), c = the viewport in uv (x0, y0, x1, y1): history outside it is not taken.
    // Blended in a tone-mapped space (c / (1 + max c): no fireflies from the bright highlights); the velocity of the
    // nearest of the 3x3 (edges keep the foreground's); the history by Catmull-Rom, clipped to the 3x3's YCoCg mean
    // +- 1.25 sigma (variance clipping), dropped where its distance is not the one expected (uncovered).
    // Out: rgb, a = this distance.
    // TAA v2 (2026-11-22, player: "TAA feels shaky and ghosty"; after Savage Wind Recomp's taa_lite, MIT, same LAS
    // lineage): the CURRENT frame is rebuilt at the pixel's un-jittered centre (Lanczos 2 over the 3x3 at their jittered
    // distances, deringed to the 3x3's range) - the old resolve took the raw jittered texel, so 10% of each frame's
    // sub-pixel offset reached the screen and edges wobbled. The history (Catmull-Rom) along the vector of the nearest
    // depth in the 3x3, clipped in tone-mapped YCoCg to the 3x3 mean +- 1.5 sigma (0.9 in fast motion) and its extremes.
    // The blend follows a per-pixel frame count (history .a = count / 16): 1 / (n + 1) down to 0.08 when still (0.3 in
    // fast motion). a = projection (unused), b = (reset, -, depth mode, -), c = viewport in uv, d = (jitter x, y in
    // pixels: the content's shift (reads stay inside the viewport c, pixels outside it get its edge: the band outside
    // Sword's 80% scene holds the clear colour - a light blue line at the top under jitter), the raw jittered sample's share of the new frame (sharper: real supersampling), -). LARECOMP_TAA_OLD=1: the old resolve (taa_old.frag).
    if (!strcmp(name, "taa.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D t;\n"
               "layout(set = 0, binding = 1) uniform sampler2D h;\n"
               "layout(set = 0, binding = 2) uniform sampler2D mv;\n"
               "layout(set = 0, binding = 3) uniform sampler2D dep;\n"
               "layout(push_constant) uniform P { vec4 a; vec4 b; vec4 c; vec4 d; } pc;\n"
               "layout(location = 0) out vec4 o;\n"
               "vec3 tm(vec3 c) { return c / (1.0 + max(c.r, max(c.g, c.b))); }\n"
               "vec3 itm(vec3 c) { return c / max(1.0 - max(c.r, max(c.g, c.b)), 1e-4); }\n"
               "vec3 ycc(vec3 c) { return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b); }\n"
               "vec3 rgb(vec3 y) { return vec3(y.x + y.y - y.z, y.x + y.z, y.x - y.y - y.z); }\n"
               "float lz2(float x2) { x2 = min(x2, 4.0); float a = 0.4 * x2 - 1.0, b = 0.25 * x2 - 1.0; return (25.0 / 16.0 * a * a - 9.0 / 16.0) * (b * b); }\n"
               "vec4 cat(vec2 uv, vec2 sz) {\n"
               "  vec2 sp = uv * sz, tp = floor(sp - 0.5) + 0.5, f = sp - tp;\n"
               "  vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f)), w1 = 1.0 + f * f * (-2.5 + 1.5 * f);\n"
               "  vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f)), w3 = f * f * (-0.5 + 0.5 * f);\n"
               "  vec2 w12 = w1 + w2, t0 = (tp - 1.0) / sz, t3 = (tp + 2.0) / sz, t12 = (tp + w2 / w12) / sz;\n"
               "  float a = w12.x * w0.y, b = w0.x * w12.y, c = w12.x * w12.y, d = w3.x * w12.y, e = w12.x * w3.y;\n"
               "  vec4 r = textureLod(h, vec2(t12.x, t0.y), 0.0) * a + textureLod(h, vec2(t0.x, t12.y), 0.0) * b + textureLod(h, t12, 0.0) * c\n"
               "         + textureLod(h, vec2(t3.x, t12.y), 0.0) * d + textureLod(h, vec2(t12.x, t3.y), 0.0) * e;\n"
               "  return max(r / (a + b + c + d + e), vec4(0.0));\n"
               "}\n"
               "void main() {\n"
               "  ivec2 sz = textureSize(t, 0), dsz = textureSize(dep, 0), msz = textureSize(mv, 0);\n"
               "  ivec2 rmin = ivec2(floor(pc.c.xy * vec2(sz) + 0.5)), rmax = max(ivec2(floor(pc.c.zw * vec2(sz) + 0.5)) - 1, rmin);\n"
               "  ivec2 p = clamp(ivec2(gl_FragCoord.xy), rmin, rmax);\n"
               "  vec2 dsc = vec2(dsz) / vec2(sz), J = pc.d.xy;\n"
               "  vec3 c0 = max(texelFetch(t, p, 0).rgb, vec3(0.0));\n"
               "  vec3 up = vec3(0.0), m1 = vec3(0.0), m2 = vec3(0.0), lo = vec3(1e9), hi = vec3(-1e9);\n"
               "  float uw = 0.0, dn = 2.0;\n"
               "  ivec2 np = p;\n"
               "  for (int y = -1; y <= 1; y++)\n"
               "    for (int x = -1; x <= 1; x++) {\n"
               "      ivec2 q = clamp(p + ivec2(x, y), rmin, rmax);\n"
               "      vec3 s = ycc(tm(max(texelFetch(t, q, 0).rgb, vec3(0.0))));\n"
               "      vec2 of = vec2(x, y) - J;\n"
               "      float w = lz2(dot(of, of));\n"
               "      up += s * w; uw += w;\n"
               "      m1 += s; m2 += s * s; lo = min(lo, s); hi = max(hi, s);\n"
               "      float d = texelFetch(dep, min(ivec2(vec2(q) * dsc), dsz - 1), 0).r;\n"
               "      if (pc.b.z < 0.5 ? d < dn : d < dn) { dn = d; np = q; }\n"
               "    }\n"
               "  m1 /= 9.0;\n"
               "  vec3 sg = sqrt(max(m2 / 9.0 - m1 * m1, vec3(0.0)));\n"
               "  up = uw > 1e-4 ? clamp(up / uw, lo, hi) : ycc(tm(c0));\n"
               "  up = mix(up, ycc(tm(c0)), pc.d.z);\n"
               "  vec4 v = texelFetch(mv, min(ivec2(vec2(np) * vec2(msz) / vec2(sz)), msz - 1), 0);\n"
               "  vec2 uv = (vec2(p) + 0.5) / vec2(sz), pu = uv - v.xy;\n"
               "  bool fresh = pc.b.x > 0.5 || any(lessThan(pu, pc.c.xy)) || any(greaterThan(pu, pc.c.zw));\n"
               "  vec3 res = up;\n"
               "  float cnt = 1.0;\n"
               "  if (!fresh) {\n"
               "    vec4 hh = cat(pu, vec2(textureSize(h, 0)));\n"
               "    vec3 hy = ycc(tm(hh.rgb));\n"
               "    float vel = length(v.xy * vec2(sz)), prevn = clamp(hh.a, 0.0, 1.0) * 16.0;\n"
               "    float g = mix(1.5, 0.9, clamp(vel / 8.0, 0.0, 1.0));\n"
               "    vec3 bmin = max(m1 - g * sg, lo), bmax = min(m1 + g * sg, hi);\n"
               "    vec3 ce = 0.5 * (bmin + bmax), ex = 0.5 * (bmax - bmin) + 1e-5, dl = hy - ce, u3 = abs(dl / ex);\n"
               "    float mx = max(u3.x, max(u3.y, u3.z));\n"
               "    if (mx > 1.0) hy = ce + dl / mx;\n"
               "    float al = max(1.0 / (prevn + 1.0), mix(pc.b.y, 0.3, clamp(vel / 16.0, 0.0, 1.0)));\n"
               "    res = mix(hy, up, al);\n"
               "    cnt = min(prevn + 1.0, 16.0);\n"
               "  }\n"
               "  o = vec4(max(itm(rgb(res)), vec3(0.0)), cnt / 16.0);\n"
               "}\n";
    }
    if (!strcmp(name, "taa_old.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D t;\n"
               "layout(set = 0, binding = 1) uniform sampler2D h;\n"
               "layout(set = 0, binding = 2) uniform sampler2D mv;\n"
               "layout(set = 0, binding = 3) uniform sampler2D dep;\n"
               "layout(push_constant) uniform P { vec4 a; vec4 b; vec4 c; } pc;\n"
               "layout(location = 0) out vec4 o;\n"
               "float lin(float d) { return pc.a.w / ((pc.b.z > 0.5 ? d * 2.0 - 1.0 : d) + pc.a.z); }\n"
               "vec3 tm(vec3 c) { return c / (1.0 + max(c.r, max(c.g, c.b))); }\n"
               "vec3 itm(vec3 c) { return c / max(1.0 - max(c.r, max(c.g, c.b)), 1e-4); }\n"
               "vec3 ycc(vec3 c) { return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b); }\n"
               "vec3 rgb(vec3 y) { return vec3(y.x + y.y - y.z, y.x + y.z, y.x - y.y - y.z); }\n"
               "vec3 cat(vec2 uv, vec2 sz) {\n"  // Catmull-Rom, 5 bilinear taps (the corners dropped)
               "  vec2 sp = uv * sz, tp = floor(sp - 0.5) + 0.5, f = sp - tp;\n"
               "  vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f)), w1 = 1.0 + f * f * (-2.5 + 1.5 * f);\n"
               "  vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f)), w3 = f * f * (-0.5 + 0.5 * f);\n"
               "  vec2 w12 = w1 + w2, t0 = (tp - 1.0) / sz, t3 = (tp + 2.0) / sz, t12 = (tp + w2 / w12) / sz;\n"
               "  vec3 r = texture(h, vec2(t12.x, t0.y)).rgb * (w12.x * w0.y) + texture(h, vec2(t0.x, t12.y)).rgb * (w0.x * w12.y)\n"
               "         + texture(h, t12).rgb * (w12.x * w12.y) + texture(h, vec2(t3.x, t12.y)).rgb * (w3.x * w12.y)\n"
               "         + texture(h, vec2(t12.x, t3.y)).rgb * (w12.x * w3.y);\n"
               "  float ws = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;\n"
               "  return max(r / ws, vec3(0.0));\n"
               "}\n"
               "void main() {\n"
               "  ivec2 sz = textureSize(t, 0), p = ivec2(gl_FragCoord.xy);\n"
               "  ivec2 dsz = textureSize(dep, 0);\n"
               "  vec3 c = max(texelFetch(t, p, 0).rgb, vec3(0.0));\n"
               "  vec2 dsc = vec2(dsz) / vec2(sz);\n"
               "  float l = lin(texelFetch(dep, min(ivec2(vec2(p) * dsc), dsz - 1), 0).r);\n"
               "  if (pc.b.x > 0.5) { o = vec4(c, l); return; }\n"
               "  vec3 m1 = vec3(0.0), m2 = vec3(0.0);\n"
               "  float dn = 1.0;\n"
               "  ivec2 np = p;\n"
               "  for (int y = -1; y <= 1; y++)\n"
               "    for (int x = -1; x <= 1; x++) {\n"
               "      ivec2 q = clamp(p + ivec2(x, y), ivec2(0), sz - 1);\n"
               "      vec3 s = ycc(tm(max(texelFetch(t, q, 0).rgb, vec3(0.0))));\n"
               "      m1 += s; m2 += s * s;\n"
               "      float d = texelFetch(dep, min(ivec2(vec2(q) * dsc), dsz - 1), 0).r;\n"
               "      if (d < dn) { dn = d; np = q; }\n"
               "    }\n"
               "  m1 /= 9.0;\n"
               "  vec3 sg = sqrt(max(m2 / 9.0 - m1 * m1, vec3(0.0)));\n"
               "  vec4 v = texelFetch(mv, min(ivec2(vec2(np) * vec2(textureSize(mv, 0)) / vec2(sz)), textureSize(mv, 0) - 1), 0);\n"
               "  vec2 uv = (vec2(p) + 0.5) / vec2(sz), pu = uv - v.xy;\n"
               "  if (any(lessThan(pu, pc.c.xy)) || any(greaterThan(pu, pc.c.zw))) { o = vec4(c, l); return; }\n"
               "  ivec2 hs = textureSize(h, 0);\n"
               "  float lh = texelFetch(h, clamp(ivec2(pu * vec2(hs)), ivec2(0), hs - 1), 0).a, le = v.z * l;\n"
               "  float keep = clamp(1.0 - (abs(lh - le) / max(le * 0.02, 2.0) - 1.0), 0.0, 1.0);\n"
               "  vec3 hy = ycc(tm(cat(pu, vec2(hs))));\n"
               "  vec3 lo = m1 - 1.25 * sg, hi = m1 + 1.25 * sg, ce = 0.5 * (hi + lo), ex = 0.5 * (hi - lo) + 1e-4;\n"
               "  vec3 dv = (hy - ce) / ex;\n"
               "  float mx = max(abs(dv.x), max(abs(dv.y), abs(dv.z)));\n"
               "  if (mx > 1.0) hy = ce + (hy - ce) / mx;\n"
               "  vec3 cy = ycc(tm(c));\n"
               "  float w = pc.b.y * keep;\n"
               "  o = vec4(itm(rgb(mix(cy, hy, w))), l);\n"
               "}\n";
    }
    // The resolved image back into the game's scene (the same size), sharpened: b.z = strength (0: a copy). The
    // sharpening (a 4-neighbour unsharp mask, kept within the neighbours' range: no halos) gives back what the
    // resolve's history blurs.
    if (!strcmp(name, "taa_copy.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D t;\n"
               "layout(push_constant) uniform P { vec4 a; vec4 b; } pc;\n"
               "layout(location = 0) out vec4 o;\n"
               "void main() {\n"
               "  ivec2 sz = textureSize(t, 0), p = min(ivec2(gl_FragCoord.xy), sz - 1);\n"  // (DLAA's output: the scene's part)
               "  vec3 c = max(texelFetch(t, p, 0).rgb, vec3(0.0));\n"
               "  if (pc.b.z > 0.0) {\n"
               "    vec3 n = texelFetch(t, clamp(p + ivec2(0, -1), ivec2(0), sz - 1), 0).rgb;\n"
               "    vec3 s = texelFetch(t, clamp(p + ivec2(0, 1), ivec2(0), sz - 1), 0).rgb;\n"
               "    vec3 e = texelFetch(t, clamp(p + ivec2(1, 0), ivec2(0), sz - 1), 0).rgb;\n"
               "    vec3 w = texelFetch(t, clamp(p + ivec2(-1, 0), ivec2(0), sz - 1), 0).rgb;\n"
               "    vec3 mn = min(c, min(min(n, s), min(e, w))), mx = max(c, max(max(n, s), max(e, w)));\n"
               "    c = clamp(c + pc.b.z * (c - 0.25 * (n + s + e + w)), mn, mx);\n"
               "  }\n"
               "  o = vec4(c, 1.0);\n"
               "}\n";
    }
    // XeSS upscaling's responsive mask (exec.c xess_upscale). Characters have no motion vectors of their own (only the
    // camera's). The 3-target pass's albedo target holds them (black where none was drawn). xess_char: a character pixel
    // that changed since the previous frame (this frame's albedo outside the min..max of the previous frame's 3x3 around
    // where the camera's vector says it was - the jitter's sub-pixel moves stay inside) = moving; a still character keeps
    // XeSS's full history (a mask on every character pixel left their edges stair-stepped). xess_mask: this frame's or the
    // previous frame's moving pixels (where a character just left, the history still holds it), grown by a pixel,
    // times pc.a.x (the strength).
    if (!strcmp(name, "xess_char.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D now;\n"
               "layout(set = 0, binding = 1) uniform sampler2D prev;\n"
               "layout(set = 0, binding = 2) uniform sampler2D mv;\n"
               "layout(push_constant) uniform P { vec4 a; } pc;\n"
               "layout(location = 0) out vec4 o;\n"
               "void main() {\n"
               "  ivec2 sz = textureSize(now, 0), p = ivec2(gl_FragCoord.xy);\n"
               "  vec3 c = texelFetch(now, p, 0).rgb;\n"
               "  ivec2 q = clamp(ivec2(floor(vec2(p) + 0.5 - texelFetch(mv, p, 0).xy * vec2(sz))), ivec2(0), sz - 1);\n"
               "  vec3 mn = vec3(1.0), mx = vec3(0.0);\n"
               "  for (int y = -1; y <= 1; y++)\n"
               "    for (int x = -1; x <= 1; x++) {\n"
               "      vec3 s = texelFetch(prev, clamp(q + ivec2(x, y), ivec2(0), sz - 1), 0).rgb;\n"
               "      mn = min(mn, s); mx = max(mx, s);\n"
               "    }\n"
               "  float any_ = max(max(c.r, max(c.g, c.b)), max(mx.r, max(mx.g, mx.b)));\n"
               "  vec3 e = max(mn - c, c - mx);\n"
               "  o = vec4(any_ > 0.0 && max(e.r, max(e.g, e.b)) > pc.a.x ? 1.0 : 0.0, 0.0, 0.0, 1.0);\n"
               "}\n";
    }
    if (!strcmp(name, "xess_mask.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D now;\n"
               "layout(set = 0, binding = 1) uniform sampler2D prev;\n"
               "layout(push_constant) uniform P { vec4 a; } pc;\n"
               "layout(location = 0) out vec4 o;\n"
               "void main() {\n"
               "  ivec2 sz = textureSize(now, 0), p = ivec2(gl_FragCoord.xy);\n"
               "  float m = 0.0;\n"
               "  for (int y = -1; y <= 1; y++)\n"
               "    for (int x = -1; x <= 1; x++) {\n"
               "      ivec2 q = clamp(p + ivec2(x, y), ivec2(0), sz - 1);\n"
               "      m = max(m, max(texelFetch(now, q, 0).r, texelFetch(prev, q, 0).r));\n"
               "    }\n"
               "  o = vec4(m * pc.a.x, 0.0, 0.0, 1.0);\n"
               "}\n";
    }
    // Object motion vectors (exec.c mv_*): the camera's vectors (taa_mv.frag) where no object wrote its own, else the
    // object's (written by the draw itself: rg = this NDC - the previous frame's, x 0.5 = in the viewport's uv, b = the
    // previous clip w, a = 1). a.xy = the scene's viewport size in the target's pixels, a.z = the y sign.
    // (research) motion vectors as colours: 0.5 + v x pc.a.x (red right, green down), blue = a
    if (!strcmp(name, "mv_viz.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D t;\n"
               "layout(push_constant) uniform P { vec4 a; } pc;\n"
               "layout(location = 0) out vec4 o;\n"
               "void main() {\n"
               "  vec4 m = texelFetch(t, ivec2(gl_FragCoord.xy), 0);\n"
               "  o = vec4(clamp(0.5 + m.xy * pc.a.x, 0.0, 1.0), m.a, 1.0);\n"
               "}\n";
    }
    if (!strcmp(name, "mv_merge.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D cam;\n"
               "layout(set = 0, binding = 1) uniform sampler2D obj;\n"
               "layout(push_constant) uniform P { vec4 a; } pc;\n"
               "layout(location = 0) out vec4 o;\n"
               "void main() {\n"
               "  ivec2 p = ivec2(gl_FragCoord.xy), sz = textureSize(cam, 0);\n"
               "  vec4 c = texelFetch(cam, p, 0);\n"
               "  ivec2 so = textureSize(obj, 0);\n"
               "  vec4 m = p.x < so.x && p.y < so.y ? texelFetch(obj, p, 0) : vec4(0.0);\n"
               "  o = m.a > 0.5 ? vec4(m.x * pc.a.x / float(sz.x), m.y * pc.a.z * pc.a.y / float(sz.y), m.z, 1.0) : c;\n"
               "}\n";
    }
    // The scene's depth as R32F (DLSS reads it as a colour image)
    if (!strcmp(name, "depth_r32.frag")) {
        *stage = STAGE_FRAGMENT;
        return "#version 450\n"
               "layout(set = 0, binding = 0) uniform sampler2D dep;\n"
               "layout(location = 0) out vec4 o;\n"
               "void main() { o = vec4(texelFetch(dep, ivec2(gl_FragCoord.xy), 0).r, 0.0, 0.0, 1.0); }\n";
    }
    return NULL;
}
