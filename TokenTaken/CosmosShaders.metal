#include <metal_stdlib>
#include <simd/simd.h>
using namespace metal;

constant float PI = 3.14159265359;
constant float TAU = 6.28318530718;

struct CosmosSceneUniforms {
    float2 size;
    float2 center;
    float3 cam;
    float3 fw;
    float3 rt;
    float3 up;
    float time;
    float clock;
    float reveal;
    float disk;
    float focal;
    int hover;
    int bodyCount;
    int bandCount;
    float edges[6];
    float3 bodyPosition[6];
    float bodyRadius[6];
    float bodyKind[6];
    float bodySeed[6];
    float bodySpin[6];
    float bodyTilt[6];
    float bodyRing[6];
};

struct CosmosParticleUniforms {
    float2 size;
    float2 center;
    float3 cam;
    float3 fw;
    float3 rt;
    float3 up;
    float time;
    float disk;
    float dust;
    float pixel;
    float points;
    float shadow;
    float edges[6];
    float focal;
    int bandCount;
};

struct CosmosFullscreenOut {
    float4 position [[position]];
    float2 uv;
};

vertex CosmosFullscreenOut cosmosSceneVertex(uint vertexID [[vertex_id]]) {
    float2 position = float2((vertexID << 1) & 2, vertexID & 2);
    CosmosFullscreenOut out;
    out.position = float4(position * 2.0 - 1.0, 0.0, 1.0);
    out.uv = position;
    return out;
}

float a3hash(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

float2 a3hash2(float2 p) {
    float n = a3hash(p);
    return float2(n, a3hash(p + n + 17.17));
}

float a3noise(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(a3hash(i), a3hash(i + float2(1, 0)), f.x),
               mix(a3hash(i + float2(0, 1)), a3hash(i + float2(1, 1)), f.x), f.y);
}

float a3fbm(float2 p) {
    float value = 0.0, amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        value += amplitude * a3noise(p);
        p = p * 2.03 + 17.1;
        amplitude *= 0.5;
    }
    return value;
}

float a3mod(float value, float period) {
    return value - period * floor(value / period);
}

