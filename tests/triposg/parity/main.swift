import Foundation

// The Swift TripoSG against PyTorch's, on what tests/triposg/make_reference.py saved.
//   parity <weights folder> <reference dir>
var failures = 0
func check(_ label: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "  PASS  \(label)" : "  FAIL  \(label)  \(detail)")
    if !ok { failures += 1 }
    fflush(stdout)
}
func load(_ dir: URL, _ name: String) -> [Float] {
    (try! Data(contentsOf: dir.appendingPathComponent(name))).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
}
func compare(_ a: [Float], _ b: [Float]) -> (maxAbs: Float, relative: Float) {
    var maxAbs: Float = 0, d2: Float = 0, r2: Float = 0
    for (x, y) in zip(a, b) { maxAbs = max(maxAbs, abs(x - y)); d2 += (x - y) * (x - y); r2 += y * y }
    return (maxAbs, (d2 / max(r2, 1e-20)).squareRoot())
}
var clock = Date()
func lap() -> String { defer { clock = Date() }; return String(format: "%.1f s", Date().timeIntervalSince(clock)) }

let args = CommandLine.arguments
let folder = URL(fileURLWithPath: args[1]), ref = URL(fileURLWithPath: args[2])
let model = try! TripoSGModel(folder: folder)
// The app's conversion makes the transformer's Linear weights int8, which
// moves the velocity about 1% further from torch's than float16 does (and
// leaves the shape as good); the other parts stay float16 either way.
let transformer = try! Safetensors(contentsOf: folder.appendingPathComponent("transformer/diffusion_pytorch_model.safetensors"))
let quantized = transformer.tensors.values.contains { $0.dtype == .int8 }
let velocityTolerance: Float = quantized ? 0.02 : 0.01
print("transformer weights: \(quantized ? "int8 in blocks, as the app converts them" : "float16 or float32")")

print("== DINOv2 ==")
_ = lap()
let embeds = try! model.imageEmbeddings(pixels: load(ref, "pixels.bin"))
let e = compare(embeds, load(ref, "embeds.bin"))
print(String(format: "  %@, max %.4f, relative %.5f", lap(), e.maxAbs, e.relative))
check("the picture's tokens match torch to 1%", e.relative < 0.01, "\(e.relative)")

print("== one step ==")
let flow = try! model.flow(embeds: load(ref, "embeds.bin"))
let sigmas = load(ref, "sigmas.bin")
let steps = sigmas.count - 1
check("the sigmas are torch's", compare(TripoSGModel.sigmas(steps: steps), sigmas).maxAbs < 1e-6)
_ = lap()
let v0 = flow.velocity(latents: load(ref, "noise0.bin"), sigma: sigmas[0], guidance: 7)
let v = compare(v0, load(ref, "velocity0.bin"))
print(String(format: "  first call (compiles) %@, max %.4f, relative %.5f", lap(), v.maxAbs, v.relative))
check("the guided velocity matches torch to \(Int(velocityTolerance * 100))%", v.relative < velocityTolerance, "\(v.relative)")

for (i, sigma) in [Float(0.55), 0.05].enumerated() {
    let probe = flow.velocity(latents: load(ref, "probe.bin"), sigma: sigma, guidance: 7)
    let p = compare(probe, load(ref, "velocity_probe\(i).bin"))
    print(String(format: "  sigma %.2f: max %.4f, relative %.5f", sigma, p.maxAbs, p.relative))
    check("the guided velocity at sigma \(sigma) matches torch to \(Int(velocityTolerance * 100))%", p.relative < velocityTolerance, "\(p.relative)")
}

print("== \(steps) steps ==")
// Sampling is a 20-step ODE with guidance 7: kernel-level differences grow
// along it (17% in float16, 6% even in float32, after every velocity above
// matched to 0.5%). What has to agree is the shape, so both sets of latents
// are decoded on a grid and their insides compared.
_ = lap()
let latents = flow.sample(noise: load(ref, "noise0.bin"), steps: steps, guidance: 7)
print(String(format: "  sampled in %@ (%.1f s a step)", lap(), Date().timeIntervalSince(clock)))
let l = compare(latents, load(ref, "latents.bin"))
print(String(format: "  latents differ by %.3f relative", l.relative))
let n = 40
var grid = [Float](); grid.reserveCapacity(n * n * n * 3)
for x in 0..<n { for y in 0..<n { for z in 0..<n {
    grid += [Float(x), Float(y), Float(z)].map { -0.95 + 1.9 * $0 / Float(n - 1) }
} } }
let ours = try! model.geometry(latents: latents).query(grid)
let theirs = try! model.geometry(latents: load(ref, "latents.bin")).query(grid)
var both = 0, either = 0
// The decoder's logits are positive outside.
for (a, b) in zip(ours, theirs) { if a < 0 && b < 0 { both += 1 }; if a < 0 || b < 0 { either += 1 } }
let iou = Double(both) / Double(max(either, 1))
print(String(format: "  inside: ours %d, torch's %d, IoU %.3f", ours.filter { $0 < 0 }.count, theirs.filter { $0 < 0 }.count, iou))
check("the sampled shape matches torch's (volume IoU over 0.9)", iou > 0.9, "\(iou)")

print("== decoder ==")
let geometry = try! model.geometry(latents: load(ref, "latents.bin"))
let k = compare(geometry.kv, load(ref, "kv.bin"))
print(String(format: "  latents self-attended %@, max %.4f, relative %.5f", lap(), k.maxAbs, k.relative))
check("the decoder's latents match torch to 1%", k.relative < 0.01, "\(k.relative)")
let logits = geometry.query(load(ref, "points.bin"))
let reference = load(ref, "logits.bin")
let q = compare(logits, reference)
var sameSign = 0
for (a, b) in zip(logits, reference) where (a > 0) == (b > 0) { sameSign += 1 }
print(String(format: "  4096 queries %@, max %.4f, relative %.5f, same sign %d", lap(), q.maxAbs, q.relative, sameSign))
check("the logits match torch to 1%", q.relative < 0.01, "\(q.relative)")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
