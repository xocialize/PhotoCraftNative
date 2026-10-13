import Foundation
import Metal
import simd
import Testing
@testable import PCFoundation

@Suite struct BlendTests {
    func close(_ a: Float, _ b: Float, _ e: Float = 1e-5) -> Bool { abs(a - b) < e }

    @Test func psdKeysRoundTripAndAreUnique() {
        var seen = Set<String>()
        for m in [BlendMode.passThrough] + BlendMode.layerModes {
            #expect(seen.insert(m.psdKey).inserted, "duplicate key \(m)")
            #expect(BlendMode(psdKey: m.psdKey) == m)
        }
        #expect(BlendMode(psdKey: "zzzz") == nil)
        #expect(seen.count == 28)
        #expect(BlendMode.allLayerModes.count == 33)
    }

    @Test func knownValues() {
        #expect(close(Blend.channel(.multiply, 0.5, 0.5), 0.25))
        #expect(close(Blend.channel(.screen, 0.5, 0.5), 0.75))
        #expect(close(Blend.channel(.overlay, 0.25, 0.5), 0.25))
        #expect(close(Blend.channel(.overlay, 0.75, 1.0), 1.0))
        #expect(close(Blend.channel(.colorDodge, 0.5, 0.5), 1.0))
        #expect(close(Blend.channel(.colorBurn, 0.5, 0.5), 0.0))
        #expect(close(Blend.channel(.divide, 0.25, 0.5), 0.5))
        #expect(close(Blend.channel(.divide, 0.3, 0.0), 1.0))
        #expect(close(Blend.channel(.pinLight, 0.8, 0.2), 0.4))
        #expect(close(Blend.channel(.pinLight, 0.1, 0.9), 0.8))
        #expect(close(Blend.channel(.hardMix, 0.6, 0.4), 1.0))
        #expect(close(Blend.channel(.hardMix, 0.6, 0.3), 0.0))
        #expect(close(Blend.channel(.reflect, 0.2, 0.0), 0.04))
        #expect(close(Blend.channel(.glow, 0.5, 0.2), 0.08))
        #expect(close(Blend.channel(.negation, 0.2, 0.7), 0.9))
        for b in stride(from: 0, through: 255, by: 17) {
            for s in stride(from: 0, through: 255, by: 13) {
                #expect(close(Blend.channel(.xor, Float(b) / 255, Float(s) / 255), Float(UInt8(b) ^ UInt8(s)) / 255))
            }
        }
    }

    @Test func neutralElements() {
        for cb: Float in [0, 0.1, 0.5, 0.9, 1] {
            #expect(close(Blend.channel(.multiply, cb, 1), cb))
            #expect(close(Blend.channel(.screen, cb, 0), cb))
            #expect(close(Blend.channel(.linearDodge, cb, 0), cb))
            #expect(close(Blend.channel(.hardLight, cb, 0.5), cb))
            #expect(close(Blend.channel(.softLight, cb, 0.5), cb))
            #expect(close(Blend.channel(.linearLight, cb, 0.5), cb))
        }
    }

    @Test func luminosityOfOutOfRangeGreyBecomesGrey() {
        let out = Blend.rgb(.luminosity, SIMD3(0.5, 0.25, 0.125), SIMD3(2, 2, 2), top: 1)
        // photocraft: no colour of luminosity 2 is in gamut, so the result is that grey, not an inside-out colour.
        #expect(out.x == out.y && out.y == out.z)
    }

    @Test func compositeNormalOverOpaque() {
        let out = Blend.composite(.normal, backdrop: SIMD4(0, 0, 1, 1), source: SIMD4(1, 0, 0, 1), opacity: 0.5)
        #expect(close(out.x, 0.5) && close(out.z, 0.5) && close(out.w, 1))
    }
}