float a3pnoise(float2 p, float period) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = a3hash(float2(a3mod(i.x, period), i.y));
    float b = a3hash(float2(a3mod(i.x + 1.0, period), i.y));
    float c = a3hash(float2(a3mod(i.x, period), i.y + 1.0));
    float d = a3hash(float2(a3mod(i.x + 1.0, period), i.y + 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float a3pfbm(float2 p, float period) {
    float value = 0.0, amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        value += amplitude * a3pnoise(p, period);
        p *= 2.0;
        period *= 2.0;
        amplitude *= 0.5;
    }
    return value;
}

float3 a3thermal(float t) {
    float3 color = mix(float3(0.8, 0.9, 1.0), float3(1.0, 0.97, 0.88), smoothstep(0.0, 0.12, t));
    color = mix(color, float3(1.0, 0.72, 0.28), smoothstep(0.12, 0.46, t));
    color = mix(color, float3(1.0, 0.36, 0.08), smoothstep(0.46, 0.76, t));
    return mix(color, float3(0.72, 0.055, 0.012), smoothstep(0.76, 1.0, t));
}

float3 a3bandColor(int index) {
    if (index == 0) return float3(0.94, 0.98, 1.08);
    if (index == 1) return float3(1.02, 1.0, 0.96);
    if (index == 2) return float3(1.03, 0.97, 0.9);
    if (index == 3) return float3(1.02, 0.94, 0.88);
    return float3(0.98, 0.9, 0.84);
}

float3 a3starLayer(float3 direction, float cells, float seed, float occupancy,
                   float impact, float depth, float faint,
                   constant CosmosSceneUniforms &u) {
    float2 uv = float2(atan2(direction.z, direction.x) / TAU + 0.5,
                       asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
    float2 dimensions = float2(cells, cells * 0.5), id = floor(uv * dimensions);
    float h = a3hash(id + seed + 7.1);
    if (h < occupancy) return float3(0.0);
    float2 cell = (id + 0.08 + 0.84 * a3hash2(id + seed)) / dimensions;
    float longitude = (cell.x - 0.5) * TAU, latitude = (cell.y - 0.5) * PI;
    float3 starDirection = float3(cos(latitude) * cos(longitude), sin(latitude), cos(latitude) * sin(longitude));
    float forward = dot(starDirection, u.fw);
    if (forward < 0.02) return float3(0.0);
    float2 position = u.center + u.focal * float2(dot(starDirection, u.rt) / forward,
                                                  -dot(starDirection, u.up) / forward);
    float2 delta = u.focal * float2(dot(direction - starDirection, u.rt),
                                    -dot(direction - starDirection, u.up));
    float2 tangent = normalize(float2(u.center.y - position.y, position.x - u.center.x) + float2(0.0001));
    float arc = 1.0 - smoothstep(2.598 * 0.34, 1.65 * 2.598 * 0.34, impact);
    float along = dot(delta, tangent), across = dot(delta, float2(-tangent.y, tangent.x));
    float distanceToStar = length(float2(along / (1.0 + arc * 0.6), across));
    float size = (mix(0.62, 0.34, faint) + mix(0.55, 0.42, faint) * pow(a3hash(id + seed + 3.3), 1.4))
               * clamp(70.0 / depth, 0.8, 1.15) * 1.25;
    float core = 1.0 - smoothstep(size * 0.45, size, distanceToStar);
    float rare = smoothstep(0.985, 0.998, a3hash(id + seed + 21.7)) * (1.0 - faint);
    float halo = exp(-distanceToStar * distanceToStar / (size * size * 2.0)) * mix(0.045 + rare * 0.08, 0.012, faint);
    float glint = (exp(-abs(across) * 3.0 - abs(along) * 0.7)
                 + exp(-abs(along) * 3.0 - abs(across) * 0.7)) * rare * 0.16;
    float brightness = mix(0.22 + 0.68 * pow(a3hash(id + seed + 5.7), 1.6) + rare * 0.45,
                           0.018 + 0.075 * pow(a3hash(id + seed + 5.7), 1.8), faint) * (1.0 - arc * 0.35);
    float3 tint = mix(float3(0.62, 0.76, 1.0), float3(1.0, 0.78, 0.55), a3hash(id + seed + 11.2));
    return mix(tint, float3(1.0), 0.18) * brightness * (core + halo + glint);
}

float3 a3sky(float3 direction, float impact, constant CosmosSceneUniforms &u) {
    float2 uv = float2(atan2(direction.z, direction.x) / TAU + 0.5,
                       asin(clamp(direction.y, -1.0, 1.0)) / PI + 0.5);
    float3 color = float3(0.00016, 0.00022, 0.00036);
    float diagonal = uv.y - (0.72 - 0.4 * uv.x + 0.025 * sin(uv.x * TAU * 2.0));
    float bandDistance = diagonal / 0.078;
    float band = exp(-bandDistance * bandDistance);
    float dust = a3fbm(uv * float2(34.0, 9.0) + float2(7.3, 2.1));
    float laneDistance = (diagonal + 0.014 * sin(uv.x * TAU * 3.0)) / 0.011;
    float laneDistance2 = (diagonal - 0.025) / 0.015;
    float lane = exp(-laneDistance * laneDistance) + 0.6 * exp(-laneDistance2 * laneDistance2);
    float laneMask = 1.0 - 0.78 * clamp(lane * (0.55 + 0.45 * dust), 0.0, 1.0);
    color += float3(0.026, 0.027, 0.034) * band * laneMask * (0.35 + 0.65 * a3fbm(uv * float2(11.0, 5.0) + 3.7));
    color += 0.9 * a3starLayer(direction, 150.0, 2.1, 0.50, impact, 55.0, 0.0, u);
    color += 0.55 * a3starLayer(direction, 560.0, 9.4, 0.76, impact, 105.0, 1.0, u);
    color += 0.45 * a3starLayer(direction, 920.0, 17.8, 0.82, impact, 180.0, 1.0, u);
    return color;
}

float4 a3disk(float3 q, float3 cam, constant CosmosSceneUniforms &u) {
    float radius = length(q.xz), angle = atan2(q.z, q.x), spin = u.time * 0.88 / pow(radius, 1.5);
    float unit = fract((angle - spin) / TAU), radial = log(radius) * 9.0 + u.time * 0.16;
    float noise = a3pfbm(float2(unit * 24.0, radial), 24.0);
    float streak = a3pfbm(float2(unit * 72.0, log(radius) * 3.0 + u.time * 0.075), 72.0);
    float spiral = 0.5 + 0.5 * sin(angle * 2.0 - log(radius) * 10.0 - u.time * 1.1 / pow(radius, 1.5));
    float clump = pow(smoothstep(0.6, 0.88, a3pfbm(float2(unit * 11.0 + u.time * 0.012, log(radius) * 7.0), 11.0)), 3.0);
    float density = (0.22 + 0.95 * noise) * (0.42 + 1.15 * streak * streak) * (0.96 + 0.06 * spiral) + clump * 0.12;
    float fade = smoothstep(1.02, 1.3, radius) * (1.0 - smoothstep(2.65, 4.0, radius));
    int maxBand = clamp(u.bandCount - 1, 0, 5);
    int index = maxBand;
    for (int i = 0; i < 6; i++) {
        if (i >= u.bandCount) break;
        if (radius < u.edges[i]) {
            index = i;
            break;
        }
    }
    float3 temperature = index == 5
        ? float3(0.541, 0.576, 0.639)
        : a3thermal(clamp((radius - 1.02) / 2.98, 0.0, 1.0)) * a3bandColor(index);
    float gap = 1.0;
    int gapCount = max(0, min(5, u.bandCount - 1));
    for (int i = 0; i < 5; i++) {
        if (i >= gapCount) break;
        gap *= 0.3 + 0.7 * smoothstep(0.006, 0.024, abs(radius - u.edges[i]));
    }
    float3 velocity = normalize(float3(-q.z, 0.0, q.x)), toCamera = normalize(cam - q);
    float approach = dot(velocity, toCamera), beta = 0.48 * sqrt(1.02 / radius);
    float beam = clamp(pow(max(0.25, 1.0 + beta * approach), 3.0), 0.2, 2.4);
    temperature = mix(temperature * float3(1.0, 0.72, 0.52), temperature * float3(0.88, 0.96, 1.16),
                      smoothstep(-0.6, 0.65, approach));
    float highlight = index == u.hover ? 1.3 : 1.0, power = pow(1.02 / radius, 3.0);
    float3 emission = temperature * density * fade * power * beam * gap * highlight * 2.2;
    float opacity = 0.28 * fade * pow(1.02 / radius, 1.5) * clamp(density, 0.0, 1.0);
    return float4(emission, opacity);
}

float4 a3wisps(float3 q, constant CosmosSceneUniforms &u) {
    float radius = length(q.xz), angle = atan2(q.z, q.x);
    float arm = pow(max(0.0, sin(angle + log(radius) * 5.2 - u.time * 0.08 / pow(radius, 1.5))), 26.0);
    float threadNoise = a3pfbm(float2(angle * 7.0 + log(radius) * 3.0, radius * 2.0 - u.time * 0.025), 7.0);
    float fade = smoothstep(1.15, 1.7, radius) * (1.0 - smoothstep(4.2, 5.15, radius));
    float alpha = arm * smoothstep(0.48, 0.78, threadNoise) * fade;
    return float4(a3thermal(clamp((radius - 1.02) / 2.98, 0.0, 1.0)) * alpha * 0.055, alpha * 0.025);
}

constant float pl_TAU = 6.28318530718;

float pl_hash11(float p) {
    p = fract(p * 0.1031);
    p *= p + 33.33;
    p *= p + p;
    return fract(p);
}

float pl_hash13(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.x + p.y) * p.z);
}

float3 pl_hash33(float3 p) {
    p = fract(p * float3(0.1031, 0.1030, 0.0973));
    p += dot(p, p.yxz + 33.33);
    return fract((p.xxy + p.yzz) * p.zyx);
}

float pl_noise1(float p) {
    float i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(pl_hash11(i), pl_hash11(i + 1.0), f);
}

float pl_noise3(float3 p) {
    float3 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(mix(pl_hash13(i), pl_hash13(i + float3(1, 0, 0)), f.x),
                   mix(pl_hash13(i + float3(0, 1, 0)), pl_hash13(i + float3(1, 1, 0)), f.x), f.y),
               mix(mix(pl_hash13(i + float3(0, 0, 1)), pl_hash13(i + float3(1, 0, 1)), f.x),
                   mix(pl_hash13(i + float3(0, 1, 1)), pl_hash13(i + float3(1, 1, 1)), f.x), f.y), f.z);
}

