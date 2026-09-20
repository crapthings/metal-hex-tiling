import AppKit
import MetalHexTiling
import Metal
import MetalKit
import QuartzCore
import simd

let renderWidth = 1280
let renderHeight = 720

struct RenderError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private struct Uniforms {
    var viewProjection: simd_float4x4
    var camera: SIMD4<Float>
    var patch: SIMD4<Float>
    var grid: SIMD4<Int32>
}

final class Renderer {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let generator: MTLComputePipelineState
    private let depthState: MTLDepthStencilState
    private let depth: MTLTexture
    private let height: MTLTexture
    private let material: MTLTexture
    private var patchOrigin: SIMD2<Float>?
    var position = SIMD2<Float>(36, 90)
    var yaw: Float = 0
    var pitch: Float = -0.48
    private var targetYaw: Float = 0
    private var targetPitch: Float = -0.48
    // Seconds: 35 ms time constant, about 81 ms to cover 90% of a step.
    private let lookResponseTime: Float = 0.035
    var altitude: Float = 72
    var wireframe = false
    var useHexTiling = !CommandLine.arguments.contains("--plain-tiling")
    var flatTopDown = CommandLine.arguments.contains("--top-down-flat")
    var parameters = HexTilingParameters(patchScale: 3)

    var modeDescription: String {
        "\(useHexTiling ? "Hex" : "Repeat") · \(flatTopDown ? "Top view" : "Terrain") · Patch \(String(format: "%.1f", parameters.patchScale)) · Contrast \(parameters.useContrastCorrectedBlending ? "on" : "off")"
    }

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw RenderError("无法创建 Metal 设备或命令队列")
        }
        self.device = device
        self.queue = queue
        guard let url = Bundle.module.url(forResource: "Terrain", withExtension: "metal") else {
            throw RenderError("找不到地形 shader")
        }
        let terrainSource = try String(contentsOf: url, encoding: .utf8)
        let library = try HexTilingMetal.makeLibrary(device: device, appending: terrainSource)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Hex terrain pipeline"
        descriptor.vertexFunction = library.makeFunction(name: "terrainVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "terrainFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm_srgb
        descriptor.depthAttachmentPixelFormat = .depth32Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        guard let function = library.makeFunction(name: "generateHeight") else { throw RenderError("找不到高度生成 kernel") }
        generator = try device.makeComputePipelineState(function: function)
        let state = MTLDepthStencilDescriptor()
        state.depthCompareFunction = .less
        state.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: state) else { throw RenderError("无法创建深度状态") }
        self.depthState = depthState
        let depthDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float, width: renderWidth, height: renderHeight, mipmapped: false)
        depthDescriptor.storageMode = .private
        depthDescriptor.usage = .renderTarget
        let heightDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 512, height: 512, mipmapped: false)
        heightDescriptor.storageMode = .private
        heightDescriptor.usage = [.shaderRead, .shaderWrite]
        guard let materialURL = Bundle.module.url(forResource: "ground-moss-seamless", withExtension: "png") else {
            throw RenderError("找不到无缝地表纹理")
        }
        let textureLoader = MTKTextureLoader(device: device)
        let material = try textureLoader.newTexture(URL: materialURL, options: [
            .SRGB: true,
            .generateMipmaps: true,
            .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
            .textureStorageMode: NSNumber(value: MTLStorageMode.private.rawValue)
        ])
        guard let depth = device.makeTexture(descriptor: depthDescriptor),
              let height = device.makeTexture(descriptor: heightDescriptor) else {
            throw RenderError("无法创建深度或高度纹理")
        }
        self.depth = depth
        self.height = height
        self.material = material
        depth.label = "1280×720 depth"
        height.label = "512×512 world fBm height"
        material.label = "Generated seamless moss and soil albedo"
    }

    func reset() {
        position = SIMD2<Float>(36, 90)
        yaw = 0; pitch = -0.48; altitude = 72
        targetYaw = yaw; targetPitch = pitch
    }

    func dragLook(x: Float, y: Float) {
        targetYaw += x * 0.005
        // Clamp the target to avoid accumulating invisible input at the limits.
        targetPitch = min(-0.12, max(-1.3, targetPitch - y * 0.005))
    }

    func stopLook() {
        // Discard the small remaining target offset so releasing the mouse leaves
        // the camera completely stationary instead of finishing the damping tail.
        targetYaw = yaw
        targetPitch = pitch
    }

    func updateLook(deltaTime: Float) {
        // Exponential damping is independent of display refresh rate and cannot overshoot.
        let blend = 1 - exp(-max(0, deltaTime) / lookResponseTime)
        yaw += (targetYaw - yaw) * blend
        pitch += (targetPitch - pitch) * blend
        // Rebase both angles together, preserving continuity across full rotations.
        let turns = (yaw / (2 * Float.pi)).rounded(.towardZero)
        if abs(turns) >= 1 {
            let offset = turns * 2 * Float.pi
            yaw -= offset
            targetYaw -= offset
        }
    }

    private func uniforms(origin: SIMD2<Float>) -> Uniforms {
        let eye: SIMD3<Float>
        let forward: SIMD3<Float>
        let right: SIMD3<Float>
        let up: SIMD3<Float>
        if flatTopDown {
            eye = SIMD3<Float>(position.x, 180, position.y)
            forward = SIMD3<Float>(0, -1, 0)
            right = SIMD3<Float>(1, 0, 0)
            up = SIMD3<Float>(0, 0, -1)
        } else {
            eye = SIMD3<Float>(position.x, altitude, position.y)
            forward = SIMD3<Float>(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))
            right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
            up = simd_cross(right, forward)
        }
        let view = simd_float4x4(columns: (
            SIMD4<Float>(right.x, up.x, -forward.x, 0),
            SIMD4<Float>(right.y, up.y, -forward.y, 0),
            SIMD4<Float>(right.z, up.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(up, eye), simd_dot(forward, eye), 1)
        ))
        let near: Float = 0.5, far: Float = 350
        let projection: simd_float4x4
        if flatTopDown {
            let width: Float = 240
            let height = width * Float(renderHeight) / Float(renderWidth)
            projection = simd_float4x4(columns: (
                SIMD4<Float>(2 / width, 0, 0, 0),
                SIMD4<Float>(0, 2 / height, 0, 0),
                SIMD4<Float>(0, 0, 1 / (near - far), 0),
                SIMD4<Float>(0, 0, near / (near - far), 1)
            ))
        } else {
            let y: Float = 1 / tan(Float.pi / 6)
            projection = simd_float4x4(columns: (
                SIMD4<Float>(y / (Float(renderWidth) / Float(renderHeight)), 0, 0, 0),
                SIMD4<Float>(0, y, 0, 0),
                SIMD4<Float>(0, 0, far / (near - far), -1),
                SIMD4<Float>(0, 0, near * far / (near - far), 0)
            ))
        }
        return Uniforms(viewProjection: projection * view,
                        camera: SIMD4<Float>(eye, 0),
                        patch: SIMD4<Float>(origin.x, origin.y, 640, 58),
                        grid: SIMD4<Int32>(Int32(floor(position.x / (2 * sqrt(3)))) - 72,
                                           Int32(floor(position.y / 3)) - 72, 145,
                                           (useHexTiling ? 1 : 0) | (flatTopDown ? 2 : 0)))
    }

    @discardableResult
    func render(to texture: MTLTexture, drawable: CAMetalDrawable? = nil, completion: ((MTLCommandBuffer) -> Void)? = nil) throws -> MTLCommandBuffer {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0.59, green: 0.70, blue: 0.76, alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.storeAction = .dontCare
        pass.depthAttachment.clearDepth = 1
        return try render(passDescriptor: pass, drawable: drawable, completion: completion)
    }

    @discardableResult
    func render(passDescriptor pass: MTLRenderPassDescriptor, drawable: CAMetalDrawable? = nil, completion: ((MTLCommandBuffer) -> Void)? = nil) throws -> MTLCommandBuffer {
        guard let command = queue.makeCommandBuffer() else { throw RenderError("无法创建命令缓冲区") }
        command.label = "Infinite hex terrain frame"
        // Snap by an exact number of texels: sampling is stable across patch shifts.
        let origin = SIMD2<Float>(floor(position.x / 40) * 40 - 320, floor(position.y / 40) * 40 - 320)
        var u = uniforms(origin: origin)
        if patchOrigin != origin {
            guard let compute = command.makeComputeCommandEncoder() else { throw RenderError("无法创建高度生成编码器") }
            compute.label = "Noise + 6 octave fBm / 512×512"
            compute.setComputePipelineState(generator)
            compute.setTexture(height, index: 0)
            compute.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
            compute.dispatchThreads(MTLSize(width: 512, height: 512, depth: 1), threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
            compute.endEncoding()
        }
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { throw RenderError("无法创建渲染编码器") }
        encoder.label = "Perturbed hex grid / 21025 instances"
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(depthState)
        encoder.setTriangleFillMode(wireframe ? .lines : .fill)
        encoder.setCullMode(.none)
        encoder.setViewport(MTLViewport(originX: 0, originY: 0, width: Double(renderWidth), height: Double(renderHeight), znear: 0, zfar: 1))
        encoder.setVertexBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexTexture(height, index: 0)
        encoder.setFragmentTexture(material, index: 0)
        var hexArguments = parameters.shaderVector
        encoder.setFragmentBytes(&hexArguments, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 18, instanceCount: 145 * 145)
        encoder.endEncoding()
        if let drawable { command.present(drawable) }
        command.addCompletedHandler { buffer in
            if let error = buffer.error { fputs("GPU error: \(error.localizedDescription)\n", stderr) }
        }
        if let completion { command.addCompletedHandler(completion) }
        command.commit()
        patchOrigin = origin
        return command
    }

    /// Measures whole offscreen frames, not isolated texture instructions. Modes
    /// rotate between rounds to reduce bias from thermal/clock drift.
    func benchmark() throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: renderWidth, height: renderHeight, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = .renderTarget
        guard let target = device.makeTexture(descriptor: descriptor) else { throw RenderError("Cannot create benchmark target") }
        let savedHex = useHexTiling
        let savedParameters = parameters
        let savedWireframe = wireframe
        defer { useHexTiling = savedHex; parameters = savedParameters; wireframe = savedWireframe }
        parameters = HexTilingParameters(patchScale: 3)
        wireframe = false
        let names = ["repeat", "hex", "hex-contrast"]
        var timings = [[Double]](repeating: [], count: 3)
        func frame() throws -> Double {
            let command = try render(to: target)
            command.waitUntilCompleted()
            guard command.status == .completed else { throw command.error ?? RenderError("Benchmark GPU failure") }
            let ms = (command.gpuEndTime - command.gpuStartTime) * 1000
            guard ms.isFinite && ms > 0 else { throw RenderError("GPU timestamps unavailable") }
            return ms
        }
        // The first frame generates height; subsequent timed frames do not.
        for round in 0..<6 {
            for step in 0..<3 {
                let mode = (round + step) % 3
                useHexTiling = mode != 0
                parameters.useContrastCorrectedBlending = mode == 2
                for _ in 0..<20 { _ = try frame() }
                for _ in 0..<50 { timings[mode].append(try frame()) }
            }
        }
        var rows = [[String: Any]]()
        for index in 0..<3 {
            let sorted = timings[index].sorted()
            let median = (sorted[149] + sorted[150]) / 2
            rows.append(["mode": names[index], "samples": sorted.count,
                         "median_ms": median, "p95_ms": sorted[284],
                         "mean_ms": sorted.reduce(0, +) / Double(sorted.count)])
        }
        let result: [String: Any] = [
            "scope": "Whole offscreen frame; no presentation, readback, or height regeneration in timed samples",
            "gpu": device.name, "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "view": flatTopDown ? "top-down-flat" : "terrain", "resolution": [renderWidth, renderHeight],
            "texture_size": [material.width, material.height], "mip_levels": material.mipmapLevelCount,
            "anisotropy": 8, "patch_scale": 3, "exponent": 8, "skip_threshold": 0.01,
            "rounds": 6, "warmup_per_mode_per_round": 20, "results": rows
        ]
        let json = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: json, as: UTF8.self))
    }

    private func readback(_ texture: MTLTexture, bytesPerPixel: Int) throws -> Data {
        let stride = texture.width * bytesPerPixel
        guard let buffer = device.makeBuffer(length: stride * texture.height, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw RenderError("无法创建回读缓冲区")
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: stride, destinationBytesPerImage: stride * texture.height)
        blit.endEncoding(); command.commit(); command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? RenderError("GPU 回读失败") }
        return Data(bytes: buffer.contents(), count: buffer.length)
    }

    func verify() throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb, width: renderWidth, height: renderHeight, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor) else { throw RenderError("无法创建验证纹理") }
        func frame() throws -> Data {
            let command = try render(to: target)
            command.waitUntilCompleted()
            guard command.status == .completed else { throw command.error ?? RenderError("GPU 渲染失败") }
            return try readback(target, bytesPerPixel: 4)
        }
        let initial = try frame()
        let heights = try readback(height, bytesPerPixel: 4)
        let values = heights.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }),
              let minimum = values.min(), let maximum = values.max(), maximum - minimum > 0.25 else {
            throw RenderError("512×512 fBm 高度纹理验证失败")
        }
        var terrainPixels = 0
        for offset in stride(from: 0, to: initial.count, by: 4) {
            if initial[offset + 1] < 160 && initial[offset + 3] == 255 { terrainPixels += 1 }
        }
        guard terrainPixels > renderWidth * renderHeight / 5 else { throw RenderError("地形覆盖验证失败：\(terrainPixels)") }
        let repeated = try frame()
        guard initial == repeated else { throw RenderError("静止相机渲染不稳定") }
        // Exercise the same live controls as the window, without recreating a pipeline.
        useHexTiling.toggle()
        let alternateSampling = try frame()
        guard alternateSampling != initial else { throw RenderError("Sampling toggle did not change the image") }
        useHexTiling.toggle()
        flatTopDown.toggle()
        let alternateView = try frame()
        guard alternateView != initial else { throw RenderError("View toggle did not change the image") }
        flatTopDown.toggle()
        guard try frame() == initial else { throw RenderError("Restoring controls changed the image") }
        position += SIMD2<Float>(80, -80)
        let moved = try frame()
        guard moved != initial else { throw RenderError("移动相机没有更新地形") }
        // The overlapping world area must contain the same heights after regeneration.
        let movedHeights = try readback(height, bytesPerPixel: 4)
        let movedValues = movedHeights.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        for y in 64..<512 {
            for x in 0..<448 {
                guard abs(movedValues[y * 512 + x] - values[(y - 64) * 512 + x + 64]) < 0.00001 else {
                    throw RenderError("高度纹理滚动接缝验证失败")
                }
            }
        }
        reset()
        let returned = try frame()
        guard initial == returned else { throw RenderError("返回原点后地形不一致") }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: renderWidth, pixelsHigh: renderHeight,
                                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                colorSpaceName: .deviceRGB, bytesPerRow: renderWidth * 4, bitsPerPixel: 32),
                  let pixels = bitmap.bitmapData else { throw RenderError("无法创建截图") }
            initial.withUnsafeBytes { source in
                let bytes = source.bindMemory(to: UInt8.self)
                for i in stride(from: 0, to: initial.count, by: 4) {
                    pixels[i] = bytes[i + 2]; pixels[i + 1] = bytes[i + 1]; pixels[i + 2] = bytes[i]; pixels[i + 3] = 255
                }
            }
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw RenderError("PNG 编码失败") }
            try png.write(to: url)
        }
        print("PASS: \(device.name), 1280×720 terrain; 512×512 fBm range \(minimum)...\(maximum); \(terrainPixels) terrain pixels; camera movement, overlap continuity and deterministic return verified")
    }
}
