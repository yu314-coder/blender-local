#include <metal_stdlib>
using namespace metal;

// Grease Pencil strokes (GreasePencilGeometry.swift, GreasePencilPass.swift).
//
// Each primitive is an instance of four vertices drawn as a triangle strip:
// a stroke segment is a quad around its two points in screen space, wide
// enough for the larger radius, and the fragment keeps what lies within the
// radius of the segment, the radius going from one end's to the other's —
// round caps and round joints for every stroke, screen-facing as Blender
// draws them. A fill is a triangle (the fourth vertex repeats the third).
//
// Depth does two jobs. Against the scene it is the depth of the object's
// drawing plane at the pixel (Stroke Depth Order 2D Layers), the real depth
// (3D Location), or in front of everything (Show In Front). Within the
// object it is that depth less a step per primitive, in the drawing's order:
// a later stroke is in front of an earlier one, and a stroke's own segments
// share their depth, so where two of them overlap the second fails the depth
// test rather than blending over the first — a semi-transparent stroke does
// not darken at its joints. An edge pixel (anti-aliased, partly covered) sits
// a step behind its stroke's inside, so the inside of the next segment still
// covers it.

struct GPPoint {
    float4 position;   // xyz in the object's space (in view points for the live stroke), w the radius
    float4 colour;
};

struct GPPrim {
    uint a;
    uint b;
    uint c;
    uint orderKind;    // the order from 1; the top bit marks a fill
    float4 colour;     // a fill's colour
};

struct GPUniforms {
    float4x4 viewProjection;
    float4x4 model;
    float4x4 inverseViewProjection;
    float4   viewport;   // xy: drawable size in pixels; z: pixels per world unit at w = 1; w: pixels per point
    float4   plane;      // the drawing plane in the world: normal xyz, w its distance (dot(n, p) = w);
                         // for Show In Front, w is the object's base depth
    float4   params;     // x: 0 plane depth, 1 real depth, 2 in front, 3 the live stroke (view points)
                         // y: pixels added to every radius (the selection outline); z: the object's scale
                         // w: the smallest radius drawn, in pixels
    float4   outline;    // the outline's colour, when params.y > 0
};

struct GPOut {
    float4 position [[position]];
    float2 a [[flat]];
    float2 b [[flat]];
    float2 radii [[flat]];
    float4 colourA [[flat]];
    float4 colourB [[flat]];
    uint orderKind [[flat]];
};

struct GPFragmentOut {
    float4 colour [[color(0)]];
    float depth [[depth(any)]];
};

static float2 to_pixels(float4 clip, float2 viewport) {
    float2 ndc = clip.xy / clip.w;
    return float2((ndc.x * 0.5 + 0.5) * viewport.x, (0.5 - ndc.y * 0.5) * viewport.y);
}

vertex GPOut gp_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                       const device GPPoint *points [[buffer(0)]],
                       const device GPPrim *prims [[buffer(1)]],
                       constant GPUniforms &u [[buffer(2)]])
{
    GPPrim p = prims[iid];
    GPOut out;
    out.orderKind = p.orderKind;
    bool fill = (p.orderKind & 0x80000000u) != 0u;
    bool live = u.params.x > 2.5;
    bool outline = u.params.y > 0.0;
    // Nothing: a position outside every clip plane.
    float4 nowhere = float4(2.0, 2.0, 2.0, 1.0);

    if (fill) {
        out.a = float2(0.0); out.b = float2(0.0); out.radii = float2(0.0);
        out.colourA = p.colour; out.colourB = p.colour;
        if (outline) { out.position = nowhere; return out; }
        uint index = vid == 0u ? p.a : (vid == 1u ? p.b : p.c);
        float4 world = u.model * float4(points[index].position.xyz, 1.0);
        out.position = u.viewProjection * world;
        return out;
    }

    GPPoint pa = points[p.a];
    GPPoint pb = points[p.b];
    float2 sa, sb;
    float ra, rb, za, zb;
    if (live) {
        sa = pa.position.xy * u.viewport.w;
        sb = pb.position.xy * u.viewport.w;
        ra = pa.position.w * u.viewport.w;
        rb = pb.position.w * u.viewport.w;
        za = 0.0; zb = 0.0;
    } else {
        float4 ca = u.viewProjection * (u.model * float4(pa.position.xyz, 1.0));
        float4 cb = u.viewProjection * (u.model * float4(pb.position.xyz, 1.0));
        if (ca.w <= 1e-5 || cb.w <= 1e-5) { out.position = nowhere; return out; }
        sa = to_pixels(ca, u.viewport.xy);
        sb = to_pixels(cb, u.viewport.xy);
        ra = pa.position.w * u.params.z * u.viewport.z / ca.w;
        rb = pb.position.w * u.params.z * u.viewport.z / cb.w;
        za = ca.z / ca.w;
        zb = cb.z / cb.w;
    }
    ra = max(ra, u.params.w) + u.params.y;
    rb = max(rb, u.params.w) + u.params.y;
    float reach = max(ra, rb) + 1.0;
    float2 d = sb - sa;
    float length_ = length(d);
    float2 along = length_ > 1e-4 ? d / length_ : float2(1.0, 0.0);
    float2 across = float2(-along.y, along.x);
    bool atB = vid >= 2u;
    float side = (vid & 1u) != 0u ? 1.0 : -1.0;
    float2 s = (atB ? sb + along * reach : sa - along * reach) + across * side * reach;
    float2 ndc = float2(s.x / u.viewport.x * 2.0 - 1.0, 1.0 - s.y / u.viewport.y * 2.0);
    out.position = float4(ndc, atB ? zb : za, 1.0);
    out.a = sa;
    out.b = sb;
    out.radii = float2(ra, rb);
    out.colourA = outline ? u.outline : pa.colour;
    out.colourB = outline ? u.outline : pb.colour;
    return out;
}