float pl_fbm1(float p) {
    float sum = 0.0, amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += amplitude * pl_noise1(p);
        p = p * 2.03 + 17.1;
        amplitude *= 0.5;
    }
    return sum * 1.0666667;
}

float pl_fbm3(float3 p) {
    float sum = 0.0, amplitude = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += amplitude * pl_noise3(p);
        p = p * 2.03 + float3(17.1, 9.2, 13.7);
        amplitude *= 0.5;
    }
    return sum * 1.0666667;
}

float3 pl_rotateY(float3 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float3(c * p.x + s * p.z, p.y, c * p.z - s * p.x);
}

float3 pl_direction(float latitude, float longitude) {
    float c = cos(latitude);
    return float3(c * cos(longitude), sin(latitude), c * sin(longitude));
}

float3 pl_vortex(float3 p, float3 center, float2 size, float churn) {
    float3 d = p - center;
    float3 u = normalize(cross(float3(0, 1, 0), center) + float3(0.00001, 0, 0));
    float3 w = normalize(cross(center, u));
    float2 uv = float2(dot(d, u) / size.x, dot(d, w) / size.y);
    float radius = length(uv), angle = atan2(uv.y, uv.x + 0.00001);
    float facing = smoothstep(0.45, 0.72, dot(p, center));
    float mask = (1.0 - smoothstep(0.72, 1.15, radius)) * facing;
    float spiral = 0.5 + 0.5 * sin(angle * 2.0 + radius * 18.0 - churn * 5.0);
    float eye = 1.0 - smoothstep(0.05, 0.32, radius);
    return float3(mask, spiral, eye);
}

float3 pl_craterField(float3 p, float coverage, float seed) {
    float3 base = floor(p - 0.5);
    float best = 8.0, id = 0.0, raw = 8.0;
    for (int x = 0; x < 2; x++) {
        for (int y = 0; y < 2; y++) {
            for (int z = 0; z < 2; z++) {
                float3 cell = base + float3(float(x), float(y), float(z));
                float3 h = pl_hash33(cell + seed * 37.11);
                float3 center = cell + 0.18 + 0.64 * h;
                float random = pl_hash13(cell + seed * 61.7 + 7.3);
                float radius = 0.24 + 0.22 * h.x;
                float distanceToCenter = length(p - center);
                float normalizedDistance = distanceToCenter / radius;
                if (random < coverage && normalizedDistance < best) {
                    best = normalizedDistance;
                    id = random;
                    raw = distanceToCenter;
                }
            }
        }
    }
    return float3(best, id, raw);
}

float3 pl_rayCrater(float3 p, float3 center, float radius, float seed) {
    float3 d = p - center;
    float3 u = normalize(cross(float3(0, 1, 0), center) + float3(0.00001, 0, 0));
    float3 w = normalize(cross(center, u));
    float2 uv = float2(dot(d, u), dot(d, w));
    float r = length(uv), angle = atan2(uv.y, uv.x + 0.00001);
    float facing = smoothstep(0.72, 0.90, dot(p, center));
    float core = 1.0 - smoothstep(0.20 * radius, 0.62 * radius, r);
    float rim = smoothstep(0.42 * radius, 0.58 * radius, r) * (1.0 - smoothstep(0.58 * radius, 0.82 * radius, r));
    float frequency = 11.0 + floor(seed * 7.0);
    float rays = pow(0.5 + 0.5 * sin(angle * frequency + seed * pl_TAU + r * 25.0), 6.0);
    float reach = smoothstep(0.52 * radius, 0.90 * radius, r) * (1.0 - smoothstep(0.90 * radius, 4.5 * radius, r));
    rays *= reach * (0.55 + 0.65 * pl_noise3(p * 38.0 + seed * 19.0));
    return float3(rays * facing, rim * facing, core * facing);
}

float3 pl_gasSurface(float3 n, float seed, float t, float fine) {
    float spin = t * (0.018 + 0.024 * (1.0 - n.y * n.y)) + seed * pl_TAU;
    float3 q = pl_rotateY(n, spin);
    float3 offset = float3(seed * 17.13, seed * 7.91 + 3.1, seed * 29.47);
    float warp = pl_fbm3(q * 2.35 + offset);
    float3 warpVector = float3(warp, pl_noise3(q * 3.1 + offset + 5.2),
                               pl_noise3(q * 2.75 + offset + 11.7)) - 0.5;
    q += 0.16 * warpVector;
    float detail = pl_fbm3(q * float3(4.0, 7.0, 4.0) + offset + warpVector * 1.8);
    float latitude = q.y + 0.075 * (warp - 0.5) + 0.025 * (detail - 0.5);
    float frequency = mix(27.0, 43.0, fine);
    float phase = latitude * frequency + 2.2 * (warp - 0.5) + 0.8 * (detail - 0.5) + seed * 4.0;
    float band = 0.5 + 0.5 * sin(phase);
    float band2 = 0.5 + 0.5 * sin(phase * 0.47 + 1.7 + warp);
    float belt = smoothstep(0.18, 0.82, band);
    float3 cream = mix(float3(0.76, 0.66, 0.50), float3(0.86, 0.74, 0.56), seed);
    float3 ochre = mix(float3(0.52, 0.34, 0.16), float3(0.62, 0.43, 0.22), seed);
    float3 rust = mix(float3(0.34, 0.13, 0.065), float3(0.43, 0.20, 0.10), seed);
    float3 brown = mix(float3(0.45, 0.35, 0.27), float3(0.56, 0.44, 0.33), seed);
    if (fine > 0.5) {
        cream = mix(float3(0.67, 0.59, 0.45), float3(0.75, 0.66, 0.51), seed);
        ochre = mix(float3(0.46, 0.38, 0.25), float3(0.54, 0.45, 0.30), seed);
        rust = mix(float3(0.34, 0.26, 0.16), float3(0.42, 0.32, 0.20), seed);
        brown = mix(float3(0.48, 0.42, 0.33), float3(0.57, 0.49, 0.38), seed);
    }
    float3 color = mix(brown, cream, belt);
    color = mix(color, ochre, smoothstep(0.55, 0.92, band2) * 0.55);
    float rustBand = pow(0.5 + 0.5 * sin(latitude * frequency * 0.43 + detail * 2.0 + seed * 9.0), 10.0);
    color = mix(color, rust, rustBand * 0.65);
    float edge = pow(1.0 - abs(sin(phase)), 14.0);
    float curl = pl_noise3(q * float3(24.0, 15.0, 24.0) + offset + float3(0.0, t * 0.006, 0.0));
    color += (curl - 0.5) * edge * 0.16;
    color = mix(color, cream, edge * smoothstep(0.55, 0.85, curl) * 0.18);
    float3 center0 = pl_direction(-0.18 + seed * 0.12, seed * pl_TAU + 1.2);
    float3 storm = pl_vortex(q, center0, float2(0.48, 0.15), detail);
    float3 stormColor = mix(rust, ochre, storm.y * 0.55);
    color = mix(color, stormColor, storm.x * 0.88);
    color = mix(color, cream, storm.x * storm.z * 0.32);
    float3 center1 = pl_direction(0.30 + seed * 0.08, seed * pl_TAU + 3.5);
    float3 storm1 = pl_vortex(q, center1, float2(0.20, 0.072), warp);
    color = mix(color, mix(ochre, cream, storm1.y), storm1.x * 0.58);
    float3 center2 = pl_direction(-0.43, seed * pl_TAU + 5.1);
    float3 storm2 = pl_vortex(q, center2, float2(0.14, 0.055), detail);
    color = mix(color, mix(brown, cream, storm2.y), storm2.x * 0.46);
    return clamp(color, float3(0.0), float3(1.0));
}

