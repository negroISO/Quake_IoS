import SwiftUI
import MetalKit
import simd

struct MetalView: UIViewRepresentable {
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.delegate = context.coordinator
        view.preferredFramesPerSecond = 60
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
            var color: SIMD4<Float>
        }

        struct WorldUniforms {
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
            float4 color;
        };

        struct WorldUniforms {
            float4x4 viewProjection;
        };

        struct WorldVertexOut {
            float4 position [[position]];
            float4 color;
        };

        vertex WorldVertexOut q3_world_vertex(const device WorldVertexIn *vertices [[buffer(0)]],
                                              constant WorldUniforms &uniforms [[buffer(1)]],
                                              uint vertexID [[vertex_id]]) {
            WorldVertexOut out;
            WorldVertexIn inVertex = vertices[vertexID];
            out.position = uniforms.viewProjection * float4(inVertex.position, 1.0);
            out.color = inVertex.color;
            return out;
        }

        fragment float4 q3_world_fragment(WorldVertexOut in [[stage_in]]) {
            return in.color;
        }
        """

        private var commandQueue: MTLCommandQueue?
        private var uiPipelineState: MTLRenderPipelineState?
        private var worldPipelineState: MTLRenderPipelineState?
        private var samplerState: MTLSamplerState?
        private var depthStencilState: MTLDepthStencilState?
        private var textureCache: [UInt32: (generation: UInt32, texture: MTLTexture)] = [:]
        private var vertexBuffer: MTLBuffer?
        private var vertexBufferCapacity = 0
        private var worldVertexBuffer: MTLBuffer?
        private var worldIndexBuffer: MTLBuffer?
        private var cachedWorldGeneration: UInt32 = 0

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
                  let samplerState,
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
                var worldUniforms = WorldUniforms(
                    viewProjection: makePerspectiveProjection(
                        fovX: sceneView.fovX,
                        fovY: sceneView.fovY,
                        zNear: 4.0,
                        zFar: 8192.0
                    ) * makeWorldViewMatrix(sceneView)
                )
                encoder.setRenderPipelineState(worldPipelineState)
                encoder.setDepthStencilState(depthStencilState)
                encoder.setVertexBuffer(worldVertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&worldUniforms, length: MemoryLayout<WorldUniforms>.stride, index: 1)

                if let worldDrawsPointer = Q3MetalRenderer_GetWorldDrawCommands(),
                   let indicesPointer = Q3MetalRenderer_GetWorldIndices() {
                    let _ = indicesPointer
                    let worldDraws = UnsafeBufferPointer(start: worldDrawsPointer, count: Int(snapshot.worldCommandCount))
                    for draw in worldDraws where draw.indexCount > 0 {
                        encoder.drawIndexedPrimitives(
                            type: .triangle,
                            indexCount: Int(draw.indexCount),
                            indexType: .uint32,
                            indexBuffer: worldIndexBuffer,
                            indexBufferOffset: Int(draw.firstIndex) * MemoryLayout<UInt32>.stride
                        )
                    }
                }
            }

            let vertexCount = Int(snapshot.vertexCount)
            if vertexCount > 0, let verticesPointer = Q3MetalRenderer_GetVertices() {
                let vertices = UnsafeBufferPointer(start: verticesPointer, count: vertexCount)
                let projection = makeOrthoProjection(width: max(Float(snapshot.drawableWidth), 1.0), height: max(Float(snapshot.drawableHeight), 1.0))
                var uniforms = Uniforms(projection: projection)
                guard let vertexBuffer = uploadVertices(vertices, device: view.device) else {
                    encoder.endEncoding()
                    commandBuffer.present(drawable)
                    commandBuffer.commit()
                    return
                }

                if let uiPipelineState {
                    encoder.setRenderPipelineState(uiPipelineState)
                }
                encoder.setDepthStencilState(nil)
                encoder.setFragmentSamplerState(samplerState, index: 0)
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

            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            samplerState = device.makeSamplerState(descriptor: samplerDescriptor)

            let depthDescriptor = MTLDepthStencilDescriptor()
            depthDescriptor.isDepthWriteEnabled = true
            depthDescriptor.depthCompareFunction = .less
            depthStencilState = device.makeDepthStencilState(descriptor: depthDescriptor)
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
                        color: SIMD4<Float>(vertex.color.0, vertex.color.1, vertex.color.2, vertex.color.3)
                    )
                )
            }

            let sourceIndices = UnsafeBufferPointer(start: indicesPointer, count: indexCount)
            worldVertexBuffer = device.makeBuffer(
                bytes: gpuVertices,
                length: gpuVertices.count * MemoryLayout<GPUWorldVertex>.stride,
                options: .storageModeShared
            )
            worldIndexBuffer = device.makeBuffer(
                bytes: sourceIndices.baseAddress!,
                length: sourceIndices.count * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            )
            cachedWorldGeneration = generation
            return worldVertexBuffer
        }

        private func texture(for handle: UInt32, device: MTLDevice?) -> MTLTexture? {
            guard let device else { return nil }

            var info = Q3MetalTextureInfo()
            guard Q3MetalRenderer_GetTextureInfo(handle, &info) != 0,
                  let rgbaBytes = info.rgbaBytes
            else {
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

        private func makePerspectiveProjection(fovX: Float, fovY: Float, zNear: Float, zFar: Float) -> simd_float4x4 {
            let xScale = 1.0 / tan(fovX * .pi / 360.0)
            let yScale = 1.0 / tan(fovY * .pi / 360.0)
            let zScale = zFar / (zNear - zFar)
            let zTranslate = (zNear * zFar) / (zNear - zFar)

            return simd_float4x4(columns: (
                SIMD4<Float>(xScale, 0, 0, 0),
                SIMD4<Float>(0, yScale, 0, 0),
                SIMD4<Float>(0, 0, zScale, -1),
                SIMD4<Float>(0, 0, zTranslate, 0)
            ))
        }

        private func makeWorldViewMatrix(_ sceneView: Q3MetalSceneView) -> simd_float4x4 {
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

            return viewer * flip
        }
    }
}
