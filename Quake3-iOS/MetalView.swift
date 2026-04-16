import SwiftUI
import MetalKit
import GameController
import QuartzCore
import simd

struct MetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.delegate = context.coordinator
        let maxFPS = UIScreen.main.maximumFramesPerSecond
        view.preferredFramesPerSecond = maxFPS
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, MTKViewDelegate {
        struct GPUVertex {
            var position: SIMD2<Float>
            var texCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }

        struct Uniforms {
            var projection: simd_float4x4
        }

        struct GPUWorldVertex {
            var position: SIMD3<Float>
            var texCoord: SIMD2<Float>
            var lightmapTexCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }

        struct WorldUniforms {
            var viewProjection: simd_float4x4
        }

        struct WorldDrawUniforms {
            var texCoordScale: SIMD2<Float>
            var texCoordScroll: SIMD2<Float>
            var timeSeconds: Float
            var debugMode: Float
            var forceWhiteVertColor: Float  // 1.0 for additive (skip BSP vertex color)
            var alphaTestThreshold: Float   // >0: discard if a<thresh; <0: discard if a>=|thresh|; 0: none
        }

        // Render debug: 0 = normal, 1 = base only, 2 = lightmap only,
        // 3 = uv1 visualization, 4 = vertex color only. Flip to diagnose
        // lightmap / uv1 issues without touching the build pipeline.
        private static let worldDebugMode: Float = 0

        private static func alphaTestThreshold(for alphaFunc: UInt32) -> Float {
            switch alphaFunc {
            case 1: return 0.004 // GT0
            case 2: return 0.5   // GE128
            case 3: return -0.5  // LT128 (negative means invert test)
            default: return 0.0  // disabled
            }
        }

        struct GPUEntityVertex {
            var position: SIMD3<Float>
            var texCoord: SIMD2<Float>
            var color: SIMD4<Float>
        }

        struct EntityUniforms {
            var viewProjection: simd_float4x4
        }

        private let shaderSource = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexIn {
            float2 position;
            float2 texCoord;
            float4 color;
        };

        struct Uniforms {
            float4x4 projection;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 texCoord;
            float4 color;
        };

        vertex VertexOut q3_ui_vertex(const device VertexIn *vertices [[buffer(0)]],
                                      constant Uniforms &uniforms [[buffer(1)]],
                                      uint vertexID [[vertex_id]]) {
            VertexOut out;
            VertexIn inVertex = vertices[vertexID];
            out.position = uniforms.projection * float4(inVertex.position, 0.0, 1.0);
            out.texCoord = inVertex.texCoord;
            out.color = inVertex.color;
            return out;
        }

        fragment float4 q3_ui_fragment(VertexOut in [[stage_in]],
                                       texture2d<float> colorTexture [[texture(0)]],
                                       sampler textureSampler [[sampler(0)]]) {
            constexpr sampler fallbackSampler(filter::linear, address::clamp_to_edge);
            float4 texel = colorTexture.sample(textureSampler, in.texCoord);
            return texel * in.color;
        }

        struct WorldVertexIn {
            float3 position;
            float2 texCoord;
            float2 lightmapTexCoord;
            float4 color;
        };

        struct WorldUniforms {
            float4x4 viewProjection;
        };

        struct WorldVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float2 lightmapTexCoord;
            float4 color;
        };

        struct WorldDrawUniforms {
            float2 texCoordScale;
            float2 texCoordScroll;
            float timeSeconds;
            float debugMode;
            float forceWhiteVertColor;
            float alphaTestThreshold;
        };

        struct EntityVertexIn {
            float3 position;
            float2 texCoord;
            float4 color;
        };

        struct EntityUniforms {
            float4x4 viewProjection;
        };

        struct EntityVertexOut {
            float4 position [[position]];
            float2 texCoord;
            float4 color;
        };

        vertex WorldVertexOut q3_world_vertex(const device WorldVertexIn *vertices [[buffer(0)]],
                                              constant WorldUniforms &uniforms [[buffer(1)]],
                                              uint vertexID [[vertex_id]]) {
            WorldVertexOut out;
            WorldVertexIn inVertex = vertices[vertexID];
            out.position = uniforms.viewProjection * float4(inVertex.position, 1.0);
            out.texCoord = inVertex.texCoord;
            out.lightmapTexCoord = inVertex.lightmapTexCoord;
            out.color = inVertex.color;
            return out;
        }

        fragment float4 q3_world_fragment(WorldVertexOut in [[stage_in]],
                                          constant WorldDrawUniforms &drawUniforms [[buffer(0)]],
                                          texture2d<float> colorTexture [[texture(0)]],
                                          texture2d<float> lightmapTexture [[texture(1)]],
                                          sampler textureSampler [[sampler(0)]]) {
            float2 texCoord = in.texCoord * drawUniforms.texCoordScale
                + drawUniforms.texCoordScroll * drawUniforms.timeSeconds;
            float4 texel = colorTexture.sample(textureSampler, texCoord);
            float4 lightmap = lightmapTexture.sample(textureSampler, in.lightmapTexCoord);
            int mode = int(drawUniforms.debugMode + 0.5);
            if (mode == 1) {
                return float4(texel.rgb, 1.0);
            }
            if (mode == 2) {
                return float4(lightmap.rgb, 1.0);
            }
            if (mode == 3) {
                return float4(fract(in.lightmapTexCoord.x), fract(in.lightmapTexCoord.y), 0.0, 1.0);
            }
            if (mode == 4) {
                return float4(in.color.rgb, 1.0);
            }
            // NOTE: No unconditional alpha-test discard here.
            //
            // ef21f24 introduced `if (result.a < 0.01) discard_fragment();` to
            // emulate GL alphaFunc, but Q3 alpha-test is a PER-SHADER-STAGE opt-in
            // (the `alphaFunc GT0|GE128|LT128` keyword on a stage), not a
            // world-wide rule. Forcing it on every fragment made q3dm1's two
            // ornamental arches go see-through whenever their stage0 texture
            // failed to resolve (see HUD "falling back to white" errors) or when
            // lightmap*vertexColor multiplied alpha below threshold.
            //
            // Until the per-stage shader driver is in place, world fragments must
            // always write. Alpha-tested stages will be reintroduced through the
            // Q3 shader parser, not as a global discard.
            //
            // Overbright: Q3 lightmaps are authored expecting a 2x boost (stock
            // r_overBrightBits default = 1, i.e. multiply by 2^1). Without the
            // boost the whole world renders at half brightness — user reported
            // the game was 'awfully dark even with phone brightness all the way
            // up'. saturate() clamps to [0,1] so bright spots don't wrap.
            // Per-shader alphaFunc: GT0 / GE128 / LT128.
            // Threshold >0 → discard if alpha < threshold (GT0=0.004, GE128=0.5)
            // Threshold <0 → discard if alpha >= |threshold| (LT128=-0.5)
            if (drawUniforms.alphaTestThreshold > 0.0) {
                if (texel.a < drawUniforms.alphaTestThreshold) discard_fragment();
            } else if (drawUniforms.alphaTestThreshold < 0.0) {
                if (texel.a >= -drawUniforms.alphaTestThreshold) discard_fragment();
            }

            // For additive surfaces (flames, glow), BSP vertex color is
            // typically (0,0,0) because Q3 shaders use rgbGen identity.
            // forceWhiteVertColor=1.0 substitutes white, preventing the
            // multiply from zeroing out the fragment.
            float3 vc = mix(in.color.rgb, float3(1.0), drawUniforms.forceWhiteVertColor);
            float  va = mix(in.color.a,   1.0,          drawUniforms.forceWhiteVertColor);
            float3 lit = saturate(texel.rgb * lightmap.rgb * 2.0) * vc;
            return float4(lit, texel.a * va);
        }

        vertex EntityVertexOut q3_entity_vertex(const device EntityVertexIn *vertices [[buffer(0)]],
                                                constant EntityUniforms &uniforms [[buffer(1)]],
                                                uint vertexID [[vertex_id]]) {
            EntityVertexOut out;
            EntityVertexIn inVertex = vertices[vertexID];
            out.position = uniforms.viewProjection * float4(inVertex.position, 1.0);
            out.texCoord = inVertex.texCoord;
            out.color = inVertex.color;
            return out;
        }

        fragment float4 q3_entity_fragment(EntityVertexOut in [[stage_in]],
                                           texture2d<float> colorTexture [[texture(0)]],
                                           sampler textureSampler [[sampler(0)]]) {
            float4 texel = colorTexture.sample(textureSampler, in.texCoord);
            return texel * in.color;
        }
        """

        private var commandQueue: MTLCommandQueue?
        private var uiPipelineState: MTLRenderPipelineState?
        private var worldPipelineState: MTLRenderPipelineState?
        private var worldFilterPipelineState: MTLRenderPipelineState?
        private var worldAlphaPipelineState: MTLRenderPipelineState?
        private var worldAdditivePipelineState: MTLRenderPipelineState?
        private var entityPipelineState: MTLRenderPipelineState?
        private var entityFilterPipelineState: MTLRenderPipelineState?
        private var entityAlphaPipelineState: MTLRenderPipelineState?
        private var entityAdditivePipelineState: MTLRenderPipelineState?
        private var additiveEntityDepthStencilState: MTLDepthStencilState?
        private var uiSamplerState: MTLSamplerState?
        private var worldSamplerState: MTLSamplerState?
        private var depthStencilState: MTLDepthStencilState?
        private var additiveDepthStencilState: MTLDepthStencilState?
        private var depthHackDepthStencilState: MTLDepthStencilState?
        private var fallbackDepthStencilState: MTLDepthStencilState?

        private func ensuredDepthStencilState(_ preferred: MTLDepthStencilState?, device: MTLDevice?) -> MTLDepthStencilState? {
            if let preferred { return preferred }
            if let fallbackDepthStencilState { return fallbackDepthStencilState }
            guard let device else { return nil }
            let desc = MTLDepthStencilDescriptor()
            desc.depthCompareFunction = .always
            desc.isDepthWriteEnabled = false
            fallbackDepthStencilState = device.makeDepthStencilState(descriptor: desc)
            return fallbackDepthStencilState
        }
        private var textureCache: [UInt32: (generation: UInt32, texture: MTLTexture)] = [:]
        private var vertexBuffer: MTLBuffer?
        private var vertexBufferCapacity = 0
        private var worldVertexBuffer: MTLBuffer?
        private var worldIndexBuffer: MTLBuffer?
        private var cachedWorldGeneration: UInt32 = 0
        private var entityVertexBuffer: MTLBuffer?
        private var entityVertexBufferCapacity = 0
        private var entityIndexBuffer: MTLBuffer?
        private var entityIndexBufferCapacity = 0
        private var debugFrameCounter: UInt32 = 0
        private var frameTimeOrigin = CACurrentMediaTime()

        override init() {
            super.init()
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            print("[Metal] Drawable size: \(size)")
            Q3MetalRenderer_UpdateDrawableSize(Int32(size.width), Int32(size.height))
        }

        func draw(in view: MTKView) {
            if commandQueue == nil {
                configureRenderer(for: view)
            }

            Q3MetalRenderer_UpdateDrawableSize(Int32(view.drawableSize.width), Int32(view.drawableSize.height))
            Quake3_Frame()

            guard let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee else { return }
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor,
                  let commandQueue,
                  let uiSamplerState,
                  let worldSamplerState,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(snapshot.clearColor.0),
                green: Double(snapshot.clearColor.1),
                blue: Double(snapshot.clearColor.2),
                alpha: Double(snapshot.clearColor.3)
            )

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                return
            }

            if snapshot.worldCommandCount > 0,
               let worldPipelineState,
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let worldVertexBuffer = uploadWorldBuffers(device: view.device, generation: snapshot.worldGeneration),
               let worldIndexBuffer {
                let viewProjection = makeWorldViewProjection(sceneView)
                var worldUniforms = WorldUniforms(viewProjection: viewProjection)
                encoder.setRenderPipelineState(worldPipelineState)
                encoder.setDepthStencilState(ensuredDepthStencilState(depthStencilState, device: view.device))
                encoder.setFrontFacing(.clockwise)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(worldVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)

                if let worldDrawsPointer = Q3MetalRenderer_GetWorldDrawCommands(),
                   let indicesPointer = Q3MetalRenderer_GetWorldIndices() {
                    let _ = indicesPointer
                    let worldDraws = UnsafeBufferPointer(start: worldDrawsPointer, count: Int(snapshot.worldCommandCount))
                    let timeSeconds = Float(CACurrentMediaTime() - frameTimeOrigin)
                    let additiveBitW = UInt32(Q3_METAL_WORLD_DRAWFLAG_ADDITIVE)
                    let alphaBitW = UInt32(Q3_METAL_WORLD_DRAWFLAG_ALPHA)
                    let filterBitW = UInt32(Q3_METAL_WORLD_DRAWFLAG_FILTER)

                    // Ordered world passes:
                    // 0 = opaque, 1 = filter, 2 = alpha, 3 = additive.
                    for worldPass in 0..<4 {
                    for draw in worldDraws where draw.indexCount > 0 {
                        let isAdditive = (draw.flags & additiveBitW) != 0
                        let isAlpha = (draw.flags & alphaBitW) != 0
                        let isFilter = (draw.flags & filterBitW) != 0
                        let drawPass = isAdditive ? 3 : (isAlpha ? 2 : (isFilter ? 1 : 0))
                        guard drawPass == worldPass else { continue }

                        guard let baseTexture = texture(for: draw.textureHandle, device: view.device) else {
                            continue
                        }
                        guard let lightmapTexture = texture(for: draw.lightmapTextureHandle, device: view.device) else {
                            continue
                        }
                        if drawPass == 3, let worldAdditivePipelineState {
                            encoder.setRenderPipelineState(worldAdditivePipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                        } else if drawPass == 2, let worldAlphaPipelineState {
                            encoder.setRenderPipelineState(worldAlphaPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                        } else if drawPass == 1, let worldFilterPipelineState {
                            encoder.setRenderPipelineState(worldFilterPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveDepthStencilState, device: view.device))
                        } else {
                            encoder.setRenderPipelineState(worldPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(depthStencilState, device: view.device))
                        }
                        let alphaTest = Self.alphaTestThreshold(for: draw.alphaFunc)
                        var drawUniforms = WorldDrawUniforms(
                            texCoordScale: SIMD2<Float>(draw.texCoordScale.0, draw.texCoordScale.1),
                            texCoordScroll: SIMD2<Float>(draw.texCoordScroll.0, draw.texCoordScroll.1),
                            timeSeconds: timeSeconds,
                            debugMode: Coordinator.worldDebugMode,
                            forceWhiteVertColor: isAdditive ? 1.0 : 0.0,
                            alphaTestThreshold: alphaTest
                        )
                        encoder.setFragmentTexture(baseTexture, index: 0)
                        encoder.setFragmentTexture(lightmapTexture, index: 1)
                        encoder.setFragmentBytes(&drawUniforms, length: MemoryLayout<WorldDrawUniforms>.stride, index: 0)
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(draw.indexCount),
                            indexType: .uint32,
                            indexBuffer: worldIndexBuffer,
                            indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                        )
                    }
                    } // end worldPass loop
                }

                debugFrameCounter &+= 1
                if debugFrameCounter % 60 == 0 {
                    let axis0 = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
                    let axis1 = SIMD3<Float>(sceneView.viewAxis.3, sceneView.viewAxis.4, sceneView.viewAxis.5)
                    let axis2 = SIMD3<Float>(sceneView.viewAxis.6, sceneView.viewAxis.7, sceneView.viewAxis.8)
                    let fovX = String(format: "%.2f", sceneView.fovX)
                    let fovY = String(format: "%.2f", sceneView.fovY)
                    print(
                        "[Metal] world frame \(debugFrameCounter) " +
                        "vieworg=(\(sceneView.viewOrigin.0), \(sceneView.viewOrigin.1), \(sceneView.viewOrigin.2)) " +
                        "axis0=\(formatVector(axis0)) axis1=\(formatVector(axis1)) axis2=\(formatVector(axis2)) " +
                        "fov=(\(fovX), \(fovY)) " +
                        "draws=\(snapshot.worldCommandCount) verts=\(snapshot.worldVertexCount) indices=\(snapshot.worldIndexCount)"
                    )
                    print("[Metal] world MVP \(formatMatrix(viewProjection))")
                }
            }

            if snapshot.entityCommandCount > 0,
               let entityPipelineState,
               let sceneView = Q3MetalRenderer_GetSceneView()?.pointee,
               let entityVertexBuffer = uploadEntityBuffers(device: view.device),
               let entityIndexBuffer {
                let entityViewProjection = makeWorldViewProjection(sceneView)
                var entityUniforms = EntityUniforms(viewProjection: entityViewProjection)
                encoder.setRenderPipelineState(entityPipelineState)
                encoder.setDepthStencilState(ensuredDepthStencilState(depthStencilState, device: view.device))
                encoder.setFrontFacing(.clockwise)
                encoder.setCullMode(.none)
                encoder.setVertexBuffer(entityVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&entityUniforms, length: MemoryLayout<EntityUniforms>.stride, index: 1)
                encoder.setFragmentSamplerState(worldSamplerState, index: 0)

                if let entityDrawsPointer = Q3MetalRenderer_GetEntityDrawCommands() {
                    let entityDraws = UnsafeBufferPointer(start: entityDrawsPointer, count: Int(snapshot.entityCommandCount))
                    let depthHackBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_DEPTHHACK)
                    let additiveBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ADDITIVE)
                    let alphaBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_ALPHA)
                    let filterBit = UInt32(Q3_METAL_ENTITY_DRAWFLAG_FILTER)

                    // Ordered entity passes:
                    // 0 = opaque, 1 = filter, 2 = alpha, 3 = additive.
                    for entityPass in 0..<4 {
                    for draw in entityDraws where draw.indexCount > 0 {
                        let isEntityAdditive = (draw.flags & additiveBit) != 0
                        let isEntityAlpha = (draw.flags & alphaBit) != 0
                        let isEntityFilter = (draw.flags & filterBit) != 0
                        let drawPass = isEntityAdditive ? 3 : (isEntityAlpha ? 2 : (isEntityFilter ? 1 : 0))
                        guard drawPass == entityPass else { continue }
                        guard let texture = texture(for: draw.textureHandle, device: view.device) else {
                            continue
                        }
                        let wantsDepthHack = (draw.flags & depthHackBit) != 0
                        if drawPass == 3, let entityAdditivePipelineState {
                            encoder.setRenderPipelineState(entityAdditivePipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else if drawPass == 2, let entityAlphaPipelineState {
                            encoder.setRenderPipelineState(entityAlphaPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else if drawPass == 1, let entityFilterPipelineState {
                            encoder.setRenderPipelineState(entityFilterPipelineState)
                            encoder.setDepthStencilState(ensuredDepthStencilState(additiveEntityDepthStencilState, device: view.device))
                        } else {
                            encoder.setRenderPipelineState(entityPipelineState)
                            let state = wantsDepthHack ? depthHackDepthStencilState : depthStencilState
                            encoder.setDepthStencilState(ensuredDepthStencilState(state, device: view.device))
                        }
                        encoder.setFragmentTexture(texture, index: 0)
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(draw.indexCount),
                            indexType: .uint32,
                            indexBuffer: entityIndexBuffer,
                            indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                        )
                    }
                    } // end entityPass loop
                }
            }

            let vertexCount = Int(snapshot.vertexCount)
            if vertexCount > 0, let verticesPointer = Q3MetalRenderer_GetVertices(),
               let vertexBuffer = uploadVertices(UnsafeBufferPointer(start: verticesPointer, count: vertexCount), device: view.device) {
                let vertices = UnsafeBufferPointer(start: verticesPointer, count: vertexCount)
                let projection = makeOrthoProjection(width: max(Float(snapshot.drawableWidth), 1.0), height: max(Float(snapshot.drawableHeight), 1.0))
                var uniforms = Uniforms(projection: projection)

                if let uiPipelineState {
                    encoder.setRenderPipelineState(uiPipelineState)
                }
                encoder.setDepthStencilState(ensuredDepthStencilState(nil, device: view.device))
                encoder.setFragmentSamplerState(uiSamplerState, index: 0)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

                if let drawCommandsPointer = Q3MetalRenderer_GetDrawCommands() {
                    let drawCommands = UnsafeBufferPointer(start: drawCommandsPointer, count: Int(snapshot.commandCount))
                    for draw in drawCommands {
                        if let texture = texture(for: draw.textureHandle, device: view.device) {
                            encoder.setFragmentTexture(texture, index: 0)
                            encoder.drawPrimitives(type: .triangle, vertexStart: Int(draw.firstVertex), vertexCount: Int(draw.vertexCount))
                        }
                    }
                }
            }

            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        @MainActor
        private func configureRenderer(for view: MTKView) {
            guard let device = view.device else { return }

            commandQueue = device.makeCommandQueue()

            let library: MTLLibrary
            do {
                library = try device.makeLibrary(source: shaderSource, options: nil)
            } catch {
                print("[Metal] Failed to compile UI shaders: \\(error)")
                return
            }

            let pipelineDescriptor = MTLRenderPipelineDescriptor()
            pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            pipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_ui_vertex")
            pipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_ui_fragment")
            pipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            pipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

            do {
                uiPipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                print("[Metal] Failed to create UI pipeline: \\(error)")
            }

            let worldPipelineDescriptor = MTLRenderPipelineDescriptor()
            worldPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            worldPipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            worldPipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_world_vertex")
            worldPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_world_fragment")

            do {
                worldPipelineState = try device.makeRenderPipelineState(descriptor: worldPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create world pipeline: \\(error)")
            }

            let worldFilterPipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldFilterPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            worldFilterPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            worldFilterPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            worldFilterPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            worldFilterPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            worldFilterPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .zero
            worldFilterPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .zero
            do {
                worldFilterPipelineState = try device.makeRenderPipelineState(descriptor: worldFilterPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create filter world pipeline: \\(error)")
            }

            let worldAlphaPipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldAlphaPipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            worldAlphaPipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            worldAlphaPipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            worldAlphaPipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            worldAlphaPipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            worldAlphaPipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            worldAlphaPipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            do {
                worldAlphaPipelineState = try device.makeRenderPipelineState(descriptor: worldAlphaPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create alpha world pipeline: \\(error)")
            }

            let worldAdditivePipelineDescriptor = worldPipelineDescriptor.copy() as! MTLRenderPipelineDescriptor
            worldAdditivePipelineDescriptor.colorAttachments[0].isBlendingEnabled = true
            worldAdditivePipelineDescriptor.colorAttachments[0].rgbBlendOperation = .add
            worldAdditivePipelineDescriptor.colorAttachments[0].alphaBlendOperation = .add
            worldAdditivePipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            worldAdditivePipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            worldAdditivePipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            worldAdditivePipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .one

            do {
                worldAdditivePipelineState = try device.makeRenderPipelineState(descriptor: worldAdditivePipelineDescriptor)
            } catch {
                print("[Metal] Failed to create additive world pipeline: \\(error)")
            }

            let entityPipelineDescriptor = MTLRenderPipelineDescriptor()
            entityPipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityPipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityPipelineDescriptor.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityPipelineDescriptor.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")

            do {
                entityPipelineState = try device.makeRenderPipelineState(descriptor: entityPipelineDescriptor)
            } catch {
                print("[Metal] Failed to create entity pipeline: \\(error)")
            }

            // Additive entity pipeline (flames, health orb glow, etc.)
            let entityAdditiveDesc = MTLRenderPipelineDescriptor()
            entityAdditiveDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityAdditiveDesc.colorAttachments[0].isBlendingEnabled = true
            entityAdditiveDesc.colorAttachments[0].sourceRGBBlendFactor = .one
            entityAdditiveDesc.colorAttachments[0].destinationRGBBlendFactor = .one
            entityAdditiveDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            entityAdditiveDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
            entityAdditiveDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityAdditiveDesc.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityAdditiveDesc.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")
            do {
                entityAdditivePipelineState = try device.makeRenderPipelineState(descriptor: entityAdditiveDesc)
            } catch {
                print("[Metal] Failed to create additive entity pipeline: \\(error)")
            }

            let entityAlphaDesc = MTLRenderPipelineDescriptor()
            entityAlphaDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityAlphaDesc.colorAttachments[0].isBlendingEnabled = true
            entityAlphaDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            entityAlphaDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            entityAlphaDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            entityAlphaDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            entityAlphaDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityAlphaDesc.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityAlphaDesc.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")
            do {
                entityAlphaPipelineState = try device.makeRenderPipelineState(descriptor: entityAlphaDesc)
            } catch {
                print("[Metal] Failed to create alpha entity pipeline: \\(error)")
            }

            let entityFilterDesc = MTLRenderPipelineDescriptor()
            entityFilterDesc.colorAttachments[0].pixelFormat = view.colorPixelFormat
            entityFilterDesc.colorAttachments[0].isBlendingEnabled = true
            entityFilterDesc.colorAttachments[0].sourceRGBBlendFactor = .destinationColor
            entityFilterDesc.colorAttachments[0].destinationRGBBlendFactor = .zero
            entityFilterDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
            entityFilterDesc.colorAttachments[0].destinationAlphaBlendFactor = .zero
            entityFilterDesc.depthAttachmentPixelFormat = view.depthStencilPixelFormat
            entityFilterDesc.vertexFunction = library.makeFunction(name: "q3_entity_vertex")
            entityFilterDesc.fragmentFunction = library.makeFunction(name: "q3_entity_fragment")
            do {
                entityFilterPipelineState = try device.makeRenderPipelineState(descriptor: entityFilterDesc)
            } catch {
                print("[Metal] Failed to create filter entity pipeline: \\(error)")
            }

            // Depth state for additive entities — read but no write
            let additiveEntityDepthDesc = MTLDepthStencilDescriptor()
            additiveEntityDepthDesc.depthCompareFunction = .lessEqual
            additiveEntityDepthDesc.isDepthWriteEnabled = false
            additiveEntityDepthStencilState = device.makeDepthStencilState(descriptor: additiveEntityDepthDesc)

            let uiSamplerDescriptor = MTLSamplerDescriptor()
            uiSamplerDescriptor.minFilter = .linear
            uiSamplerDescriptor.magFilter = .linear
            uiSamplerDescriptor.sAddressMode = .clampToEdge
            uiSamplerDescriptor.tAddressMode = .clampToEdge
            uiSamplerState = device.makeSamplerState(descriptor: uiSamplerDescriptor)

            let worldSamplerDescriptor = MTLSamplerDescriptor()
            worldSamplerDescriptor.minFilter = .linear
            worldSamplerDescriptor.magFilter = .linear
            worldSamplerDescriptor.sAddressMode = .repeat
            worldSamplerDescriptor.tAddressMode = .repeat
            worldSamplerState = device.makeSamplerState(descriptor: worldSamplerDescriptor)

            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            depthDescriptor.depthCompareFunction = .lessEqual
            depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)

            let additiveDepthDescriptor = MTLDepthStencilDescriptor()
            additiveDepthDescriptor.isDepthWriteEnabled = false
            additiveDepthDescriptor.depthCompareFunction = .lessEqual
            additiveDepthStencilState = device.makeDepthStencilState(descriptor: additiveDepthDescriptor)

            // Depth-hack state for first-person viewmodel: always pass depth
            // test so the gun is never occluded by world geometry, while
            // still writing depth so model self-occlusion stays correct.
            let depthHackDescriptor = MTLDepthStencilDescriptor()
            depthHackDescriptor.isDepthWriteEnabled = true
            depthHackDescriptor.depthCompareFunction = .always
            depthHackDepthStencilState = device.makeDepthStencilState(descriptor: depthHackDescriptor)
        }

        private func uploadVertices(_ vertices: UnsafeBufferPointer<Q3MetalVertex>, device: MTLDevice?) -> MTLBuffer? {
            guard let device else { return nil }

            let requiredLength = vertices.count * MemoryLayout<GPUVertex>.stride
            if requiredLength == 0 {
                return nil
            }

            if vertexBuffer == nil || requiredLength > vertexBufferCapacity {
                let nextCapacity = max(requiredLength, max(vertexBufferCapacity * 2, 4096))
                vertexBuffer = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                vertexBufferCapacity = nextCapacity
            }

            guard let vertexBuffer, let rawPointer = vertexBuffer.contents().bindMemory(to: GPUVertex.self, capacity: vertices.count) as UnsafeMutablePointer<GPUVertex>? else {
                return nil
            }

            for i in 0..<vertices.count {
                let vertex = vertices[i]
                rawPointer[i] = GPUVertex(
                    position: SIMD2<Float>(vertex.position.0, vertex.position.1),
                    texCoord: SIMD2<Float>(vertex.texCoord.0, vertex.texCoord.1),
                    color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3)
                )
            }

            return vertexBuffer
        }

        private func uploadWorldBuffers(device: MTLDevice?, generation: UInt32) -> MTLBuffer? {
            guard let device,
                  let verticesPointer = Q3MetalRenderer_GetWorldVertices(),
                  let indicesPointer = Q3MetalRenderer_GetWorldIndices(),
                  let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee
            else { return nil }

            if cachedWorldGeneration == generation, let worldVertexBuffer {
                return worldVertexBuffer
            }

            let vertexCount = Int(snapshot.worldVertexCount)
            let indexCount = Int(snapshot.worldIndexCount)
            guard vertexCount > 0, indexCount > 0 else { return nil }

            let sourceVertices = UnsafeBufferPointer(start: verticesPointer, count: vertexCount)
            var gpuVertices = [GPUWorldVertex]()
            gpuVertices.reserveCapacity(vertexCount)
            for vertex in sourceVertices {
                    gpuVertices.append(
                        GPUWorldVertex(
                            position: SIMD3<Float>(vertex.position.0, vertex.position.1, vertex.position.2),
                            texCoord: SIMD2<Float>(vertex.texCoord.0, vertex.texCoord.1),
                            lightmapTexCoord: SIMD2<Float>(vertex.lightmapTexCoord.0, vertex.lightmapTexCoord.1),
                            color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3)
                        )
                    )
                }

            let sourceIndices = UnsafeBufferPointer(start: indicesPointer, count: indexCount)
            guard let sourceIndexBase = sourceIndices.baseAddress else {
                return nil
            }
            worldVertexBuffer = device.makeBuffer(
                bytes: gpuVertices,
                length: gpuVertices.count * MemoryLayout<GPUWorldVertex>.stride,
                options: .storageModeShared
            )
            worldIndexBuffer = device.makeBuffer(
                bytes: sourceIndexBase,
                length: sourceIndices.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            )
            cachedWorldGeneration = generation
            return worldVertexBuffer
        }

        private func uploadEntityBuffers(device: MTLDevice?) -> MTLBuffer? {
            guard let device,
                  let snapshot = Q3MetalRenderer_GetFrameSnapshot()?.pointee,
                  let verticesPointer = Q3MetalRenderer_GetEntityVertices(),
                  let indicesPointer = Q3MetalRenderer_GetEntityIndices()
            else { return nil }

            let vertexCount = Int(snapshot.entityVertexCount)
            let indexCount = Int(snapshot.entityIndexCount)
            guard vertexCount > 0, indexCount > 0 else { return nil }

            let vertexLength = vertexCount * MemoryLayout<GPUEntityVertex>.stride
            if entityVertexBuffer == nil || vertexLength > entityVertexBufferCapacity {
                let nextCapacity = max(vertexLength, max(entityVertexBufferCapacity * 2, 4096))
                entityVertexBuffer = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                entityVertexBufferCapacity = nextCapacity
            }

            guard let entityVertexBuffer,
                  let rawVertexPointer = entityVertexBuffer.contents().bindMemory(to: GPUEntityVertex.self, capacity: vertexCount) as UnsafeMutablePointer<GPUEntityVertex>?
            else {
                return nil
            }

            let sourceVertices = UnsafeBufferPointer(start: verticesPointer, count: vertexCount)
            for i in 0..<vertexCount {
                let vertex = sourceVertices[i]
                rawVertexPointer[i] = GPUEntityVertex(
                    position: SIMD3<Float>(vertex.position.0, vertex.position.1, vertex.position.2),
                    texCoord: SIMD2<Float>(vertex.texCoord.0, vertex.texCoord.1),
                    color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3)
                )
            }

            let indexLength = indexCount * MemoryLayout<UInt32>.stride
            if entityIndexBuffer == nil || indexLength > entityIndexBufferCapacity {
                let nextCapacity = max(indexLength, max(entityIndexBufferCapacity * 2, 4096))
                entityIndexBuffer = device.makeBuffer(length: nextCapacity, options: .storageModeShared)
                entityIndexBufferCapacity = nextCapacity
            }

            guard let entityIndexBuffer,
                  let rawIndexPointer = entityIndexBuffer.contents().bindMemory(to: UInt32.self, capacity: indexCount) as UnsafeMutablePointer<UInt32>?
            else {
                return nil
            }

            let sourceIndices = UnsafeBufferPointer(start: indicesPointer, count: indexCount)
            for i in 0..<indexCount {
                rawIndexPointer[i] = sourceIndices[i]
            }

            return entityVertexBuffer
        }

        private func texture(for handle: UInt32, device: MTLDevice?) -> MTLTexture? {
            guard let device else { return nil }

            var info = Q3MetalTextureInfo()
            guard Q3MetalRenderer_GetTextureInfo(handle, &info) != 0,
                  let rgbaBytes = info.rgbaBytes
            else {
                return nil
            }

            guard info.width > 0, info.height > 0 else {
                return nil
            }

            if let cached = textureCache[handle], cached.generation == info.generation {
                return cached.texture
            }

            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,
                width: Int(info.width),
                height: Int(info.height),
                mipmapped: false
            )
            descriptor.usage = .shaderRead

            guard let texture = device.makeTexture(descriptor: descriptor) else {
                return nil
            }

            let bytesPerRow = Int(info.width) * 4
            texture.replace(
                region: MTLRegionMake2D(0, 0, Int(info.width), Int(info.height)),
                mipmapLevel: 0,
                withBytes: rgbaBytes,
                bytesPerRow: bytesPerRow
            )

            textureCache[handle] = (generation: info.generation, texture: texture)
            return texture
        }

        private func makeOrthoProjection(width: Float, height: Float) -> simd_float4x4 {
            simd_float4x4(columns: (
                SIMD4<Float>(2.0 / width, 0, 0, 0),
                SIMD4<Float>(0, -2.0 / height, 0, 0),
                SIMD4<Float>(0, 0, 1, 0),
                SIMD4<Float>(-1, 1, 0, 1)
            ))
        }

        private func makeWorldViewProjection(_ sceneView: Q3MetalSceneView) -> simd_float4x4 {
            let origin = SIMD3<Float>(sceneView.viewOrigin.0, sceneView.viewOrigin.1, sceneView.viewOrigin.2)
            let axis0 = SIMD3<Float>(sceneView.viewAxis.0, sceneView.viewAxis.1, sceneView.viewAxis.2)
            let axis1 = SIMD3<Float>(sceneView.viewAxis.3, sceneView.viewAxis.4, sceneView.viewAxis.5)
            let axis2 = SIMD3<Float>(sceneView.viewAxis.6, sceneView.viewAxis.7, sceneView.viewAxis.8)

            let viewer = simd_float4x4(columns: (
                SIMD4<Float>(axis0.x, axis1.x, axis2.x, 0),
                SIMD4<Float>(axis0.y, axis1.y, axis2.y, 0),
                SIMD4<Float>(axis0.z, axis1.z, axis2.z, 0),
                SIMD4<Float>(-simd_dot(origin, axis0), -simd_dot(origin, axis1), -simd_dot(origin, axis2), 1)
            ))

            let flip = simd_float4x4(columns: (
                SIMD4<Float>(0, 0, -1, 0),
                SIMD4<Float>(-1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 0, 1)
            ))

            let zNear: Float = 4.0
            let zFar: Float = 8192.0
            let xScale = 1.0 / tan(sceneView.fovX * .pi / 360.0)
            let yScale = 1.0 / tan(sceneView.fovY * .pi / 360.0)
            let depth = zFar - zNear
            let quakeProjection = simd_float4x4(columns: (
                SIMD4<Float>(xScale, 0, 0, 0),
                SIMD4<Float>(0, yScale, 0, 0),
                SIMD4<Float>(0, 0, -(zFar + zNear) / depth, -1),
                SIMD4<Float>(0, 0, -(2 * zFar * zNear) / depth, 0)
            ))

            // Quake's legacy projection targets OpenGL clip space. Metal keeps the
            // same XY clip rules but uses a 0...1 depth range instead of -1...1.
            let openGLToMetalClip = simd_float4x4(columns: (
                SIMD4<Float>(1, 0, 0, 0),
                SIMD4<Float>(0, 1, 0, 0),
                SIMD4<Float>(0, 0, 0.5, 0),
                SIMD4<Float>(0, 0, 0.5, 1)
            ))

            return openGLToMetalClip * quakeProjection * flip * viewer
        }

        private func formatVector(_ vector: SIMD3<Float>) -> String {
            String(format: "(%.3f, %.3f, %.3f)", vector.x, vector.y, vector.z)
        }

        private func formatMatrix(_ matrix: simd_float4x4) -> String {
            let c0 = matrix.columns.0
            let c1 = matrix.columns.1
            let c2 = matrix.columns.2
            let c3 = matrix.columns.3
            return String(
                format: "[[%.3f, %.3f, %.3f, %.3f], [%.3f, %.3f, %.3f, %.3f], [%.3f, %.3f, %.3f, %.3f], [%.3f, %.3f, %.3f, %.3f]]",
                c0.x, c0.y, c0.z, c0.w,
                c1.x, c1.y, c1.z, c1.w,
                c2.x, c2.y, c2.z, c2.w,
                c3.x, c3.y, c3.z, c3.w
            )
        }
    }
}

@MainActor
final class GameControllerBridge {
    static let shared = GameControllerBridge()

    private struct State {
        var leftX: Float = 0
        var leftY: Float = 0
        var rightX: Float = 0
        var rightY: Float = 0
        var firePressed: Int32 = 0
        var jumpPressed: Int32 = 0
        var crouchPressed: Int32 = 0
        var buttonMask: UInt32 = 0
    }

    /* Mirror of code/ios/ios_local.h Q3_PAD_* bits. */
    private struct PadBit {
        static let a:              UInt32 = 1 << 0
        static let b:              UInt32 = 1 << 1
        static let x:              UInt32 = 1 << 2
        static let y:              UInt32 = 1 << 3
        static let leftShoulder:   UInt32 = 1 << 4
        static let rightShoulder:  UInt32 = 1 << 5
        static let leftTrigger:    UInt32 = 1 << 6
        static let rightTrigger:   UInt32 = 1 << 7
        static let dpadUp:         UInt32 = 1 << 8
        static let dpadDown:       UInt32 = 1 << 9
        static let dpadLeft:       UInt32 = 1 << 10
        static let dpadRight:      UInt32 = 1 << 11
        static let menu:           UInt32 = 1 << 12
        static let options:        UInt32 = 1 << 13
        static let leftThumb:      UInt32 = 1 << 14
        static let rightThumb:     UInt32 = 1 << 15
    }

    private var started = false
    private var activeController: GCController?
    private var state = State()
    private var lastLoggedState: State?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        print("[GCController] start")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidConnect(_:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(controllerDidDisconnect(_:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )

        print("[GCController] existing controllers: \(GCController.controllers().count)")
        for controller in GCController.controllers() {
            print("[GCController] existing \(describe(controller))")
        }

        GCController.startWirelessControllerDiscovery { [weak self] in
            print("[GCController] wireless discovery completed")
            Task { @MainActor in
                self?.pickActiveController()
            }
        }
        pickActiveController()
    }

    @objc private func controllerDidConnect(_ notification: Notification) {
        if let controller = notification.object as? GCController {
            print("[GCController] connected \(describe(controller))")
        } else {
            print("[GCController] connected unknown controller")
        }
        pickActiveController(preferred: notification.object as? GCController)
    }

    @objc private func controllerDidDisconnect(_ notification: Notification) {
        let disconnected = notification.object as? GCController
        if activeController === disconnected {
            activeController = nil
            state = State()
            lastLoggedState = nil
            pushState()
        }
        if let disconnected {
            print("[GCController] disconnected \(describe(disconnected))")
        } else {
            print("[GCController] disconnected unknown controller")
        }
        pickActiveController()
    }

    private func pickActiveController(preferred: GCController? = nil) {
        let nextController = [preferred, activeController]
            .compactMap { $0 }
            .first { $0.extendedGamepad != nil }
            ?? GCController.controllers().first { $0.extendedGamepad != nil }

        guard activeController !== nextController else {
            return
        }

        activeController?.extendedGamepad?.valueChangedHandler = nil
        activeController = nextController
        state = State()
        lastLoggedState = nil
        pushState()

        guard let controller = nextController, let gamepad = controller.extendedGamepad else {
            print("[GCController] no extended gamepad controller selected")
            return
        }

        controller.playerIndex = .index1
        controller.handlerQueue = .main
        gamepad.valueChangedHandler = { [weak self] gamepad, element in
            self?.ingest(gamepad: gamepad, source: element)
        }
        ingest(gamepad: gamepad, source: nil)
        print("[GCController] using \(describe(controller))")
    }

    private func ingest(gamepad: GCExtendedGamepad, source: GCControllerElement?) {
        state.leftX = gamepad.leftThumbstick.xAxis.value
        state.leftY = gamepad.leftThumbstick.yAxis.value
        state.rightX = gamepad.rightThumbstick.xAxis.value
        state.rightY = gamepad.rightThumbstick.yAxis.value
        state.firePressed = gamepad.rightTrigger.isPressed ? 1 : 0
        state.jumpPressed = gamepad.buttonA.isPressed ? 1 : 0
        state.crouchPressed = gamepad.buttonB.isPressed ? 1 : 0

        var mask: UInt32 = 0
        if gamepad.buttonA.isPressed             { mask |= PadBit.a }
        if gamepad.buttonB.isPressed             { mask |= PadBit.b }
        if gamepad.buttonX.isPressed             { mask |= PadBit.x }
        if gamepad.buttonY.isPressed             { mask |= PadBit.y }
        if gamepad.leftShoulder.isPressed        { mask |= PadBit.leftShoulder }
        if gamepad.rightShoulder.isPressed       { mask |= PadBit.rightShoulder }
        if gamepad.leftTrigger.isPressed         { mask |= PadBit.leftTrigger }
        if gamepad.rightTrigger.isPressed        { mask |= PadBit.rightTrigger }
        if gamepad.dpad.up.isPressed             { mask |= PadBit.dpadUp }
        if gamepad.dpad.down.isPressed           { mask |= PadBit.dpadDown }
        if gamepad.dpad.left.isPressed           { mask |= PadBit.dpadLeft }
        if gamepad.dpad.right.isPressed          { mask |= PadBit.dpadRight }
        if gamepad.buttonMenu.isPressed          { mask |= PadBit.menu }
        if gamepad.buttonOptions?.isPressed == true { mask |= PadBit.options }
        if gamepad.leftThumbstickButton?.isPressed == true  { mask |= PadBit.leftThumb }
        if gamepad.rightThumbstickButton?.isPressed == true { mask |= PadBit.rightThumb }
        state.buttonMask = mask

        logStateChange(source: source)
        pushState()
    }

    private func pushState() {
        // Feed the engine continuously from the latest controller sample.
        Q3Gamepad_SetState(
            state.leftX,
            state.leftY,
            state.rightX,
            state.rightY,
            state.firePressed,
            state.jumpPressed,
            state.crouchPressed
        )
        Q3Gamepad_SetButtons(state.buttonMask)
    }

    private func logStateChange(source: GCControllerElement?) {
        let shouldLog: Bool
        if let lastLoggedState {
            shouldLog =
                abs(state.leftX - lastLoggedState.leftX) >= 0.05 ||
                abs(state.leftY - lastLoggedState.leftY) >= 0.05 ||
                abs(state.rightX - lastLoggedState.rightX) >= 0.05 ||
                abs(state.rightY - lastLoggedState.rightY) >= 0.05 ||
                state.firePressed != lastLoggedState.firePressed ||
                state.jumpPressed != lastLoggedState.jumpPressed ||
                state.crouchPressed != lastLoggedState.crouchPressed ||
                state.buttonMask != lastLoggedState.buttonMask
        } else {
            shouldLog = true
        }

        guard shouldLog else { return }
        lastLoggedState = state

        let sourceName = source.map { String(describing: type(of: $0)) } ?? "initial"
        let maskHex = String(format: "0x%04X", state.buttonMask)
        var btns: [String] = []
        if state.buttonMask & PadBit.a != 0             { btns.append("A") }
        if state.buttonMask & PadBit.b != 0             { btns.append("B") }
        if state.buttonMask & PadBit.x != 0             { btns.append("X") }
        if state.buttonMask & PadBit.y != 0             { btns.append("Y") }
        if state.buttonMask & PadBit.leftShoulder != 0  { btns.append("LB") }
        if state.buttonMask & PadBit.rightShoulder != 0 { btns.append("RB") }
        if state.buttonMask & PadBit.leftTrigger != 0   { btns.append("LT") }
        if state.buttonMask & PadBit.rightTrigger != 0  { btns.append("RT") }
        if state.buttonMask & PadBit.dpadUp != 0        { btns.append("dU") }
        if state.buttonMask & PadBit.dpadDown != 0      { btns.append("dD") }
        if state.buttonMask & PadBit.dpadLeft != 0      { btns.append("dL") }
        if state.buttonMask & PadBit.dpadRight != 0     { btns.append("dR") }
        if state.buttonMask & PadBit.menu != 0          { btns.append("MENU") }
        if state.buttonMask & PadBit.options != 0       { btns.append("OPT") }
        if state.buttonMask & PadBit.leftThumb != 0     { btns.append("L3") }
        if state.buttonMask & PadBit.rightThumb != 0    { btns.append("R3") }
        let btnStr = btns.isEmpty ? "-" : btns.joined(separator: "+")
        print(
            String(
                format: "[GCController] input %@ left=(%.2f, %.2f) right=(%.2f, %.2f) fire=%d jump=%d crouch=%d buttons=%@ mask=%@",
                sourceName,
                state.leftX,
                state.leftY,
                state.rightX,
                state.rightY,
                state.firePressed,
                state.jumpPressed,
                state.crouchPressed,
                btnStr,
                maskHex
            )
        )
    }

    private func describe(_ controller: GCController) -> String {
        let name = controller.vendorName ?? "Unknown"
        let profile = controller.extendedGamepad != nil ? "extended" : "non-extended"
        return "\(name) profile=\(profile)"
    }
}
