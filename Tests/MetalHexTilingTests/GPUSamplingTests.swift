import Metal
import XCTest
@testable import MetalHexTiling

/// Tests execute the shipped sampling function with explicit gradients. They do
/// not need a window. Runners without Metal report a skip rather than a false pass.
final class GPUSamplingTests: XCTestCase {
    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var pipeline: MTLComputePipelineState!

    override func setUpWithError() throws {
        guard let gpu = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable; run GPU tests on a Mac with GPU access")
        }
        device = gpu
        queue = try XCTUnwrap(gpu.makeCommandQueue())
        let library = try HexTilingMetal.makeLibrary(device: gpu, appending: """
        kernel void probe(texture2d<float> source [[texture(0)]],
                          constant HexTilingArguments &args [[buffer(0)]],
                          constant float4 *points [[buffer(1)]],
                          device float4 *output [[buffer(2)]],
                          uint i [[thread_position_in_grid]]) {
            constexpr sampler s(coord::normalized, address::repeat,
                                filter::linear, mip_filter::linear);
            float4 p = points[i];
            output[i] = hexTilingSample(source, s, p.xy,
                                       float2(p.z, 0), float2(0, p.z), args);
        }
        """)
        pipeline = try gpu.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: "probe")))
    }

    private func texture(colors: [SIMD4<Float>]) throws -> MTLTexture {
        let size = 1 << (colors.count - 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: size, height: size, mipmapped: colors.count > 1)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        for (level, color) in colors.enumerated() {
            let width = max(1, size >> level)
            let pixels = [SIMD4<Float>](repeating: color, count: width * width)
            pixels.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, width), mipmapLevel: level,
                                withBytes: $0.baseAddress!, bytesPerRow: width * 16)
            }
        }
        return texture
    }

    private func sample(_ texture: MTLTexture, points: [SIMD4<Float>],
                        parameters: HexTilingParameters) throws -> [SIMD4<Float>] {
        let count = points.count
        let input = try XCTUnwrap(points.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        })
        let output = try XCTUnwrap(device.makeBuffer(length: count * 16, options: .storageModeShared))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        var args = parameters.shaderVector
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&args, length: 16, index: 0)
        encoder.setBuffer(input, offset: 0, index: 1)
        encoder.setBuffer(output, offset: 0, index: 2)
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(count, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed, command.error?.localizedDescription ?? "GPU command failed")
        return Array(UnsafeBufferPointer(start: output.contents().bindMemory(to: SIMD4<Float>.self, capacity: count), count: count))
    }

    private func assertClose(_ actual: SIMD4<Float>, _ expected: SIMD4<Float>,
                             file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<4 {
            XCTAssertTrue(actual[channel].isFinite, file: file, line: line)
            XCTAssertEqual(actual[channel], expected[channel], accuracy: 0.0002, file: file, line: line)
        }
    }

    // Include both triangle centroids (worst case for high-exponent underflow),
    // corners, boundaries and negative coordinates, expressed in source UV.
    private func points(scale: Float) -> [SIMD4<Float>] {
        let lattice: [SIMD2<Float>] = [SIMD2(1/3, 1/3), SIMD2(2/3, 2/3),
                                     SIMD2(0, 0), SIMD2(0.2, 0.8), SIMD2(-0.7, -1.1), SIMD2(0.01, 0.47)]
        return lattice.map {
            let u = SIMD2<Float>($0.x + 0.5 * $0.y, sqrt(3) / 2 * $0.y) / (scale * exp2(1.8) / 8)
            return SIMD4(u.x, u.y, 0.001, 0)
        }
    }

    func testConstantColorSurvivesExtremeWeightsAndSkipping() throws {
        let color = SIMD4<Float>(0.18, 0.42, 0.75, 0.35)
        let tex = try texture(colors: [color, color, color])
        for scale: Float in [0.0001, 2, 8] {
            for exponent: Float in [0.0001, 8, 64] {
                for threshold: Float in [0, 0.01, 0.4, 1] {
                    for correction in [false, true] {
                        let params = HexTilingParameters(patchScale: scale, useContrastCorrectedBlending: correction,
                                                        lookupSkipThreshold: threshold, textureSampleCoefficientExponent: exponent)
                        for value in try sample(tex, points: points(scale: scale), parameters: params) {
                            assertClose(value, color)
                        }
                    }
                }
            }
        }
    }

    func testExplicitGradientsSelectMipLevels() throws {
        let red = SIMD4<Float>(1, 0, 0, 1), green = SIMD4<Float>(0, 1, 0, 1), blue = SIMD4<Float>(0, 0, 1, 1)
        let tex = try texture(colors: [red, green, blue])
        let factor: Float = exp2(1.8) / 8
        let params = HexTilingParameters(useContrastCorrectedBlending: false, lookupSkipThreshold: 0)
        let uv = points(scale: 2)[0]
        let probes = [SIMD4<Float>(uv.x, uv.y, 0, 0), SIMD4(uv.x, uv.y, 0.5 / factor, 0), SIMD4(uv.x, uv.y, 1 / factor, 0)]
        let values = try sample(tex, points: probes, parameters: params)
        for (value, expected) in zip(values, [red, green, blue]) { assertClose(value, expected) }
    }

    func testContrastAffectsRGBButNotAlpha() throws {
        let tex = try texture(colors: [SIMD4(0.4, 0.5, 0.6, 0.25), SIMD4(0.2, 0.3, 0.4, 0.9)])
        let result = try sample(tex, points: [points(scale: 2)[0]],
                                parameters: HexTilingParameters(lookupSkipThreshold: 0, textureSampleCoefficientExponent: 1))[0]
        let gain: Float = sqrt(3)
        assertClose(result, SIMD4(0.2 + 0.2 * gain, 0.3 + 0.2 * gain, 0.4 + 0.2 * gain, 0.25))
    }

    func testSingleMipFallsBackToOrdinaryBlending() throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba32Float, width: 4, height: 4, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        let tex = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        // A nonconstant texture detects mistakenly using a local texel as mean.
        let pixels = (0..<16).map { SIMD4<Float>(Float($0) / 16, Float($0 % 4) / 4, 0.7, 1) }
        pixels.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, 4, 4), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 64)
        }
        let p = points(scale: 2)
        let withCorrection = try sample(tex, points: p, parameters: HexTilingParameters())
        let withoutCorrection = try sample(tex, points: p, parameters: HexTilingParameters(useContrastCorrectedBlending: false))
        for (a, b) in zip(withCorrection, withoutCorrection) { assertClose(a, b) }
    }

    func testSRGBTextureDecodesColorButPreservesAlpha() throws {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        let tex = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = [128, 128, 128, 128]
        bytes.withUnsafeBytes {
            tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: $0.baseAddress!, bytesPerRow: 4)
        }
        let result = try sample(tex, points: points(scale: 2), parameters: HexTilingParameters())
        let encoded: Float = 128 / 255
        let linear = pow((encoded + 0.055) / 1.055, 2.4)
        for value in result {
            // Hardware sRGB conversion can use an approximation.
            for channel in 0..<3 { XCTAssertEqual(value[channel], linear, accuracy: 0.002) }
            XCTAssertEqual(value.w, encoded, accuracy: 0.0002)
        }
    }

    func testFlatNormalDataRemainsNeutral() throws {
        let normal = SIMD4<Float>(0.5, 0.5, 1, 1)
        let tex = try texture(colors: [normal, normal])
        for value in try sample(tex, points: points(scale: 2), parameters: HexTilingParameters(useContrastCorrectedBlending: false, lookupSkipThreshold: 0.4)) {
            assertClose(value, normal)
        }
    }
}
