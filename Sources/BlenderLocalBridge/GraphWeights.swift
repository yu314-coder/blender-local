import Foundation
import Metal
import MetalPerformanceShadersGraph
import Accelerate

/// Where a network's weights come from.
public protocol WeightSource {
    /// Shape, byte offset and type; nil when there is no such tensor.
    func locate(_ name: String) -> (shape: [Int], offset: Int, dtype: Safetensors.DType)?
    /// Copies `count` bytes from `offset` to `destination`.
    func read(offset: Int, count: Int, into destination: UnsafeMutableRawPointer) throws
}

extension Safetensors: WeightSource {
    public func locate(_ name: String) -> (shape: [Int], offset: Int, dtype: DType)? {
        guard let t = tensors[name], t.dtype != .bfloat16 else { return nil }
        return (t.shape, t.offset, t.dtype)
    }
}

/// A network's weights as MPSGraph placeholders, each fed from a shared Metal
/// buffer of float16 read straight from the file.
///
/// As graph constants the weights were held three times over — the float32
/// copy, the float16 copy, and the graph's own.
/// A buffer per weight is the only copy, freed with the graph.
public final class GraphWeights {
    public let graph: MPSGraph
    public let device: MTLDevice
    /// The type weights and activations run in: float16 normally; float32
    /// only to check a port against PyTorch, since it doubles the memory.
    public let dataType: MPSDataType
    let sources: [WeightSource]
    public private(set) var feeds: [MPSGraphTensor: MPSGraphTensorData] = [:]
    public private(set) var bytes = 0

    public enum Failure: Error, CustomStringConvertible {
        case missing(String), shape(String), memory(String), conversion
        public var description: String {
            switch self {
            case .missing(let name): return "the weights have no \(name)"
            case .shape(let what): return "unexpected shape: \(what)"
            case .memory(let name): return "no memory for \(name)"
            case .conversion: return "float16 conversion failed"
            }
        }
    }

    public init(graph: MPSGraph, device: MTLDevice, sources: [WeightSource], dataType: MPSDataType = .float16) {
        self.graph = graph; self.device = device; self.sources = sources; self.dataType = dataType
    }

    public func shape(_ name: String) throws -> [Int] {
        for s in sources { if let t = s.locate(name) { return t.shape } }
        throw Failure.missing(name)
    }

    public func has(_ name: String) -> Bool { sources.contains { $0.locate(name) != nil } }

    /// A tensor as float16, reshaped to `shape`; `transpose` swaps a matrix's
    /// rows and columns on the way (PyTorch's Linear weight is out × in).
    public func half(_ name: String, shape: [Int]? = nil, transpose: (rows: Int, columns: Int)? = nil) throws -> MPSGraphTensor {
        guard let (source, t) = sources.lazy.compactMap({ s in s.locate(name).map { (s, $0) } }).first else {
            throw Failure.missing(name)
        }
        let target = shape ?? t.shape
        let count = t.shape.reduce(1, *)
        guard count == target.reduce(1, *) else { throw Failure.shape("\(target) for \(name)") }
        if dataType == .float32 {
            var values = try floats(name)
            if let swap = transpose { values = Self.transposed(values, rows: swap.rows, columns: swap.columns) }
            return try half(values: values, shape: target)
        }
        guard let buffer = device.makeBuffer(length: count * 2, options: .storageModeShared) else {
            throw Failure.memory(name)
        }
        let to = buffer.contents()
        guard t.dtype != .int8 else { throw Failure.shape("\(name) is quantized; only Linear weights may be") }
        switch (t.dtype == .float16, transpose) {
        case (true, nil):
            try source.read(offset: t.offset, count: count * 2, into: to)
        case (false, nil):
            var values = [Float](repeating: 0, count: count)
            try values.withUnsafeMutableBytes { try source.read(offset: t.offset, count: count * 4, into: $0.baseAddress!) }
            try values.withUnsafeBufferPointer { try Self.toHalf($0.baseAddress!, to, count) }
        case (false, let swap?):
            var values = [Float](repeating: 0, count: count)
            try values.withUnsafeMutableBytes { try source.read(offset: t.offset, count: count * 4, into: $0.baseAddress!) }
            var swapped = [Float](repeating: 0, count: count)
            vDSP_mtrans(values, 1, &swapped, 1, vDSP_Length(swap.columns), vDSP_Length(swap.rows))
            try swapped.withUnsafeBufferPointer { try Self.toHalf($0.baseAddress!, to, count) }
        case (true, let swap?):
            var values = [UInt16](repeating: 0, count: count)
            try values.withUnsafeMutableBytes { try source.read(offset: t.offset, count: count * 2, into: $0.baseAddress!) }
            let out = to.assumingMemoryBound(to: UInt16.self)
            for r in 0..<swap.rows {
                for c in 0..<swap.columns { out[c * swap.rows + r] = values[r * swap.columns + c] }
            }
        }
        return feed(buffer, shape: target)
    }

