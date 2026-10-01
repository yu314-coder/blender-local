#include <metal_stdlib>
using namespace metal;

// Solid-mode shading for the 3D viewport, matching what Blender's default
// "Studio" viewport shading looks like: a light grey surface lit by a three-way
// studio rig, an orange silhouette on the selection, and a fading floor grid.

struct Uniforms {
    float4x4 viewProjection;
    float4x4 model;
    float4x4 normalMatrix;
    float4    baseColor;
    float4    params;      // x = outline extrusion, y = camera distance
};

// ---------------------------------------------------------------- solid mesh

struct MeshIn {
    float3 position;
    float3 normal;
    float2 uv;
};

struct MeshOut {
    float4 position [[position]];
    float3 worldNormal;
    float3 worldPos;
    float2 uv;
};

vertex MeshOut mesh_vertex(uint vid [[vertex_id]],
                           const device MeshIn *verts [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]])
{
    MeshIn v = verts[vid];
    float4 world = u.model * float4(v.position, 1.0);

    MeshOut out;
    out.position    = u.viewProjection * world;
    out.worldNormal = normalize((u.normalMatrix * float4(v.normal, 0.0)).xyz);
    out.worldPos    = world.xyz;
    out.uv          = v.uv;
    return out;
}

// ------------------------------------------------- vertex-attribute display
//
// Vertex Paint and Weight Paint colour the surface per vertex, not per object,
// so they need their own pair: the same studio lighting, but with the base
// colour coming from a parallel buffer indexed by vertex rather than from the
// uniform. Keeping it separate leaves MeshVertex — and therefore every other
// pass — untouched.

struct AttributeOut {
    float4 position [[position]];
    float3 worldNormal;
    float4 colour;
};

vertex AttributeOut attribute_vertex(uint vid [[vertex_id]],
                                     const device MeshIn *verts [[buffer(0)]],
                                     constant Uniforms &u [[buffer(1)]],
                                     const device float4 *attr [[buffer(2)]])
{
    MeshIn v = verts[vid];
    AttributeOut out;
    out.position    = u.viewProjection * (u.model * float4(v.position, 1.0));
    out.worldNormal = normalize((u.normalMatrix * float4(v.normal, 0.0)).xyz);
    out.colour      = attr[vid];
    return out;
}

fragment float4 attribute_fragment(AttributeOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(1)]])
{
    float3 n = normalize(in.worldNormal);
    const float3 keyDir  = normalize(float3(-0.35,  0.55,  0.75));
    const float3 fillDir = normalize(float3( 0.70, -0.30,  0.35));
    float key  = saturate(dot(n, keyDir));
    float fill = saturate(dot(n, fillDir));
    // Flatter than the solid pass on purpose: Blender's paint modes keep the
    // shading light so the attribute itself stays readable.
    float3 lit = in.colour.rgb * (0.55 + 0.50 * key) + float3(0.10) * fill * 0.4;
    return float4(saturate(lit), 1.0);
}

fragment float4 mesh_fragment(MeshOut in [[stage_in]],
                              constant Uniforms &u [[buffer(1)]])
{
    float3 n = normalize(in.worldNormal);

    // Blender's default studiolight, reduced to the three dominant lobes:
    // a key from the upper front-left, a cool fill, and a rim from behind.
    const float3 keyDir  = normalize(float3(-0.35,  0.55,  0.75));
    const float3 fillDir = normalize(float3( 0.70, -0.30,  0.35));
    const float3 rimDir  = normalize(float3( 0.10, -0.85, -0.45));

    float key  = saturate(dot(n, keyDir));
    float fill = saturate(dot(n, fillDir));
    float rim  = saturate(dot(n, rimDir));

    float3 lit = u.baseColor.rgb * (0.30 + 0.75 * key)
               + float3(0.16, 0.18, 0.22) * fill * 0.55
               + float3(0.22, 0.22, 0.24) * rim  * 0.35;

    return float4(saturate(lit), u.baseColor.a);
}

// ------------------------------------------------------------------ PBR
//
// Material Preview shades with a metallic/roughness workflow — the same inputs
// Blender's Principled BSDF takes — using Cook-Torrance GGX. There is no
// environment map, so the specular reflects the same three studio lights the
// solid pass uses rather than a real surrounding.