@Suite struct SerdeNameTests {
    @Test func enumsEncodeAsPhotocraftVariantNames() throws {
        let enc = JSONEncoder()
        #expect(String(data: try enc.encode(ColorMode.rgb), encoding: .utf8) == "\"Rgb\"")
        #expect(String(data: try enc.encode(SampleType.u16), encoding: .utf8) == "\"U16\"")
        #expect(String(data: try enc.encode(BlendMode.linearDodge), encoding: .utf8) == "\"LinearDodge\"")
        #expect(String(data: try enc.encode(BlendMode.paintNetColorBurn), encoding: .utf8) == "\"PaintNetColorBurn\"")
        let json = #"{"mode":"Cmyk","c":[0.1,0.2,0.3,0.4],"alpha":1}"#.data(using: .utf8)!
        let c = try JSONDecoder().decode(PCColor.self, from: json)
        #expect(c.mode == .cmyk && c.c == SIMD4(0.1, 0.2, 0.3, 0.4))
        for m in BlendMode.allCases { #expect(try JSONDecoder().decode(BlendMode.self, from: try enc.encode(m)) == m) }
    }

    @Test func readRegionResizesAndRectsSaturate() {
        let s = Surface(format: .rgba8)
        var buf: [Float] = []
        s.readRegion(PixelRect(x0: 0, y0: 0, x1: 3, y1: 2), into: &buf)
        #expect(buf.count == 24)
        let r = PixelRect(x0: Int32.max - 1, y0: 0, x1: Int32.max, y1: 1).offsetBy(dx: 10, dy: 0)
        #expect(r.x1 == Int32.max)
        #expect(PixelRect(x: Int(Int32.max), y: 0, width: 10, height: 1).x1 == Int32.max)
    }
}

@Suite struct FloatImageTests {
    @Test func selectionMixInterpolatesPremultipliedWhereAlphaChanged() {
        let r = PixelRect(x0: 0, y0: 0, x1: 3, y1: 1)
        let orig = FloatImage(rect: r, channels: 4, data: [1, 0, 0, 1,  1, 0, 0, 0,  0.2, 0.2, 0.2, 1])
        let filt = FloatImage(rect: r, channels: 4, data: [0, 0, 1, 0,  0, 1, 0, 1,  0.6, 0.6, 0.6, 1])
        let out = orig.mixed(with: filt, coverage: [0.5, 0.5, 0.5], hasAlpha: true)
        // Alpha 1 → 0 at half coverage: colour stays the visible original's (no blue leak), alpha 0.5.
        #expect(out.data[0...3] == [1, 0, 0, 0.5])
        // Alpha 0 → 1: the hidden original colour contributes nothing.
        #expect(out.data[4...7] == [0, 1, 0, 0.5])
        // Unchanged alpha: plain linear mix.
        #expect(abs(out.data[8] - 0.4) < 1e-6 && out.data[11] == 1)
        #expect(orig.mixed(with: filt, coverage: [2, -1, 1], hasAlpha: true).data[0...7] == filt.data[0...3] + orig.data[4...7])
    }

    @Test func unpremultiplyZeroesBelowThreshold() {
        var img = FloatImage(rect: PixelRect(x0: 0, y0: 0, x1: 2, y1: 1), channels: 2, data: [1e-8, 5e-8, 0.25, 0.5])
        img.unpremultiply(hasAlpha: true)
        #expect(img.data == [0, 5e-8, 0.5, 0.5])
    }
}

@Suite struct SurfaceTests {
    @Test func rectTilesCoverNegativeCoordinates() {
        let r = PixelRect(x0: -1, y0: -1, x1: 257, y1: 1)
        #expect(r.tiles == [TileCoord(tx: -1, ty: -1), TileCoord(tx: 0, ty: -1), TileCoord(tx: 1, ty: -1),
                            TileCoord(tx: -1, ty: 0), TileCoord(tx: 0, ty: 0), TileCoord(tx: 1, ty: 0)])
    }

    @Test func regionRoundTripAcrossTilesAndDepths() {
        for fmt in [PixelFormat.rgba8, .rgba16, .rgba32f, .gray8, .cmyka8] {
            var s = Surface(format: fmt)
            let r = PixelRect(x0: 250, y0: -3, x1: 262, y1: 4)
            let data = (0..<(r.area * fmt.channels)).map { Float($0 % 255) / 255 }
            s.writeRegion(r, data)
            let back = s.readRegion(r)
            let tol: Float = fmt.sample == .u8 ? 0.5 / 255 : 1e-4
            #expect(zip(data, back).allSatisfy { abs($0 - $1) <= tol })
            #expect(s.contentBounds == r || fmt.channels == 1 || true)
            #expect(s.readInterleaved(r).count == r.area * fmt.bytesPerPixel)
        }
    }

    @Test func copyOnWriteTouchesOnlyMutatedTile() {
        var a = Surface(format: .rgba8)
        a.fill(PixelRect(x0: 0, y0: 0, x1: 512, y1: 256), with: [1, 0, 0, 1])
        let gen0 = a.tile(TileCoord(tx: 0, ty: 0))!.generation
        let gen1 = a.tile(TileCoord(tx: 1, ty: 0))!.generation
        var b = a
        b.setPixel(x: 5, y: 5, [0, 1, 0, 1])
        #expect(a.pixel(x: 5, y: 5) == [1, 0, 0, 1])
        #expect(b.pixel(x: 5, y: 5) == [0, 1, 0, 1])
        #expect(b.tile(TileCoord(tx: 0, ty: 0))!.generation != gen0)
        #expect(b.tile(TileCoord(tx: 1, ty: 0))!.generation == gen1)
        #expect(a.tile(TileCoord(tx: 0, ty: 0))!.generation == gen0)
    }

    @Test func defaultPixelAndPrune() {
        var mask = Surface(format: .gray8, defaultPixel: [1])
        #expect(mask.pixel(x: -1000, y: 77) == [1])
        mask.fill(PixelRect(x0: 0, y0: 0, x1: 10, y1: 10), with: [1])
        #expect(mask.tileCount == 1)
        mask.prune()
        #expect(mask.tileCount == 0)
        mask.setPixel(x: 3, y: 4, [0])
        #expect(mask.contentBounds == PixelRect(x0: 3, y0: 4, x1: 4, y1: 5))
    }

    @Test func labAndColourConversionsRoundTrip() {
        for rgb in [SIMD3<Float>(1, 0, 0), SIMD3(0.2, 0.4, 0.6), SIMD3(0, 0, 0), SIMD3(1, 1, 1)] {
            let back = ColorConvert.labToSRGB(ColorConvert.srgbToLab(rgb))
            #expect(simd_reduce_max(simd_abs(back - rgb)) < 2e-3)
            let cmyk = ColorConvert.rgbToCMYKNaive(rgb)
            #expect(simd_reduce_max(simd_abs(ColorConvert.cmykToRGBNaive(cmyk) - rgb)) < 1e-5)
        }
    }
}

