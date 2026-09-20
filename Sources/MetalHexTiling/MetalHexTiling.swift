import Foundation
import Metal
import simd

/// Runtime controls for stochastic hex texture tiling.
public struct HexTilingParameters: Sendable, Equatable {
    public var patchScale: Float
    public var useContrastCorrectedBlending: Bool
    public var lookupSkipThreshold: Float
    public var textureSampleCoefficientExponent: Float

    public init(
        patchScale: Float = 2,
        useContrastCorrectedBlending: Bool = true,
        lookupSkipThreshold: Float = 0.01,
        textureSampleCoefficientExponent: Float = 8
    ) {
        self.patchScale = patchScale
        self.useContrastCorrectedBlending = useContrastCorrectedBlending
        self.lookupSkipThreshold = lookupSkipThreshold
        self.textureSampleCoefficientExponent = textureSampleCoefficientExponent
    }

    /// The 16-byte value expected by `HexTilingArguments.options` in the MSL API.
    /// Non-finite or out-of-range input is sanitized to prevent shader NaNs.
    public var shaderVector: SIMD4<Float> {
        SIMD4(
            max(patchScale.isFinite ? patchScale : 2, 0.0001),
            useContrastCorrectedBlending ? 1 : 0,
            min(max(lookupSkipThreshold.isFinite ? lookupSkipThreshold : 0.01, 0), 1),
            min(max(textureSampleCoefficientExponent.isFinite ? textureSampleCoefficientExponent : 8, 0.0001), 64)
        )
    }
}

/// Loads and composes the library's MSL source with an application's shaders.
public enum HexTilingMetal {
    public static var shaderSource: String {
        get throws {
            guard let url = Bundle.module.url(forResource: "HexTiling", withExtension: "metal") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// Compiles the tiling implementation and client shader as one translation unit, allowing
    /// `hexTilingSample` to be inlined without requiring Metal dynamic libraries.
    public static func makeLibrary(
        device: MTLDevice,
        appending clientSource: String,
        options: MTLCompileOptions? = nil
    ) throws -> MTLLibrary {
        try device.makeLibrary(source: shaderSource + "\n" + clientSource, options: options)
    }
}
