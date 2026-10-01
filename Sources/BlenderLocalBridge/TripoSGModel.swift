import Foundation
import Metal
import MetalPerformanceShadersGraph

/// TripoSG — VAST-AI's image-to-shape model (MIT) — run with Metal, from the
/// safetensors files VAST-AI publishes.
///
/// TripoSG generates the shape rather than predicting it in one pass: a
/// 1.44 B-parameter transformer denoises 2048 latent tokens by rectified flow,
/// conditioned on DINOv2-large's reading of the picture, and a variational
/// decoder turns the latents into a field sharp enough for teeth, feathers and
/// fingers. What each part is, matching
/// github.com/VAST-AI-Research/TripoSG:
///
/// - the image encoder: DINOv2-large at 224², 257 tokens of 1024;
/// - the flow transformer: a timestep token and 2048 latent tokens of 2048,
///   21 blocks of self-attention, cross-attention to the picture and a GELU
///   feed-forward, with query and key RMS-normalised, and long skips from the
///   first ten blocks into the last ten;
/// - the sampler: Euler steps from sigma 1 to 0, with classifier-free
///   guidance against an all-zero picture;
/// - the decoder: the latents through 16 self-attention blocks once, then per
///   query point a frequency embedding cross-attending to them, to one logit.
///
/// One quirk is reproduced exactly: attention concatenates the query, key and
/// value projections before splitting them into heads, so each head's query,
/// key and value are drawn across all three projections.
///
/// Weights run in float16, norms in float32.
/// `scripts/run-triposg-parity.sh` checks the result against PyTorch.
public final class TripoSGModel {

    public enum Failure: Error, CustomStringConvertible {
        case noMetal, shape(String), files(String)
        public var description: String {
            switch self {
            case .noMetal: return "this device has no Metal GPU"
            case .shape(let what): return "unexpected shape: \(what)"
            case .files(let what): return "the TripoSG weights are not usable: \(what)"
            }
        }
    }

    public static let imageSize = 224
    public static let imageTokens = 257
    public static let latentTokens = 2048
    public static let latentChannels = 64
    /// The shape's bounds: the decoder is queried in [-bound, bound]³.
    public static let bound: Float = 1.005

    let device: MTLDevice
    let queue: MTLCommandQueue
    let encoderWeights: Safetensors
    let transformerWeights: Safetensors
    let vaeWeights: Safetensors