/// The depth of the drawing plane where the pixel's ray meets it, or the
/// fragment's own where the ray runs along the plane or meets it outside the
/// view.
static float plane_depth(float2 pixel, float fallback, constant GPUniforms &u) {
    float2 ndc = float2(pixel.x / u.viewport.x * 2.0 - 1.0, 1.0 - pixel.y / u.viewport.y * 2.0);
    float4 n0 = u.inverseViewProjection * float4(ndc, 0.0, 1.0);
    float4 n1 = u.inverseViewProjection * float4(ndc, 1.0, 1.0);
    float3 o = n0.xyz / n0.w;
    float3 e = n1.xyz / n1.w;
    float3 dir = e - o;
    float denominator = dot(u.plane.xyz, dir);
    if (abs(denominator) < 1e-9) return fallback;
    float t = (u.plane.w - dot(u.plane.xyz, o)) / denominator;
    if (t < 0.0 || t > 1.0) return fallback;
    float4 c = u.viewProjection * float4(o + dir * t, 1.0);
    return c.z / c.w;
}

fragment GPFragmentOut gp_fragment(GPOut in [[stage_in]], constant GPUniforms &u [[buffer(2)]])
{
    GPFragmentOut out;
    bool fill = (in.orderKind & 0x80000000u) != 0u;
    uint order = u.params.y > 0.0 ? 0u : (in.orderKind & 0x7fffffffu);
    float4 colour;
    bool inside = true;
    if (fill) {
        colour = in.colourA;
    } else {
        float2 p = in.position.xy;
        float2 d = in.b - in.a;
        float l2 = dot(d, d);
        float t = l2 > 1e-8 ? clamp(dot(p - in.a, d) / l2, 0.0, 1.0) : 0.0;
        float r = mix(in.radii.x, in.radii.y, t);
        float distance = length(p - (in.a + t * d)) - r;
        float coverage = clamp(0.5 - distance, 0.0, 1.0);
        if (coverage <= 0.0) discard_fragment();
        inside = coverage >= 0.999;
        colour = mix(in.colourA, in.colourB, t);
        colour.a *= coverage;
    }
    if (colour.a <= 0.0) discard_fragment();
    out.colour = colour;

    float mode = u.params.x;
    if (mode > 0.5 && mode < 1.5) {
        // 3D Location: the stroke's own depth.
        out.depth = in.position.z;
        return out;
    }
    float base;
    if (mode > 2.5) base = 1e-4;            // the live stroke, over everything
    else if (mode > 1.5) base = u.plane.w;  // Show In Front: the object's band
    else base = plane_depth(in.position.xy, in.position.z, u);
    uint key = order * 2u + (inside ? 2u : 1u);
    uint bits = as_type<uint>(clamp(base, 0.0, 1.0));
    out.depth = as_type<float>(bits > key ? bits - key : 0u);
    return out;
}
