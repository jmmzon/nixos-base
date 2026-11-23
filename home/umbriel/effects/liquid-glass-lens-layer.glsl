// Liquid glass for layer surfaces (Noctalia bar, dock, panels, OSD; Vicinae),
// lens variant: the optics of liquid-glass-lens.glsl (liquidglass.dev's
// refracting bevel plus kube.io's coloured rim) on the edge search of
// liquid-glass-layer.glsl. umbriel_shape(uv) is the coverage of the shape the
// client draws (its alpha past blur_ignore_alpha), so the rim follows the
// capsules and panels instead of the layer's rectangle.
//
// The edge search only reaches REACH px, so the bevel is at most that wide.
// Thin shapes (a bar capsule) get a narrower bevel and a smaller bend: the
// thickness along the normal is measured, and the bend never samples past
// half of it.
//
// The outline is antialiased from a box filter of the mask (cover), and the
// thickness is measured to a fraction of a pixel so the bevel does not jump.

#ifndef REACH
#define REACH 60.0 // [8..60 px] how far the edge search looks, logical px
#endif
#ifndef REFRACTION
#define REFRACTION 60.0 // [0..300 px] bend at the very edge, logical px
#endif
#ifndef BEZEL
#define BEZEL 120.0 // [4..120 px] width of the curved rim, px (at most REACH)
#endif
#ifndef CURVATURE
#define CURVATURE 3.7 // [1.1..10] rim profile exponent
#endif
#ifndef IOR
#define IOR 1.91 // [1.05..3.0] index of refraction
#endif
#ifndef CHROMA
#define CHROMA 0.88 // [0..1] blue bends (1 + CHROMA)x, green (1 + CHROMA/2)x as far as red
#endif
#ifndef SPECULAR
#define SPECULAR 0.16 // [0..1] white rim highlight strength
#endif
#ifndef SPECULAR_W
#define SPECULAR_W 1.6 // [0.5..10 px] white rim width, px (glow reaches 5x this)
#endif
#ifndef LIGHT
#define LIGHT -120.0 // [-180..180 deg] white rim light direction, degrees
#endif
#ifndef RIM_OPACITY
#define RIM_OPACITY 0.4 // [0..1] coloured rim (kube.io): how much it shows
#endif
#ifndef RIM_SATURATION
#define RIM_SATURATION 6.0 // [0..15] saturation of the backdrop in it
#endif
#ifndef RIM_WHITE
#define RIM_WHITE 0.16 // [0..1] white over it, fraction of its opacity
#endif
#ifndef RIM_W
#define RIM_W 2.0 // [0.5..10 px] its width, px
#endif
#ifndef RIM_LIGHT
#define RIM_LIGHT -60.0 // [-180..180 deg] its light direction, degrees
#endif

// == Screen light ==
// The rim light turns towards the brightest area on the output (Umbriel's
// umbriel_light, [effects] glass_light: the blurred wallpaper, or the live
// screen), seen from each point of the edge, so every pane is lit from its own
// side. Without a clear bright area (strength 0) the fixed angles above hold.
#ifndef LIGHT_FOLLOW
#define LIGHT_FOLLOW 1.0 // [0..1] how far the rim light turns towards the brightest area; 0 = fixed angles
#endif
#ifndef LIGHT_COLOR
#define LIGHT_COLOR 0.6 // [0..1] how much the rim light takes that area's colour
#endif
#ifndef LIGHT_GAIN
#define LIGHT_GAIN 0.5 // [0..1] how much the rim brightness follows how strongly that area stands out
#endif

// Unit direction towards the light at uv: the fixed angle (deg), turned to the screen light.
vec2 lightDir(vec2 uv, float deg) {
  vec2 fixedDir = vec2(cos(radians(deg)), sin(radians(deg)));
  vec2 d = umbriel_light_dir(uv);
  float k = clamp(LIGHT_FOLLOW * umbriel_light.z, 0.0, 1.0);
  if (k <= 0.0 || dot(d, d) == 0.0) {
    return fixedDir;
  }
  vec2 m = mix(fixedDir, d, k);
  return dot(m, m) > 1e-6 ? normalize(m) : d;
}