    /// A Linear layer's weight, ready for `x · W` with x's features last.
    /// An int8 weight is kept int8, with a scale per block of each row, and
    /// dequantized in the graph as its layer runs.
    public func linearWeight(_ name: String) throws -> MPSGraphTensor {
        let s = try shape(name)
        guard let (source, t) = sources.lazy.compactMap({ src in src.locate(name).map { (src, $0) } }).first,
              t.dtype == .int8 else {
            return try half(name, shape: [s[1], s[0]], transpose: (s[0], s[1]))
        }
        let rows = s[0], columns = s[1]
        let scaleShape = try shape(name + Self.scaleSuffix)
        guard scaleShape.count == 2, scaleShape[0] == rows, scaleShape[1] > 0, columns % scaleShape[1] == 0 else {
            throw Failure.shape("\(scaleShape) scales for \(name)")
        }
        let blocks = scaleShape[1], block = columns / blocks
        guard let buffer = device.makeBuffer(length: rows * columns, options: .storageModeShared) else {
            throw Failure.memory(name)
        }
        try source.read(offset: t.offset, count: rows * columns, into: buffer.contents())
        let g = graph
        let quantized = feed(buffer, shape: [rows, columns], dataType: .int8)
        let scale = try half(name + Self.scaleSuffix, shape: [rows, blocks, 1])
        let blocked = g.reshape(g.cast(quantized, to: dataType, name: nil), shape: [rows, blocks, block].map { $0 as NSNumber }, name: nil)
        let weight = g.reshape(g.multiplication(blocked, scale, name: nil), shape: [rows as NSNumber, columns as NSNumber], name: nil)
        return g.transposeTensor(weight, dimension: 0, withDimension: 1, name: nil)
    }

    /// Beside an int8 weight (rows × columns): its scales, rows × blocks.
    public static let scaleSuffix = "_scale"

