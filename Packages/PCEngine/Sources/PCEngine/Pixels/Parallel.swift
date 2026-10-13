// Parallel loops over pixel buffers (photocraft uses rayon's par_iter for the same work), MIT OR Apache-2.0, © ArtCraft Team and the PhotoCraft contributors.

/// A mutable buffer shared by the iterations of a parallel loop that each write disjoint indices.
public struct SendableBuffer<T>: @unchecked Sendable {
    public let base: UnsafeMutableBufferPointer<T>
    public init(_ base: UnsafeMutableBufferPointer<T>) { self.base = base }
    @inline(__always) public subscript(i: Int) -> T {
        get { base[i] }
        nonmutating set { base[i] = newValue }
    }
    public var count: Int { base.count }
}
