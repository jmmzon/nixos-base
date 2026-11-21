// Liquid-glass backdrop, lens variant: a port of liquidglass.dev's optics
// (lib/liquid-glass.js, renderLensMap) to Umbriel's backdrop effect kind
// (patches/umbriel-backdrop-effect.patch), tuned to
//   <lg-lens radius="21" refraction="60" bezel="0.3" curvature="3.5"
//            chroma="0.35" blur="4" specular="0.1">
// The rim is a rounded bevel of height h(s) = (1 - (1-s)^k)^(1/k); a ray
// through it refracts by Snell's law, so the edge shows the backdrop from
// further inside (a convex, magnifying rim). The frost is the compositor's
// blur ([appearance.blur]); the web version blurs first and then bends, so
// sampling umbriel_sample at the bent position is the same pipeline.
//
// Differences from the web version, on purpose:
// - BEZEL is a fixed width in px, not a fraction of the half-size, so large
//   windows don't get a 150 px rim (0.3 x 140 px = 42 px in the demo).
// - The normal is smoothed at the corners (no diagonal seams), and the bend
//   is continuous (the web map is 8-bit).
// - The window's own corner radius is used, not radius="21".

#ifndef REFRACTION
#define REFRACTION 47.0 // [0..300 px] bend at the very edge, logical px
#endif
#ifndef BEZEL
#define BEZEL 61.0 // [4..120 px] width of the curved rim, logical px
#endif
#ifndef CURVATURE
#define CURVATURE 4.8 // [1.1..10] rim profile exponent: 2 circular, higher = steeper
#endif
#ifndef IOR
#define IOR 2.12 // [1.05..3.0] index of refraction
#endif
#ifndef CHROMA
#define CHROMA 0.8 // [0..1] blue bends (1 + CHROMA)x, green (1 + CHROMA/2)x as far as red
#endif
#ifndef SPECULAR
#define SPECULAR 0.06 // [0..1] rim highlight strength
#endif
#ifndef SPECULAR_W
#define SPECULAR_W 6.6 // [0.5..10 px] rim highlight width, px (glow reaches 5x this)
#endif
#ifndef LIGHT
#define LIGHT 41.0 // [-180..180 deg] light direction, degrees; 0 = from the right, -90 = from the top
#endif
// Coloured rim as kube.io/blog/liquid-glass-css-svg builds it: in a thin rim,
// lit on the side facing the light and the opposite side, the bent backdrop
// is shown heavily saturated, with a faint white line over it.
#ifndef RIM_OPACITY
#define RIM_OPACITY 0.48 // [0..1] how much the rim shows (kube.io: 0.2 to 0.5)
#endif
#ifndef RIM_SATURATION
#define RIM_SATURATION 3.5 // [0..15] saturation of the backdrop in the rim (kube.io: 4 to 9)
#endif
#ifndef RIM_WHITE
#define RIM_WHITE 0.17 // [0..1] white over the rim, fraction of its opacity
#endif
#ifndef RIM_W
#define RIM_W 4.6 // [0.5..10 px] rim width, px
#endif
#ifndef RIM_LIGHT
#define RIM_LIGHT -53.0 // [-180..180 deg] rim light direction, degrees (kube.io default: up-right)
#endif

// Imperfections: the pane is not perfectly flat. A static height field fixed
// to the surface bends the backdrop by its slope: soft waves (old window
// glass) plus long streaks (cords in drawn glass). Values per part of the
// desktop come from [effects.preset.<name>] params / [effects.params.<name>]
// in glass.toml; these are the defaults. glass.toml padding must cover
// (REFRACTION + WAVE_AMP + STREAK_AMP + RIPPLE_AMP) * (1 + CHROMA)
// + zone shift (up to 0.21 * ZONE_SIZE * ZONE_PCT / 100) * 2 + SAND_SCATTER.
#ifndef WAVE_AMP
#define WAVE_AMP 4.0 // [0..8 px] soft waves: largest shift of the backdrop
#endif
#ifndef WAVE_SIZE
#define WAVE_SIZE 220.0 // [20..800 px] size of one wave
#endif
#ifndef STREAK_AMP
#define STREAK_AMP 4.0 // [0..8 px] streaks: largest shift across them
#endif
#ifndef STREAK_LEN
#define STREAK_LEN 360.0 // [40..1500 px] length of a streak
#endif
#ifndef STREAK_W
#define STREAK_W 22.0 // [4..120 px] width of a streak
#endif
#ifndef STREAK_ANGLE
#define STREAK_ANGLE 0.0 // [-90..90 deg] streak direction; 0 = horizontal
#endif
#ifndef CENTER_FADE
#define CENTER_FADE 0.3 // [0..1] how much weaker the flaws are away from the edge (keeps text readable)
#endif
#ifndef FADE_IN
#define FADE_IN 120.0 // [0..600 px] distance from the edge over which they weaken
#endif
#ifndef SEED
#define SEED 0.0 // [0..100] change for a different pattern
#endif

