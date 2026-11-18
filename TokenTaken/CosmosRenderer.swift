import AppKit
import Metal
import MetalKit
import QuartzCore
import simd

private struct CosmosFloat5 {
    var v0: Float = 0, v1: Float = 0, v2: Float = 0, v3: Float = 0, v4: Float = 0

    init(_ values: [Double]) {
        v0 = Float(values.indices.contains(0) ? values[0] : 0)
        v1 = Float(values.indices.contains(1) ? values[1] : 0)
        v2 = Float(values.indices.contains(2) ? values[2] : 0)
        v3 = Float(values.indices.contains(3) ? values[3] : 0)
        v4 = Float(values.indices.contains(4) ? values[4] : 0)
    }
}

private struct CosmosFloat6 {
    var v0: Float = 0, v1: Float = 0, v2: Float = 0, v3: Float = 0, v4: Float = 0, v5: Float = 0

    init(_ values: [Float]) {
        v0 = values.indices.contains(0) ? values[0] : 0
        v1 = values.indices.contains(1) ? values[1] : 0
        v2 = values.indices.contains(2) ? values[2] : 0
        v3 = values.indices.contains(3) ? values[3] : 0
        v4 = values.indices.contains(4) ? values[4] : 0
        v5 = values.indices.contains(5) ? values[5] : 0
    }
}

private struct CosmosVector6 {
    var v0 = SIMD3<Float>(), v1 = SIMD3<Float>(), v2 = SIMD3<Float>()
    var v3 = SIMD3<Float>(), v4 = SIMD3<Float>(), v5 = SIMD3<Float>()

    init(_ values: [SIMD3<Float>]) {
        if values.indices.contains(0) { v0 = values[0] }
        if values.indices.contains(1) { v1 = values[1] }
        if values.indices.contains(2) { v2 = values[2] }
        if values.indices.contains(3) { v3 = values[3] }
        if values.indices.contains(4) { v4 = values[4] }
        if values.indices.contains(5) { v5 = values[5] }
    }
}

private struct CosmosSceneUniforms {
    var size = SIMD2<Float>()
    var center = SIMD2<Float>()
    var cam = SIMD3<Float>()
    var fw = SIMD3<Float>()
    var rt = SIMD3<Float>()
    var up = SIMD3<Float>()
    var time: Float = 0
    var clock: Float = 0
    var reveal: Float = 1
    var disk: Float = 0
    var focal: Float = 900
    var hover: Int32 = -1
    var bodyCount: Int32 = 0
    var edges = CosmosFloat5([])
    var bodyPosition = CosmosVector6([])
    var bodyRadius = CosmosFloat6([])
    var bodyKind = CosmosFloat6([])
    var bodySeed = CosmosFloat6([])
    var bodySpin = CosmosFloat6([])
    var bodyTilt = CosmosFloat6([])
    var bodyRing = CosmosFloat6([])
}

private struct CosmosParticleUniforms {
    var size = SIMD2<Float>()
    var center = SIMD2<Float>()
    var cam = SIMD3<Float>()
    var fw = SIMD3<Float>()
    var rt = SIMD3<Float>()
    var up = SIMD3<Float>()
    var time: Float = 0
    var disk: Float = 0
    var dust: Float = 0
    var pixel: Float = 1
    var points: Float = 0
    var shadow: Float = 0
    var edges = CosmosFloat5([])
    var focal: Float = 0
}

final class CosmosRenderer {
    private static let particleCount = 8_000
    private static let maximumDustCount = 420
    private static let shadow = 2.598 * 0.34
    private static let cameraDistance = sqrt(3.18 * 3.18 + 14.65 * 14.65)

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let scenePipeline: MTLRenderPipelineState
    private let particlePipeline: MTLRenderPipelineState
    private let blitPipeline: MTLRenderPipelineState
    private let flowBuffer: MTLBuffer
    private let dustBuffer: MTLBuffer
    private let flowSeeds: [Float]

