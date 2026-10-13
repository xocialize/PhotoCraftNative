// Port of photocraft-algo (crates/algo/src/lib.rs, other.rs), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.
//
// Parameter enums shared by several filter areas.

import PCFoundation

/// How pixels uncovered by a displacement are filled (photocraft `UndefinedAreas`).
public enum UndefinedAreas: String, Codable, Sendable, Hashable, CaseIterable {
    case wrap, `repeat`, transparent

    /// The `EdgeMode` sampling uses (photocraft `other::edge_of`).
    public var edge: EdgeMode {
        switch self { case .wrap: .wrap; case .repeat: .repeatEdge; case .transparent: .transparent }
    }
    /// MSL `PCA_EDGE_*`.
    public var gpuEdge: UInt32 {
        switch self { case .transparent: 0; case .repeat: 1; case .wrap: 2 }
    }
}
