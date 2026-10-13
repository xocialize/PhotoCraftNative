// Lab / XYZ conversions, colour differences and black points.
// Replaces photocraft-cms (crates/cms/src/math.rs, `transform::black_point`) with ColorSync plus the
// CIE formulas. Port of its API shape, MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft
// contributors.

@preconcurrency import ColorSync
import Foundation
import PCFoundation

public enum ColorMath {
    /// The ICC PCS white (D50), as photocraft's `math::D50`.
    public static let d50 = SIMD3<Double>(0.9642, 1.0, 0.8249)

    /// CIE 1976 colour difference (photocraft `delta_e76`).
    public static func deltaE76(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d * d).sum().squareRoot()
    }

    /// CIEDE2000 colour difference (kL = kC = kH = 1).
    public static func deltaE2000(_ lab1: SIMD3<Double>, _ lab2: SIMD3<Double>) -> Double {
        let (l1, a1, b1) = (lab1.x, lab1.y, lab1.z), (l2, a2, b2) = (lab2.x, lab2.y, lab2.z)
        let c1 = (a1 * a1 + b1 * b1).squareRoot(), c2 = (a2 * a2 + b2 * b2).squareRoot()
        let cb = (c1 + c2) / 2
        let g = 0.5 * (1 - (pow(cb, 7) / (pow(cb, 7) + pow(25, 7))).squareRoot())
        let a1p = (1 + g) * a1, a2p = (1 + g) * a2
        let c1p = (a1p * a1p + b1 * b1).squareRoot(), c2p = (a2p * a2p + b2 * b2).squareRoot()
        func hue(_ b: Double, _ a: Double) -> Double {
            if a == 0 && b == 0 { return 0 }
            let h = atan2(b, a) * 180 / .pi
            return h < 0 ? h + 360 : h
        }
        let h1p = hue(b1, a1p), h2p = hue(b2, a2p)
        let dLp = l2 - l1, dCp = c2p - c1p
        var dhp = 0.0
        if c1p * c2p != 0 {
            dhp = h2p - h1p
            if dhp > 180 { dhp -= 360 } else if dhp < -180 { dhp += 360 }
        }
        let dHp = 2 * (c1p * c2p).squareRoot() * sin(dhp / 2 * .pi / 180)
        let lbp = (l1 + l2) / 2, cbp = (c1p + c2p) / 2
        var hbp = h1p + h2p
        if c1p * c2p != 0 {
            if abs(h1p - h2p) > 180 { hbp += (h1p + h2p < 360) ? 360 : -360 }
            hbp /= 2
        }
        let t = 1 - 0.17 * cos((hbp - 30) * .pi / 180) + 0.24 * cos(2 * hbp * .pi / 180)
            + 0.32 * cos((3 * hbp + 6) * .pi / 180) - 0.20 * cos((4 * hbp - 63) * .pi / 180)
        let dTheta = 30 * exp(-pow((hbp - 275) / 25, 2))
        let rc = 2 * (pow(cbp, 7) / (pow(cbp, 7) + pow(25, 7))).squareRoot()
        let sl = 1 + 0.015 * pow(lbp - 50, 2) / (20 + pow(lbp - 50, 2)).squareRoot()
        let sc = 1 + 0.045 * cbp, sh = 1 + 0.015 * cbp * t
        let rt = -sin(2 * dTheta * .pi / 180) * rc
        let x = dLp / sl, y = dCp / sc, z = dHp / sh
        return (x * x + y * y + z * z + rt * y * z).squareRoot()
    }

    /// XYZ → L*a*b* relative to `white` (photocraft `xyz_to_lab`).
    public static func xyzToLab(_ xyz: SIMD3<Double>, white: SIMD3<Double> = d50) -> SIMD3<Double> {
        let e = 216.0 / 24389.0, k = 24389.0 / 27.0
        func f(_ t: Double) -> Double { t > e ? cbrt(t) : (k * t + 16) / 116 }
        let r = xyz / white
        let (fx, fy, fz) = (f(r.x), f(r.y), f(r.z))
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// L*a*b* → XYZ relative to `white` (photocraft `lab_to_xyz`).
    public static func labToXYZ(_ lab: SIMD3<Double>, white: SIMD3<Double> = d50) -> SIMD3<Double> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        let e = 6.0 / 29.0
        func finv(_ t: Double) -> Double { t > e ? t * t * t : 3 * e * e * (t - 4.0 / 29.0) }
        return SIMD3(finv(fx), finv(fy), finv(fz)) * white
    }

    /// The Lab colour of `device` values in `profile` (exact, through ColorSync).
    public static func lab(_ device: [Float], in profile: ICCProfile, intent: RenderingIntent = .relativeColorimetric) throws -> SIMD3<Double> {
        let t = try ColorTransform.cached(source: profile, destination: BuiltinProfile.labD50.profile, options: .init(intent: intent))
        let o = t.eval(device)
        return LabEncoding.colorSync.decode(SIMD3(o[0], o[1], o[2]))
    }

    /// The device values of a Lab colour in `profile` (exact, through ColorSync).
    public static func device(fromLab lab: SIMD3<Double>, in profile: ICCProfile, intent: RenderingIntent = .relativeColorimetric,
                              blackPointCompensation: Bool = false) throws -> [Float] {
        let t = try ColorTransform.cached(source: BuiltinProfile.labD50.profile, destination: profile,
                                          options: .init(intent: intent, blackPointCompensation: blackPointCompensation))
        let e = LabEncoding.colorSync.encode(lab)
        return t.eval([e.x, e.y, e.z])
    }

    /// The D50 XYZ of `device` values in `profile` (through Lab, exact).
    public static func xyz(_ device: [Float], in profile: ICCProfile, intent: RenderingIntent = .relativeColorimetric) throws -> SIMD3<Double> {
        labToXYZ(try lab(device, in: profile, intent: intent))
    }

    /// The luminance Y of the profile's darkest colour for `intent` (photocraft `black_point`):
    /// the Lab black sent to the device and back, as a relative Y.
    public static func blackPoint(_ profile: ICCProfile, intent: RenderingIntent = .relativeColorimetric) throws -> Double {
        switch profile.colorSpace {
        case .lab, .xyz: return 0
        default: break
        }
        // v4 LUT profiles' perceptual/saturation tables are built to the ICC perceptual reference
        // medium, whose black is fixed (photocraft `PERCEPTUAL_BLACK`).
        if intent == .perceptual || intent == .saturation, profile.version.major >= 4, profile.tag("A2B0") != nil {
            return 0.0034731
        }
        let dev: [Float]
        switch profile.colorSpace {
        case .rgb, .gray: dev = [Float](repeating: 0, count: profile.channels)
        default:
            // Subtractive: the darkest reachable colour (Lab 0 through the colorimetric BToA).
            let colorimetric: RenderingIntent = intent == .saturation ? .saturation : .relativeColorimetric
            dev = try device(fromLab: SIMD3(0, 0, 0), in: profile, intent: colorimetric)
        }
        let l = try lab(dev, in: profile, intent: intent)
        return min(max(labToXYZ(SIMD3(l.x, 0, 0)).y, 0), 0.5)
    }
}
