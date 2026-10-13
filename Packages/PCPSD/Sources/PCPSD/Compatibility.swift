// Photoshop-acceptance checks run before saving: the structural rules photocraft's writer learned
// from its open issues (#291 32-bit colour mode data, #1281/#2469 files Photoshop would not open,
// #200 PSB lengths, #949 mask order) and the conventions Photoshop's own files follow.
// Extends photocraft-psd's `PsdFile::validate` (crates/psd/src/file.rs) and
// `TaggedBlock::check_structure` (tagged.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors. The type-layer EngineData rules come from Photoshop 27.11 itself (see
// TextRequirements.swift).

import Foundation

public struct PSDCompatibilityIssue: Hashable, Sendable, CustomStringConvertible {
    public enum Severity: Hashable, Sendable {
        /// Photoshop (or a strict reader) is expected to reject or misread the file.
        case error
        /// Differs from what Photoshop writes; known readers cope.
        case warning
    }

    public var severity: Severity
    public var message: String
    public var layerIndex: Int?
    /// The named rule, for issues callers act on programmatically (`nil` for the generic checks).
    public var rule: PSDCompatibilityRule?

    public init(severity: Severity, message: String, layerIndex: Int? = nil, rule: PSDCompatibilityRule? = nil) {
        self.severity = severity
        self.message = message
        self.layerIndex = layerIndex
        self.rule = rule
    }

    public var description: String {
        "\(severity == .error ? "error" : "warning")\(layerIndex.map { " (layer \($0))" } ?? ""): \(message)"
    }
}