    private var cachedTexture: MTLTexture?
    private var cachedFlowShares: [Double]?
    private var renderScale: CGFloat = 1.5
    private var frameAverage = 16.0
    private var frameCount = 0
    private var firstDrawTime: CFTimeInterval?
    private var lastDrawTime: CFTimeInterval?

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let sceneVertex = library.makeFunction(name: "cosmosSceneVertex"),
              let sceneFragment = library.makeFunction(name: "cosmosSceneFragment"),
              let particleVertex = library.makeFunction(name: "cosmosParticleVertex"),
              let particleFragment = library.makeFunction(name: "cosmosParticleFragment"),
              let blitFragment = library.makeFunction(name: "cosmosBlitFragment"),
              let flowBuffer = device.makeBuffer(
                length: Self.particleCount * 2 * 6 * MemoryLayout<Float>.stride,
                options: .storageModeShared
              ),
              let dustBuffer = device.makeBuffer(
                length: Self.maximumDustCount * 6 * MemoryLayout<Float>.stride,
                options: .storageModeShared
              )
        else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.flowBuffer = flowBuffer
        self.dustBuffer = dustBuffer

        do {
            let sceneDescriptor = MTLRenderPipelineDescriptor()
            sceneDescriptor.label = "Cosmos scene"
            sceneDescriptor.vertexFunction = sceneVertex
            sceneDescriptor.fragmentFunction = sceneFragment
            sceneDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            scenePipeline = try device.makeRenderPipelineState(descriptor: sceneDescriptor)

            let vertexDescriptor = MTLVertexDescriptor()
            vertexDescriptor.attributes[0].format = .float4
            vertexDescriptor.attributes[0].offset = 0
            vertexDescriptor.attributes[0].bufferIndex = 0
            vertexDescriptor.attributes[1].format = .float2
            vertexDescriptor.attributes[1].offset = 16
            vertexDescriptor.attributes[1].bufferIndex = 0
            vertexDescriptor.layouts[0].stride = 24
            vertexDescriptor.layouts[0].stepRate = 1
            vertexDescriptor.layouts[0].stepFunction = .perVertex

            let particleDescriptor = MTLRenderPipelineDescriptor()
            particleDescriptor.label = "Cosmos particles"
            particleDescriptor.vertexFunction = particleVertex
            particleDescriptor.fragmentFunction = particleFragment
            particleDescriptor.vertexDescriptor = vertexDescriptor
            particleDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            let attachment = particleDescriptor.colorAttachments[0]!
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .one
            particlePipeline = try device.makeRenderPipelineState(descriptor: particleDescriptor)

            let blitDescriptor = MTLRenderPipelineDescriptor()
            blitDescriptor.label = "Cosmos upscale"
            blitDescriptor.vertexFunction = sceneVertex
            blitDescriptor.fragmentFunction = blitFragment
            blitDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            blitPipeline = try device.makeRenderPipelineState(descriptor: blitDescriptor)
        } catch {
            return nil
        }

        var seed = UInt32(83_021)
        var seeds: [Float] = []
        seeds.reserveCapacity(Self.particleCount * 4)
        for _ in 0..<(Self.particleCount * 4) {
            seeds.append(Self.nextRandom(&seed))
        }
        flowSeeds = seeds

