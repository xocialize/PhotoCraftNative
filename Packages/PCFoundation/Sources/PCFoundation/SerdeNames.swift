// Codable by name: the enums photocraft serialises with serde write their Rust variant names
// ("Rgb", "U16", "LinearDodge"), so JSON from either side decodes on the other. Raw values stay
// numeric for the shaders and PSD codes; only the Codable representation is the name.

/// An enum whose Codable form is its photocraft (Rust variant) name: the Swift case name with its
/// first letter upper-cased.
public protocol SerdeNamedEnum: CaseIterable, Codable {}

extension SerdeNamedEnum {
    public var serdeName: String {
        let s = String(describing: self)
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    public init(serdeName: String) throws {
        guard let v = Self.allCases.first(where: { $0.serdeName == serdeName }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "unknown \(Self.self) '\(serdeName)'"))
        }
        self = v
    }
}

extension SampleType: SerdeNamedEnum {
    public init(from decoder: any Decoder) throws { try self.init(serdeName: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(serdeName) }
}

extension ColorMode: SerdeNamedEnum {
    public init(from decoder: any Decoder) throws { try self.init(serdeName: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(serdeName) }
}

extension BlendMode: SerdeNamedEnum {
    public init(from decoder: any Decoder) throws { try self.init(serdeName: try decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(serdeName) }
}