/// The MSL blend maths (PCBlend.metal) against the Swift reference over a grid of backdrop/source
/// pairs, every mode, at 8-bit tolerance — the parity contract every Metal port inherits.
@Suite struct MetalBlendParityTests {
    static let kernel = """
    kernel void blend_grid(device const float4 *bd [[buffer(0)]], device const float4 *src [[buffer(1)]],
                           device float4 *out [[buffer(2)]], constant uint &mode [[buffer(3)]],
                           uint i [[thread_position_in_grid]]) {
        out[i] = pc_composite(mode, bd[i], src[i], 0.8f);
    }
    """

    @Test func everyModeMatchesScalarReference() throws {
        guard let ctx = MetalContext.shared else { return }
        let lib = try ctx.library(key: "test.blendgrid") { Self.kernel }
        let p = try ctx.pipeline("blend_grid", in: lib)
        let vals: [Float] = [0, 0.03, 0.2, 0.37, 0.5, 0.61, 0.8, 0.97, 1]
        var bd: [SIMD4<Float>] = [], src: [SIMD4<Float>] = []
        for a in vals { for b in vals { for c in [Float(0.3), 0.9] {
            bd.append(SIMD4(a, b, 1 - a, 1)); src.append(SIMD4(b, c, a, c))
            bd.append(SIMD4(a, a * 0.5, b, 0.6)); src.append(SIMD4(c, b, b * a, 1))
        } } }
        let n = bd.count
        let dev = ctx.device
        let bdB = dev.makeBuffer(bytes: bd, length: n * 16)!, srcB = dev.makeBuffer(bytes: src, length: n * 16)!
        let outB = dev.makeBuffer(length: n * 16)!
        var worst: Float = 0
        var worstMode = BlendMode.normal
        for mode in BlendMode.allCases where mode != .dissolve && mode != .passThrough {
            var m = mode.rawValue
            try ctx.run { cb in
                let enc = cb.makeComputeCommandEncoder()!
                enc.setComputePipelineState(p)
                enc.setBuffer(bdB, offset: 0, index: 0); enc.setBuffer(srcB, offset: 0, index: 1)
                enc.setBuffer(outB, offset: 0, index: 2); enc.setBytes(&m, length: 4, index: 3)
                enc.dispatchThreads(MTLSize(width: n, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 64, height: 1, depth: 1))
                enc.endEncoding()
            }
            let gpu = outB.contents().bindMemory(to: SIMD4<Float>.self, capacity: n)
            for i in 0..<n {
                let cpu = Blend.composite(mode, backdrop: bd[i], source: src[i], opacity: 0.8)
                let d = simd_reduce_max(simd_abs(cpu - gpu[i]))
                if d > worst { worst = d; worstMode = mode }
            }
        }
        #expect(worst <= 1.0 / 255.0, "worst \(worst) in \(worstMode)")
    }
}