        seed = 9_127
        dustBuffer.contents().withMemoryRebound(to: Float.self, capacity: Self.maximumDustCount * 6) { output in
            for index in 0..<Self.maximumDustCount {
                let offset = index * 6
                output[offset] = Self.nextRandom(&seed)
                output[offset + 1] = Self.nextRandom(&seed) * Float(2 * Double.pi)
                output[offset + 2] = Self.nextRandom(&seed) + Self.nextRandom(&seed) - 1
                output[offset + 3] = Self.nextRandom(&seed)
                output[offset + 4] = 5
                output[offset + 5] = 0
            }
        }
    }

    func draw(_ frame: CosmosFrame, to renderPassDescriptor: MTLRenderPassDescriptor, drawable: MTLDrawable, drawableSize: CGSize) {
        guard frame.size.width > 0, frame.size.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else { return }
        updateAdaptiveQuality(frame: frame, drawableSize: drawableSize)
        let pixelSize = CGSize(
            width: max(1, (frame.size.width * renderScale).rounded()),
            height: max(1, (frame.size.height * renderScale).rounded())
        )
        guard let texture = sceneTexture(pixelSize: pixelSize),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "Cosmos frame"
        encodeScene(frame, into: texture, pixelSize: pixelSize, commandBuffer: commandBuffer)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
        encoder.label = "Cosmos upscale"
        encoder.setRenderPipelineState(blitPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func snapshot(_ frame: CosmosFrame, pixelSize: CGSize) -> CGImage? {
        guard frame.size.width > 0, frame.size.height > 0,
              pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let width = max(1, Int(pixelSize.width.rounded())), height = max(1, Int(pixelSize.height.rounded()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return nil }
        commandBuffer.label = "Cosmos snapshot"
        encodeScene(
            frame,
            into: texture,
            pixelSize: CGSize(width: CGFloat(width), height: CGFloat(height)),
            commandBuffer: commandBuffer
        )
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        let bytesPerRow = width * 4
        var bytes = Data(count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { output in
            texture.getBytes(
                output.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0
            )
        }
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }

    private static func nextRandom(_ seed: inout UInt32) -> Float {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        return Float(seed) / 4_294_967_296.0
    }

    private func updateAdaptiveQuality(frame: CosmosFrame, drawableSize: CGSize) {
        let now = CACurrentMediaTime()
        let backingScale = max(0.75, drawableSize.width / frame.size.width)
        let cap = min(1.5, backingScale)
        renderScale = min(renderScale, cap)
        if firstDrawTime == nil { firstDrawTime = now }
        defer {
            lastDrawTime = now
            frameCount += 1
        }
        guard let lastDrawTime else { return }
        let elapsed = now - lastDrawTime
        guard elapsed <= 0.25 else {
            frameAverage = 16
            frameCount = 0
            return
        }
        guard frameCount > 75, let firstDrawTime, now - firstDrawTime > 1.8 else { return }
        frameAverage += (elapsed * 1_000 - frameAverage) * 0.04
        if frameAverage > 20, renderScale > 0.75 {
            renderScale = max(min(0.75, cap), renderScale - 0.25)
            cachedTexture = nil
            frameAverage = 16
            frameCount = 0
        }
    }

    private func sceneTexture(pixelSize: CGSize) -> MTLTexture? {
        let width = Int(pixelSize.width), height = Int(pixelSize.height)
        if let cachedTexture, cachedTexture.width == width, cachedTexture.height == height {
            return cachedTexture
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        cachedTexture = device.makeTexture(descriptor: descriptor)
        return cachedTexture
    }

    private func encodeScene(
        _ frame: CosmosFrame,
        into texture: MTLTexture,
        pixelSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) {
        updateFlowParticles(shares: frame.scene.particleShares)
        var sceneUniforms = makeSceneUniforms(frame)
        var particleUniforms = makeParticleUniforms(frame, pixelSize: pixelSize)
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.label = "Cosmos scene and particles"
        encoder.setRenderPipelineState(scenePipeline)
        encoder.setFragmentBytes(&sceneUniforms, length: MemoryLayout<CosmosSceneUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setRenderPipelineState(particlePipeline)
        encoder.setVertexBytes(&particleUniforms, length: MemoryLayout<CosmosParticleUniforms>.stride, index: 1)
        encoder.setFragmentBytes(&particleUniforms, length: MemoryLayout<CosmosParticleUniforms>.stride, index: 0)
        if frame.disk > 0 {
            encoder.setVertexBuffer(flowBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: Self.particleCount * 2)
        }
        if frame.scene.dustCount > 0 {
            particleUniforms.dust = 1
            particleUniforms.points = 1
            encoder.setVertexBytes(&particleUniforms, length: MemoryLayout<CosmosParticleUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&particleUniforms, length: MemoryLayout<CosmosParticleUniforms>.stride, index: 0)
            encoder.setVertexBuffer(dustBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: frame.scene.dustCount)
        }
        encoder.endEncoding()
    }

    private func updateFlowParticles(shares: [Double]) {
        guard cachedFlowShares != shares else { return }
        cachedFlowShares = shares
        flowBuffer.contents().withMemoryRebound(to: Float.self, capacity: Self.particleCount * 2 * 6) { output in
            for index in 0..<Self.particleCount {
                let quantile = (Double(index) + 0.5) / Double(Self.particleCount)
                var band = 0
                var accumulated = 0.0
                while band < 4 {
                    accumulated += shares.indices.contains(band) ? shares[band] : 0
                    if quantile < accumulated { break }
                    band += 1
                }
                for tail in 0..<2 {
                    let outputOffset = (index * 2 + tail) * 6
                    let seedOffset = index * 4
                    output[outputOffset] = flowSeeds[seedOffset]
                    output[outputOffset + 1] = flowSeeds[seedOffset + 1]
                    output[outputOffset + 2] = flowSeeds[seedOffset + 2]
                    output[outputOffset + 3] = flowSeeds[seedOffset + 3]
                    output[outputOffset + 4] = Float(band)
                    output[outputOffset + 5] = Float(tail)
                }
            }
        }
    }

    private func makeSceneUniforms(_ frame: CosmosFrame) -> CosmosSceneUniforms {
        var uniforms = CosmosSceneUniforms()
        uniforms.size = SIMD2(Float(frame.size.width), Float(frame.size.height))
        uniforms.center = SIMD2(Float(frame.center.x), Float(frame.center.y))
        uniforms.cam = frame.camera.position.float
        uniforms.fw = frame.camera.forward.float
        uniforms.rt = frame.camera.right.float
        uniforms.up = frame.camera.up.float
        uniforms.time = Float(frame.time)
        uniforms.clock = Float(frame.clock)
        uniforms.reveal = Float(frame.reveal)
        uniforms.disk = Float(frame.disk)
        uniforms.focal = Float(frame.focal)
        uniforms.hover = Int32(frame.hoverCategory)
        uniforms.bodyCount = Int32(frame.scene.bodies.count)
        uniforms.edges = CosmosFloat5(frame.scene.categories.map(\.edge))

        var positions: [SIMD3<Float>] = []
        var radii: [Float] = [], kinds: [Float] = [], seeds: [Float] = []
        var spins: [Float] = [], tilts: [Float] = [], rings: [Float] = []
        for body in frame.scene.bodies {
            guard let placement = frame.placements.first(where: { $0.id == body.id }) else { continue }
            positions.append(placement.world.float)
            radii.append(Float(placement.radius))
            kinds.append(Float(body.kind))
            seeds.append(Float(body.seed % 10_000) / 100)
            spins.append(Float(body.seed % 256) + Float(frame.time) * 0.42)
            tilts.append(Float(body.tilt))
            rings.append(body.kind == 3 ? 1 : 0)
        }
        uniforms.bodyPosition = CosmosVector6(positions)
        uniforms.bodyRadius = CosmosFloat6(radii)
        uniforms.bodyKind = CosmosFloat6(kinds)
        uniforms.bodySeed = CosmosFloat6(seeds)
        uniforms.bodySpin = CosmosFloat6(spins)
        uniforms.bodyTilt = CosmosFloat6(tilts)
        uniforms.bodyRing = CosmosFloat6(rings)
        return uniforms
    }

    private func makeParticleUniforms(_ frame: CosmosFrame, pixelSize: CGSize) -> CosmosParticleUniforms {
        var uniforms = CosmosParticleUniforms()
        uniforms.size = SIMD2(Float(frame.size.width), Float(frame.size.height))
        uniforms.center = SIMD2(Float(frame.center.x), Float(frame.center.y))
        uniforms.cam = frame.camera.position.float
        uniforms.fw = frame.camera.forward.float
        uniforms.rt = frame.camera.right.float
        uniforms.up = frame.camera.up.float
        uniforms.time = Float(frame.time)
        uniforms.disk = Float(frame.disk)
        uniforms.dust = frame.scene.dustCount > 0 ? 1 : 0
        uniforms.pixel = Float(pixelSize.width / frame.size.width)
        uniforms.points = 0
        uniforms.shadow = Float(Self.shadow * frame.focal / Self.cameraDistance)
        uniforms.edges = CosmosFloat5(frame.scene.categories.map(\.edge))
        uniforms.focal = Float(frame.focal)
        return uniforms
    }
}

private extension SIMD3<Double> {
    var float: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}
