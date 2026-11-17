#include <metal_stdlib>
using namespace metal;

struct GlassUniforms {
    float4 tintColor;      // rgb + alpha
    float refraction;      // 0.0 .. 1.0 edge lens curvature
    float specular;        // 0.0 .. 1.5 rim highlight intensity
    float dispersion;      // 0.0 .. 1.0 chromatic aberration
    float focusK;          // 0.0 .. 1.0 front focus weight
    float phase;           // animated light angle from swipe velocity
};

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex VertexOut csGlassVertex(uint vid [[vertex_id]]) {
    float2 pos[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

fragment float4 csGlassFragment(VertexOut in [[stage_in]],
                                constant GlassUniforms &u [[buffer(0)]]) {
    float2 p = in.uv * 2.0 - 1.0;
    float r = length(p);
    if (r > 1.0) {
        return float4(0.0);
    }

    // Smooth circular anti-aliased edge
    float edgeMask = smoothstep(1.0, 0.965, r);

    // Optical spherical dome normal & Fresnel rim curve
    float fresnel = pow(clamp(r, 0.0, 1.0), mix(3.4, 1.85, clamp(u.refraction, 0.0, 1.0)));
    float rimBand = exp(-pow((r - 0.955) / 0.026, 2.0));

    // Directional studio light + dynamic swipe-coupled sheen
    float theta = atan2(p.y, p.x);
    float light1 = exp(-pow(atan2(sin(theta + 2.356 - u.phase), cos(theta + 2.356 - u.phase)) / 0.68, 2.0));
    float light2 = exp(-pow(atan2(sin(theta - 0.785 + u.phase * 0.5), cos(theta - 0.785 + u.phase * 0.5)) / 0.85, 2.0)) * 0.52;
    float crescent = exp(-pow((r - 0.84) / 0.09, 2.0)) * light1 * 0.42;

    // Subtle chromatic dispersion along the glass bevel
    float dispShift = u.dispersion * fresnel * 0.28;
    float3 specRGB = float3(
        0.92 + dispShift * sin(theta * 2.0 + u.phase),
        0.96,
        1.00 + dispShift * cos(theta * 2.0 - u.phase)
    );

    float specStrength = (rimBand * (0.28 + 0.78 * max(light1, light2)) + crescent) * u.specular * (0.75 + 0.35 * u.focusK);
    float bodyTint = fresnel * u.tintColor.a * 0.48;

    float3 outRGB = mix(u.tintColor.rgb, specRGB, clamp(specStrength / max(specStrength + bodyTint, 0.001), 0.0, 1.0));
    float outAlpha = clamp((specStrength + bodyTint) * edgeMask, 0.0, 0.92);

    return float4(outRGB * outAlpha, outAlpha);
}
