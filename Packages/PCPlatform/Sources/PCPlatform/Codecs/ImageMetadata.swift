// Format-independent metadata carried from decode to encode.
// Replaces photocraft-codecs' `Metadata` (crates/codecs/src/image.rs) and its EXIF/XMP resolution and
// orientation readers (crates/codecs/src/{resolution,orientation,exif_color}.rs) with ImageIO's
// property dictionaries and `CGImageMetadata`. Port of its API shape, MIT OR Apache-2.0, © ArtCraft
// Team and the PhotoCraft contributors.
//
// photocraft keeps the raw EXIF TIFF block and the XMP packet as bytes. ImageIO exposes neither raw
// EXIF block, only parsed dictionaries ({Exif}, {TIFF}, {GPS}, {IPTC}, {PNG}, …) and the merged
// metadata tree (`CGImageMetadata`, whose XMP serialisation carries EXIF/IPTC mirrored as XMP). Both
// are stored here as bytes so the value stays `Sendable` and `Equatable`: the dictionaries as a binary
// property list, the tree as its XMP serialisation.

import Foundation
import ImageIO

/// Physical resolution in pixels per inch.
public struct Resolution: Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public static let screen = Resolution(x: 72, y: 72)
}

/// One free-form text entry (PNG tEXt/iTXt, TIFF ImageDescription…).
public struct TextEntry: Sendable, Equatable, Hashable {
    public var key: String
    public var value: String
    public init(key: String, value: String) { self.key = key; self.value = value }
}

public struct ImageMetadata: Sendable, Equatable {
    /// ImageIO's property dictionaries, binary property list (geometry keys removed).
    public var propertyList: Data?
    /// The full metadata tree (EXIF, IPTC, XMP) as an XMP packet.
    public var xmp: Data?
    public var resolution: Resolution?
    /// EXIF/TIFF orientation 1–8 of the stored pixels (1 after a decode that turned them upright).
    public var orientation: Int
    public var text: [TextEntry]

    public init(propertyList: Data? = nil, xmp: Data? = nil, resolution: Resolution? = nil, orientation: Int = 1, text: [TextEntry] = []) {
        self.propertyList = propertyList; self.xmp = xmp; self.resolution = resolution; self.orientation = orientation; self.text = text
    }

    public var isEmpty: Bool { propertyList == nil && xmp == nil && resolution == nil && text.isEmpty }

    /// Keys that describe pixel geometry and are recomputed on encode.
    static let geometryKeys: Set<String> = [
        kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth, kCGImagePropertyColorModel,
        kCGImagePropertyHasAlpha, kCGImagePropertyIsFloat, kCGImagePropertyIsIndexed, kCGImagePropertyOrientation,
        kCGImagePropertyProfileName, kCGImagePropertyFileSize, kCGImagePropertyPrimaryImage, kCGImagePropertyNamedColorSpace,
    ].map { $0 as String }.reduce(into: []) { $0.insert($1) }

    /// The ImageIO property dictionaries.
    public var properties: [String: Any] {
        guard let d = propertyList,
              let p = try? PropertyListSerialization.propertyList(from: d, options: [], format: nil) as? [String: Any] else { return [:] }
        return p
    }

    /// One property group (`"{Exif}"`, `"{TIFF}"`, `"{GPS}"`, `"{IPTC}"`, `"{PNG}"`, …).
    public func group(_ name: String) -> [String: Any] { properties[name] as? [String: Any] ?? [:] }

    /// The `{Exif}` dictionary.
    public var exif: [String: Any] { group(kCGImagePropertyExifDictionary as String) }

    /// An EXIF value by key (e.g. `"UserComment"`, `"DateTimeOriginal"`).
    public func exif(_ key: String) -> Any? { exif[key] }

    /// The metadata tree for writing.
    public var cgImageMetadata: CGImageMetadata? {
        xmp.flatMap { CGImageMetadataCreateFromXMPData($0 as CFData) }
    }

    /// The value at an XMP path such as `"dc:title"` or `"exif:UserComment"`.
    public func xmpValue(_ path: String) -> String? {
        guard let m = cgImageMetadata, let tag = CGImageMetadataCopyTagWithPath(m, nil, path as CFString) else { return nil }
        let v = CGImageMetadataTagCopyValue(tag)
        if let s = v as? String { return s }
        if let a = v as? [Any], let first = a.first {
            if let str = first as? String { return str }
            if CFGetTypeID(first as CFTypeRef) == CGImageMetadataTagGetTypeID() {
                return CGImageMetadataTagCopyValue(first as! CGImageMetadataTag) as? String
            }
            return nil
        }
        return v.map { "\($0)" }
    }

