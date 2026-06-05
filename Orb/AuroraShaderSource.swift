import Foundation

enum AuroraShaderSource {
    static let metal = """
    #include <metal_stdlib>
    using namespace metal;

    struct AuroraUniforms {
        float time;
        float2 resolution;
        float2 mouse;
        float hoverStrength;
        float animationStrength;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut aurora_vertex_main(uint vertexId [[vertex_id]]) {
        float2 positions[4] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0,  1.0)
        };

        float2 uv[4] = {
            float2(0.0, 0.0),
            float2(1.0, 0.0),
            float2(0.0, 1.0),
            float2(1.0, 1.0)
        };

        VertexOut out;
        out.position = float4(positions[vertexId], 0.0, 1.0);
        out.uv = uv[vertexId];
        return out;
    }

    static float hash21(float2 p) {
        p = fract(p * float2(123.34, 456.21));
        p += dot(p, p + 45.32);
        return fract(p.x * p.y);
    }

    static float noise(float2 p) {
        float2 i = floor(p);
        float2 f = fract(p);
        float2 u = f * f * (3.0 - 2.0 * f);

        return mix(
            mix(hash21(i), hash21(i + float2(1.0, 0.0)), u.x),
            mix(hash21(i + float2(0.0, 1.0)), hash21(i + float2(1.0, 1.0)), u.x),
            u.y
        );
    }

    static float fbm(float2 p) {
        float value = 0.0;
        float amplitude = 0.5;

        for (int i = 0; i < 5; i++) {
            value += noise(p) * amplitude;
            p = float2(p.x * 1.74 - p.y * 0.42, p.x * 0.42 + p.y * 1.74) + 8.13;
            amplitude *= 0.52;
        }

        return value;
    }

    fragment float4 aurora_fragment_main(VertexOut in [[stage_in]],
                                         constant AuroraUniforms& uniforms [[buffer(0)]]) {
        float2 uv = in.uv;
        float2 centered = uv * 2.0 - 1.0;
        centered.x *= uniforms.resolution.x / max(uniforms.resolution.y, 1.0);

        float t = uniforms.time * uniforms.animationStrength;
        float2 mouse = uniforms.mouse * uniforms.hoverStrength;
        float2 parallax = float2(mouse.x * 0.16, mouse.y * 0.10);
        float2 p = centered - parallax;
        float radius = length(p);
        float angle = atan2(p.y, p.x);

        float lens = smoothstep(0.98, 0.20, radius);
        float hardLens = smoothstep(0.93, 0.76, radius) * smoothstep(1.08, 0.90, radius);
        float innerBody = smoothstep(0.72, 0.08, radius);

        float spin = sin(angle * 3.0 + t * 1.45 + radius * 7.0) * 0.5 + 0.5;
        float slowSpin = sin(angle * -2.0 + t * 0.62 + fbm(p * 2.1 + t * 0.07) * 3.2) * 0.5 + 0.5;
        float liquid = fbm(p * 3.0 + float2(t * 0.10, -t * 0.08));
        float fineGrain = fbm(p * 12.0 + t * 0.15);

        float crescent = smoothstep(0.06, 0.0, abs(radius - (0.54 + slowSpin * 0.22))) * smoothstep(0.96, 0.20, radius);
        float upperGlint = exp(-pow((p.y - 0.36 - mouse.y * 0.10) * 4.0, 2.0)) * smoothstep(-0.70, 0.36, p.x) * smoothstep(0.90, 0.15, radius);
        float rim = smoothstep(0.92, 0.70, radius) - smoothstep(1.04, 0.92, radius);
        float shadow = smoothstep(0.95, 0.30, radius) * smoothstep(-0.90, 0.18, -p.y + p.x * 0.30);

        float3 deepGreen = float3(0.015, 0.23, 0.13);
        float3 glassGreen = float3(0.10, 0.70, 0.34);
        float3 mint = float3(0.50, 1.00, 0.64);
        float3 lime = float3(0.72, 1.00, 0.30);
        float3 whiteGlass = float3(0.88, 1.00, 0.88);

        float3 color = mix(deepGreen, glassGreen, innerBody);
        color = mix(color, mint, spin * 0.26 * lens);
        color += lime * crescent * 0.42;
        color += whiteGlass * upperGlint * 0.38;
        color += float3(0.22, 0.92, 0.44) * liquid * 0.17 * lens;
        color -= float3(0.0, 0.16, 0.04) * shadow * 0.42;
        color += whiteGlass * rim * 0.30;
        color += (fineGrain - 0.5) * 0.035;

        float2 glowP = centered - float2(parallax.x * 0.42, parallax.y * 0.20);
        float glow = exp(-dot(glowP, glowP) * 1.65);
        color += float3(0.10, 0.62, 0.30) * glow * 0.18;

        float alpha = clamp(lens * 0.92 + hardLens * 0.34 + glow * 0.24, 0.0, 0.96);
        alpha *= smoothstep(1.26, 0.68, length(centered));

        return float4(color, alpha);
    }
    """
}