struct PBRUniforms {
    float4x4 viewProjection;
    float4x4 model;
    float4x4 normalMatrix;
    float4   baseColor;
    float4   emission;        // rgb = colour, a = strength
    float4   params;          // x metallic, y roughness, z ior, w camera dist
    float4   cameraPos;
};

static inline float distributionGGX(float3 n, float3 h, float roughness)
{
    float a = roughness * roughness;
    float a2 = a * a;
    float ndoth = max(dot(n, h), 0.0);
    float d = ndoth * ndoth * (a2 - 1.0) + 1.0;
    return a2 / max(3.14159265 * d * d, 1e-6);
}

static inline float geometrySmith(float3 n, float3 v, float3 l, float roughness)
{
    float r = roughness + 1.0;
    float k = (r * r) / 8.0;
    float ndotv = max(dot(n, v), 0.0);
    float ndotl = max(dot(n, l), 0.0);
    float gv = ndotv / (ndotv * (1.0 - k) + k);
    float gl = ndotl / (ndotl * (1.0 - k) + k);
    return gv * gl;
}

static inline float3 fresnelSchlick(float cosTheta, float3 f0)
{
    return f0 + (1.0 - f0) * pow(clamp(1.0 - cosTheta, 0.0, 1.0), 5.0);
}

vertex MeshOut pbr_vertex(uint vid [[vertex_id]],
                          const device MeshIn *verts [[buffer(0)]],
                          constant PBRUniforms &u [[buffer(1)]])
{
    MeshIn v = verts[vid];
    float4 world = u.model * float4(v.position, 1.0);
    MeshOut out;
    out.position    = u.viewProjection * world;
    out.worldNormal = normalize((u.normalMatrix * float4(v.normal, 0.0)).xyz);
    out.worldPos    = world.xyz;
    out.uv          = v.uv;
    return out;
}

fragment float4 pbr_fragment(MeshOut in [[stage_in]],
                             constant PBRUniforms &u [[buffer(1)]],
                             texture2d<float> albedoMap [[texture(0)]],
                             sampler albedoSampler [[sampler(0)]])
{
    float3 n = normalize(in.worldNormal);
    float3 v = normalize(u.cameraPos.xyz - in.worldPos);

    float metallic  = clamp(u.params.x, 0.0, 1.0);
    float roughness = clamp(u.params.y, 0.045, 1.0);
    float3 albedo   = u.baseColor.rgb;

    // cameraPos.w flags a painted texture; it multiplies the base colour, the
    // way Blender wires an Image Texture into Base Color.
    if (u.cameraPos.w > 0.5 && !is_null_texture(albedoMap)) {
        albedo *= albedoMap.sample(albedoSampler, in.uv).rgb;
    }

    // Dielectric reflectance from IOR, as the Principled BSDF derives it.
    float ior = max(u.params.z, 1.0);
    float f0d = pow((ior - 1.0) / (ior + 1.0), 2.0);
    float3 f0 = mix(float3(f0d), albedo, metallic);

    // The studio rig the solid pass uses, so the two modes agree on lighting.
    const float3 dirs[3] = {
        normalize(float3(-0.35,  0.55,  0.75)),
        normalize(float3( 0.70, -0.30,  0.35)),
        normalize(float3( 0.10, -0.85, -0.45)),
    };
    const float3 colors[3] = {
        float3(1.00, 0.98, 0.95) * 3.0,
        float3(0.55, 0.62, 0.78) * 1.1,
        float3(0.70, 0.70, 0.75) * 0.8,
    };

    float3 lit = float3(0.0);
    for (int i = 0; i < 3; i++) {
        float3 l = dirs[i];
        float3 h = normalize(v + l);
        float ndotl = max(dot(n, l), 0.0);
        if (ndotl <= 0.0) continue;

        float  ndf = distributionGGX(n, h, roughness);
        float  g   = geometrySmith(n, v, l, roughness);
        float3 f   = fresnelSchlick(max(dot(h, v), 0.0), f0);

        float3 spec = (ndf * g * f) / max(4.0 * max(dot(n, v), 0.0) * ndotl, 1e-4);
        float3 kd = (1.0 - f) * (1.0 - metallic);
        lit += (kd * albedo / 3.14159265 + spec) * colors[i] * ndotl;
    }

    // A little ambient so unlit sides are not pure black, standing in for the
    // world lighting a render engine would provide.
    lit += albedo * (1.0 - metallic) * 0.06;
    lit += u.emission.rgb * u.emission.a;

    // Reinhard, then gamma, so bright speculars roll off instead of clipping.
    lit = lit / (lit + 1.0);
    return float4(pow(lit, 1.0 / 2.2), u.baseColor.a);
}