// == Ripple ==
// Fine ripple, orange peel: like the waves, but small and crinkly. Gets the
// lens colour fringe and the middle fade like the other flaws. 0 = off.
#ifndef RIPPLE_AMP
#define RIPPLE_AMP 0.0 // [0..3 px] fine ripple: largest shift (0.7 faint, 1.5 textured, 3 crinkled)
#endif
#ifndef RIPPLE_SIZE
#define RIPPLE_SIZE 8.0 // [4..30 px] size of one ripple
#endif

// == Zones ==
// Local magnify/shrink: soft round zones where the pane is a little thicker
// or thinner, so the backdrop grows or shrinks by up to ZONE_PCT. 0 = off.
#ifndef ZONE_PCT
#define ZONE_PCT 0.0 // [0..6 %] how much a zone magnifies or shrinks
#endif
#ifndef ZONE_SIZE
#define ZONE_SIZE 220.0 // [60..400 px] spacing of the zones (each is about a third as wide)
#endif
#ifndef ZONE_BIAS
#define ZONE_BIAS 0.0 // [-1..1] 0 = mixed, 1 = magnify only, -1 = shrink only
#endif
#ifndef ZONE_CHROMA
#define ZONE_CHROMA 0.2 // [0..1] colour fringe of the zones; 1 = as strong as the lens
#endif

// == Frost ==
// Sandblasted frost (scatter + grain + milk) and uneven frost (patches where
// the glass is clearer: the sharp backdrop shows through). 0 = off.
#ifndef SAND_SCATTER
#define SAND_SCATTER 0.0 // [0..4 px] sandblast: each pixel reads the backdrop from a random spot this near
#endif
#ifndef SAND_GRAIN
#define SAND_GRAIN 0.0 // [0..0.08] sandblast: fixed light/dark grain
#endif
#ifndef MILK
#define MILK 0.0 // [0..0.4] milky haze: lift towards white
#endif
#ifndef FROST_PATCH
#define FROST_PATCH 0.0 // [0..1] uneven frost: how much clearer the clear patches are
#endif
#ifndef PATCH_SIZE
#define PATCH_SIZE 140.0 // [20..600 px] uneven frost: size of a patch
#endif

float flawHash(vec2 i) {
  i = fract(i * vec2(0.1031, 0.1030));
  i += dot(i, i.yx + 33.33);
  return fract((i.x + i.y) * i.x) * 2.0 - 1.0;
}

// Value noise with its analytic gradient: (value, d/dx, d/dy).
vec3 flawNoise(vec2 x) {
  vec2 i = floor(x);
  vec2 f = fract(x);
  vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
  vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
  float a = flawHash(i), b = flawHash(i + vec2(1.0, 0.0));
  float c = flawHash(i + vec2(0.0, 1.0)), d = flawHash(i + vec2(1.0, 1.0));
  float k = a - b - c + d;
  return vec3(a + (b - a) * u.x + (c - a) * u.y + k * u.x * u.y,
              du * vec2(b - a + k * u.y, c - a + k * u.x));
}