// Colour of the light: white, tinted towards the bright area's colour.
vec3 lightTint() {
  return mix(vec3(1.0), umbriel_light_color, LIGHT_COLOR * umbriel_light.z * umbriel_light.w);
}

// Brightness of the light: 0.4x for a faint bright area up to 1.6x for a stark one.
float lightGain() {
  return mix(1.0, 0.4 + 1.2 * umbriel_light.z, LIGHT_GAIN * umbriel_light.w);
}
#ifndef LIGHT_TINT
#define LIGHT_TINT 1.0 // [0..1] edge light colour: 0 white, 1 the backdrop just outside the edge
#endif
#ifndef LIGHT_OUT
#define LIGHT_OUT 6.0 // [0..8 px] how far outside the edge that colour is taken, px (padding is 8)
#endif
#ifndef LIGHT_WHITE
#define LIGHT_WHITE 0.25 // [0..1] white kept in the tinted light, so dark backdrops still give a highlight
#endif

// Imperfections: the pane is not perfectly flat. A static height field fixed
// to the surface bends the backdrop by its slope: soft waves (old window
// glass) plus long streaks (cords in drawn glass). Values per part of the
// desktop come from [effects.preset.<name>] params / [effects.params.<name>]
// in glass.toml; these are the defaults. glass.toml padding must cover
// (REFRACTION + WAVE_AMP + STREAK_AMP + RIPPLE_AMP) * (1 + CHROMA)
// + zone shift (up to 0.21 * ZONE_SIZE * ZONE_PCT / 100) * 2 + SAND_SCATTER.
#ifndef WAVE_AMP
#define WAVE_AMP 3.0 // [0..8 px] soft waves: largest shift of the backdrop
#endif
#ifndef WAVE_SIZE
#define WAVE_SIZE 220.0 // [20..800 px] size of one wave
#endif
#ifndef STREAK_AMP
#define STREAK_AMP 3.0 // [0..8 px] streaks: largest shift across them
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
#define CENTER_FADE 0.5 // [0..1] how much weaker the flaws are away from the edge (keeps text readable)
#endif
#ifndef FADE_IN
#define FADE_IN 60.0 // [0..600 px] distance from the edge over which they weaken (layers: at most REACH)
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

bool outside(vec2 uv, vec2 dir, float px) {
  return umbriel_shape(uv + dir * px / umbriel_size) < 0.5;
}

