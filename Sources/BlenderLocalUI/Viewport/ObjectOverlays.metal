#include <metal_stdlib>
using namespace metal;

// Cameras, lights and empties: Blender's overlay lines (ObjectOverlays.swift),
// drawn as ribbons of a fixed width on screen.
//
// Metal's own line primitive is one pixel wide at any display scale, which on
// an iPad is a half or a third of the point-wide line Blender draws its
// overlays with (`U.pixelsize`). So each segment is two triangles, spread
// sideways here once both ends are on screen.

struct OverlayLineVertex {
    float4 position;   // xyz: this end, in world space. w: which side of the
                       // line this corner is, -1 or +1; 0 for a corner of a
                       // filled triangle, which is not spread.
    float4 other;      // xyz: the segment's other end.
    float4 color;
};

struct OverlayLineUniforms {
    float4x4 viewProjection;
    float4   viewport;   // xy: drawable size in pixels. z: line width in pixels.
};

struct OverlayLineOut {
    float4 position [[position]];
    float4 color;
};

vertex OverlayLineOut overlay_line_vertex(uint vid [[vertex_id]],
                                          const device OverlayLineVertex *verts [[buffer(0)]],
                                          constant OverlayLineUniforms &u [[buffer(1)]])
{
    OverlayLineVertex v = verts[vid];
    OverlayLineOut out;
    out.color = v.color;

    float4 a = u.viewProjection * float4(v.position.xyz, 1.0);
    if (v.position.w == 0.0) {
        out.position = a;
        return out;
    }
    float4 b = u.viewProjection * float4(v.other.xyz, 1.0);

    // Both ends in front of the eye, or the ribbon would be spread along a
    // direction flipped by the projection. A line entirely behind the eye is
    // sent outside the clip volume.
    const float nearW = 1e-5;
    if (a.w < nearW && b.w < nearW) {
        out.position = float4(0.0, 0.0, -1.0, 1.0);
        return out;
    }
    if (a.w < nearW) { a = mix(a, b, (nearW - a.w) / (b.w - a.w)); }
    if (b.w < nearW) { b = mix(b, a, (nearW - b.w) / (a.w - b.w)); }

    float2 halfViewport = u.viewport.xy * 0.5;
    float2 sa = a.xy / a.w * halfViewport;
    float2 sb = b.xy / b.w * halfViewport;
    float2 d = sb - sa;
    float len = length(d);
    float2 normal = len > 1e-6 ? float2(-d.y, d.x) / len : float2(0.0, 1.0);
    float2 offset = normal * (u.viewport.z * 0.5 * v.position.w);
    a.xy += offset / halfViewport * a.w;
    out.position = a;
    return out;
}

fragment float4 overlay_line_fragment(OverlayLineOut in [[stage_in]])
{
    return in.color;
}

// Image empties' pictures (ImageEmptyPass.swift; round 4, group 8), as
// Blender's overlay_image_vert/frag.glsl draw them: the texture times the
// object's colour; without Opacity, anything under 5% alpha discarded and the
// rest drawn opaque; with it, blended premultiplied.

struct ImageEmptyVertex {
    float4 position;   // xyz world
    float2 uv;         // Blender's uvs: (0,0) at the image's lower left
    float2 pad;
};

struct ImageEmptyUniforms {
    float4x4 viewProjection;
    float4   tint;      // ob->color
    float4   flags;     // x: alpha blend, y: premultiplied texture
};

struct ImageEmptyOut {
    float4 position [[position]];
    float2 uv;
};

vertex ImageEmptyOut image_empty_vertex(uint vid [[vertex_id]],
                                        const device ImageEmptyVertex *verts [[buffer(0)]],
                                        constant ImageEmptyUniforms &u [[buffer(1)]])
{
    ImageEmptyOut out;
    out.position = u.viewProjection * float4(verts[vid].position.xyz, 1.0);
    out.uv = verts[vid].uv;
    return out;
}

fragment float4 image_empty_fragment(ImageEmptyOut in [[stage_in]],
                                     texture2d<float> image [[texture(0)]],
                                     constant ImageEmptyUniforms &u [[buffer(1)]])
{
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    // Metal's rows run top down; Blender's uvs bottom up.
    float2 uv = clamp(in.uv, 0.0, 1.0);
    float4 texel = image.sample(s, float2(uv.x, 1.0 - uv.y));
    // The texture is uploaded premultiplied (CGContext's only RGBA8 form):
    // back to straight colour, as `texture_read_as_linearrgb` hands the shader.
    float3 straight = texel.a > 1e-4 ? texel.rgb / texel.a : float3(0.0);
    float4 color = float4(straight, texel.a) * u.tint;
    if (u.flags.x < 0.5) {
        if (texel.a < 0.05) {
            discard_fragment();
        }
        color.a = 1.0;
    }
    color.rgb *= color.a;
    return color;
}
