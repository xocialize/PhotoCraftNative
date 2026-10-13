// Data-driven graphics: Image › Variables and Data Sets.
// Port of photocraft-doc (crates/doc/src/variables.rs), MIT OR Apache-2.0, © ArtCraft Team and
// the PhotoCraft contributors.
//
// A variable binds a named data slot to one layer, driving its visibility, its text, or its pixel
// content. A data set is a named row of values, one per variable. Applying a data set mutates the
// document so a single template renders many variations — ideal for batch generation
// (`file.export.dataSetsAsFiles`) and agents driving the CLI/MCP.
//
// Pure data (the model takes no I/O): loading a replacement image for a Pixel Replacement variable
// is the engine's job; here a data value just names the file.

/// All variable definitions and data sets for a document.
public struct Variables: Hashable, Sendable, Codable {
    /// Variable definitions, each bound to a layer.
    public var defs: [VariableDef] = []
    /// Named data sets (rows of values).
    public var dataSets: [DataSet] = []
    /// Index into `dataSets` of the data set applied last, if any.
    public var active: Int?

    public init(defs: [VariableDef] = [], dataSets: [DataSet] = [], active: Int? = nil) {
        self.defs = defs; self.dataSets = dataSets; self.active = active
    }

    /// True when there are no definitions or data sets.
    public var isEmpty: Bool { defs.isEmpty && dataSets.isEmpty }

    /// Find a definition by variable name.
    public func def(_ name: String) -> VariableDef? { defs.first { $0.name == name } }

    /// Find a data set by name.
    public func dataSet(_ name: String) -> DataSet? { dataSets.first { $0.name == name } }

    /// Index of a data set by name.
    public func dataSetIndex(_ name: String) -> Int? { dataSets.firstIndex { $0.name == name } }

    enum CodingKeys: String, CodingKey { case defs, dataSets = "data_sets", active }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defs = try c.decode(.defs, or: [])
        dataSets = try c.decode(.dataSets, or: [])
        active = try c.decodeIfPresent(Int.self, forKey: .active)
    }
}

/// One named variable bound to a layer.
public struct VariableDef: Hashable, Sendable, Codable {
    /// Unique variable name (matched by data-set values and CSV headers).
    public var name: String
    /// The layer this variable drives.
    public var layer: LayerId
    /// What it controls.
    public var kind: VarKind

    public init(name: String, layer: LayerId, kind: VarKind) { self.name = name; self.layer = layer; self.kind = kind }
}

/// The aspect of a layer a variable controls (Photoshop's three variable types).
/// JSON: internally tagged by `"type"` (`{"type":"pixelReplacement","method":"fill",…}`).
public enum VarKind: Hashable, Sendable, Codable {
    /// Show or hide the layer.
    case visibility
    /// Replace a text layer's string.
    case textReplacement
    /// Replace a pixel layer's content with an image file, scaled and aligned; `clip` clips the
    /// replacement to the original layer's bounds.
    case pixelReplacement(method: PixelMethod, align: PixelAlign, clip: Bool)

    enum CodingKeys: String, CodingKey { case type, method, align, clip }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "visibility": self = .visibility
        case "textReplacement": self = .textReplacement
        case "pixelReplacement":
            self = .pixelReplacement(method: try c.decode(.method, or: .fit), align: try c.decode(.align, or: .center), clip: try c.decode(.clip, or: false))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown variable type \(type)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .visibility: try c.encode("visibility", forKey: .type)
        case .textReplacement: try c.encode("textReplacement", forKey: .type)
        case .pixelReplacement(let method, let align, let clip):
            try c.encode("pixelReplacement", forKey: .type)
            try c.encode(method, forKey: .method)
            try c.encode(align, forKey: .align)
            try c.encode(clip, forKey: .clip)
        }
    }
}

/// How a replacement image is scaled into the layer bounds (Photoshop's "Method").
public enum PixelMethod: String, CaseIterable, Hashable, Sendable, Codable {
    /// Scale to fit inside the bounds, keeping aspect (default).
    case fit
    /// Scale to cover the bounds, keeping aspect.
    case fill
    /// Place at original size.
    case asIs
    /// Stretch to the bounds, ignoring aspect.
    case conform
}

/// Where a replacement image sits within the layer bounds.
public enum PixelAlign: String, CaseIterable, Hashable, Sendable, Codable {
    case topLeft, topCenter, topRight, centerLeft, center, centerRight, bottomLeft, bottomCenter, bottomRight
}

/// A named row of values, one per variable (keyed by variable name).
public struct DataSet: Hashable, Sendable, Codable {
    public var name: String
    /// Variable name → value. A variable with no entry keeps the document's current value.
    public var values: [DataValue]

    public init(name: String = "", values: [DataValue] = []) { self.name = name; self.values = values }

    /// The value for a variable in this data set, if present.
    public func get(_ variable: String) -> VariableValue? { values.first { $0.variable == variable }?.value }

    enum CodingKeys: String, CodingKey { case name, values }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        values = try c.decode(.values, or: [])
    }
}

/// One variable's value within a data set. JSON: `{"variable":…,"kind":…,"value":…}` (the
/// value's tag and content flattened in).
public struct DataValue: Hashable, Sendable, Codable {
    /// Which variable (by name).
    public var variable: String
    public var value: VariableValue

    public init(variable: String, value: VariableValue) { self.variable = variable; self.value = value }

    enum CodingKeys: String, CodingKey { case variable }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        variable = try c.decode(String.self, forKey: .variable)
        value = try VariableValue(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(variable, forKey: .variable)
        try value.encode(to: encoder)
    }
}

/// The payload of a `DataValue`, matched to the variable's `VarKind` (photocraft
/// `variables::Value`). JSON: adjacently tagged, `{"kind":"text","value":"Hello"}`.
public enum VariableValue: Hashable, Sendable, Codable {
    /// For a Visibility variable.
    case visibility(Bool)
    /// For a Text Replacement variable.
    case text(String)
    /// For a Pixel Replacement variable: a path to the replacement image.
    case pixels(String)

    enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "visibility": self = .visibility(try c.decode(Bool.self, forKey: .value))
        case "text": self = .text(try c.decode(String.self, forKey: .value))
        case "pixels": self = .pixels(try c.decode(String.self, forKey: .value))
        default: throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "unknown value kind \(kind)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .visibility(let b): try c.encode("visibility", forKey: .kind); try c.encode(b, forKey: .value)
        case .text(let s): try c.encode("text", forKey: .kind); try c.encode(s, forKey: .value)
        case .pixels(let s): try c.encode("pixels", forKey: .kind); try c.encode(s, forKey: .value)
        }
    }
}
