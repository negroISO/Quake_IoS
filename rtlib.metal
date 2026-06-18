#include <metal_stdlib>

            #include <metal_stdlib>
            using namespace metal;

            struct PPUniforms {
                float intensity;
                float gamma;
            };

            kernel void q3_postprocess(texture2d<float, access::read_write> drawable [[texture(0)]],
                                       constant PPUniforms &u [[buffer(0)]],
                                       uint2 tid [[thread_position_in_grid]]) {
                uint w = drawable.get_width();
                uint h = drawable.get_height();
                if (tid.x >= w || tid.y >= h) return;
                float4 c = drawable.read(tid);
                float3 rgb = saturate(c.rgb * u.intensity);
                rgb = pow(rgb, float3(u.gamma));
                drawable.write(float4(rgb, c.a), tid);
            }
            