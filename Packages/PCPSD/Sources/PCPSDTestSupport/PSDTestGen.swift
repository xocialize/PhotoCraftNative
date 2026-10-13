// Deterministic synthetic PSD/PSB generator for tests: every depth, colour mode and compression,
// layers with masks (real masks and parameters), nested groups, every blend mode, Unicode names,
// empty layers, negative offsets, many tagged blocks, descriptors and resources.
// Port of photocraft-psd (crates/psd/src/testgen.rs), MIT OR Apache-2.0, © ArtCraft Team and the
// PhotoCraft contributors.
//
// Shipped as the `PCPSDTestSupport` library so other packages' tests can generate the same files.
// Built on PCPSD's public API only (it compiles in release builds, without `@testable`).

import Foundation
import PCPSD

/// The synthetic PSD/PSB generator (photocraft `testgen`).
public enum PSDTestGen {
    public struct Case: Sendable {
        public let name: String
        public let file: PSDFile
        public init(name: String, file: PSDFile) {
            self.name = name
            self.file = file
        }
    }

    /// Deterministic planar samples for a `w × h` plane.
    public static func patternPlane(_ w: Int, _ h: Int, _ depth: UInt16, _ seed: UInt32) -> [UInt8] {
        var out: [UInt8] = []
        let s = Int(seed)
        for y in 0 ..< h {
            switch depth {
            case 1:
                for bx in 0 ..< PSDHeader.rowBytes(width: w, depth: 1) { out.append(UInt8(truncatingIfNeeded: bx * 37 + y * 11 + s) ^ 0x5A) }
            case 8:
                for x in 0 ..< w { out.append((x / 4 + y) % 3 == 0 ? UInt8(truncatingIfNeeded: s * 17) : UInt8(truncatingIfNeeded: x * 3 + y * 7 + s)) }
            case 16:
                for x in 0 ..< w {
                    let v = UInt16((x * 997 + y * 131 + s * 7919) % 65536)
                    out += [UInt8(v >> 8), UInt8(v & 0xFF)]
                }
            default:
                for x in 0 ..< w { out += PSDSamples.bytes(f32: [Float((x + y + s) % 17) / 16]) }
            }
        }
        return out
    }

    public static func modeChannels(_ m: PSDColorMode) -> UInt16 { m == .multichannel ? 2 : UInt16(m.colorChannels ?? 1) }

    public static func modeDepths(_ m: PSDColorMode) -> [UInt16] {
        switch m {
        case .bitmap: [1]
        case .indexed, .duotone: [8]
        case .multichannel, .cmyk, .lab: [8, 16]
        default: [8, 16, 32]
        }
    }

    public static let modes: [PSDColorMode] = [.bitmap, .grayscale, .indexed, .rgb, .cmyk, .lab, .multichannel, .duotone]

    /// Colour-mode data: a palette (Indexed), placeholder duotone bytes, and at 32 bits the HDR
    /// toning data Photoshop requires (`PSDHDRToning`; without it Photoshop refuses the file).
    public static func colorModeData(_ m: PSDColorMode, depth: UInt16 = 8) -> Data {
        if depth == 32 { return PSDHDRToning.colorModeData(depth: 32) }
        return switch m {
        case .indexed: Data((0 ..< 768).map { UInt8($0 * 7 % 256) })
        case .duotone: Data(0 ..< 24)
        default: Data()
        }
    }

