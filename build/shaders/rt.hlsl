struct RenderIndices {
    uint tlas;
    uint output_uav;
    uint colors_srv;
    uint normals_srv;
    uint offsets_srv;
    uint lights_srv; // 0xffffffffu disables explicit light sampling
};

ConstantBuffer<RenderIndices> g : register(b0);

cbuffer CameraBuffer : register(b1) {
    float4 cam_position; // xyz = position, w = tan(yfov/2)
    float4 cam_forward;  // xyz = forward, w = aspect ratio
    float4 cam_right;
    float4 cam_up;
};

struct MeshColor {
    float4 base_color;
    float3 emission;
};

struct LightTriangle {
    float4 p0, p1, p2;
    float4 normal_area;
    float4 emissive_cumarea;
};

struct Payload {
    float3 albedo, emission, normal;
    float hit_t;
};

static const bool ENABLE_REINHARD = true;
static const float EPS = 0.001;
static const float PI = 3.14159265;
// Restore the Cornell reference radiance (17, 12, 4) from normalized glTF emission.
static const float CORNELL_EMISSION_SCALE = 17.0;

float rand01(inout uint seed) {
    uint x = ++seed;
    x ^= x >> 16; x *= 0x7feb352du;
    x ^= x >> 15; x *= 0x846ca68bu;
    return ((x ^ (x >> 16)) >> 8) * (1.0 / 16777216.0);
}

float3 sampleDiffuse(float3 n, inout uint seed) {
    float u = rand01(seed);
    float phi = rand01(seed) * (2 * PI);
    float3 axis = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
    float3 t = normalize(cross(axis, n));
    return sqrt(u) * (cos(phi) * t + sin(phi) * cross(n, t)) + sqrt(1 - u) * n;
}

float3 directLighting(float3 hit, Payload surface, uint count, float totalArea, inout uint seed) {
    StructuredBuffer<LightTriangle> lights = ResourceDescriptorHeap[g.lights_srv];
    float target = rand01(seed) * totalArea;
    uint lo = 0, hi = count - 1;
    while (lo < hi) {
        uint mid = lo + (hi - lo) / 2;
        if (lights[mid].emissive_cumarea.w <= target) lo = mid + 1;
        else hi = mid;
    }
    LightTriangle light = lights[lo];
    if (!(light.normal_area.w > 0)) return 0;
    float u = rand01(seed);
    float v = rand01(seed);
    if (u + v > 1) { u = 1 - u; v = 1 - v; }
    float3 p = light.p0.xyz + u * (light.p1.xyz - light.p0.xyz) + v * (light.p2.xyz - light.p0.xyz);
    float3 delta = p - hit;
    float dist2 = dot(delta, delta);
    if (!(dist2 > EPS * EPS)) return 0;
    float3 wi = delta * rsqrt(dist2);
    float cosSurface = dot(surface.normal, wi);
    float cosLight = dot(light.normal_area.xyz, -wi);
    if (!(cosLight > 0 && cosSurface > 0)) return 0;
    // The area density is 1 / totalArea; convert to solid angle at the surface.
    float pdf = (dist2 / totalArea) / cosLight;
    if (!(pdf > 0) || !isfinite(pdf)) return 0;

    RayDesc shadow;
    shadow.Origin = hit + surface.normal * EPS;
    delta = p - shadow.Origin;
    float dist = length(delta);
    shadow.TMin = 0;
    shadow.TMax = dist - max(EPS, dist * 1e-6);
    if (!(shadow.TMax > shadow.TMin)) return 0;
    shadow.Direction = delta / dist;
    Payload visibility = (Payload)0; // A skipped closest hit leaves hit_t nonnegative.
    RaytracingAccelerationStructure scene = ResourceDescriptorHeap[g.tlas];
    TraceRay(scene, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH | RAY_FLAG_SKIP_CLOSEST_HIT_SHADER,
             0xff, 0, 0, 0, shadow, visibility);
    if (visibility.hit_t >= 0) return 0;
    return surface.albedo * (CORNELL_EMISSION_SCALE * light.emissive_cumarea.rgb) * ((cosSurface / PI) / pdf);
}

