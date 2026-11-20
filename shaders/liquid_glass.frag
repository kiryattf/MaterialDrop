#version 460 core
#include <flutter/runtime_effect.glsl>

layout(location = 0) uniform vec2 uSize;
layout(location = 1) uniform float uTime;
layout(location = 2) uniform float uProgress;
layout(location = 3) uniform vec3 uAccent;
layout(location = 4) uniform float uDarkMode;

out vec4 fragColor;

float sdRoundedBox(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + vec2(r);
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

void main() {
  vec2 uv = FlutterFragCoord().xy;
  vec2 halfSize = max(uSize * 0.5, vec2(1.0));
  vec2 p = uv - halfSize;

  float radius = min(halfSize.x, halfSize.y);
  float d = sdRoundedBox(p, halfSize - vec2(1.5), max(radius - 1.5, 4.0));

  // Crisp anti-aliased capsule boundary + outer glow halo
  float fillMask = 1.0 - smoothstep(-1.2, 1.0, d);
  float glowMask = exp(-max(d, 0.0) * 0.22) * (0.28 + 0.16 * uProgress);

  // Chromatic spatial edge refraction simulation via directional border sampling
  float angle = atan(p.y, p.x);
  float wave = 0.5 + 0.5 * sin(angle * 2.0 + uTime * 2.4);
  float rimBand = smoothstep(-7.5, -0.5, d) * (1.0 - smoothstep(-0.5, 1.8, d));
  float innerBevel = smoothstep(-16.0, 0.0, d);

  // Specular highlights shifting along capsule rim according to accent & phase
  float specPos = sin(angle - uTime * 1.35 + p.x / max(halfSize.x, 1.0));
  float spec = pow(max(specPos, 0.0), 4.0) * rimBand;

  vec3 darkBase = vec3(0.075, 0.078, 0.105);
  vec3 lightBase = vec3(0.955, 0.962, 0.985);
  vec3 glassBase = mix(lightBase, darkBase, uDarkMode);

  // Chromatic dispersion shift along capsule edges (RGB offsets modulated by SDF rim)
  vec3 chromatic = vec3(
    sin(angle + 0.4 + uTime) * 0.5 + 0.5,
    sin(angle + 2.2 + uTime) * 0.5 + 0.5,
    sin(angle + 4.1 + uTime) * 0.5 + 0.5
  );
  vec3 tint = mix(uAccent, chromatic, 0.22 * rimBand);

  float topSheen = smoothstep(halfSize.y, -halfSize.y * 0.35, p.y) * 0.12;
  vec3 bodyColor = mix(glassBase, tint, 0.14 + 0.18 * innerBevel) + vec3(topSheen);

  vec3 rimColor = mix(uAccent * 1.25, vec3(1.0), 0.35 + 0.25 * wave);
  vec3 finalRgb = bodyColor + rimColor * (rimBand * (0.38 + 0.24 * uProgress) + spec * 0.55);

  // Add soft ambient halo just outside the pill edge
  finalRgb += uAccent * glowMask * (1.0 - fillMask);

  float baseAlpha = mix(0.84, 0.90, uDarkMode);
  float outAlpha = clamp(fillMask * baseAlpha + glowMask * 0.55 + rimBand * 0.20, 0.0, 1.0);

  fragColor = vec4(finalRgb * outAlpha, outAlpha);
}