float3 pl_iceSurface(float3 n, float seed, float t) {
    float3 q = pl_rotateY(n, seed * pl_TAU + t * 0.009);
    float3 offset = float3(seed * 13.7 + 2.0, seed * 31.1, seed * 7.3 + 8.0);
    float flow = pl_fbm3(q * float3(2.8, 5.5, 2.8) + offset);
    float band = sin(q.y * 20.0 + (flow - 0.5) * 1.6 + seed * 3.0);
    float3 color = mix(float3(0.30, 0.54, 0.60), float3(0.48, 0.72, 0.75),
                       clamp(0.52 + (flow - 0.5) * 0.65 + band * 0.045, 0.0, 1.0));
    float polar = pow(clamp(abs(n.y), 0.0, 1.0), 3.5);
    color = mix(color, float3(0.68, 0.82, 0.82), polar * 0.42);
    float haze = pl_noise3(q * 10.0 + offset);
    color *= 0.97 + 0.06 * haze;
    float3 spotCenter = pl_direction(0.16 + seed * 0.12, seed * pl_TAU + 3.0);
    float3 spot = pl_vortex(q, spotCenter, float2(0.24, 0.15), flow);
    color = mix(color, float3(0.17, 0.37, 0.43), spot.x * (0.18 + 0.08 * spot.y));
    return clamp(color, float3(0.0), float3(1.0));
}

float3 pl_rockySurface(float3 n, float seed) {
    float3 offset = float3(seed * 23.1 + 4.0, seed * 11.7, seed * 41.3 + 2.0);
    float maria = pl_fbm3(n * 2.2 + offset);
    float mariaMask = smoothstep(0.50, 0.68, maria);
    float regolith = pl_noise3(n * 38.0 + offset);
    float micro = pl_noise3(n * 95.0 + offset * 1.7);
    float3 color = mix(float3(0.29, 0.255, 0.215), float3(0.48, 0.425, 0.35), 0.30 + 0.55 * regolith);
    color *= 1.0 - 0.38 * mariaMask;
    float3 crater1 = pl_craterField(n * 6.5 + offset, 0.78, seed);
    float floor1 = 1.0 - smoothstep(0.15, 0.82, crater1.x);
    float rim1 = smoothstep(0.68, 0.88, crater1.x) * (1.0 - smoothstep(0.88, 1.10, crater1.x));
    color *= 1.0 - 0.30 * floor1;
    color += float3(0.12, 0.105, 0.085) * rim1;
    float3 crater2 = pl_craterField(n * 15.0 + offset * 1.31, 0.55, seed + 0.37);
    float floor2 = 1.0 - smoothstep(0.10, 0.76, crater2.x);
    float rim2 = smoothstep(0.65, 0.86, crater2.x) * (1.0 - smoothstep(0.86, 1.08, crater2.x));
    color *= 1.0 - 0.17 * floor2;
    color += float3(0.065, 0.057, 0.047) * rim2;
    color *= 0.88 + 0.20 * regolith + 0.08 * micro;
    return clamp(color, float3(0.0), float3(1.0));
}

float4 pl_moltenSurface(float3 n, float seed, float t) {
    float3 q = pl_rotateY(n, seed * pl_TAU + t * 0.003);
    float3 offset = float3(seed * 19.7 + 1.0, seed * 37.3, seed * 8.9 + 6.0);
    float warp = pl_fbm3(q * 1.8 + offset);
    float field = pl_fbm3(q * 2.7 + offset + float3(warp - 0.5) * 0.72);
    float width = 0.075 + 0.05 * pl_noise3(q * 4.0 + offset);
    float distanceToCrack = abs(field - 0.5);
    float cracks = 1.0 - smoothstep(width * 0.45, width, distanceToCrack);
    float glow = 1.0 - smoothstep(width, width * 4.0, distanceToCrack);
    float basalt = pl_noise3(q * 9.0 + offset);
    float3 color = mix(float3(0.012, 0.014, 0.017), float3(0.060, 0.050, 0.043), basalt);
    color *= 0.65 + 0.60 * warp;
    color = mix(color, float3(0.16, 0.032, 0.005), cracks * 0.75);
    float heat = cracks * (0.95 + 0.25 * basalt) + glow * 0.16;
    return float4(color, heat);
}

float3 pl_moonSurface(float3 n, float seed) {
    float3 offset = float3(seed * 29.3 + 5.0, seed * 17.9, seed * 7.1 + 3.0);
    float patch = pl_fbm3(n * 2.0 + offset);
    float dust = pl_noise3(n * 48.0 + offset);
    float3 color = mix(float3(0.50, 0.49, 0.46), float3(0.72, 0.70, 0.65), smoothstep(0.22, 0.78, patch));
    color *= 0.92 + 0.13 * dust;
    float3 crater = pl_craterField(n * 5.2 + offset, 0.38, seed);
    float craterFloor = 1.0 - smoothstep(0.12, 0.78, crater.x);
    float rim = smoothstep(0.64, 0.84, crater.x) * (1.0 - smoothstep(0.84, 1.08, crater.x));
    color *= 1.0 - 0.17 * craterFloor;
    color += float3(0.14, 0.135, 0.12) * rim;
    float3 ray0 = pl_rayCrater(n, pl_direction(-0.22 + seed * 0.20, seed * pl_TAU + 0.8), 0.095, seed);
    float3 ray1 = pl_rayCrater(n, pl_direction(0.35, seed * pl_TAU + 2.9), 0.072, fract(seed + 0.31));
    float3 ray2 = pl_rayCrater(n, pl_direction(-0.48, seed * pl_TAU + 4.8), 0.060, fract(seed + 0.67));
    float3 rays = ray0 + ray1 * 0.82 + ray2 * 0.68;
    color *= 1.0 - 0.15 * clamp(rays.z, 0.0, 1.0);
    color += float3(0.20, 0.19, 0.17) * (rays.x * 0.48 + rays.y);
    return clamp(color, float3(0.0), float3(0.92));
}

