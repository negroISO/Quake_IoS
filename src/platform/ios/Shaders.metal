#include <metal_stdlib>

using namespace metal;

struct Q3QuadVertexIn {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float4 color [[attribute(2)]];
};

struct Q3QuadVertexOut {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

vertex Q3QuadVertexOut q3_quad_vertex(Q3QuadVertexIn in [[stage_in]]) {
    Q3QuadVertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.texCoord = in.texCoord;
    out.color = in.color;
    return out;
}

fragment float4 q3_quad_fragment(Q3QuadVertexOut in [[stage_in]],
                                 texture2d<float> colorTexture [[texture(0)]],
                                 sampler linearSampler [[sampler(0)]]) {
    const float4 sampled = colorTexture.sample(linearSampler, in.texCoord);
    return sampled * in.color;
}
