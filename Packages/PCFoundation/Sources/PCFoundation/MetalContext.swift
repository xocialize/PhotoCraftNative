// The shared Metal context: one device, one command queue, cached libraries and pipelines, and the
// texture ⇄ FloatImage bridges every GPU module uses. Replaces photocraft-gpu's wgpu device setup
// (crates/gpu/src/lib.rs). Shaders are .metal files shipped as package resources and compiled at
// first use with `makeLibrary(source:)` (cached per key), so the same sources build under
// `swift build` and Xcode; foundation's shared MSL (PCBlend.metal: blend-mode maths matching
// `Blend`) is prepended on request.
//
// GPU maths vs the Swift references (measured by the ports): the GPU flushes subnormals to zero;
// MSL `fmod`, `atan2(y, ±0)` and fast `sqrt` are not libm-exact (use `precise::` where parity
// needs it); `.safe` math mode alone still fuses `a*b + c`, which is why PCBlend.metal sets
// `#pragma METAL fp contract(off)` for every library built here.

import Foundation
import Metal

public enum MetalContextError: Error, CustomStringConvertible {
    case noDevice
    case missingFunction(String)
    case commandBufferFailed(String)
    case unsupportedChannels(Int)

    public var description: String {
        switch self {
        case .noDevice: "no Metal device"
        case .missingFunction(let n): "Metal function '\(n)' not found"
        case .commandBufferFailed(let e): "command buffer failed: \(e)"
        case .unsupportedChannels(let c): "\(c)-channel images need splitting before upload"
        }
    }
}

public final class MetalContext: @unchecked Sendable {
    public let device: any MTLDevice
    public let queue: any MTLCommandQueue
    private let lock = NSLock()
    private var libraries: [String: any MTLLibrary] = [:]
    private var pipelines: [String: any MTLComputePipelineState] = [:]

    /// The process-wide context on the system default device (nil without Metal).
    public static let shared: MetalContext? = MetalContext()

    public init?(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) {
        guard let device, let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue
        queue.label = "PhotoCraftNative"
    }

    // MARK: Libraries and pipelines

    /// Concatenates every `.metal` file in `bundle`'s `subdirectory`, sorted by name.
    public static func shaderSource(bundle: Bundle, subdirectory: String = "Shaders") -> String {
        let urls = (bundle.urls(forResourcesWithExtension: "metal", subdirectory: subdirectory) ?? [])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return urls.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
    }

    /// Foundation's shared MSL: `#include <metal_stdlib>` plus the blend-mode maths (`pc_blend_*`).
    public static var foundationShaderSource: String { shaderSource(bundle: .module) }

    /// Compiles (once per key) a library from `source()`, with foundation's shared MSL first when
    /// `includeFoundation` is true.
    /// The default compile options: safe maths (no fast-math reassociation), MSL 3.2.
    public static func defaultCompileOptions() -> MTLCompileOptions {
        let options = MTLCompileOptions()
        options.mathMode = .safe   // parity with the CPU reference
        options.languageVersion = .version3_2
        return options
    }

    public func library(key: String, includeFoundation: Bool = true, options: MTLCompileOptions? = nil,
                        source: () -> String) throws -> any MTLLibrary {
        lock.lock(); defer { lock.unlock() }
        if let lib = libraries[key] { return lib }
        let src = (includeFoundation ? MetalContext.foundationShaderSource + "\n" : "") + source()
        let options = options ?? MetalContext.defaultCompileOptions()
        let lib = try device.makeLibrary(source: src, options: options)
        libraries[key] = lib
        return lib
    }

    /// The library built from `bundle`'s Shaders directory (plus foundation's shared MSL).
    public func library(bundle: Bundle, key: String) throws -> any MTLLibrary {
        try library(key: key) { MetalContext.shaderSource(bundle: bundle) }
    }

    /// A cached compute pipeline for `function` in `library`. Pass `constants` for function
    /// specialisation (the WGSL `override` equivalent); `constantsKey` must identify them.
    public func pipeline(_ function: String, in library: any MTLLibrary, constants: MTLFunctionConstantValues? = nil,
                         constantsKey: String = "") throws -> any MTLComputePipelineState {
        let key = "\(ObjectIdentifier(library as AnyObject)).\(function).\(constantsKey)"
        lock.lock(); defer { lock.unlock() }
        if let p = pipelines[key] { return p }
        let fn: (any MTLFunction)?
        if let constants { fn = try library.makeFunction(name: function, constantValues: constants) } else { fn = library.makeFunction(name: function) }
        guard let fn else { throw MetalContextError.missingFunction(function) }
        let p = try device.makeComputePipelineState(function: fn)
        pipelines[key] = p
        return p
    }