/// Named compatibility rules.
public struct PSDCompatibilityRule: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// A type layer's EngineData lacks structures Photoshop dereferences unchecked: **Photoshop
    /// crashes on open** (null dereference; Photoshop 27.11). See `PSDEngineData.photoshopStructureGaps()`.
    public static let typeLayerEngineDataCrashesPhotoshop = PSDCompatibilityRule(rawValue: "typeLayerEngineDataCrashesPhotoshop")
    /// A type layer's EngineData has the crash-critical structures but lacks the font-set fields
    /// (`ResourceDict.FontSet[].FontType` / `Synthetic`): **Photoshop refuses to open the file**.
    public static let typeLayerEngineDataBlocksPhotoshop = PSDCompatibilityRule(rawValue: "typeLayerEngineDataBlocksPhotoshop")
    /// A `TySh` block that does not parse at all.
    public static let typeLayerUnreadable = PSDCompatibilityRule(rawValue: "typeLayerUnreadable")
    /// A layer or group uses a blend mode its document's mode and depth cannot have: **Photoshop
    /// refuses the file** (Photoshop 27.11; see `PSDBlendMode.allowedModes(mode:depth:isGroup:)`).
    public static let blendModeInvalidForDocument = PSDCompatibilityRule(rawValue: "blendModeInvalidForDocument")
    /// Pass-through on a record that is not a group: **Photoshop raises a modal** while opening.
    public static let passThroughOnNonGroup = PSDCompatibilityRule(rawValue: "passThroughOnNonGroup")
    /// A layer tagged block whose length is not a multiple of 4. Photoshop 4-aligns every layer
    /// block it writes; for `grdm` it is an error, because **Photoshop refuses the file**
    /// (Photoshop 27.11). Other keys get a warning. Fix with `PSDTaggedBlock.fourAligned()`.
    public static let layerBlockNotFourAligned = PSDCompatibilityRule(rawValue: "layerBlockNotFourAligned")
    /// The `Lr16`/`Lr32` layer-info block precedes its `Mt16`/`Mt32` (or `Mtrn`) matte block:
    /// **Photoshop refuses the file** (Photoshop 27.11). Photoshop writes the matte block first.
    public static let layerInfoBeforeMatteBlock = PSDCompatibilityRule(rawValue: "layerInfoBeforeMatteBlock")
    /// A 32-bit document whose colour-mode data is not HDR toning (`hdrt`): **Photoshop refuses
    /// the file** (#291). PCPSD's writer substitutes the default toning data when serializing
    /// such a model, so this fires on models, never on what PCPSD writes.
    public static let hdrToningMissingAt32Bit = PSDCompatibilityRule(rawValue: "hdrToningMissingAt32Bit")
    /// A type layer's FontSize (style run or style sheet), effective size (FontSize × transform
    /// scale) or transform is outside what Photoshop reads as type. Photoshop opens the file but
    /// **rasterizes the layer and loses its text**: Photoshop 27.11 turned a 1e30 pt layer into
    /// an empty pixel layer, and a `Double.greatestFiniteMagnitude` one raised the modal "type
    /// layers … were rasterized". An error for those measured classes (non-finite values, sizes of
    /// 1e6 pt or more); a warning outside Photoshop's documented limits only (0.01–1,296 pt,
    /// transform components within ±300,000). The oracle's pre-screen 3 (`TypeSizeScreen`).
    public static let typeSizeOutOfRange = PSDCompatibilityRule(rawValue: "typeSizeOutOfRange")
    /// A placed layer whose `SoLd`/`SoLE` holds only `Idnt` and `Trnf` and whose unique id no
    /// linked-file item (`lnk2`/`lnk3`/`lnkD`/`lnkE`) carries: **Photoshop refuses the file**
    /// (Photoshop 27.11, PCIO's `placedLayerBlocksKeepTheirKeys`; deleting that record opens it).
    /// A placed layer with Photoshop's full descriptor and no linked item opens (a missing link).
    public static let placedLayerWithoutLinkedData = PSDCompatibilityRule(rawValue: "placedLayerWithoutLinkedData")
    /// A `PlLd`, `SoLd` or `SoLE` block that does not parse strictly (`PSDTaggedBlock.checkStructure`):
    /// **Photoshop refuses the file** (Photoshop 27.11 refused a 4-byte stand-in `PlLd` and opened
    /// the file once it was dropped).
    public static let placedLayerDataUnreadable = PSDCompatibilityRule(rawValue: "placedLayerDataUnreadable")
    /// A linked-file item whose kind (`liFD`, `liFE`, `liFA`) does not match its layout: it does not
    /// read as its own kind but does as another. **Photoshop refuses the file** (Photoshop 27.11
    /// refused embedded items relabelled `liFE` and opened the file once `liFD` was restored).
    public static let linkedFileKindMismatch = PSDCompatibilityRule(rawValue: "linkedFileKindMismatch")
    /// A fill-layer block (`SoCo`, `GdFl`, `PtFl`) that is empty or does not parse. For `SoCo` an
    /// error: **Photoshop refuses the file** (Photoshop 27.11 refused PCIO's
    /// `vectorRenderedMaskNotDoubledOnShapes` for its 0-byte `SoCo`: with a real `SoCo` the file
    /// opened, with a real `vmsk` and the empty `SoCo` it was still refused). For `GdFl`/`PtFl` a
    /// warning (not measured).
    public static let fillLayerDataUnreadable = PSDCompatibilityRule(rawValue: "fillLayerDataUnreadable")
    /// A vector mask (`vmsk`/`vsms`) without path records; Photoshop writes none (217/217 have
    /// records) and reads one as no vector mask. A warning only: Photoshop 27.11 opens them (an
    /// 8-byte and a 12-byte version-0 form, and 8-byte disabled ones).
    public static let vectorMaskWithoutPaths = PSDCompatibilityRule(rawValue: "vectorMaskWithoutPaths")
    /// A pattern in a `Patt`/`Pat2`/`Pat3` block keeps its transparency in the user mask array
    /// (slot 24): **Photoshop refuses the file** (Photoshop 27.11 refused all 40 PCIO exports
    /// written so and opened all 27 with it in the sheet mask). Every transparent pattern
    /// Photoshop writes keeps it in the sheet mask array (slot 25) and leaves the user mask
    /// unwritten; `PSDPattern.writeBlock` does the same.
    public static let patternTransparencyInUserMask = PSDCompatibilityRule(rawValue: "patternTransparencyInUserMask")
    /// A `Patt`/`Pat2`/`Pat3` block whose pattern data does not parse: Photoshop cannot read it
    /// (not isolated by the oracle; a damaged copy of a block Photoshop parses generally makes
    /// the file unopenable). Photoshop's own empty pattern block has length 0. Bytes after the
    /// last pattern that are not padding only warn: Photoshop opened files ending in `01 02`.
    public static let patternDataUnreadable = PSDCompatibilityRule(rawValue: "patternDataUnreadable")
}