// x: px from the nearest edge (REACH when none is closer); yz: outward normal.
vec3 edge(vec2 uv) {
  // Deep inside a large shape: no edge within REACH in 8 directions.
  bool near = false;
  for (int i = 0; i < 8; i++) {
    float a = float(i) * 0.785398;
    if (outside(uv, vec2(cos(a), sin(a)), REACH)) {
      near = true;
    }
  }
  if (!near) {
    return vec3(REACH, 0.0, 0.0);
  }
  float best = REACH;
  vec2 bestDir = vec2(0.0);
  vec2 normal = vec2(0.0);
  for (int i = 0; i < 16; i++) {
    float a = float(i) * 0.392699;
    vec2 d = vec2(cos(a), sin(a));
    for (int k = 1; k <= 14; k++) {
      float t = float(k) * 2.0;
      if (t > best + 2.0) {
        break;
      }
      if (outside(uv, d, t)) {
        normal += d / (t * t);
        if (t < best) {
          best = t;
          bestDir = d;
        }
        break;
      }
    }
  }
  if (best >= REACH) {
    return vec3(REACH, 0.0, 0.0);
  }
  // Refine the crossing along the nearest direction to a fraction of a pixel.
  float lo = max(best - 2.0, 0.0);
  float hi = best;
  for (int j = 0; j < 4; j++) {
    float mid = 0.5 * (lo + hi);
    if (outside(uv, bestDir, mid)) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  vec2 n = length(normal) > 0.0 ? normalize(normal) : bestDir;
  return vec3(0.5 * (lo + hi), n);
}

// Thickness of the shape along -n from uv: px to the opposite edge, coarse
// 8 px steps refined to a fraction of a pixel (a coarse value makes the bevel
// width jump where the normal turns into a rounded end: a visible seam).
float depth(vec2 uv, vec2 n) {
  for (int k = 1; k <= 32; k++) {
    float t = float(k) * 8.0;
    if (outside(uv, -n, t)) {
      float lo = t - 8.0;
      float hi = t;
      for (int j = 0; j < 6; j++) {
        float mid = 0.5 * (lo + hi);
        if (outside(uv, -n, mid)) {
          hi = mid;
        } else {
          lo = mid;
        }
      }
      return 0.5 * (lo + hi);
    }
  }
  return 1000.0;
}

// Coverage of the pixel at uv by the shape, from a 5x5 box of the mask at
// 1 px spacing. Noctalia draws its capsules with hard edges and the layer is
// clipped by an on/off stencil, so the outline is a staircase; averaging the
// mask gives the outermost pixels fractional coverage along it. The mask
// reaches about 2 px past the stencil, so the visible outermost pixel averages
// only 0.82 to 0.87 (measured on the bar, 2026-11-10); COVER_LO..COVER_HI
// stretches that to roughly 0.3 there and 0.8 one pixel in.
#ifndef COVER_LO
#define COVER_LO 0.74 // [0..0.98]
#endif
#ifndef COVER_HI
#define COVER_HI 0.98 // [0.02..1]
#endif

float cover(vec2 uv) {
  float c = 0.0;
  for (int i = -2; i <= 2; i++) {
    for (int j = -2; j <= 2; j++) {
      c += umbriel_shape(uv + vec2(float(i), float(j)) / umbriel_size);
    }
  }
  return clamp((c / 25.0 - COVER_LO) / (COVER_HI - COVER_LO), 0.0, 1.0);
}

float profile(float s) {
  if (s >= 1.0) {
    return 0.0;
  }
  float a = pow(1.0 - s, CURVATURE);
  float slope = pow(1.0 - s, CURVATURE - 1.0) * pow(max(1.0 - a, 1e-6), 1.0 / CURVATURE - 1.0);
  float th = atan(slope);
  return tan(th - asin(sin(th) / IOR)) / tan(1.5707963 - asin(1.0 / IOR));
}

vec4 backdrop(vec2 uv) {
  vec3 e = edge(uv);
  float s = e.x;
  vec2 n = e.yz;
  // The edge search ends at REACH, so the middle fade completes by then.
  float fadeIn = min(FADE_IN, REACH);
  if (s >= REACH) {
    return vec4(glassBody(uv, vec2(0.0), uv * umbriel_size, s, fadeIn, 1e6), 1.0);
  }

  float thick = s + depth(uv, n);
  float bezel = min(BEZEL, thick * 0.3);
  float m = profile(s / bezel);
  float px = min(m * REFRACTION, 0.5 * thick / (1.0 + CHROMA));
  vec2 off = -n * px / umbriel_size;
  // Thin shapes (bar capsules): the flaws never shift more than a tenth of the thickness.
  vec3 col = glassBody(uv, off, uv * umbriel_size, s, fadeIn, 0.1 * thick);

  float facing = dot(n, lightDir(uv, LIGHT));
  float shade = 0.12 + 0.88 * (facing > 0.0 ? facing : -0.4 * facing);
  float crisp = max(0.0, 1.0 - s / SPECULAR_W);
  float glow = max(0.0, 1.0 - s / (SPECULAR_W * 5.0));
  // Edge light coloured by what is behind: the blurred backdrop just outside
  // the edge, brought up to full brightness so it still reads as light.
  vec3 around = umbriel_sample(uv + n * (s + LIGHT_OUT) / umbriel_size).rgb;
  vec3 hue = around / max(max(around.r, max(around.g, around.b)), 0.05);
  vec3 light = mix(vec3(1.0), mix(hue, vec3(1.0), LIGHT_WHITE), LIGHT_TINT) * lightTint();

  col += light * min(1.0, SPECULAR * lightGain() * (crisp * crisp + 0.3 * glow * glow) * shade);

  vec2 rimDir = lightDir(uv, RIM_LIGHT);
  float edgeW = max(0.0, 1.0 - s / RIM_W);
  float rim = RIM_OPACITY * edgeW * edgeW * abs(dot(n, rimDir));
  float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
  col = mix(col, max(mix(vec3(lum), col, RIM_SATURATION), 0.0), rim);
  col = mix(col, light, rim * RIM_WHITE);

  float a = s < 5.0 ? cover(uv) : 1.0;
  return vec4(col * a, a);
}