float4 pl_surface(float3 n, float kind, float seed, float t) {
    if (kind < 0.5) return float4(pl_gasSurface(n, seed, t, 0.0), 0.0);
    if (kind < 1.5) return float4(pl_iceSurface(n, seed, t), 0.0);
    if (kind < 2.5) return float4(pl_rockySurface(n, seed), 0.0);
    if (kind < 3.5) return float4(pl_gasSurface(n, seed, t, 1.0), 0.0);
    if (kind < 4.5) return pl_moltenSurface(n, seed, t);
    return float4(pl_moonSurface(n, seed), 0.0);
}

float3 shadePlanet(float4 surface, float3 n, float3 v, float3 l, float3 lightColor, float kind) {
    float3 albedo = surface.rgb;
    float ndl = dot(n, l), ndv = clamp(dot(n, v), 0.0, 1.0);
    bool gas = kind < 1.5 || (kind > 2.5 && kind < 3.5);
    float diffuse, limb = 1.0;
    if (gas) {
        diffuse = clamp((ndl + 0.15) / 1.15, 0.0, 1.0);
        limb = 0.52 + 0.48 * pow(ndv, 0.48);
    } else {
        diffuse = max(ndl, 0.0) * smoothstep(-0.02, 0.055, ndl);
    }
    float3 color = albedo * lightColor * diffuse * limb + albedo * 0.006;
    if (gas) {
        float rim = pow(1.0 - ndv, 4.0) * clamp(ndl + 0.35, 0.0, 1.0);
        float phase = clamp(0.5 - 0.5 * dot(l, v), 0.0, 1.0);
        float3 tint = (kind > 0.5 && kind < 1.5) ? float3(0.40, 0.76, 1.0) : float3(1.0, 0.76, 0.46);
        color += lightColor * tint * rim * (0.055 + 0.14 * phase);
    }
    if (kind > 0.5 && kind < 1.5) {
        float3 h = normalize(l + v + float3(0.00001));
        float fresnel = 0.04 + 0.96 * pow(1.0 - clamp(dot(v, h), 0.0, 1.0), 5.0);
        float specular = pow(max(dot(n, h), 0.0), 80.0) * fresnel;
        color += lightColor * specular * 0.18 * smoothstep(0.0, 0.12, ndl);
    }
    if (kind > 3.5 && kind < 4.5) {
        float3 hot = mix(float3(1.0, 0.12, 0.004), float3(1.0, 0.32, 0.012), clamp(surface.a * 0.65, 0.0, 1.0));
        float rim = pow(1.0 - ndv, 3.2);
        color += hot * surface.a * 1.55;
        color += float3(1.0, 0.16, 0.008) * rim * (0.16 + 0.10 * clamp(surface.a, 0.0, 1.0));
    }
    return color;
}

float4 shadeHalo(float distanceToCenter, float3 v, float3 l, float3 lightColor, float kind) {
    bool gas = kind < 1.5 || (kind > 2.5 && kind < 3.5);
    bool molten = kind > 3.5 && kind < 4.5;
    if ((!gas && !molten) || distanceToCenter <= 1.0 || distanceToCenter >= 1.25) return float4(0.0);
    float x = clamp((distanceToCenter - 1.0) * 4.0, 0.0, 1.0);
    if (molten) {
        float alpha = pow(1.0 - x, 2.0) * 0.18;
        return float4(float3(1.0, 0.14, 0.006) * alpha * 0.8, alpha);
    }
    float alpha = pow(1.0 - x, 2.4) * 0.28;
    float phase = clamp(0.5 - 0.5 * dot(l, v), 0.0, 1.0);
    float forward = phase * phase * (3.0 - 2.0 * phase);
    alpha *= 0.16 + 0.84 * forward;
    float3 tint = (kind > 0.5 && kind < 1.5) ? float3(0.38, 0.74, 1.0) : float3(1.0, 0.74, 0.42);
    float3 rgb = lightColor * tint * alpha * (0.35 + 1.40 * forward);
    return float4(rgb, alpha);
}

float4 shadeRing(float normalizedRadius, float seed, float lightFactor, float t) {
    float radius = clamp(normalizedRadius, 0.0, 1.0);
    float broad = pl_noise1(radius * 9.0 + seed * 31.7);
    float fine = pl_fbm1(radius * 190.0 + seed * 73.1);
    float micro = pl_noise1(radius * 740.0 + seed * 119.3);
    float ringlets = clamp(0.30 + 0.62 * fine + 0.18 * (micro - 0.5), 0.0, 1.0);
    float bx = (radius - 0.39) / 0.19;
    float broadRing = exp(-bx * bx * 2.0);
    float gap = smoothstep(0.018, 0.052, abs(radius - 0.62));
    float edges = smoothstep(0.0, 0.035, radius) * (1.0 - smoothstep(0.94, 1.0, radius));
    float alpha = clamp((0.14 + 0.46 * ringlets + 0.34 * broadRing) * gap * edges, 0.0, 0.90);
    float3 color = mix(float3(0.38, 0.35, 0.30), float3(0.74, 0.66, 0.53),
                       clamp(0.24 + 0.64 * broad + 0.20 * (fine - 0.5), 0.0, 1.0));
    color *= 0.82 + 0.32 * broadRing + 0.12 * fine;
    float shimmer = 0.99 + 0.01 * sin(t * 0.35 + radius * 37.0 + seed * pl_TAU);
    float light = 0.055 + 0.945 * clamp(lightFactor, 0.0, 1.0);
    return float4(color * alpha * light * shimmer, alpha);
}