extension PSDFile {
    /// Checks the model against what Photoshop requires. `decodeChannels` also decodes every
    /// channel (slow on large files) to prove its data matches its rectangle.
    public func compatibilityIssues(decodeChannels: Bool = false) -> [PSDCompatibilityIssue] {
        var out: [PSDCompatibilityIssue] = []
        func err(_ m: String, _ l: Int? = nil) { out.append(PSDCompatibilityIssue(severity: .error, message: m, layerIndex: l)) }
        func warn(_ m: String, _ l: Int? = nil) { out.append(PSDCompatibilityIssue(severity: .warning, message: m, layerIndex: l)) }

        do { try validate() } catch { err("\(error)") }
        let h = header
        if h.depth == 32 {
            if !PSDHDRToning.isToningData(colorModeData) {
                out.append(PSDCompatibilityIssue(severity: .error,
                                                 message: "PHOTOSHOP REFUSES THE FILE: 32-bit file without HDR toning colour mode data (hdrt; Photoshop: \"the open options are incorrect\")",
                                                 rule: .hdrToningMissingAt32Bit))
            }
            if h.colorMode != .rgb, h.colorMode != .grayscale { err("Photoshop has no 32-bit \(h.colorMode) mode") }
        }
        if h.depth == 1, h.colorMode != .bitmap { err("1-bit depth is only valid in Bitmap mode") }
        if h.colorMode == .bitmap, h.depth != 1 { err("Bitmap mode requires 1-bit depth") }
        if case .unknown = h.colorMode { err("unknown colour mode \(h.colorMode.code)") }
        if let cc = colorChannelCount, Int(h.channels) < cc { err("merged image has \(h.channels) channels, \(h.colorMode) needs \(cc)") }
        if [.bitmap, .indexed, .multichannel].contains(h.colorMode), !layers.isEmpty {
            warn("Photoshop does not support layers in \(h.colorMode) mode")
        }
        if imageData.compression == .zip || imageData.compression == .zipPrediction {
            warn("merged image is ZIP-compressed; Photoshop writes raw or RLE merged data")
        }
        if case .unknown = imageData.compression { err("merged image uses unknown compression \(imageData.compression.code)") }
        if resource(PSDResourceID.versionInfo) == nil { warn("no version info resource (1057)") }

        // Layer info placement and padding.
        if let info = layerInfo {
            if info.layers.count > Int(Int16.max) { err("more than 32767 layers") }
            if h.depth != 8, case .section = layerInfoPlacement { warn("\(h.depth)-bit layers stored in the section; Photoshop uses an Lr\(h.depth) block") }
            if case let .globalBlock(index, _, key, _, _) = layerInfoPlacement,
               let matte = globalBlocks.indices.first(where: { ["Mtrn", "Mt16", "Mt32"].contains(globalBlocks[$0].key) }), matte >= index {
                out.append(PSDCompatibilityIssue(severity: .error,
                                                 message: "PHOTOSHOP REFUSES THE FILE: \(key) layer info is written before its \(globalBlocks[matte].key) matte block",
                                                 layerIndex: nil, rule: .layerInfoBeforeMatteBlock))
            }
            if h.depth == 8, case .globalBlock = layerInfoPlacement { warn("8-bit layers stored in a global block") }
            if let len = try? info.unpaddedLength(h.version) {
                let pad = info.padding?.count ?? Int(len % 2)
                if (len + UInt64(pad)) % 4 != 0 { warn("layer info not padded to a multiple of 4 (psd-tools misreads following blocks)") }
            }
        }

        // Group nesting must balance.
        var depth = 0
        for (i, rec) in layers.enumerated() {
            switch rec.sectionType {
            case .boundingDivider: depth += 1
            case .openFolder, .closedFolder:
                if depth == 0 { err("group folder without a bounding divider below it", i) } else { depth -= 1 }
            default: break
            }
        }
        if depth > 0 { err("\(depth) bounding divider(s) without a closing folder") }

        // Layerless modes (Bitmap, Indexed, Multichannel) are reported above; the blend table
        // applies to the modes that have layers.
        let hasLayers = ![.bitmap, .indexed, .multichannel].contains(h.colorMode)
        let maxDim = h.version == .psd ? Int64(PSDHeader.maxPSDDimension) : Int64(PSDHeader.maxDimension)
        let colorIDs = Set((0 ..< Int16(colorChannelCount ?? 0)).map { $0 })
        let linkedIDs = Self.linkedItemIDs(globalBlocks)
        for (i, rec) in layers.enumerated() {
            if rec.rect.width < 0 || rec.rect.height < 0 { err("negative layer rectangle \(rec.rect)", i) }
            if rec.rect.width > maxDim || rec.rect.height > maxDim { err("layer larger than the \(h.version) limit", i) }
            if case .unknown(let k) = rec.blendMode { warn("unknown blend mode key \(k)", i) }
            if hasLayers {
                let isGroup = rec.sectionType != .other
                var modes: [(PSDBlendMode, String)] = [(rec.blendMode, "")]
                if let b = rec.sectionDivider?.blendMode, b != rec.blendMode { modes.append((b, " (lsct)")) }
                for (mode, place) in modes {
                    if case .unknown = mode { continue }
                    if mode == .passThrough, !isGroup {
                        out.append(PSDCompatibilityIssue(severity: .error, message: "PHOTOSHOP RAISES A MODAL: pass-through blend mode on a layer that is not a group",
                                                         layerIndex: i, rule: .passThroughOnNonGroup))
                    } else if !PSDBlendMode.isAllowed(mode, mode: h.colorMode, depth: h.depth, isGroup: isGroup) {
                        out.append(PSDCompatibilityIssue(severity: .error,
                                                         message: "PHOTOSHOP REFUSES THE FILE: blend mode \(mode.key)\(place) is not available on \(isGroup ? "groups" : "layers") in \(h.colorMode) \(h.depth)-bit documents",
                                                         layerIndex: i, rule: .blendModeInvalidForDocument))
                    }
                }
            }
            if rec.block("luni") == nil, rec.name.contains(where: { $0 >= 0x80 }) {
                warn("non-ASCII legacy name without a luni block", i)
            }
            let ids = Set(rec.channels.map(\.id))
            if ids.count != rec.channels.count { err("duplicate channel ids", i) }
            if !rec.rect.isEmpty, rec.sectionType == .other, !colorIDs.isSubset(of: ids), rec.kind == .pixel {
                warn("missing colour channel(s) \(colorIDs.subtracting(ids).sorted())", i)
            }
            if ids.contains(PSDChannelID.userMask), rec.layerMask == nil, case .none = rec.mask { err("user mask channel without a mask record", i) }
            if ids.contains(PSDChannelID.realUserMask), rec.layerMask?.real == nil { err("real user mask channel without real-mask fields", i) }
            for c in rec.channels {
                if c.compression == nil, !c.data.isEmpty { warn("channel \(c.id) stored without a compression field", i) }
                if case .unknown(let v)? = c.compression { err("channel \(c.id) uses unknown compression \(v)", i) }
                if c.compression == .zip, h.depth == 32 { warn("channel \(c.id): ZIP at 32 bits — Photoshop reads it as ZIP with prediction", i) }
                if decodeChannels {
                    do { _ = try rec.decodeChannel(c.id, depth: h.depth, version: h.version) } catch { err("channel \(c.id) does not decode: \(error)", i) }
                }
            }
            for b in rec.blocks {
                do { try b.checkStructure() } catch {
                    if Self.placedLayerKeys.contains(b.key) {
                        out.append(PSDCompatibilityIssue(severity: .error, message: "PHOTOSHOP REFUSES THE FILE: \(b.key) placed-layer data does not parse (\(error))",
                                                         layerIndex: i, rule: .placedLayerDataUnreadable))
                    } else {
                        err("block \(b.key): \(error)", i)
                    }
                }
                if let issue = Self.fillOrVectorMaskIssue(b, layer: i) { out.append(issue) }
                if b.isForeignOrder { err("block \(b.key) is in little-endian layout (signature \(b.signature), kept from a TIFF): Photoshop cannot read it", i) }
                if b.data.count % 4 != 0 {
                    if b.key == "grdm" {
                        out.append(PSDCompatibilityIssue(severity: .error, message: "PHOTOSHOP REFUSES THE FILE: grdm block length \(b.data.count) is not a multiple of 4",
                                                         layerIndex: i, rule: .layerBlockNotFourAligned))
                    } else {
                        out.append(PSDCompatibilityIssue(severity: .warning, message: "layer block \(b.key) length \(b.data.count) is not a multiple of 4 (Photoshop 4-aligns every layer block)",
                                                         layerIndex: i, rule: .layerBlockNotFourAligned))
                    }
                }
            }
            if let tysh = rec.block("TySh") {
                do {
                    let tool = try PSDTypeTool(bytes: tysh.data)
                    let gaps = tool.photoshopStructureGaps()
                    let crashing = gaps.filter { $0.consequence == .crashesPhotoshop }.map(\.path)
                    let refusing = gaps.filter { $0.consequence == .photoshopRefusesFile }.map(\.path)
                    func list(_ p: [String]) -> String { p.prefix(6).joined(separator: ", ") + (p.count > 6 ? ", … (\(p.count) in all)" : "") }
                    if !crashing.isEmpty {
                        out.append(PSDCompatibilityIssue(severity: .error, message: "PHOTOSHOP CRASHES ON OPEN: type layer EngineData lacks required structures \(list(crashing))",
                                                         layerIndex: i, rule: .typeLayerEngineDataCrashesPhotoshop))
                    }
                    if !refusing.isEmpty {
                        out.append(PSDCompatibilityIssue(severity: .error, message: "PHOTOSHOP REFUSES THE FILE: type layer EngineData lacks font-set fields \(list(refusing))",
                                                         layerIndex: i, rule: .typeLayerEngineDataBlocksPhotoshop))
                    }
                    if let issue = Self.typeSizeIssue(tool, layer: i) { out.append(issue) }
                } catch {
                    out.append(PSDCompatibilityIssue(severity: .error, message: "type layer TySh does not parse: \(error)", layerIndex: i, rule: .typeLayerUnreadable))
                }
            }
            if let issue = Self.placedLayerLinkIssue(rec, linkedIDs: linkedIDs, layer: i) { out.append(issue) }
        }
        for b in globalBlocks {
            do { try b.checkStructure() } catch { err("global block \(b.key): \(error)") }
            if b.isForeignOrder { err("global block \(b.key) is in little-endian layout (signature \(b.signature), kept from a TIFF): Photoshop cannot read it") }
            if PSDPattern.blockKeys.contains(b.key), !b.isForeignOrder { out += Self.patternIssues(b) }
            if PSDFile.linkedFileKeys.contains(b.key), !b.isForeignOrder { out += Self.linkedFileKindIssues(b) }
        }
        if decodeChannels {
            do { _ = try decodeMerged() } catch { err("merged image does not decode: \(error)") }
        }
        return out
    }