// ------------------------------------------------------------- outline pass
//
// Inverted-hull silhouette: push each vertex out along its normal and draw only
// back faces, so the flat colour survives exactly where the object's outline is.

vertex float4 outline_vertex(uint vid [[vertex_id]],
                             const device MeshIn *verts [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]])
{
    MeshIn v = verts[vid];
    float4 world = u.model * float4(v.position, 1.0);
    // Blender gives a wire or loose vertex at the object's origin the normal
    // (0,0,0) (measured in 5.2.1: the first vertex of a line from the origin,
    // the middle of a NURBS path). normalize(0) is NaN and NaN times a zero
    // extrusion is still NaN, so every wire, Wireframe shading and the
    // edit-mode wire lost each edge touching such a vertex while it stayed
    // tappable (tests/shaders measures it). Such a vertex is not extruded.
    float3 n = (u.normalMatrix * float4(v.normal, 0.0)).xyz;
    float lengthSquared = dot(n, n);
    if (u.params.x != 0.0 && lengthSquared > 1e-12) {
        // Scale the extrusion with camera distance so the outline keeps a
        // roughly constant on-screen width as the user dollies in and out.
        world.xyz += n * rsqrt(lengthSquared) * u.params.x * max(u.params.y, 0.5);
    }
    return u.viewProjection * world;
}

fragment float4 outline_fragment(constant Uniforms &u [[buffer(1)]])
{
    return u.baseColor;
}

// ------------------------------------------------------------- edit points
//
// Edit mode draws every vertex as a square dot, which is what makes a mesh
// look editable. Metal needs an explicit point size from the vertex stage.

struct PointOut {
    float4 position [[position]];
    float  size     [[point_size]];
    float4 color;
};

vertex PointOut point_vertex(uint vid [[vertex_id]],
                             const device MeshIn *verts [[buffer(0)]],
                             constant Uniforms &u [[buffer(1)]])
{
    MeshIn v = verts[vid];
    PointOut out;
    out.position = u.viewProjection * (u.model * float4(v.position, 1.0));
    // params.x carries the dot size in pixels.
    out.size  = u.params.x;
    out.color = u.baseColor;
    return out;
}

fragment float4 point_fragment(PointOut in [[stage_in]],
                               float2 coord [[point_coord]])
{
    return in.color;
}

// --------------------------------------------------------------- floor grid

struct GridIn {
    float3 position;
    float4 color;
};

struct GridOut {
    float4 position [[position]];
    float4 color;
    float3 worldPos;
};

vertex GridOut grid_vertex(uint vid [[vertex_id]],
                           const device GridIn *verts [[buffer(0)]],
                           constant Uniforms &u [[buffer(1)]])
{
    GridIn v = verts[vid];
    GridOut out;
    out.position = u.viewProjection * float4(v.position, 1.0);
    out.color    = v.color;
    out.worldPos = v.position;
    return out;
}

fragment float4 grid_fragment(GridOut in [[stage_in]],
                              constant Uniforms &u [[buffer(1)]])
{
    // Blender fades the grid toward the horizon rather than cutting it off.
    //
    // This has to be per-fragment: each grid line is two vertices at opposite
    // far ends, so both endpoints sit beyond the fade radius. Computing the
    // fade in the vertex shader would interpolate zero across the whole line
    // and the grid would vanish entirely.
    float d = length(in.worldPos.xy);
    float fade = 1.0 - smoothstep(u.params.x * 0.45, u.params.x, d);
    return float4(in.color.rgb, in.color.a * fade);
}
