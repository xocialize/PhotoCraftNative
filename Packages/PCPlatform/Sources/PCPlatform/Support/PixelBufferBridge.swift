// CVPixelBuffer → RasterBuffer, for the frames media-bridge's ImageBridge hands back.
// Part of PCPlatform's replacement of photocraft-codecs (crates/codecs) with native frameworks. Port of
// its API shape, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

import CoreVideo
import Foundation
import PCFoundation

enum PixelBufferBridge {
    /// A 32BGRA (premultiplied, as Core Image renders it) buffer as straight 8-bit RGBA.
    static func rgba8(_ pb: CVPixelBuffer) -> RasterBuffer {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), row = CVPixelBufferGetBytesPerRow(pb)
        var out = [UInt8](repeating: 0, count: w * h * 4)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return RasterBuffer(width: w, height: h, format: .rgba8, bytes: out) }
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let s = y * row + x * 4, d = (y * w + x) * 4
                let a = p[s + 3]
                func un(_ v: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (Int(v) * 255 + Int(a) / 2) / Int(a))) }
                out[d] = un(p[s + 2]); out[d + 1] = un(p[s + 1]); out[d + 2] = un(p[s]); out[d + 3] = a
            }
        }
        return RasterBuffer(width: w, height: h, format: .rgba8, bytes: out)
    }
}