    /// `folder` holds VAST-AI's layout: image_encoder_dinov2/model.safetensors,
    /// transformer/diffusion_pytorch_model.safetensors and
    /// vae/diffusion_pytorch_model.safetensors, in float32 or float16.
    public init(folder: URL) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw Failure.noMetal
        }
        self.device = device
        self.queue = queue
        do {
            encoderWeights = try Safetensors(contentsOf: folder.appendingPathComponent("image_encoder_dinov2/model.safetensors"))
            transformerWeights = try Safetensors(contentsOf: folder.appendingPathComponent("transformer/diffusion_pytorch_model.safetensors"))
            vaeWeights = try Safetensors(contentsOf: folder.appendingPathComponent("vae/diffusion_pytorch_model.safetensors"))
        } catch {
            throw Failure.files("\(error)")
        }
    }

    // MARK: - The picture

    /// DINOv2-large's last hidden state: 257 × 1024. `pixels` is 3 × 224 × 224,
    /// normalised with ImageNet's statistics.
    public func imageEmbeddings(pixels: [Float]) throws -> [Float] {
        // Metal's objects are autoreleased: without a pool of its own, a
        // stage's weights and activations stay until the thread's pool
        // drains, and every stage piles on the last.
        try autoreleasepool { try embeddings(pixels) }
    }

    private func embeddings(_ pixels: [Float]) throws -> [Float] {
        let n = Self.imageSize
        guard pixels.count == 3 * n * n else { throw Failure.shape("pixels \(pixels.count)") }
        let graph = MPSGraph()
        let w = GraphWeights(graph: graph, device: device, sources: [encoderWeights])
        let image = graph.placeholder(shape: [1, 3, n as NSNumber, n as NSNumber], dataType: .float16, name: nil)
        let conv = MPSGraphConvolution2DOpDescriptor(
            strideInX: 14, strideInY: 14, dilationRateInX: 1, dilationRateInY: 1, groups: 1,
            paddingLeft: 0, paddingRight: 0, paddingTop: 0, paddingBottom: 0,
            paddingStyle: .explicit, dataLayout: .NCHW, weightsLayout: .OIHW)!
        let g = graph
        var x = g.convolution2D(image, weights: try w.half("embeddings.patch_embeddings.projection.weight"),
                                descriptor: conv, name: nil)
        x = g.addition(x, try w.half("embeddings.patch_embeddings.projection.bias", shape: [1, 1024, 1, 1]), name: nil)
        x = g.transposeTensor(g.reshape(x, shape: [1, 1024, 256], name: nil), dimension: 1, withDimension: 2, name: nil)
        x = g.concatTensors([try w.half("embeddings.cls_token"), x], dimension: 1, name: nil)
        // 37 × 37 positions resized to 16 × 16 by size, bicubic.
        let table = try w.floats("embeddings.position_embeddings")
        let positions = Self.bicubicPositions(table, dim: 1024, from: 37, to: 16, scale: 16.0 / 37.0)
        x = g.addition(x, try w.half(values: positions, shape: [1, 257, 1024]), name: nil)

        for layer in 0..<24 {
            let l = "encoder.layer.\(layer)."
            var h = try w.layerNorm(x, l + "norm1", eps: 1e-6)
            let q = Self.heads(g, try w.linear(h, l + "attention.attention.query"), batch: 1, heads: 16, size: 64)
            let k = Self.heads(g, try w.linear(h, l + "attention.attention.key"), batch: 1, heads: 16, size: 64)
            let v = Self.heads(g, try w.linear(h, l + "attention.attention.value"), batch: 1, heads: 16, size: 64)
            h = Self.merge(g, w.attention(query: q, key: k, value: v, headSize: 64), batch: 1, width: 1024)
            h = try w.linear(h, l + "attention.output.dense")
            h = g.multiplication(h, try w.half(l + "layer_scale1.lambda1"), name: nil)
            x = g.addition(x, h, name: nil)
            h = try w.layerNorm(x, l + "norm2", eps: 1e-6)
            h = try w.linear(w.gelu(try w.linear(h, l + "mlp.fc1")), l + "mlp.fc2")
            h = g.multiplication(h, try w.half(l + "layer_scale2.lambda1"), name: nil)
            x = g.addition(x, h, name: nil)
        }
        let out = g.cast(try w.layerNorm(x, "layernorm", eps: 1e-6), to: .float32, name: nil)
        let feed = GraphWeights.tensorData(device, pixels, shape: [1, 3, n, n], half: true)
        let result = w.run(queue, feeds: [image: feed], targets: [out])
        return GraphWeights.read(result[out]!, count: 257 * 1024)
    }

    // MARK: - The flow

    /// Rectified flow's sigmas for `steps`: 1 down to 1/steps, then 0.
    public static func sigmas(steps: Int) -> [Float] {
        (0..<steps).map { 1 - Float($0) / Float(steps) } + [0]
    }

    /// The transformer, built once and run per step.
    public final class Flow {
        let model: TripoSGModel
        let weights: GraphWeights
        let latents: MPSGraphTensor       // 1 × 2048 × 64, float32
        let timestep: MPSGraphTensor      // 1 × 1 × 2048 sinusoid, float32
        let guidance: MPSGraphTensor      // scalar, float32
        let velocity: MPSGraphTensor      // 1 × 2048 × 64, float32
        let context: MPSGraphTensorData   // the picture and the empty picture

        init(model: TripoSGModel, embeds: [Float], dataType: MPSDataType) throws {
            self.model = model
            let graph = MPSGraph()
            let w = GraphWeights(graph: graph, device: model.device, sources: [model.transformerWeights], dataType: dataType)
            weights = w
            let g = graph
            latents = g.placeholder(shape: [1, 2048, 64], dataType: .float32, name: nil)
            timestep = g.placeholder(shape: [1, 1, 2048], dataType: .float32, name: nil)
            guidance = g.placeholder(shape: [1], dataType: .float32, name: nil)
            let contextTensor = g.placeholder(shape: [2, 257, 1024], dataType: dataType, name: nil)

            // Batch of two: the empty picture first, then the picture.
            let doubled = g.cast(g.concatTensors([latents, latents], dimension: 0, name: nil), to: dataType, name: nil)
            var temb = try w.linear(g.cast(timestep, to: dataType, name: nil), "time_proj.linear_1")
            temb = try w.linear(w.gelu(temb), "time_proj.linear_2")
            temb = g.concatTensors([temb, temb], dimension: 0, name: nil)
            var x = g.concatTensors([temb, try w.linear(doubled, "proj_in")], dimension: 1, name: nil)   // 2 × 2049 × 2048

            var skips: [MPSGraphTensor] = []
            for layer in 0..<21 {
                let b = "blocks.\(layer)."
                if layer > 10 {
                    let skip = skips.removeLast()
                    x = try w.layerNorm(try w.linear(g.concatTensors([skip, x], dimension: 2, name: nil), b + "skip_linear"),
                                        b + "skip_norm", eps: 1e-5)
                }
                var h = try w.layerNorm(x, b + "norm1", eps: 1e-5)
                h = try TripoSGModel.selfAttention(w, h, batch: 2, prefix: b + "attn1", heads: 16, width: 2048, qkNorm: true)
                x = g.addition(x, h, name: nil)
                h = try w.layerNorm(x, b + "norm2", eps: 1e-5)
                h = try TripoSGModel.crossAttention(w, h, context: contextTensor, batch: 2, prefix: b + "attn2", heads: 16,
                                                     width: 2048, qkNorm: true, contextNorm: nil)
                x = g.addition(x, h, name: nil)
                h = try w.layerNorm(x, b + "norm3", eps: 1e-5)
                h = try w.linear(w.gelu(try w.linear(h, b + "ff.net.0.proj")), b + "ff.net.2")
                x = g.addition(x, h, name: nil)
                if layer < 10 { skips.append(x) }
            }
            x = try w.layerNorm(x, "norm_out", eps: 1e-5)
            x = g.sliceTensor(x, dimension: 1, start: 1, length: 2048, name: nil)
            x = g.cast(try w.linear(x, "proj_out"), to: .float32, name: nil)                 // 2 × 2048 × 64
            let parts = g.split(x, numSplits: 2, axis: 0, name: nil)
            velocity = g.addition(parts[0], g.multiplication(g.subtraction(parts[1], parts[0], name: nil), guidance, name: nil), name: nil)

            var both = [Float](repeating: 0, count: 257 * 1024)
            both += embeds
            context = GraphWeights.tensorData(model.device, both, shape: [2, 257, 1024], half: dataType == .float16)
            contextPlaceholder = contextTensor
        }
        let contextPlaceholder: MPSGraphTensor

        /// diffusers' `Timesteps(2048, flip_sin_to_cos=False, freq_shift=0)`.
        static func sinusoid(_ t: Float) -> [Float] {
            let half = 1024
            var out = [Float](repeating: 0, count: 2048)
            for i in 0..<half {
                let frequency = exp(-log(Float(10000)) * Float(i) / Float(half))
                out[i] = sin(t * frequency)
                out[half + i] = cos(t * frequency)
            }
            return out
        }

        /// The guided velocity at `sigma` for `latents` (2048 × 64).
        public func velocity(latents values: [Float], sigma: Float, guidance scale: Float) -> [Float] {
            autoreleasepool { guided(values, sigma: sigma, guidance: scale) }
        }

        private func guided(_ values: [Float], sigma: Float, guidance scale: Float) -> [Float] {
            let d = model.device
            let result = weights.run(model.queue, feeds: [
                latents: GraphWeights.tensorData(d, values, shape: [1, 2048, 64], half: false),
                timestep: GraphWeights.tensorData(d, Self.sinusoid(sigma * 1000), shape: [1, 1, 2048], half: false),
                guidance: GraphWeights.tensorData(d, [scale], shape: [1], half: false),
                contextPlaceholder: context,
            ], targets: [velocity])
            return GraphWeights.read(result[velocity]!, count: 2048 * 64)
        }

        /// Euler steps from `noise` to the shape's latents.
        public func sample(noise: [Float], steps: Int, guidance scale: Float = 7,
                           progress: ((Int) -> Void)? = nil) -> [Float] {
            let sigmas = TripoSGModel.sigmas(steps: steps)
            var x = noise
            for i in 0..<steps {
                let v = velocity(latents: x, sigma: sigmas[i], guidance: scale)
                let delta = sigmas[i] - sigmas[i + 1]
                for k in x.indices { x[k] += delta * v[k] }
                progress?(i + 1)
            }
            return x
        }
    }

    /// `dataType` float32 only to check against PyTorch: it doubles the
    /// transformer's memory to 5.8 GB.
    public func flow(embeds: [Float], dataType: MPSDataType = .float16) throws -> Flow {
        guard embeds.count == 257 * 1024 else { throw Failure.shape("embeds \(embeds.count)") }
        return try autoreleasepool { try Flow(model: self, embeds: embeds, dataType: dataType) }
    }

    /// Standard normal latents from a seed (SplitMix64 and Box–Muller), so a
    /// seed gives the same shape every time on every device.
    public static func noise(seed: UInt64) -> [Float] {
        var state = seed
        func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return (Double(z >> 11) + 0.5) / Double(1 << 53)
        }
        var out = [Float](repeating: 0, count: 2048 * 64)
        var i = 0
        while i < out.count {
            let u = next(), v = next()
            let r = (-2 * log(u)).squareRoot()
            out[i] = Float(r * cos(2 * .pi * v))
            if i + 1 < out.count { out[i + 1] = Float(r * sin(2 * .pi * v)) }
            i += 2
        }
        return out
    }

    // MARK: - The shape

    /// The decoder: the latents self-attended once, then queried at points.
    public final class Geometry {
        let model: TripoSGModel
        let weights: GraphWeights
        let points: MPSGraphTensor
        let logits: MPSGraphTensor
        let kvData: MPSGraphTensorData
        let kvPlaceholder: MPSGraphTensor
        public let chunk: Int
        /// The self-attended latents, 2048 × 1024, for checking.
        public let kv: [Float]

        init(model: TripoSGModel, latents: [Float], chunk: Int) throws {
            self.model = model
            self.chunk = chunk
            let d = model.device

            // Once: post_quant and the 16 self-attention blocks.
            do {
                let graph = MPSGraph()
                let w = GraphWeights(graph: graph, device: d, sources: [model.vaeWeights])
                let g = graph
                let input = g.placeholder(shape: [1, 2048, 64], dataType: .float16, name: nil)
                var x = try w.linear(input, "post_quant")
                for layer in 0..<16 {
                    let b = "decoder.blocks.\(layer)."
                    var h = try w.layerNorm(x, b + "norm1", eps: 1e-5)
                    h = try TripoSGModel.selfAttention(w, h, batch: 1, prefix: b + "attn1", heads: 8, width: 1024, qkNorm: false)
                    x = g.addition(x, h, name: nil)
                    h = try w.layerNorm(x, b + "norm3", eps: 1e-5)
                    h = try w.linear(w.gelu(try w.linear(h, b + "ff.net.0.proj")), b + "ff.net.2")
                    x = g.addition(x, h, name: nil)
                }
                let out = g.cast(x, to: .float32, name: nil)
                let result = w.run(model.queue, feeds: [input: GraphWeights.tensorData(d, latents, shape: [1, 2048, 64], half: true)],
                                   targets: [out])
                kv = GraphWeights.read(result[out]!, count: 2048 * 1024)
            }

            // Per chunk of points: the last block's cross-attention.
            let graph = MPSGraph()
            let w = GraphWeights(graph: graph, device: d, sources: [model.vaeWeights])
            weights = w
            let g = graph
            points = g.placeholder(shape: [chunk as NSNumber, 3], dataType: .float32, name: nil)
            kvPlaceholder = g.placeholder(shape: [1, 2048, 1024], dataType: .float16, name: nil)
            kvData = GraphWeights.tensorData(d, kv, shape: [1, 2048, 1024], half: true)

            // [x, sin(x · 2^k), cos(x · 2^k)] for k in 0..<8, per axis then per frequency.
            let frequencies = g.constant((0..<8).map { Float(1 << $0) }.withUnsafeBufferPointer { Data(buffer: $0) },
                                         shape: [1, 1, 8], dataType: .float32)
            let scaled = g.reshape(g.multiplication(g.expandDims(points, axis: 2, name: nil), frequencies, name: nil),
                                   shape: [chunk as NSNumber, 24], name: nil)
            let embedded = g.concatTensors([points, g.sin(with: scaled, name: nil), g.cos(with: scaled, name: nil)],
                                           dimension: 1, name: nil)
            let b = "decoder.blocks.16."
            var x = try w.linear(g.expandDims(g.cast(embedded, to: .float16, name: nil), axis: 0, name: nil), "decoder.proj_query")
            var h = try w.layerNorm(x, b + "norm2", eps: 1e-5)
            h = try TripoSGModel.crossAttention(w, h, context: kvPlaceholder, batch: 1, prefix: b + "attn2", heads: 8,
                                                 width: 1024, qkNorm: false, contextNorm: b + "attn2.norm_cross")
            x = g.addition(x, h, name: nil)
            h = try w.layerNorm(x, b + "norm3", eps: 1e-5)
            h = try w.linear(w.gelu(try w.linear(h, b + "ff.net.0.proj")), b + "ff.net.2")
            x = g.addition(x, h, name: nil)
            x = try w.layerNorm(x, "decoder.norm_out", eps: 1e-5)
            let raw = g.cast(try w.linear(x, "decoder.proj_out"), to: .float32, name: nil)
            logits = g.negative(with: g.reshape(raw, shape: [chunk as NSNumber], name: nil), name: nil)
        }

        /// The decoder's logits at `positions` (N × 3), in chunks. Positive is
        /// outside: TripoSG's decoder answers the negated projection.
        public func query(_ positions: [Float]) -> [Float] {
            let n = positions.count / 3
            var out = [Float](repeating: 0, count: n)
            var batch = [Float](repeating: 0, count: chunk * 3)
            var start = 0
            while start < n {
                let count = min(chunk, n - start)
                for k in 0..<(count * 3) { batch[k] = positions[start * 3 + k] }
                for k in (count * 3)..<(chunk * 3) { batch[k] = 0 }
                autoreleasepool {
                    let result = weights.run(model.queue, feeds: [
                        points: GraphWeights.tensorData(model.device, batch, shape: [chunk, 3], half: false),
                        kvPlaceholder: kvData,
                    ], targets: [logits])
                    let values = GraphWeights.read(result[logits]!, count: chunk)
                    for k in 0..<count { out[start + k] = values[k] }
                }
                start += count
            }
            return out
        }
    }

    public func geometry(latents: [Float], chunk: Int = 8192) throws -> Geometry {
        guard latents.count == 2048 * 64 else { throw Failure.shape("latents \(latents.count)") }
        return try autoreleasepool { try Geometry(model: self, latents: latents, chunk: chunk) }
    }

    /// A position table of `from` × `from` resized to `to` × `to` the way
    /// torch's bicubic interpolate does with `scale_factor` (a = -0.75, edges
    /// clamped), the class token's own entry kept first.
    static func bicubicPositions(_ table: [Float], dim: Int, from: Int, to: Int, scale: Double) -> [Float] {
        func cubic(_ t: Double) -> [Double] {
            let a = -0.75
            func near(_ x: Double) -> Double { ((a + 2) * x - (a + 3)) * x * x + 1 }
            func far(_ x: Double) -> Double { ((a * x - 5 * a) * x + 8 * a) * x - 4 * a }
            return [far(t + 1), near(t), near(1 - t), far(2 - t)]
        }
        var out = [Float](repeating: 0, count: (1 + to * to) * dim)
        for c in 0..<dim { out[c] = table[c] }                      // the class token's own
        var taps: [(index: [Int], weight: [Double])] = []
        for d in 0..<to {
            let real = (Double(d) + 0.5) / scale - 0.5
            let base = Int(real.rounded(.down))
            let weights = cubic(real - Double(base))
            taps.append(((-1...2).map { min(max(base + $0, 0), from - 1) }, weights))
        }
        for y in 0..<to {
            for x in 0..<to {
                let dst = (1 + y * to + x) * dim
                for (i, wy) in zip(taps[y].index, taps[y].weight) {
                    for (j, wx) in zip(taps[x].index, taps[x].weight) {
                        let src = (1 + i * from + j) * dim
                        let wgt = Float(wy * wx)
                        for c in 0..<dim { out[dst + c] += table[src + c] * wgt }
                    }
                }
            }
        }
        return out
    }

    // MARK: - Attention as TripoSG writes it

    /// Splits (batch, tokens, heads · size) into (batch, heads, tokens, size).
    static func heads(_ g: MPSGraph, _ x: MPSGraphTensor, batch: Int, heads: Int, size: Int) -> MPSGraphTensor {
        let r = g.reshape(x, shape: [batch as NSNumber, -1, heads as NSNumber, size as NSNumber], name: nil)
        return g.transposeTensor(r, dimension: 1, withDimension: 2, name: nil)
    }

    static func merge(_ g: MPSGraph, _ x: MPSGraphTensor, batch: Int, width: Int) -> MPSGraphTensor {
        g.reshape(g.transposeTensor(x, dimension: 1, withDimension: 2, name: nil),
                  shape: [batch as NSNumber, -1, width as NSNumber], name: nil)
    }

    /// Self-attention with query, key and value concatenated before the head
    /// split.
    static func selfAttention(_ w: GraphWeights, _ x: MPSGraphTensor, batch: Int, prefix: String, heads: Int, width: Int,
                              qkNorm: Bool) throws -> MPSGraphTensor {
        let g = w.graph
        let size = width / heads
        let qkv = g.concatTensors([try w.linear(x, prefix + ".to_q"), try w.linear(x, prefix + ".to_k"),
                                   try w.linear(x, prefix + ".to_v")], dimension: 2, name: nil)
        let grouped = g.reshape(qkv, shape: [batch as NSNumber, -1, heads as NSNumber, (3 * size) as NSNumber], name: nil)
        let parts = g.split(grouped, numSplits: 3, axis: 3, name: nil)
        var q = g.transposeTensor(parts[0], dimension: 1, withDimension: 2, name: nil)
        var k = g.transposeTensor(parts[1], dimension: 1, withDimension: 2, name: nil)
        let v = g.transposeTensor(parts[2], dimension: 1, withDimension: 2, name: nil)
        if qkNorm {
            q = try w.rmsNorm(q, prefix + ".norm_q", eps: 1e-6)
            k = try w.rmsNorm(k, prefix + ".norm_k", eps: 1e-6)
        }
        let y = merge(g, w.attention(query: q, key: k, value: v, headSize: size), batch: batch, width: width)
        return try w.linear(y, prefix + ".to_out.0")
    }

    /// Cross-attention with key and value concatenated before the head split.
    static func crossAttention(_ w: GraphWeights, _ x: MPSGraphTensor, context: MPSGraphTensor, batch: Int, prefix: String,
                               heads: Int, width: Int, qkNorm: Bool, contextNorm: String?) throws -> MPSGraphTensor {
        let g = w.graph
        let size = width / heads
        var c = context
        if let contextNorm { c = try w.layerNorm(c, contextNorm, eps: 1e-5) }
        var q = Self.heads(g, try w.linear(x, prefix + ".to_q"), batch: batch, heads: heads, size: size)
        let kv = g.concatTensors([try w.linear(c, prefix + ".to_k"), try w.linear(c, prefix + ".to_v")], dimension: 2, name: nil)
        let grouped = g.reshape(kv, shape: [batch as NSNumber, -1, heads as NSNumber, (2 * size) as NSNumber], name: nil)
        let parts = g.split(grouped, numSplits: 2, axis: 3, name: nil)
        var k = g.transposeTensor(parts[0], dimension: 1, withDimension: 2, name: nil)
        let v = g.transposeTensor(parts[1], dimension: 1, withDimension: 2, name: nil)
        if qkNorm {
            q = try w.rmsNorm(q, prefix + ".norm_q", eps: 1e-6)
            k = try w.rmsNorm(k, prefix + ".norm_k", eps: 1e-6)
        }
        let y = merge(g, w.attention(query: q, key: k, value: v, headSize: size), batch: batch, width: width)
        return try w.linear(y, prefix + ".to_out.0")
    }
}