float3 a3axis(float tilt) {
    return float3(-sin(tilt), cos(tilt), 0.0);
}

float3 a3local(float3 p, float tilt, float spin) {
    float c = cos(tilt), s = sin(tilt);
    p = float3(c * p.x + s * p.y, -s * p.x + c * p.y, p.z);
    c = cos(spin);
    s = sin(spin);
    return float3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}

float3 a3lightDir(float3 center) {
    float2 x = normalize(center.xz + float2(0.0001));
    return normalize(float3(x.x * 1.02, 0.0, x.y * 1.02) - center);
}

float3 a3lightColor(float3 center, constant CosmosSceneUniforms &u) {
    float2 x = normalize(center.xz + float2(0.0001));
    float3 lightPosition = float3(x.x * 1.02, 0.0, x.y * 1.02);
    float d = distance(lightPosition, center);
    float3 emissionPoint = float3(x.x * 1.12, 0.0, x.y * 1.12);
    float3 emission = a3disk(emissionPoint, u.cam, u).rgb;
    float warm = clamp((length(center.xz) - 4.0) / 2.5, 0.0, 1.0);
    return emission * (4.2 / (d * d + 0.3)) * mix(float3(0.9, 0.97, 1.1), float3(1.25, 0.78, 0.46), warm) * u.disk;
}

float3 a3keyDir(float3 center, float3 v) {
    float3 brightest = normalize(float3(2.4, 0.12, 2.2) - center);
    return normalize(mix(brightest, v, 0.22));
}

float3 a3keyColor(float3 center, constant CosmosSceneUniforms &u) {
    float3 emission = a3disk(float3(2.4, 0.0, 2.2), u.cam, u).rgb;
    return (float3(0.38, 0.25, 0.14) + emission * 0.5) * u.disk;
}

float a3sphereShadow(float3 p, float3 l, float3 center, float radius) {
    float3 oc = p - center;
    float b = dot(oc, l), c = dot(oc, oc) - radius * radius, h = b * b - c;
    if (h < 0.0) return 1.0;
    float t = -b - sqrt(h);
    if (t < 0.001) t = -b + sqrt(h);
    return t > 0.001 ? 0.06 : 1.0;
}

float4 a3surface(float3 point, float3 center, float radius, float kind, float seed,
                 float spin, float tilt, float ringed, constant CosmosSceneUniforms &u) {
    float3 n = normalize(point - center), v = normalize(u.cam - point), l = a3lightDir(center);
    float3 light = a3lightColor(center, u);
    if (ringed > 0.5) {
        float denominator = dot(l, a3axis(tilt));
        if (abs(denominator) > 0.001) {
            float t = dot(center - point, a3axis(tilt)) / denominator;
            if (t > 0.001) {
                float3 ringPoint = point + l * t - center;
                float ringRadius = length(ringPoint);
                if (ringRadius > 1.35 * radius && ringRadius < 2.3 * radius) {
                    float normalizedRadius = (ringRadius / radius - 1.35) / 0.95;
                    light *= 1.0 - shadeRing(normalizedRadius, seed, 1.0, u.time).a * 0.82;
                }
            }
        }
    }
    float3 nl = a3local(n, tilt, spin), vl = a3local(v, tilt, spin), ll = a3local(l, tilt, spin);
    float3 keyDirection = a3keyDir(center, v), keyLight = a3keyColor(center, u);
    float3 keyLocal = a3local(keyDirection, tilt, spin);
    float4 surface = pl_surface(nl, kind, seed, u.time);
    float3 albedo = surface.rgb;
    float3 color = shadePlanet(surface, nl, vl, ll, light, kind);
    if (kind > 3.5 && kind < 4.5) color += albedo * keyLight * max(dot(nl, keyLocal), 0.0) * 0.9;
    else color += shadePlanet(surface, nl, vl, keyLocal, keyLight, kind) * 0.9;
    color = (color + albedo * float3(0.065, 0.078, 0.10)) * 1.18;
    float distanceHaze = smoothstep(12.0, 22.0, distance(u.cam, point));
    float luminance = dot(color, float3(0.2126, 0.7152, 0.0722));
    color = mix(color, float3(luminance) * float3(0.58, 0.75, 1.08), distanceHaze * 0.34) * (1.0 - distanceHaze * 0.12);
    float footprint = distance(u.cam, point) / u.focal / radius;
    float alpha = smoothstep(0.0, clamp(footprint * 1.6, 0.008, 0.22), dot(n, v));
    return float4(color, alpha);
}

float4 a3ring(float3 point, float3 center, float radius, float seed, float tilt,
              constant CosmosSceneUniforms &u) {
    float ringRadius = distance(point, center), normalizedRadius = (ringRadius / radius - 1.35) / 0.95;
    float3 l = a3lightDir(center);
    float lit = a3sphereShadow(point + l * radius * 0.002, l, center, radius);
    return shadeRing(clamp(normalizedRadius, 0.0, 1.0), seed, lit, u.time);
}

float3 a3aces(float3 x) {
    float3 y = max((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), float3(0.0));
    float3 z = max(y - float3(0.86), float3(0.0));
    return min(y, float3(0.86)) + 0.14 * (1.0 - exp(-z / 0.14));
}

