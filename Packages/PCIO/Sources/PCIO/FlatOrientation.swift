// Turning a decoded flat image upright by its stored EXIF/TIFF orientation, like Photoshop: the
// pixels are re-ordered (width and height swap for 5–8, as does the resolution) and the EXIF and
// XMP orientation are rewritten to 1 so the result is not rotated again on display or export.
// Port of photocraft-codecs (crates/codecs/src/orientation.rs `Image::oriented`, `walk`),
// MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import PCDocument
import PCFoundation
import PCIOCore

public enum FlatOrientation {
    /// The source pixel of output pixel (x, y) for orientation `o` of a `w`×`h` image.
    @inline(__always)
    static func source(_ o: Int, _ x: Int, _ y: Int, _ w: Int, _ h: Int) -> (Int, Int) {
        switch o {
        case 2: (w - 1 - x, y)
        case 3: (w - 1 - x, h - 1 - y)
        case 4: (x, h - 1 - y)
        case 5: (y, x)
        case 6: (y, h - 1 - x)
        case 7: (w - 1 - y, h - 1 - x)
        case 8: (w - 1 - y, x)
        default: (x, y)
        }
    }

    /// `img` turned upright (`orientation` 1); unchanged for orientation 1 or out of range.
    public static func upright(_ img: DecodedImage) -> DecodedImage {
        let o = img.orientation
        guard (2 ... 8).contains(o), img.width > 0, img.height > 0 else { return img }
        let (w, h) = (img.width, img.height)
        let swap = o >= 5
        let (ow, oh) = swap ? (h, w) : (w, h)
        let fmt = img.surface.format
        let ch = fmt.channels
        let src = img.surface.readRegion(PixelRect(x0: 0, y0: 0, x1: Int32(w), y1: Int32(h)))
        var out = Surface(format: fmt)
        // A band of output rows at a time.
        let band = max(1, (16 << 20) / max(1, ow * ch * 4))
        var y0 = 0
        while y0 < oh {
            let y1 = min(oh, y0 + band)
            var vals = [Float](repeating: 0, count: (y1 - y0) * ow * ch)
            var k = 0
            for y in y0 ..< y1 {
                for x in 0 ..< ow {
                    let (sx, sy) = source(o, x, y, w, h)
                    let at = (sy * w + sx) * ch
                    for c in 0 ..< ch { vals[k + c] = src[at + c] }
                    k += ch
                }
            }
            out.writeRegion(PixelRect(x0: 0, y0: Int32(y0), x1: Int32(ow), y1: Int32(y1)), vals)
            y0 = y1
        }
        out.prune()
        var r = img
        r.surface = out
        r.width = ow
        r.height = oh
        r.orientation = 1
        if let e = img.exif, let fixed = MetadataExport.uprightExif(e) { r.exif = fixed }
        if let x = img.xmp, let fixed = MetadataExport.uprightXmp(x) { r.xmp = fixed }
        if swap { r.dpi = img.dpi.map { ($0.y, $0.x) } }
        return r
    }
}
