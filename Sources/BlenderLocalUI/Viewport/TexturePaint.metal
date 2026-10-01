#include <metal_stdlib>
using namespace metal;

// Texture Paint's drawing: a mesh through its paint surface.
//
// Blender stores a UV per face corner, so where a seam runs the same vertex
// has two UVs. The viewport's vertex buffer has one entry per Blender vertex —
// edit mode names vertices to Blender by that index — so rather than split it,
// this draws corner by corner: `vertex_id` is a corner, and the corner says
// which vertex it is and which UV it has.

struct TPUniforms {          // Uniforms in Shaders.metal and ViewportRenderer.swift
    float4x4 viewProjection;
    float4x4 model;
    float4x4 normalMatrix;
    float4   baseColor;
    float4   params;         // z: 1 when an image is bound
};

struct TPVertexIn {          // MeshIn / MeshVertex
    float3 position;
    float3 normal;
    float2 uv;
};

// The same members as MeshOut in Shaders.metal, so pbr_fragment can shade it.
struct TPOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPos;
    float2 uv;
};

vertex TPOut texpaint_vertex(uint corner [[vertex_id]],
                             const device TPVertexIn *verts [[buffer(0)]],
                             constant TPUniforms &u [[buffer(1)]],
                             const device float2 *cornerUVs [[buffer(2)]],
                             const device uint *cornerVertices [[buffer(3)]])
{
    TPVertexIn v = verts[cornerVertices[corner]];
    float4 world = u.model * float4(v.position, 1.0);
    TPOut out;
    out.position    = u.viewProjection * world;
    out.worldNormal = normalize((u.normalMatrix * float4(v.normal, 0.0)).xyz);
    out.worldPos    = world.xyz;
    // Images are held top row first; UV v runs up from the bottom.
    float2 uv = cornerUVs[corner];
    out.uv = float2(uv.x, 1.0 - uv.y);
    return out;
}

// Solid shading with the image as the surface colour — what Blender's
// workbench does for the object being texture-painted. The studio rig is
// mesh_fragment's, so a face with no image looks exactly as the solid pass
// draws it.
fragment float4 texpaint_fragment(TPOut in [[stage_in]],
                                  constant TPUniforms &u [[buffer(1)]],
                                  texture2d<float> image [[texture(0)]],
                                  sampler imageSampler [[sampler(0)]])
{
    float3 n = normalize(in.worldNormal);
    const float3 keyDir  = normalize(float3(-0.35,  0.55,  0.75));
    const float3 fillDir = normalize(float3( 0.70, -0.30,  0.35));
    const float3 rimDir  = normalize(float3( 0.10, -0.85, -0.45));
    float key  = saturate(dot(n, keyDir));
    float fill = saturate(dot(n, fillDir));
    float rim  = saturate(dot(n, rimDir));

    float3 base = u.baseColor.rgb;
    if (u.params.z > 0.5 && !is_null_texture(image)) {
        base = image.sample(imageSampler, in.uv).rgb;
    }
    float3 lit = base * (0.30 + 0.75 * key)
               + float3(0.16, 0.18, 0.22) * fill * 0.55
               + float3(0.22, 0.22, 0.24) * rim  * 0.35;
    return float4(saturate(lit), u.baseColor.a);
}