    // MARK: Dispatch

    /// Encodes `body` into one command buffer, commits it and waits; throws the GPU error, if any.
    public func run(label: String = "pc", _ body: (any MTLCommandBuffer) throws -> Void) throws {
        guard let cb = queue.makeCommandBuffer() else { throw MetalContextError.commandBufferFailed("makeCommandBuffer") }
        cb.label = label
        try body(cb)
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw MetalContextError.commandBufferFailed(e.localizedDescription) }
    }

    /// Dispatches `pipeline` over a width × height grid with 2D threadgroups sized from the pipeline.
    public static func dispatch2D(_ enc: any MTLComputeCommandEncoder, _ pipeline: any MTLComputePipelineState, width: Int, height: Int) {
        enc.setComputePipelineState(pipeline)
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        enc.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: min(h, 16), depth: 1))
    }

    // MARK: Textures

    public func makeTexture(width: Int, height: Int, pixelFormat: MTLPixelFormat = .rgba32Float,
                            usage: MTLTextureUsage = [.shaderRead, .shaderWrite],
                            storage: MTLStorageMode = .shared) -> (any MTLTexture)? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: max(1, width), height: max(1, height), mipmapped: false)
        d.usage = usage
        d.storageMode = storage
        return device.makeTexture(descriptor: d)
    }

    /// The float texture format holding `channels` channels (3 is padded to RGBA).
    public static func floatFormat(channels: Int) throws -> MTLPixelFormat {
        switch channels {
        case 1: .r32Float
        case 2: .rg32Float
        case 3, 4: .rgba32Float
        default: throw MetalContextError.unsupportedChannels(channels)
        }
    }

    /// Uploads a FloatImage (1–4 channels; 3 is padded with alpha 1) to a shared float texture.
    public func makeTexture(from image: FloatImage, usage: MTLTextureUsage = [.shaderRead, .shaderWrite]) throws -> any MTLTexture {
        let fmt = try MetalContext.floatFormat(channels: image.channels)
        guard let tex = makeTexture(width: image.width, height: image.height, pixelFormat: fmt, usage: usage) else {
            throw MetalContextError.commandBufferFailed("makeTexture \(image.width)×\(image.height)")
        }
        if image.rect.isEmpty { return tex }
        let texCh = image.channels == 3 ? 4 : image.channels
        var data = image.data
        if image.channels == 3 {
            data = [Float](repeating: 1, count: image.rect.area * 4)
            for i in 0..<image.rect.area { for k in 0..<3 { data[i * 4 + k] = image.data[i * 3 + k] } }
        }
        data.withUnsafeBytes { p in
            tex.replace(region: MTLRegionMake2D(0, 0, image.width, image.height), mipmapLevel: 0,
                        withBytes: p.baseAddress!, bytesPerRow: image.width * texCh * 4)
        }
        return tex
    }

    /// Reads a shared float texture back into a FloatImage at `rect` with `channels` channels
    /// (a 4-channel texture read as 3 drops alpha).
    public func readImage(_ tex: any MTLTexture, rect: PixelRect, channels: Int) -> FloatImage {
        let texCh: Int
        switch tex.pixelFormat {
        case .r32Float: texCh = 1
        case .rg32Float: texCh = 2
        default: texCh = 4
        }
        var raw = [Float](repeating: 0, count: rect.area * texCh)
        raw.withUnsafeMutableBytes { p in
            tex.getBytes(p.baseAddress!, bytesPerRow: rect.width * texCh * 4,
                         from: MTLRegionMake2D(0, 0, rect.width, rect.height), mipmapLevel: 0)
        }
        if texCh == channels { return FloatImage(rect: rect, channels: channels, data: raw) }
        var out = FloatImage(rect: rect, channels: channels)
        for i in 0..<rect.area { for k in 0..<min(channels, texCh) { out.data[i * channels + k] = raw[i * texCh + k] } }
        return out
    }
}