    // MARK: Placed layers, linked files, fills and vector masks

    static let placedLayerKeys: Set<FourCC> = ["PlLd", "SoLd", "SoLE"]
    static let fillKeys: Set<FourCC> = ["SoCo", "GdFl", "PtFl"]

    /// The unique id of every linked-file item, read from its bytes whatever its kind (an item
    /// whose kind does not match its layout still names its source).
    static func linkedItemIDs(_ blocks: [PSDTaggedBlock]) -> Set<String> {
        var ids = Set<String>()
        for b in blocks where PSDFile.linkedFileKeys.contains(b.key) {
            guard let files = try? PSDLinkedFiles(bytes: b.data) else { continue }
            for item in files.items {
                let raw = [UInt8](item.raw)
                guard raw.count > 8, raw.count >= 9 + Int(raw[8]) else { continue }
                ids.insert(trimmedID(String(decoding: raw[9 ..< 9 + Int(raw[8])], as: UTF8.self)))
            }
        }
        return ids
    }

    static func trimmedID(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) }

    /// `placedLayerWithoutLinkedData` for one record.
    static func placedLayerLinkIssue(_ rec: PSDLayerRecord, linkedIDs: Set<String>, layer: Int) -> PSDCompatibilityIssue? {
        guard let b = rec.block("SoLd") ?? rec.block("SoLE"), let so = try? PSDPlacedLayerData(bytes: b.data),
              let uid = so.uniqueID.map(trimmedID), !linkedIDs.contains(uid) else { return nil }
        let keys = so.descriptor.descriptor.items.map { "\($0.key)" }
        guard Set(keys).isSubset(of: ["Idnt", "Trnf"]) else { return nil }
        return PSDCompatibilityIssue(severity: .error,
                                     message: "PHOTOSHOP REFUSES THE FILE: placed layer \"\(uid)\" has no linked-file item, and its \(b.key) holds only \(keys.joined(separator: " and ")) (Photoshop's carries the placement: Type, Sz, Rslt, placed, …)",
                                     layerIndex: layer, rule: .placedLayerWithoutLinkedData)
    }

    /// `linkedFileKindMismatch` for one linked-file block: each item that does not read strictly as
    /// its own kind but does as another.
    static func linkedFileKindIssues(_ b: PSDTaggedBlock) -> [PSDCompatibilityIssue] {
        guard let files = try? PSDLinkedFiles(bytes: b.data) else { return [] }
        var out: [PSDCompatibilityIssue] = []
        for (n, item) in files.items.enumerated() where item.strictInfo == nil && item.raw.count >= 4 {
            let own = String(decoding: item.raw.prefix(4), as: UTF8.self)
            for kind in ["liFD", "liFE", "liFA"] where kind != own {
                var raw = [UInt8](item.raw)
                raw.replaceSubrange(0 ..< 4, with: Array(kind.utf8))
                guard let info = PSDLinkedFile(raw: Data(raw)).strictInfo else { continue }
                out.append(PSDCompatibilityIssue(severity: .error,
                                                 message: "PHOTOSHOP REFUSES THE FILE: \(b.key) item \(n) (\"\(info.fileName)\") is labelled \(own) but laid out as \(kind)",
                                                 rule: .linkedFileKindMismatch))
                break
            }
        }
        return out
    }

    /// `fillLayerDataUnreadable` and `vectorMaskWithoutPaths` for one layer block.
    static func fillOrVectorMaskIssue(_ b: PSDTaggedBlock, layer: Int) -> PSDCompatibilityIssue? {
        if fillKeys.contains(b.key), b.data.isEmpty || (try? PSDFillSetting(key: b.key, bytes: b.data)) == nil {
            let what = b.data.isEmpty ? "is empty" : "does not parse"
            if b.key == "SoCo" {
                return PSDCompatibilityIssue(severity: .error, message: "PHOTOSHOP REFUSES THE FILE: SoCo fill-layer block \(what)",
                                             layerIndex: layer, rule: .fillLayerDataUnreadable)
            }
            return PSDCompatibilityIssue(severity: .warning, message: "\(b.key) fill-layer block \(what) (Photoshop refuses an unreadable SoCo; \(b.key) is not measured)",
                                         layerIndex: layer, rule: .fillLayerDataUnreadable)
        }
        if b.key == "vmsk" || b.key == "vsms", let m = try? PSDVectorMask(bytes: b.data), m.path.records.isEmpty {
            return PSDCompatibilityIssue(severity: .warning,
                                         message: "\(b.key) (version \(m.version), \(b.data.count) bytes) has no path records; Photoshop opens it and reads it as no vector mask, but never writes one",
                                         layerIndex: layer, rule: .vectorMaskWithoutPaths)
        }
        return nil
    }

    /// The type-size rule for one type layer: one issue listing its out-of-range values, an error
    /// when any is in a measured class.
    static func typeSizeIssue(_ t: PSDTypeTool, layer: Int) -> PSDCompatibilityIssue? {
        let v = t.typeSizeViolations()
        guard !v.isEmpty else { return nil }
        let list = v.prefix(4).map(\.what).joined(separator: "; ") + (v.count > 4 ? "; … (\(v.count) in all)" : "")
        if v.contains(where: \.measured) {
            return PSDCompatibilityIssue(severity: .error,
                                         message: "PHOTOSHOP RASTERIZES THE TYPE LAYER (the text is lost, possibly with a modal): \(list)",
                                         layerIndex: layer, rule: .typeSizeOutOfRange)
        }
        return PSDCompatibilityIssue(severity: .warning,
                                     message: "type layer outside Photoshop's documented limits (0.01–1,296 pt, transform ±300,000): \(list)",
                                     layerIndex: layer, rule: .typeSizeOutOfRange)
    }

    /// The pattern rules for one `Patt`/`Pat2`/`Pat3` block.
    static func patternIssues(_ b: PSDTaggedBlock) -> [PSDCompatibilityIssue] {
        let parsed: (patterns: [PSDPattern], strayTail: Int)
        do {
            parsed = try PSDPattern.parseBlockAndTail(b.data)
        } catch {
            return [PSDCompatibilityIssue(severity: .error, message: "\(b.key) pattern data does not parse (\(error)); Photoshop cannot read it",
                                          rule: .patternDataUnreadable)]
        }
        var out: [PSDCompatibilityIssue] = parsed.patterns.compactMap { p in
            guard let s = p.stored, s.writesUserMask else { return nil }
            let what = s.transparencySlot == s.slotCount ? "keeps its transparency in" : "writes"
            return PSDCompatibilityIssue(severity: .error,
                                         message: "PHOTOSHOP REFUSES THE FILE: \(b.key) pattern \"\(p.name)\" \(what) the user mask array (slot \(s.slotCount)); Photoshop stores transparency in the sheet mask array (slot \(s.slotCount + 1)) and leaves the user mask unwritten",
                                         rule: .patternTransparencyInUserMask)
        }
        if parsed.strayTail > 0 {
            out.append(PSDCompatibilityIssue(severity: .warning,
                                             message: "\(b.key): \(parsed.strayTail) bytes after the last pattern are not zero padding (Photoshop writes none, and ignores a tail shorter than a length word)"))
        }
        return out
    }
}
