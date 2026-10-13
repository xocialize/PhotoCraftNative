// Port of photocraft-psd (crates/psd/src/io.rs `Reader`, `Reader::new_little`; layer.rs
// `real_before_parameters`, `mask_parameter_bytes`; tagged.rs `is_sig`), MIT OR Apache-2.0,
// © ArtCraft Team and the PhotoCraft contributors.
//
// What the layered-TIFF transcoder needs beyond PCPSD's public API: a bounds-checked cursor that
// reads either byte order (the transcoder walks little-endian structures), the foreign-order
// block markers and the byte-order-neutral mask-layout test. The big-endian tagged-block,
// layer-info and image-resource readers and writers are PCPSD's (`PSDTaggedBlock.readBlocks` /
// `serialize`, `PSDLayerInfo(body:version:)` / `serializedUnpaddedBody`,
// `PSDImageResource.readBlocks` / `serialize`).

import Foundation
import PCPSD

extension PSDTIFF {
    /// Readers and writers of the Photoshop structures inside the TIFF tags (internal).
    enum Records {
        // MARK: Cursor

        /// A bounds-checked cursor over `data[pos..<end]`, big- or little-endian (photocraft
        /// `Reader`, `Reader::new_little`).
        struct Cursor {
            let data: [UInt8]
            var pos: Int
            var end: Int
            var little: Bool

            init(_ data: [UInt8], little: Bool = false) {
                self.data = data
                pos = 0
                end = data.count
                self.little = little
            }

            init(_ data: [UInt8], from: Int, to: Int, little: Bool) {
                self.data = data
                pos = max(0, min(from, data.count))
                end = max(pos, min(to, data.count))
                self.little = little
            }

            var remaining: Int { end - pos }
            var isEmpty: Bool { pos >= end }

            /// The bytes left (photocraft `peek_rest`).
            var rest: ArraySlice<UInt8> { data[pos ..< end] }

            func need(_ n: Int) throws {
                if n < 0 { throw PSDError.invalid("negative length") }
                if n > remaining { throw PSDError.unexpectedEOF(offset: pos, needed: n - remaining) }
            }

            /// `count × minItemSize` bytes must remain (photocraft `check_count`).
            func checkCount(_ count: UInt64, _ minItemSize: UInt64) throws {
                let (need, overflow) = count.multipliedReportingOverflow(by: minItemSize)
                let have = UInt64(remaining)
                if overflow || need > have {
                    throw PSDError.unexpectedEOF(offset: pos, needed: Int(clamping: overflow ? UInt64.max : need - have))
                }
            }

            mutating func u8() throws -> UInt8 {
                try need(1)
                defer { pos += 1 }
                return data[pos]
            }

            mutating func u16() throws -> UInt16 {
                try need(2)
                defer { pos += 2 }
                let a = UInt16(data[pos]), b = UInt16(data[pos + 1])
                return little ? b << 8 | a : a << 8 | b
            }

            mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }

            mutating func u32() throws -> UInt32 {
                try need(4)
                defer { pos += 4 }
                var v: UInt32 = 0
                if little {
                    for i in (0 ..< 4).reversed() { v = v << 8 | UInt32(data[pos + i]) }
                } else {
                    for i in 0 ..< 4 { v = v << 8 | UInt32(data[pos + i]) }
                }
                return v
            }

            mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

            mutating func u64() throws -> UInt64 {
                try need(8)
                defer { pos += 8 }
                var v: UInt64 = 0
                if little {
                    for i in (0 ..< 8).reversed() { v = v << 8 | UInt64(data[pos + i]) }
                } else {
                    for i in 0 ..< 8 { v = v << 8 | UInt64(data[pos + i]) }
                }
                return v
            }

            mutating func f64() throws -> Double { Double(bitPattern: try u64()) }

            /// A 4- or 8-byte length field.
            mutating func lengthField(long: Bool) throws -> UInt64 { long ? try u64() : UInt64(try u32()) }

            /// A length from a (possibly 64-bit) field as a byte count that fits the data.
            func count(_ n: UInt64) throws -> Int {
                guard n <= UInt64(Int.max) else { throw PSDError.limitExceeded("length exceeds address space") }
                let k = Int(n)
                try need(k)
                return k
            }

            mutating func bytes(_ n: Int) throws -> ArraySlice<UInt8> {
                try need(n)
                defer { pos += n }
                return data[pos ..< pos + n]
            }

            mutating func bytes(u64 n: UInt64) throws -> ArraySlice<UInt8> { try bytes(try count(n)) }

            mutating func skip(_ n: Int) throws {
                try need(n)
                pos += n
            }

            mutating func fourCC() throws -> FourCC { FourCC(bytes: try bytes(4)) }

            /// A Pascal string whose total (length byte included) is padded to `align`.
            mutating func pascal(align: Int) throws -> [UInt8] {
                let n = Int(try u8())
                let s = Array(try bytes(n))
                let total = 1 + n
                try skip((align - total % align) % align)
                return s
            }

            mutating func rect() throws -> PSDRect {
                PSDRect(top: try i32(), left: try i32(), bottom: try i32(), right: try i32())
            }
        }

        // MARK: Tagged blocks

        static func isForeignMarker(_ v: UInt32) -> Bool {
            v == FourCC("MIB8").rawValue || v == FourCC("46B8").rawValue
        }

        static func defaultPadding(_ len: Int, _ alignment: Int) -> Int { (alignment - len % alignment) % alignment }

        // MARK: Layer info

        /// Bytes of a mask-parameters field for parameter flags `pf` (photocraft
        /// `mask_parameter_bytes`).
        static func maskParameterBytes(_ pf: UInt8) -> Int {
            (pf & 1 != 0 ? 1 : 0) + (pf & 2 != 0 ? 8 : 0) + (pf & 4 != 0 ? 1 : 0) + (pf & 8 != 0 ? 8 : 0)
        }

        /// Whether a mask record with parameters stores the real-mask fields before them, as
        /// Photoshop does (photocraft `LayerMask::real_before_parameters`, #949). Looks only at
        /// lengths and the parameter-flags byte, so it reads the same in either byte order.
        static func realBeforeParameters(_ d: ArraySlice<UInt8>) -> Bool {
            let d = Array(d)
            func fits(_ at: Int) -> Bool {
                guard at < d.count else { return false }
                let n = maskParameterBytes(d[at])
                return (at + 1 + n ... at + 4 + n).contains(d.count)
            }
            if fits(18) { return false }
            if !fits(36) { return false }
            let knownFlags = { (pf: UInt8) in pf & 0xF0 == 0 }
            let backgroundOK = { (at: Int) in at + 1 < d.count && (d[at + 1] == 0 || d[at + 1] == 255) }
            let photoshopPlausible = backgroundOK(18) && d.count > 36 && knownFlags(d[36])
            var specPlausible = false
            if d.count > 18 {
                let pf = d[18]
                let realAt = 19 + maskParameterBytes(pf)
                specPlausible = knownFlags(pf) && (realAt + 18 ... realAt + 21).contains(d.count) && backgroundOK(realAt)
            }
            return photoshopPlausible || !specPlausible
        }
    }
}