    public static func baseResources() -> [PSDImageResource] {
        [
            PSDImageResource(id: PSDResourceID.resolutionInfo, data: PSDResolutionInfo(dpi: 72).serialized()),
            PSDImageResource(id: PSDResourceID.globalAngle, data: Data([0, 0, 0, 30])),
            PSDImageResource(id: PSDResourceID.globalAltitude, data: Data([0, 0, 0, 30])),
            PSDImageResource(id: PSDResourceID.iccProfile, data: Data(repeating: 0x42, count: 13)),
            PSDImageResource(id: PSDResourceID.xmp, data: Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'/>".utf8)),
            PSDImageResource(id: 2000, data: Data([1, 2, 3]), name: Array("Path 1".utf8)),
            PSDVersionInfo.resource(hasRealMergedData: true),
        ]
    }

    public static func encodeChannel(_ id: Int16, _ c: PSDCompression, _ plane: [UInt8], _ w: Int, _ h: Int, _ depth: UInt16, _ v: PSDVersion) -> PSDChannel {
        // The generator stores exactly the requested compression (no Photoshop-acceptance mapping).
        let layout = PlaneLayout(planes: 1, width: w, height: h, depth: depth, version: v)
        return PSDChannel(id: id, compression: c, data: Data(try! PlaneCodec.encode(c, plane, layout: layout)))
    }

    public static func mergedOnly(_ v: PSDVersion, _ mode: PSDColorMode, _ depth: UInt16, _ c: PSDCompression, _ w: UInt32, _ h: UInt32) -> PSDFile {
        let channels = modeChannels(mode)
        let header = PSDHeader(version: v, width: w, height: h, channels: channels, depth: depth, colorMode: mode)
        var planes: [UInt8] = []
        for ch in 0 ..< channels { planes += patternPlane(Int(w), Int(h), depth, UInt32(ch)) }
        let data = (try? PlaneCodec.encode(c, planes, layout: PSDImageData.layout(header))) ?? []
        return PSDFile(header: header, colorModeData: colorModeData(mode, depth: depth), resources: baseResources(),
                       imageData: PSDImageData(compression: c, data: Data(data)))
    }

    public static func rasterLayer(header: PSDHeader, compression: PSDCompression, rect: PSDRect, name: String, blend: PSDBlendMode,
                            mask: PSDLayerMask?, seed: UInt32) -> PSDLayerRecord {
        let (w, h) = (try? rect.size()) ?? (0, 0)
        let depth = header.depth, v = header.version
        let cc = Int16(modeChannels(header.colorMode))
        var channels: [PSDChannel] = []
        for id in Int16(-1) ..< cc {
            let plane = patternPlane(w, h, depth, seed + UInt32(id + 1))
            let comp: PSDCompression = id == -1 && compression == .rle ? .zip : compression
            channels.append(encodeChannel(id, comp, plane, w, h, depth, v))
        }
        var maskData = PSDMaskData.none
        if let m = mask {
            let (mw, mh) = (try? m.rect.size()) ?? (0, 0)
            channels.append(encodeChannel(-2, compression, patternPlane(mw, mh, depth, seed + 99), mw, mh, depth, v))
            if let real = m.real {
                let (rw, rh) = (try? real.rect.size()) ?? (0, 0)
                channels.append(encodeChannel(-3, compression, patternPlane(rw, rh, depth, seed + 7), rw, rh, depth, v))
            }
            maskData = .mask(m)
        }
        var flags = PSDLayerFlags()
        flags.isHidden = seed % 5 == 4
        return PSDLayerRecord(rect: rect, channels: channels, blendMode: blend, opacity: UInt8(255 - (seed * 13) % 128),
                              clipping: seed % 7 == 3 ? 1 : 0, flags: flags, mask: maskData, blendingRanges: .full(channels: Int(cc)),
                              name: PSDLayerRecord.legacyName(name), blocks: [.unicodeName(name), .layerID(seed + 1)])
    }

    public static func groupRecord(_ header: PSDHeader, _ name: String, _ kind: PSDSectionType, _ blend: PSDBlendMode, _ id: UInt32) -> PSDLayerRecord {
        let cc = Int16(modeChannels(header.colorMode))
        let channels = (Int16(-1) ..< cc).map { PSDChannel(id: $0, compression: .raw, data: Data()) }
        let lsct: PSDTaggedBlock = kind == .boundingDivider ? .sectionDivider(kind) : .sectionDivider(kind, blendMode: blend, subType: 0)
        return PSDLayerRecord(channels: channels, blendMode: blend, blendingRanges: .full(channels: Int(cc)), name: PSDLayerRecord.legacyName(name),
                              blocks: [.unicodeName(name), .layerID(id), lsct])
    }

    public static func sampleDescriptor() -> PSDVersionedDescriptor {
        PSDVersionedDescriptor(
            PSDDescriptor()
                .with("Scl ", .unitFloat(unit: "#Prc", value: 100))
                .with("masterFXSwitch", .boolean(true))
                .with("DrSh", .descriptor(PSDDescriptor(classID: "DrSh")
                        .with("enab", .boolean(true))
                        .with("Md  ", .enumerated(type: "BlnM", value: "Mltp"))
                        .with("Clr ", .descriptor(PSDDescriptor(classID: "RGBC").with("Rd  ", .double(0))))
                        .with("lagl", .unitFloat(unit: "#Ang", value: 120))
                        .with("Nm  ", .text(.nulTerminated("Shadow")))))
                .with("list", .list([.integer(1), .largeInteger(-2)])))
    }

    public static func extraBlocks(_ seed: UInt32) -> [PSDTaggedBlock] {
        var lfx2 = Data([0, 0, 0, 0])
        lfx2.append(sampleDescriptor().serialized())
        var odd = PSDTaggedBlock(key: "zOdd", bytes: [1, 2, 3])
        odd.padding = [0, 0, 0]
        var unpadded = PSDTaggedBlock(key: "zNop", bytes: [9])
        unpadded.padding = []
        return [
            .nameSource("cont"), .blendClippedAsGroup(true), .blendInteriorElements(false), .knockout(0),
            .protection(seed % 8), .sheetColor(UInt16(seed % 8)), .fillOpacity(200),
            PSDTaggedBlock(key: "shmd", bytes: [0, 0, 0, 0]), PSDTaggedBlock(key: "lfx2", data: lfx2),
            PSDTaggedBlock(key: "fxrp", data: Data(count: 16)), odd, unpadded,
        ]
    }

    /// A layered document of 30+ layers in nested groups, one per blend mode among them.
    ///
    /// By default every blend mode is one Photoshop accepts for the document's mode and depth:
    /// requested modes go through `PSDBlendMode.nearestAllowed`, so layers stay in place. With
    /// `invalidBlendModes`, the layers carry every known key as given, including pass-through on
    /// a layer, modes the depth or mode excludes, and an unknown key. Use that for fuzzing and
    /// round trips; Photoshop refuses such files.
    public static func layered(_ v: PSDVersion, _ mode: PSDColorMode, _ depth: UInt16, _ c: PSDCompression,
                               invalidBlendModes: Bool = false) -> PSDFile {
        func valid(_ m: PSDBlendMode, group: Bool = false) -> PSDBlendMode {
            invalidBlendModes ? m : PSDBlendMode.nearestAllowed(m, mode: mode, depth: depth, isGroup: group)
        }
        let (w, h) = (UInt32(24), UInt32(16))
        let channels = modeChannels(mode) + 1
        let header = PSDHeader(version: v, width: w, height: h, channels: channels, depth: depth, colorMode: mode)
        var layers: [PSDLayerRecord] = []
        var seed: UInt32 = 0
        func next(_ rect: PSDRect, _ name: String, _ blend: PSDBlendMode, _ mask: PSDLayerMask?) {
            seed += 1
            var rec = rasterLayer(header: header, compression: c, rect: rect, name: name, blend: valid(blend), mask: mask, seed: seed)
            if seed % 3 == 0 { rec.blocks += extraBlocks(seed) }
            layers.append(rec)
        }
        next(PSDRect(x: 0, y: 0, width: w, height: h), "Background", .normal, nil)
        next(PSDRect(x: -5, y: -3, width: 10, height: 7), "Neg offset \u{1F600}", .multiply,
             PSDLayerMask(rect: PSDRect(x: -2, y: -2, width: 6, height: 5), defaultColor: 0, flags: PSDLayerMask.flagRelative))
        next(.zero, "Empty", .screen, nil)
        next(PSDRect(x: -100, y: 5, width: 400, height: 2), "Wide", .overlay, nil)
        let id0: UInt32 = 1000
        layers.append(groupRecord(header, "</Layer group>", .boundingDivider, .normal, id0))
        next(PSDRect(x: 2, y: 2, width: 5, height: 5), "In outer", .darken, nil)
        layers.append(groupRecord(header, "</Layer group>", .boundingDivider, .normal, id0 + 1))
        let realMask = PSDLayerMask(rect: PSDRect(x: 1, y: 1, width: 4, height: 3), defaultColor: 255, flags: PSDLayerMask.flagParameters,
                                    parameters: PSDMaskParameters(flags: 0b0011, userDensity: 200, userFeather: 1.5),
                                    real: PSDRealMask(flags: 0, background: 255, rect: PSDRect(x: 0, y: 0, width: 3, height: 3)),
                                    trailing: [], realFirst: true)
        next(PSDRect(x: 3, y: 3, width: 6, height: 4), "Grüße", .colorDodge, realMask)
        layers.append(groupRecord(header, "Inner", .closedFolder, valid(.normal, group: true), id0 + 2))
        layers.append(groupRecord(header, "Outer", .openFolder, valid(.passThrough, group: true), id0 + 3))
        for (i, m) in PSDBlendMode.all.enumerated() {
            next(PSDRect(x: Int32(i % 20), y: Int32(i % 12), width: 3, height: 2), "blend \(m)", m, nil)
        }
        next(PSDRect(x: 0, y: 0, width: 2, height: 2), "unknown blend", .unknown("zzzz"), nil)

        var planes: [UInt8] = []
        for ch in 0 ..< channels { planes += patternPlane(Int(w), Int(h), depth, 50 + UInt32(ch)) }
        let image = PSDImageData(compression: c, data: Data(try! PlaneCodec.encode(c, planes, layout: PSDImageData.layout(header))))
        let info = PSDLayerInfo(mergedAlpha: true, layers: layers)
        let placement: PSDLayerInfoPlacement
        let blocks: [PSDTaggedBlock]
        if depth == 16 || depth == 32 {
            placement = .globalBlock(index: 1, signature: "8BIM", key: depth == 16 ? "Lr16" : "Lr32", padding: nil, longLengthOverride: nil)
            blocks = [PSDTaggedBlock(key: "Patt", bytes: []), PSDTaggedBlock(key: "Txt2", bytes: [0, 1, 2, 3])]
        } else {
            placement = .section
            blocks = [PSDTaggedBlock(key: "Patt", bytes: []), PSDTaggedBlock(key: "FMsk", bytes: [UInt8](repeating: 0, count: 10))]
        }
        return PSDFile(header: header, colorModeData: colorModeData(mode, depth: depth), resources: baseResources(), layerInfo: info,
                       layerInfoPlacement: placement, globalLayerMask: PSDGlobalLayerMask(data: [0, 0, 0xFF, 0xFF, 0, 0, 0, 0, 0, 0, 0, 50, 128, 0]),
                       globalBlocks: blocks, imageData: image)
    }

    public static func small(_ v: PSDVersion, _ c: PSDCompression) -> PSDFile {
        let header = PSDHeader(version: v, width: 4, height: 3, channels: 4, depth: 8, colorMode: .rgb)
        let layers = [
            rasterLayer(header: header, compression: c, rect: PSDRect(x: 0, y: 0, width: 4, height: 3), name: "a", blend: .normal,
                        mask: PSDLayerMask(rect: PSDRect(x: 0, y: 0, width: 2, height: 2), defaultColor: 0, flags: 0), seed: 1),
            groupRecord(header, "</Layer group>", .boundingDivider, .normal, 9),
            rasterLayer(header: header, compression: c, rect: PSDRect(x: -1, y: 1, width: 2, height: 2), name: "b", blend: .screen, mask: nil, seed: 2),
            groupRecord(header, "g", .openFolder, .passThrough, 10),
        ]
        var planes: [UInt8] = []
        for ch in 0 ..< 4 { planes += patternPlane(4, 3, 8, UInt32(ch)) }
        return PSDFile(header: header, resources: [PSDImageResource(id: PSDResourceID.resolutionInfo, data: PSDResolutionInfo(dpi: 72).serialized())],
                       layerInfo: PSDLayerInfo(mergedAlpha: true, layers: layers), globalLayerMask: PSDGlobalLayerMask(),
                       // Photoshop's empty pattern block (every layered file it writes has
                       // one), not the 2-byte `01 02` placeholder this used to carry.
                       globalBlocks: [PSDTaggedBlock(key: "Patt", bytes: [])],
                       imageData: PSDImageData(compression: c, data: Data(try! PlaneCodec.encode(c, planes, layout: PSDImageData.layout(header)))))
    }

    /// Every generated case. `invalidBlendModes` as in `layered`.
    public static func allCases(invalidBlendModes: Bool = false) -> [Case] {
        var v: [Case] = []
        for version in PSDVersion.allCases {
            for mode in modes {
                for depth in modeDepths(mode) {
                    for c in PSDCompression.all {
                        v.append(Case(name: "merged \(version) \(mode) \(depth)bit \(c)", file: mergedOnly(version, mode, depth, c, 13, 7)))
                    }
                }
            }
            for mode in [PSDColorMode.grayscale, .rgb, .cmyk, .lab] {
                for depth in modeDepths(mode) where depth >= 8 {
                    for c in PSDCompression.all {
                        v.append(Case(name: "layered \(version) \(mode) \(depth)bit \(c)", file: layered(version, mode, depth, c, invalidBlendModes: invalidBlendModes)))
                    }
                }
            }
            for c in PSDCompression.all { v.append(Case(name: "small \(version) \(c)", file: small(version, c))) }
            v.append(Case(name: "1x1 canvas \(version)", file: mergedOnly(version, .rgb, 8, .rle, 1, 1)))
        }
        return v
    }
}

/// Deterministic xorshift generator for the seeded randomised tests (proptest replacement).
public struct PSDSeededRandom: Sendable {
    public var state: UInt64
    public init(_ seed: UInt64) { state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    public mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
    public mutating func int(_ range: Range<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
    public mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
    public mutating func bytes(_ n: Int) -> [UInt8] { (0 ..< n).map { _ in byte() } }
    public mutating func bool() -> Bool { next() & 1 == 1 }
}