float3 reinhard_luminance(float3 color);

[shader("raygeneration")]
void RayGen() {
    uint2 idx = DispatchRaysIndex().xy;
    uint2 dims = DispatchRaysDimensions().xy;
    uint seed = idx.x * 9781u + idx.y * 6271u;
    RaytracingAccelerationStructure scene = ResourceDescriptorHeap[g.tlas];
    RWTexture2D<float4> output = ResourceDescriptorHeap[g.output_uav];
    float2 ndc = (float2(idx) + 0.5) / float2(dims) * 2 - 1;
    float3 dir = normalize(cam_forward.xyz + cam_position.w *
        (ndc.x * cam_forward.w * cam_right.xyz - ndc.y * cam_up.xyz));

    uint count = 0;
    float totalArea = 0;
    if (g.lights_srv != 0xffffffffu) {
        StructuredBuffer<LightTriangle> lights = ResourceDescriptorHeap[g.lights_srv];
        uint stride;
        lights.GetDimensions(count, stride);
        if (count > 0) totalArea = lights[count - 1].emissive_cumarea.w;
    }
    bool useNEE = totalArea > 0 && isfinite(totalArea);
    const uint samples = 8, maxBounces = 6;
    float3 radiance = 0;
    for (uint s = 0; s < samples; ++s) {
        float3 throughput = 1;
        RayDesc ray;
        ray.Origin = cam_position.xyz;
        ray.Direction = dir;
        ray.TMin = EPS;
        ray.TMax = 1000;
        for (uint bounce = 0; bounce < maxBounces; ++bounce) {
            Payload surface = (Payload)0;
            TraceRay(scene, RAY_FLAG_NONE, 0xff, 0, 0, 0, ray, surface);
            if (surface.hit_t < 0) break;
            float3 hit = ray.Origin + ray.Direction * surface.hit_t;
            // With NEE the previous vertex already estimated this emitter connection.
            if (bounce == 0 || !useNEE) radiance += throughput * surface.emission;
            if (useNEE) radiance += throughput * directLighting(hit, surface, count, totalArea, seed);
            throughput *= surface.albedo;
            if (!any(throughput) || bounce + 1 == maxBounces) break;
            ray.Origin = hit + EPS * surface.normal;
            ray.Direction = sampleDiffuse(surface.normal, seed);
        }
    }
    float3 color = radiance / samples;
    output[idx] = float4(ENABLE_REINHARD ? reinhard_luminance(color) : color, 1);
}

[shader("closesthit")]
void ClosestHit(inout Payload payload, in BuiltInTriangleIntersectionAttributes attr) {
    StructuredBuffer<MeshColor> colors = ResourceDescriptorHeap[g.colors_srv];
    StructuredBuffer<float4> normals = ResourceDescriptorHeap[g.normals_srv];
    StructuredBuffer<uint> offsets = ResourceDescriptorHeap[g.offsets_srv];
    MeshColor material = colors[InstanceID()];
    float3 n = normalize(normals[offsets[InstanceID()] + PrimitiveIndex()].xyz);
    bool front = dot(n, WorldRayDirection()) < 0;
    payload.hit_t = RayTCurrent();
    payload.normal = front ? n : -n;
    payload.emission = front ? CORNELL_EMISSION_SCALE * material.emission : 0;
    payload.albedo = material.base_color.rgb;
}

[shader("miss")]
void Miss(inout Payload payload) {
    payload.hit_t = -1;
}

// Luminance-based Reinhard (better preserves hue and saturation)
float3 reinhard_luminance(float3 color) {
    float luma = dot(color, float3(0.2126, 0.7152, 0.0722));
    float toneMappedLuma = luma / (1.0f + luma);
    return color * (toneMappedLuma / max(luma, 0.0001f));
}