fragment float4 cosmosSceneFragment(CosmosFullscreenOut in [[stage_in]],
                                    constant CosmosSceneUniforms &u [[buffer(0)]]) {
    float2 fragCoord = float2(in.uv.x, 1.0 - in.uv.y) * u.size, screenPosition = fragCoord - u.center;
    float3 cam = u.cam, initial = normalize(u.fw * u.focal + u.rt * screenPosition.x - u.up * screenPosition.y);
    float3 rd = initial;
    float3 crossH = cross(cam, rd);
    float h2 = dot(crossH, crossH), impact = sqrt(h2), critical = 2.598 * 0.34;
    float travel = max(0.0, -dot(cam, rd) - 7.0);
    float3 p = cam + rd * travel;
    float3 scene = float3(0.0);
    float trans = 1.0;
    bool captured = false;
    float haloDistance = 2.0, haloTravel = 0.0, haloTrans = 1.0;
    float3 haloRGB = float3(0.0);
    for (int step = 0; step < 68; step++) {
        float pr = length(p);
        if (pr < 0.34) {
            captured = true;
            break;
        }
        float dt = clamp(pr * 0.075, 0.055, 0.42);
        float3 old = p;
        float oldTravel = travel;
        rd = normalize(rd - 1.5 * 0.34 * h2 * p / pow(pr, 5.0) * dt);
        p += rd * dt;
        travel += dt;
        float3 segment = p - old;
        float segmentLength = length(segment);
        float3 segmentDirection = segment / segmentLength;
        int hitType = -1;
        float nearest = 1e8, hitRadius = 0.0, hitKind = 0.0, hitSeed = 0.0, hitSpin = 0.0, hitTilt = 0.0, hitRing = 0.0;
        float3 hitPoint = float3(0.0), hitCenter = float3(0.0);
        for (int i = 0; i < 6; i++) {
            if (i >= u.bodyCount) break;
            float3 center = u.bodyPosition[i];
            float radius = u.bodyRadius[i], ringed = u.bodyRing[i];
            float closestT = clamp(dot(center - old, segmentDirection), 0.0, segmentLength);
            float3 closest = old + segmentDirection * closestT;
            float centerDistance = distance(closest, center);
            float bound = radius * (ringed > 0.5 ? 2.35 : 1.28) + travel / u.focal;
            if (centerDistance > bound) continue;
            float3 oc = old - center;
            float b = dot(oc, segmentDirection), c = dot(oc, oc) - radius * radius, discriminant = b * b - c;
            if (discriminant > 0.0) {
                float t = -b - sqrt(discriminant);
                if (t >= 0.0 && t <= segmentLength && oldTravel + t < nearest) {
                    nearest = oldTravel + t;
                    hitType = 0;
                    hitPoint = old + segmentDirection * t;
                    hitCenter = center;
                    hitRadius = radius;
                    hitKind = u.bodyKind[i];
                    hitSeed = u.bodySeed[i];
                    hitSpin = u.bodySpin[i];
                    hitTilt = u.bodyTilt[i];
                    hitRing = ringed;
                }
            }
            if (ringed > 0.5) {
                float3 axis = a3axis(u.bodyTilt[i]);
                float denominator = dot(segmentDirection, axis);
                if (abs(denominator) > 0.0001) {
                    float t = dot(center - old, axis) / denominator;
                    if (t >= 0.0 && t <= segmentLength && oldTravel + t < nearest) {
                        float3 ringPoint = old + segmentDirection * t;
                        float ringRadius = distance(ringPoint, center);
                        if (ringRadius >= 1.35 * radius && ringRadius <= 2.3 * radius) {
                            nearest = oldTravel + t;
                            hitType = 1;
                            hitPoint = ringPoint;
                            hitCenter = center;
                            hitRadius = radius;
                            hitKind = u.bodyKind[i];
                            hitSeed = u.bodySeed[i];
                            hitSpin = u.bodySpin[i];
                            hitTilt = u.bodyTilt[i];
                            hitRing = 1.0;
                        }
                    }
                }
            }
            float hd = centerDistance / radius;
            if (hd > 1.0 && hd < 1.25 && hd < haloDistance) {
                float3 v = normalize(cam - closest), l = a3lightDir(center);
                float4 halo = shadeHalo(hd, a3local(v, u.bodyTilt[i], u.bodySpin[i]),
                                        a3local(l, u.bodyTilt[i], u.bodySpin[i]), a3lightColor(center, u), u.bodyKind[i]);
                haloDistance = hd;
                haloTravel = oldTravel + closestT;
                haloTrans = trans;
                haloRGB = halo.rgb;
            }
        }
        bool hasDisk = false;
        float diskTravel = 0.0;
        float4 diskSample = float4(0.0);
        bool diskCross = (old.y < 0.0 && p.y >= 0.0) || (old.y > 0.0 && p.y <= 0.0);
        if (diskCross) {
            float f = old.y / (old.y - p.y);
            float3 q = mix(old, p, f);
            float diskRadius = length(q.xz);
            diskTravel = oldTravel + segmentLength * f;
            if (u.disk > 0.0) {
                if (diskRadius >= 1.02 && diskRadius <= 4.0) {
                    diskSample = a3disk(q, cam, u);
                    hasDisk = true;
                }
                if (diskRadius > 1.05 && diskRadius < 5.15) {
                    float4 wisp = a3wisps(q, u);
                    diskSample.rgb += wisp.rgb;
                    diskSample.a = 1.0 - (1.0 - diskSample.a) * (1.0 - wisp.a);
                    hasDisk = true;
                }
            }
        }
        if (hasDisk && (hitType < 0 || diskTravel < nearest)) {
            scene += trans * diskSample.rgb;
            trans *= 1.0 - diskSample.a;
            hasDisk = false;
        }
        if (hitType == 0) {
            float4 body = a3surface(hitPoint, hitCenter, hitRadius, hitKind, hitSeed, hitSpin, hitTilt, hitRing, u);
            scene += trans * body.rgb * body.a;
            trans *= 1.0 - body.a;
            break;
        }
        if (hitType == 1) {
            float4 ring = a3ring(hitPoint, hitCenter, hitRadius, hitSeed, hitTilt, u);
            scene += trans * ring.rgb;
            trans *= 1.0 - ring.a;
            if (hasDisk) {
                scene += trans * diskSample.rgb;
                trans *= 1.0 - diskSample.a;
            }
        }
        if (haloDistance < 1.25 && haloTravel >= oldTravel && haloTravel <= travel) haloTrans = trans;
        if ((pr > 8.0 && dot(p, rd) > 0.0) || trans < 0.003) break;
    }
    float ed = (impact - critical * 1.035) / 0.027, einstein = exp(-ed * ed);
    if (!captured) {
        float3 bentSky = a3sky(rd, impact, u);
        scene += trans * bentSky * (1.0 + einstein * 1.4) + float3(0.22, 0.29, 0.4) * einstein * 0.045 * trans;
        float photon = exp(-abs(impact - critical) * 100.0), halo = exp(-abs(impact - critical) * 18.0);
        float secondary = exp(-abs(impact - critical * 1.012) * 240.0);
        float edge = smoothstep(critical * 1.002, critical * 1.018, impact);
        scene += trans * (float3(1.25, 1.12, 0.92) * photon * 2.0 + float3(1.0, 0.62, 0.26) * halo * 0.12);
        scene += trans * float3(0.9, 0.82, 0.68) * secondary * 0.075 * edge;
    }
    if (haloDistance < 1.25 && (!captured || haloTravel < travel)) scene += haloRGB * haloTrans;
    float2 glowPosition = (fragCoord - u.center) / float2(105.0, 36.0);
    float outside = smoothstep(critical * 0.78, critical * 1.12, impact);
    scene += (float3(0.62, 0.75, 1.0) * 0.035 + float3(1.0, 0.52, 0.16) * 0.025)
           * exp(-dot(glowPosition, glowPosition) * 1.5) * outside * u.disk;
    float3 color = mix(a3sky(initial, impact, u), scene, u.reveal);
    color = pow(a3aces(color), float3(1.0 / 2.2));
    float2 vignette = (fragCoord / u.size - 0.5) * float2(1.05, 1.0);
    color *= 1.0 - 0.2 * smoothstep(0.22, 0.75, length(vignette));
    float grain = (a3hash(fragCoord + float2(fract(u.clock * 17.0) * 93.0, fract(u.clock * 11.0) * 57.0)) - 0.5) * 0.028;
    color *= 1.0 + grain;
    return float4(color, 1.0);
}