    static let pngTextKeys: Set<String> = Set([
        kCGImagePropertyPNGTitle, kCGImagePropertyPNGAuthor, kCGImagePropertyPNGDescription, kCGImagePropertyPNGCopyright,
        kCGImagePropertyPNGComment, kCGImagePropertyPNGSoftware, kCGImagePropertyPNGDisclaimer, kCGImagePropertyPNGWarning,
        kCGImagePropertyPNGSource, kCGImagePropertyPNGCreationTime,
    ].map { $0 as String })

    /// Reads metadata from an image source (photocraft's per-codec metadata readers).
    static func read(source: CGImageSource, index: Int) -> ImageMetadata {
        var m = ImageMetadata()
        let props = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]) ?? [:]
        m.orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        if let x = props[kCGImagePropertyDPIWidth as String] as? Double, let y = props[kCGImagePropertyDPIHeight as String] as? Double, x > 0, y > 0 {
            m.resolution = Resolution(x: x, y: y)
        }
        var kept = props.filter { !geometryKeys.contains($0.key) && $0.key != kCGImagePropertyDPIWidth as String && $0.key != kCGImagePropertyDPIHeight as String }
        // Free-form text.
        if let png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
            for k in [kCGImagePropertyPNGTitle, kCGImagePropertyPNGAuthor, kCGImagePropertyPNGDescription, kCGImagePropertyPNGCopyright,
                      kCGImagePropertyPNGComment, kCGImagePropertyPNGSoftware, kCGImagePropertyPNGDisclaimer, kCGImagePropertyPNGWarning,
                      kCGImagePropertyPNGSource, kCGImagePropertyPNGCreationTime] {
                if let v = png[k as String] as? String { m.text.append(TextEntry(key: k as String, value: v)) }
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            for k in [kCGImagePropertyTIFFImageDescription, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright, kCGImagePropertyTIFFSoftware] {
                if let v = tiff[k as String] as? String, !m.text.contains(where: { $0.value == v }) { m.text.append(TextEntry(key: k as String, value: v)) }
            }
        }
        // Drop per-frame animation timing and format-specific geometry from what is re-written.
        for g in [kCGImagePropertyGIFDictionary, kCGImagePropertyHEICSDictionary, kCGImagePropertyWebPDictionary] { kept.removeValue(forKey: g as String) }
        if !kept.isEmpty {
            m.propertyList = try? PropertyListSerialization.data(fromPropertyList: kept, format: .binary, options: 0)
        }
        if let tree = CGImageSourceCopyMetadataAtIndex(source, index, nil),
           let x = CGImageMetadataCreateXMPData(tree, nil) as Data? {
            m.xmp = x
        }
        return m
    }

    /// The property dictionary for a destination: the stored groups (EXIF, GPS, IPTC, TIFF text,
    /// PNG text) plus resolution and orientation.
    func destinationProperties(includeGroups: Bool) -> [String: Any] {
        var p: [String: Any] = [:]
        if includeGroups {
            for (k, v) in properties where k.hasPrefix("{") { p[k] = v }
            // ImageIO derives these from the pixels; stale copies confuse some writers.
            if var exif = p[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension as String)
                exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension as String)
                p[kCGImagePropertyExifDictionary as String] = exif
            }
            if !text.isEmpty {
                var png = p[kCGImagePropertyPNGDictionary as String] as? [String: Any] ?? [:]
                var tiff = p[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                for t in text {
                    if Self.pngTextKeys.contains(t.key) { png[t.key] = t.value } else { tiff[t.key] = t.value }
                }
                if !png.isEmpty { p[kCGImagePropertyPNGDictionary as String] = png }
                if !tiff.isEmpty { p[kCGImagePropertyTIFFDictionary as String] = tiff }
            }
        }
        if let r = resolution {
            p[kCGImagePropertyDPIWidth as String] = r.x
            p[kCGImagePropertyDPIHeight as String] = r.y
        }
        p[kCGImagePropertyOrientation as String] = orientation
        return p
    }
}
