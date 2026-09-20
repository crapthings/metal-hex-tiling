import XCTest
@testable import MetalHexTiling

final class MetalHexTilingTests: XCTestCase {
    func testDefaultsMatchUpstream() {
        XCTAssertEqual(HexTilingParameters().shaderVector, SIMD4<Float>(2, 1, 0.01, 8))
    }

    func testShaderValuesAreSanitized() {
        let value = HexTilingParameters(
            patchScale: .nan,
            useContrastCorrectedBlending: false,
            lookupSkipThreshold: 4,
            textureSampleCoefficientExponent: 100
        ).shaderVector
        XCTAssertEqual(value, SIMD4<Float>(2, 0, 1, 64))
    }

    func testShaderResourceIsExposed() throws {
        XCTAssertTrue(try HexTilingMetal.shaderSource.contains("hexTilingSample"))
    }
}