// Shift of the backdrop in px at q (px in the surface), s px in from the edge.
// The noise gradient peaks near 2.85 for two octaves, so AMP is about the max.
vec2 imperfection(vec2 q, float s, float fadeIn) {
  vec2 seed = vec2(SEED * 7.13, SEED * 3.71);
  vec2 w = q / WAVE_SIZE + seed;
  vec2 d = (flawNoise(w).yz + 0.5 * flawNoise(w * 2.03 + 17.0).yz) * (WAVE_AMP / 2.85);
  float a = radians(STREAK_ANGLE);
  vec2 ax = vec2(cos(a), sin(a));
  vec2 ay = vec2(-ax.y, ax.x);
  vec2 r = vec2(dot(q, ax) / STREAK_LEN, dot(q, ay) / STREAK_W) + seed + 41.0;
  vec2 g = flawNoise(r).yz + 0.5 * flawNoise(r * vec2(1.7, 2.1) + 73.0).yz;
  // A slope along a streak is STREAK_W / STREAK_LEN as steep as across it.
  vec2 sl = vec2(g.x * STREAK_W / STREAK_LEN, g.y) * (STREAK_AMP / 2.85);
  d += ax * sl.x + ay * sl.y;
  if (RIPPLE_AMP > 0.0) {
    vec2 rq = q / RIPPLE_SIZE + seed + 97.0;
    d += (flawNoise(rq).yz + 0.5 * flawNoise(rq * 2.03 + 29.0).yz) * (RIPPLE_AMP / 2.85);
  }
  return d * (1.0 - CENTER_FADE * smoothstep(0.0, max(fadeIn, 0.001), s));
}

// The backdrop at uv shifted by off, with the lens colour fringe.
vec3 sampleBent(vec2 uv, vec2 off) {
  return vec3(umbriel_sample(uv + off).r,
              umbriel_sample(uv + off * (1.0 + CHROMA * 0.5)).g,
              umbriel_sample(uv + off * (1.0 + CHROMA)).b);
}

// Local magnify/shrink zones: a Gaussian bump per grid cell, centre jittered.
vec2 zoneShift(vec2 q, float s, float fadeIn) {
  if (ZONE_PCT <= 0.0) {
    return vec2(0.0);
  }
  vec2 seed = vec2(SEED * 5.31, SEED * 2.17) + 151.0;
  vec2 i0 = floor(q / ZONE_SIZE);
  float sg = ZONE_SIZE * 0.35;
  vec2 d = vec2(0.0);
  for (int y = -1; y <= 1; y++) {
    for (int x = -1; x <= 1; x++) {
      vec2 i = i0 + vec2(float(x), float(y));
      vec2 c = (i + 0.5 + 0.35 * vec2(flawHash(i + seed), flawHash(i + seed + 8.7))) * ZONE_SIZE;
      float h = flawHash(i + seed + 13.3);
      float k = clamp(sign(h) + 2.0 * ZONE_BIAS, -1.0, 1.0) * (0.6 + 0.4 * abs(h));
      vec2 v = q - c;
      d -= v * k * exp(-dot(v, v) / (2.0 * sg * sg));
    }
  }
  return d * (ZONE_PCT / 100.0) * (1.0 - CENTER_FADE * smoothstep(0.0, max(fadeIn, 0.001), s));
}

vec2 capFlaw(vec2 f, float lim) {
  return f * min(1.0, lim / max(length(f), 0.001));
}

// The glass body at uv: the backdrop bent by the lens (lensOff, uv units) and
// the flaws (each capped at lim px), with the frost on top. q: px in the
// surface, s: px in from the edge.
vec3 glassBody(vec2 uv, vec2 lensOff, vec2 q, float s, float fadeIn, float lim) {
  vec2 flaw = capFlaw(imperfection(q, s, fadeIn), lim) / umbriel_size;
  vec2 zone = capFlaw(zoneShift(q, s, fadeIn), lim) / umbriel_size;
  vec2 scat = vec2(0.0);
  vec2 seed = vec2(SEED * 3.17, SEED * 6.29);
  if (SAND_SCATTER > 0.0) {
    vec2 jq = q / 1.3 + seed;
    scat = capFlaw(vec2(flawNoise(jq + 211.0).x, flawNoise(jq + 307.0).x) * SAND_SCATTER, lim) / umbriel_size;
  }
  vec2 bent = lensOff + flaw;
  vec3 col = vec3(umbriel_sample(uv + bent + zone + scat).r,
                  umbriel_sample(uv + bent * (1.0 + CHROMA * 0.5) + zone * (1.0 + ZONE_CHROMA * CHROMA * 0.5) + scat).g,
                  umbriel_sample(uv + bent * (1.0 + CHROMA) + zone * (1.0 + ZONE_CHROMA * CHROMA) + scat).b);
  float frost = 1.0;
  if (FROST_PATCH > 0.0) {
    vec2 pq = q / PATCH_SIZE + seed + 401.0;
    float v = flawNoise(pq).x + 0.5 * flawNoise(pq * 2.07 + 19.0).x;
    frost = 1.0 - FROST_PATCH * smoothstep(-0.2, 0.6, v);
    col = mix(umbriel_sample_raw(uv + bent + zone).rgb, col, frost);
  }
  if (MILK > 0.0) {
    col = mix(col, vec3(1.0), MILK * frost);
  }
  if (SAND_GRAIN > 0.0) {
    col += flawHash(floor(q) + seed + 503.0) * SAND_GRAIN * frost;
  }
  return col;
}

float sdRoundBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// Normalised bend for s = depth / bezel in [0, 1]: 1 at the edge, 0 past the bezel.
float profile(float s) {
  if (s >= 1.0) {
    return 0.0;
  }
  float a = pow(1.0 - s, CURVATURE);
  float slope = pow(1.0 - s, CURVATURE - 1.0) * pow(max(1.0 - a, 1e-6), 1.0 / CURVATURE - 1.0);
  float th = atan(slope);
  float bend = tan(th - asin(sin(th) / IOR));
  // The bend grows with the tilt, so it peaks at the edge (tilt 90 degrees).
  return bend / tan(1.5707963 - asin(1.0 / IOR));
}

vec4 backdrop(vec2 uv) {
  vec2 halfSize = umbriel_size * 0.5;
  vec2 p = uv * umbriel_size - halfSize;
  // The window's own corner radius (tl, tr, br, bl), as Umbriel rounds it.
  vec4 c = umbriel_corner_radius;
  float r = p.y < 0.0 ? (p.x < 0.0 ? c.x : c.y) : (p.x < 0.0 ? c.w : c.z);
  r = min(r, min(halfSize.x, halfSize.y));
  float s = max(-sdRoundBox(p, halfSize, r), 0.0);  // px in from the edge

  // Smooth outward direction: a wide difference keeps the corners from creasing.
  // The bend direction comes from the shape rounded to at least the bevel, so it turns
  // smoothly round the corners (no seam along the corner diagonal).
  float rn = min(max(r, min(BEZEL, min(halfSize.x, halfSize.y) * 0.5)), min(halfSize.x, halfSize.y));
  float h = 3.0;
  vec2 g = vec2(
    sdRoundBox(p + vec2(h, 0.0), halfSize, rn) - sdRoundBox(p - vec2(h, 0.0), halfSize, rn),
    sdRoundBox(p + vec2(0.0, h), halfSize, rn) - sdRoundBox(p - vec2(0.0, h), halfSize, rn));
  vec2 n = length(g) > 0.0 ? normalize(g) : vec2(0.0);

  // Small windows: keep the rim within half the shorter side.
  float bezel = min(BEZEL, min(halfSize.x, halfSize.y) * 0.5);
  float m = profile(s / bezel);
  // Never bend past the centre line, so small windows don't sample outside.
  float px = min(m * REFRACTION, min(halfSize.x, halfSize.y) / (1.0 + CHROMA));
  vec2 off = -n * px / umbriel_size;  // inward: convex glass
  vec3 col = glassBody(uv, off, uv * umbriel_size, s, FADE_IN, 1e6);

  // Rim highlight: a crisp line and a softer glow, brightest where the edge
  // faces the light, a dim reflection on the far side.
  float la = radians(LIGHT);
  float facing = dot(n, vec2(cos(la), sin(la)));
  float shade = 0.12 + 0.88 * (facing > 0.0 ? facing : -0.4 * facing);
  float crisp = max(0.0, 1.0 - s / SPECULAR_W);
  float glow = max(0.0, 1.0 - s / (SPECULAR_W * 5.0));
  col += min(1.0, SPECULAR * (crisp * crisp + 0.3 * glow * glow) * shade);

  // Coloured rim: strongest where the edge faces the light or faces away from
  // it, fading over RIM_W px from the edge.
  float ra = radians(RIM_LIGHT);
  float edge = max(0.0, 1.0 - s / RIM_W);
  float rim = RIM_OPACITY * edge * edge * abs(dot(n, vec2(cos(ra), sin(ra))));
  float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
  vec3 vivid = max(mix(vec3(lum), col, RIM_SATURATION), 0.0);
  col = mix(col, vivid, rim);
  col = mix(col, vec3(1.0), rim * RIM_WHITE);

  return vec4(col, 1.0);
}