    /// Values computed here, as float16.
    public func half(values: [Float], shape: [Int]) throws -> MPSGraphTensor {
        guard values.count == shape.reduce(1, *) else { throw Failure.shape("\(shape) for \(values.count)") }
        let width = dataType == .float32 ? 4 : 2
        guard let buffer = device.makeBuffer(length: values.count * width, options: .storageModeShared) else {
            throw Failure.memory("values")
        }
        if dataType == .float32 {
            _ = values.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, values.count * 4) }
        } else {
            try values.withUnsafeBufferPointer { try Self.toHalf($0.baseAddress!, buffer.contents(), values.count) }
        }
        return feed(buffer, shape: shape)
    }

    static func transposed(_ values: [Float], rows: Int, columns: Int) -> [Float] {
        var out = [Float](repeating: 0, count: values.count)
        for r in 0..<rows { for c in 0..<columns { out[c * rows + r] = values[r * columns + c] } }
        return out
    }

    /// A tensor as float32 values, copied out: small ones (norms, biases,
    /// position tables) used on the CPU or as constants.
    public func floats(_ name: String) throws -> [Float] {
        guard let (source, t) = sources.lazy.compactMap({ s in s.locate(name).map { (s, $0) } }).first else {
            throw Failure.missing(name)
        }
        let count = t.shape.reduce(1, *)
        var out = [Float](repeating: 0, count: count)
        guard t.dtype != .int8 else { throw Failure.shape("\(name) is quantized") }
        if t.dtype == .float16 {
            var raw = [UInt16](repeating: 0, count: count)
            try raw.withUnsafeMutableBytes { try source.read(offset: t.offset, count: count * 2, into: $0.baseAddress!) }
            try raw.withUnsafeMutableBufferPointer { r in
                var src = vImage_Buffer(data: r.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                try out.withUnsafeMutableBufferPointer { o in
                    var dst = vImage_Buffer(data: o.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                    guard vImageConvert_Planar16FtoPlanarF(&src, &dst, 0) == kvImageNoError else { throw Failure.conversion }
                }
            }
        } else {
            try out.withUnsafeMutableBytes { try source.read(offset: t.offset, count: count * 4, into: $0.baseAddress!) }
        }
        return out
    }

    /// A float32 constant — for the norms' scales and offsets.
    public func full(_ name: String, shape: [Int]? = nil) throws -> MPSGraphTensor {
        let values = try floats(name)
        return graph.constant(values.withUnsafeBufferPointer { Data(buffer: $0) },
                              shape: (try shape ?? self.shape(name)).map { $0 as NSNumber }, dataType: .float32)
    }

    private func feed(_ buffer: MTLBuffer, shape: [Int], dataType type: MPSDataType? = nil) -> MPSGraphTensor {
        let numbers = shape.map { $0 as NSNumber }
        let placeholder = graph.placeholder(shape: numbers, dataType: type ?? dataType, name: nil)
        feeds[placeholder] = MPSGraphTensorData(buffer, shape: numbers, dataType: type ?? dataType)
        bytes += buffer.length
        return placeholder
    }

    static func toHalf(_ source: UnsafeRawPointer, _ destination: UnsafeMutableRawPointer, _ count: Int) throws {
        var from = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source), height: 1,
                                 width: vImagePixelCount(count), rowBytes: count * 4)
        var to = vImage_Buffer(data: destination, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
        guard vImageConvert_PlanarFtoPlanar16F(&from, &to, 0) == kvImageNoError else { throw Failure.conversion }
    }

    // MARK: Layers shared by the networks

    /// `x · Wᵀ + b` for a PyTorch Linear named `name`; x's features last.
    public func linear(_ x: MPSGraphTensor, _ name: String, bias: Bool = true) throws -> MPSGraphTensor {
        let g = graph
        var y = g.matrixMultiplication(primary: x, secondary: try linearWeight(name + ".weight"), name: nil)
        if bias, has(name + ".bias") {
            y = g.addition(y, try half(name + ".bias"), name: nil)
        }
        return y
    }

    /// LayerNorm over the last axis, computed in float32 (activations whose
    /// squares overflow float16 are common in these networks).
    public func layerNorm(_ x: MPSGraphTensor, _ name: String, eps: Double) throws -> MPSGraphTensor {
        let g = graph
        let x32 = g.cast(x, to: .float32, name: nil)
        let mean = g.mean(of: x32, axes: [-1], name: nil)
        let centred = g.subtraction(x32, mean, name: nil)
        let variance = g.mean(of: g.square(with: centred, name: nil), axes: [-1], name: nil)
        var y = g.division(centred, g.squareRoot(with: g.addition(variance, g.constant(eps, dataType: .float32), name: nil), name: nil), name: nil)
        y = g.multiplication(y, try full(name + ".weight"), name: nil)
        if has(name + ".bias") { y = g.addition(y, try full(name + ".bias"), name: nil) }
        return g.cast(y, to: dataType, name: nil)
    }

    /// RMSNorm over the last axis, in float32.
    public func rmsNorm(_ x: MPSGraphTensor, _ name: String, eps: Double) throws -> MPSGraphTensor {
        let g = graph
        let x32 = g.cast(x, to: .float32, name: nil)
        let meanSquare = g.mean(of: g.square(with: x32, name: nil), axes: [-1], name: nil)
        var y = g.division(x32, g.squareRoot(with: g.addition(meanSquare, g.constant(eps, dataType: .float32), name: nil), name: nil), name: nil)
        y = g.multiplication(y, try full(name + ".weight"), name: nil)
        return g.cast(y, to: dataType, name: nil)
    }

    /// GELU, exact (erf), in float32.
    public func gelu(_ x: MPSGraphTensor) -> MPSGraphTensor {
        let g = graph
        let x32 = g.cast(x, to: .float32, name: nil)
        let erf = g.erf(with: g.multiplication(x32, g.constant(1 / 2.squareRoot(), dataType: .float32), name: nil), name: nil)
        let y = g.multiplication(g.multiplication(x32, g.constant(0.5, dataType: .float32), name: nil),
                                 g.addition(erf, g.constant(1, dataType: .float32), name: nil), name: nil)
        return g.cast(y, to: dataType, name: nil)
    }

    /// Scaled dot-product attention over (batch, heads, tokens, head size).
    public func attention(query: MPSGraphTensor, key: MPSGraphTensor, value: MPSGraphTensor, headSize: Int) -> MPSGraphTensor {
        let g = graph
        let scale = 1 / Float(headSize).squareRoot()
        if #available(macOS 15.0, iOS 18.0, *) {
            return g.scaledDotProductAttention(query: query, key: key, value: value, scale: scale, name: nil)
        }
        let q32 = g.cast(query, to: .float32, name: nil), k32 = g.cast(key, to: .float32, name: nil)
        let logits = g.multiplication(g.matrixMultiplication(primary: q32, secondary: g.transposeTensor(k32, dimension: 2, withDimension: 3, name: nil), name: nil),
                                      g.constant(Double(scale), dataType: .float32), name: nil)
        let weights = g.cast(g.softMax(with: logits, axis: -1, name: nil), to: dataType, name: nil)
        return g.matrixMultiplication(primary: weights, secondary: value, name: nil)
    }

    /// Runs `graph` on the GPU with the weights fed, and waits. Optimisation
    /// level 0 keeps every operation on the GPU: at level 1 MPSGraph put parts
    /// of a placeholder-fed encoder on the Neural Engine, which asserted.
    public func run(_ queue: MTLCommandQueue, feeds extra: [MPSGraphTensor: MPSGraphTensorData],
                    targets: [MPSGraphTensor]) -> [MPSGraphTensor: MPSGraphTensorData] {
        var all = feeds
        for (k, v) in extra { all[k] = v }
        let execution = MPSGraphExecutionDescriptor()
        let compilation = MPSGraphCompilationDescriptor()
        compilation.optimizationLevel = .level0
        execution.compilationDescriptor = compilation
        execution.waitUntilCompleted = true
        return graph.runAsync(with: queue, feeds: all, targetTensors: targets, targetOperations: nil,
                              executionDescriptor: execution)
    }

    public static func read(_ data: MPSGraphTensorData, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        out.withUnsafeMutableBytes { data.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }
        return out
    }

    public static func tensorData(_ device: MTLDevice, _ values: [Float], shape: [Int], half: Bool) -> MPSGraphTensorData {
        let numbers = shape.map { $0 as NSNumber }
        if !half {
            return MPSGraphTensorData(device: MPSGraphDevice(mtlDevice: device),
                                      data: values.withUnsafeBufferPointer { Data(buffer: $0) },
                                      shape: numbers, dataType: .float32)
        }
        var dst = [UInt16](repeating: 0, count: values.count)
        values.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in _ = try? toHalf(s.baseAddress!, d.baseAddress!, values.count) }
        }
        return MPSGraphTensorData(device: MPSGraphDevice(mtlDevice: device),
                                  data: dst.withUnsafeBufferPointer { Data(buffer: $0) },
                                  shape: numbers, dataType: .float16)
    }
}