struct CosmosParticleIn {
    float4 seed [[attribute(0)]];
    float2 meta [[attribute(1)]];
};

struct CosmosParticleOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
    float alpha;
    float2 screen;
};

vertex CosmosParticleOut cosmosParticleVertex(CosmosParticleIn in [[stage_in]],
                                               constant CosmosParticleUniforms &u [[buffer(1)]]) {
    float band = in.meta.x, tail = in.meta.y, random = in.seed.w;
    bool dust = band > 5.5;
    float low = 1.02, high = u.edges[0];
    if (band > 0.5 && band < 1.5) { low = u.edges[0]; high = u.edges[1]; }
    else if (band > 1.5 && band < 2.5) { low = u.edges[1]; high = u.edges[2]; }
    else if (band > 2.5 && band < 3.5) { low = u.edges[2]; high = u.edges[3]; }
    else if (band > 3.5 && band < 4.5) { low = u.edges[3]; high = u.edges[4]; }
    else if (band > 4.5 && band < 5.5) { low = u.edges[4]; high = u.edges[5]; }
    bool plunge = !dust && fract(random * 13.17) < 0.18;
    float life = fract(random + u.time * (plunge ? 0.085 : 0.018));
    float radius = dust ? 5.25 + in.seed.x * 0.72
                        : plunge ? mix(1.075, 0.79, life * life)
                                 : mix(low + 0.002, high - 0.002, pow(1.0 - life, 1.8));
    float pull = plunge ? clamp((1.075 - radius) / 0.285, 0.0, 1.0) : 0.0;
    float omega = 0.48 * pow(1.02 / max(radius, 0.4), 1.5) * (1.0 + pull * 2.8);
    float angle = in.seed.y + u.time * omega - tail * (0.018 + 0.17 * pow(1.02 / max(radius, 0.5), 1.6)) * (1.0 + pull * 4.2);
    radius += tail * (0.004 + pull * 0.095);
    float height = in.seed.z * (0.012 + 0.032 * radius / 4.0) * (1.0 - pull * 0.85);
    if (dust) {
        angle = in.seed.y + u.time * 0.045;
        height = in.seed.z * 0.12;
    }
    float3 world = float3(cos(angle) * radius, height, sin(angle) * radius), relative = world - u.cam;
    float depth = dot(relative, u.fw);
    float2 screen = u.center + u.focal * float2(dot(relative, u.rt) / max(depth, 0.01),
                                                -dot(relative, u.up) / max(depth, 0.01));
    CosmosParticleOut out;
    out.screen = screen;
    out.position = float4(screen.x / u.size.x * 2.0 - 1.0, 1.0 - screen.y / u.size.y * 2.0, 0.0, 1.0);
    out.pointSize = (0.65 + random * 1.1) * u.pixel;
    float nearSide = smoothstep(-0.15, 0.15, dot(world, normalize(u.cam)));
    float fade = smoothstep(0.0, 0.08, life) * (1.0 - smoothstep(plunge ? 0.72 : 0.9, 1.0, life));
    if (dust) {
        out.color = mix(float3(0.3, 0.35, 0.43), float3(0.62, 0.48, 0.3), random);
        out.alpha = (0.025 + 0.07 * random) * u.dust;
    } else {
        int maxBand = clamp(u.bandCount - 1, 0, 5);
        int index = 0;
        if (maxBand >= 1 && radius >= u.edges[0]) index = 1;
        if (maxBand >= 2 && radius >= u.edges[1]) index = 2;
        if (maxBand >= 3 && radius >= u.edges[2]) index = 3;
        if (maxBand >= 4 && radius >= u.edges[3]) index = 4;
        if (maxBand >= 5 && radius >= u.edges[4]) index = 5;
        float innerGain = 0.28 + 1.1 * pow(1.02 / max(radius, 0.9), 1.4);
        float3 bandRGB = index == 5
            ? float3(0.541, 0.576, 0.639)
            : a3thermal(clamp((radius - 1.02) / 2.98, 0.0, 1.0)) * a3bandColor(index);
        out.color = bandRGB * 1.25;
        out.alpha = (0.12 + 0.22 * random) * fade * (1.0 - tail * 0.58) * u.disk * innerGain * (1.0 + pull * 0.6);
        float side = abs(dot(normalize(world.xz), normalize(u.cam.xz)));
        out.alpha *= mix(mix(0.18, 1.0, smoothstep(0.15, 0.7, side)), 1.0, smoothstep(1.3, 2.0, radius));
    }
    out.alpha *= nearSide * (depth >= 0.01 ? 1.0 : 0.0);
    return out;
}

fragment float4 cosmosParticleFragment(CosmosParticleOut in [[stage_in]],
                                       float2 pointCoordinate [[point_coord]],
                                       constant CosmosParticleUniforms &u [[buffer(0)]]) {
    float shadowDistance = distance(in.screen, u.center);
    if (shadowDistance < u.shadow) discard_fragment();
    float alpha = in.alpha * smoothstep(u.shadow, u.shadow + 1.0, shadowDistance);
    if (u.points > 0.5) {
        float d = length(pointCoordinate - 0.5) * 2.0;
        alpha *= 1.0 - smoothstep(0.35, 1.0, d);
    }
    return float4(in.color * alpha, alpha);
}

fragment float4 cosmosBlitFragment(CosmosFullscreenOut in [[stage_in]],
                                   texture2d<float> colorTexture [[texture(0)]]) {
    constexpr sampler colorSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    return colorTexture.sample(colorSampler, float2(in.uv.x, 1.0 - in.uv.y));
}
