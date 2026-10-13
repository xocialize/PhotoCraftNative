// Port of photocraft-color's `CmykSpace::for_profile` and photocraft-engine's `doc_cmyk_space`
// (crates/color/src/convert.rs, crates/engine/src/brush_cmds.rs), MIT OR Apache-2.0, © ArtCraft Team
// and the PhotoCraft contributors.
//
// A document's own CMYK profile for its strokes and paint commands. photocraft enters
// `with_cmyk_space(doc_cmyk_space(s), …)` around a stroke so the brush colour converts into the
// document's CMYK the way its profile says; here the same converter goes into PCFoundation's scoped
// slot (`ColorConvert.withCMYK`), which every CMYK conversion inside the command consults before
// the process-wide one. Converters are cached by profile bytes (photocraft caches by allocation).

import Foundation
import PCDocument
import PCFoundation
import PCPlatform
import Synchronization

public enum DocumentCMYK {
    /// Profile bytes → converter (nil: not a CMYK profile, or the built-in coated CMYK).
    private static let cache = Mutex<[Data: ColorSyncCMYKConverter?]>([:])

    /// The converter of `doc`'s embedded CMYK profile: nil when it has none, it isn't a CMYK
    /// profile, or it is the built-in coated CMYK (the process-wide converter already is).
    public static func converter(for doc: Document?) -> (any CMYKConverter)? {
        guard let bytes = doc?.iccProfile else { return nil }
        return converter(forProfile: bytes)
    }

    /// The converter of an embedded profile's bytes (PCIO's `CMYKConverterFactory`, so imports
    /// and exports of a CMYK document convert through its own profile too).
    public static func converter(forProfile bytes: [UInt8]) -> (any CMYKConverter)? {
        guard !bytes.isEmpty else { return nil }
        let data = Data(bytes)
        if let known = cache.withLock({ $0[data] }) { return known }
        var made: ColorSyncCMYKConverter?
        if let p = try? ColorCommands.profile(fromBytes: bytes), p.colorSpace == .cmyk, p != BuiltinProfile.coatedCMYK.profile {
            made = try? ColorSyncCMYKConverter(cmyk: p)
        }
        cache.withLock { c in
            if c.count > 16 { c.removeAll() }
            c[data] = made
        }
        return made
    }

    /// Runs `body` with `doc`'s CMYK profile as the scoped converter (photocraft
    /// `with_cmyk_space(doc_cmyk_space(s), …)`).
    public static func run<R>(_ doc: Document?, _ body: () throws -> R) rethrows -> R {
        try ColorConvert.withCMYK(converter(for: doc), body)
    }

    /// Commands that paint with a colour (`paint.*`: brush, pencil, mixer, colour replacement,
    /// erasers, bucket, gradient, stamps and healing) run inside the active document's CMYK space.
    static func scopes(_ command: String) -> Bool { command.hasPrefix("paint.") }
}
