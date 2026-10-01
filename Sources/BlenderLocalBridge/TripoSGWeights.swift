import Foundation
import CryptoKit
import Accelerate
import Observation

/// TripoSG's weights: VAST-AI's three safetensors files, downloaded once from
/// the official Hugging Face repository (MIT licence) at a pinned revision and
/// kept on the device converted.
///
/// VAST-AI publishes float32, 7.95 GB. Each file is checked against the size
/// and SHA-256 Hugging Face publishes for that revision, then rewritten with
/// its large weights in float16 — what the network runs in anyway — and the
/// transformer's Linear weights int8 in blocks of 64, and the float32 file is
/// deleted. The model then takes 2.6 GB on the device, and a run peaks at
/// 2.5 GB of memory rather than 3.8 GB. The files live in Application
/// Support, left out of iCloud backups; `remove()` gives the space back.
@Observable
public final class TripoSGWeights: NSObject {

    public static let shared = TripoSGWeights()

    public struct File: Sendable {
        public let path: String
        public let byteCount: Int64
        public let sha256: String
    }

    public static let revision = "2c1c516d22d58db486a058d98d31bb6177344e06"
    /// Smallest first, so a failure shows early.
    public static let files: [File] = [
        File(path: "vae/diffusion_pytorch_model.safetensors", byteCount: 970_685_468,
             sha256: "a2e667c24927a5a35e5f19fcb4c75890e9399aa966b6db8131d7df733a750c8b"),
        File(path: "image_encoder_dinov2/model.safetensors", byteCount: 1_217_522_888,
             sha256: "399fba97a95f22c36834418bc69373364a99af3a1153da1c0fb31db567c92e23"),
        File(path: "transformer/diffusion_pytorch_model.safetensors", byteCount: 5_758_280_104,
             sha256: "9192b5923f7b605b394192809aa2ceb73bf0f4009674d8e3b999b45bb97d4bf2"),
    ]
    public static var downloadBytes: Int64 { files.reduce(0) { $0 + $1.byteCount } }
    /// On the device once converted.
    public static let storedBytes: Int64 = 2_617_623_772

    public static func source(_ file: File) -> URL {
        URL(string: "https://huggingface.co/VAST-AI/TripoSG/resolve/\(revision)/\(file.path)")!
    }

    public enum State: Equatable {
        case missing
        /// 0...1 of all three downloads, by bytes.
        case downloading(Double)
        /// Checking and converting file `index` of `files`.
        case preparing(Int)
        case ready
        case failed(String)
    }

    public private(set) var state: State = .missing

    /// VAST-AI's layout, which TripoSGModel(folder:) reads.
    public static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Models/TripoSG", isDirectory: true)
    }

    @ObservationIgnored private var session: URLSession?
    @ObservationIgnored private var task: URLSessionDownloadTask?
    @ObservationIgnored private var resumeData: Data?
    @ObservationIgnored private var current = 0
    /// Bytes of the files already in place when the current one started.
    @ObservationIgnored private var doneBytes: Int64 = 0

    public override init() {
        super.init()
        Self.removeTripoSR()
        refresh()
    }

    /// Build 35's full 3D model, which nothing uses since TripoSG replaced it.
    static func removeTripoSR() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let old = base.appendingPathComponent("Models/TripoSR", isDirectory: true)
        if FileManager.default.fileExists(atPath: old.path) { try? FileManager.default.removeItem(at: old) }
    }

    /// Whether `file` is in place, converted from the published file.
    static func isConverted(_ file: File, in folder: URL) -> Bool {
        let url = folder.appendingPathComponent(file.path)
        guard FileManager.default.fileExists(atPath: url.path),
              let converted = try? Safetensors(contentsOf: url) else { return false }
        return converted.metadata[sourceKey] == file.sha256 && converted.metadata[formatKey] == format
    }

    static let sourceKey = "converted_from_sha256"

    public func refresh() {
        switch state {
        case .downloading, .preparing: return
        default: break
        }
        state = Self.files.allSatisfy { Self.isConverted($0, in: Self.folder) } ? .ready : .missing
    }

    /// Free space needed from here: the float16 files still to make, and the
    /// largest download beside its conversion.
    public static func bytesNeeded(in folder: URL) -> Int64 {
        let missing = files.filter { !isConverted($0, in: folder) }
        let converted = missing.reduce(0) { $0 + $1.byteCount / 2 }
        let largest = missing.map(\.byteCount).max() ?? 0
        return missing.isEmpty ? 0 : converted + largest + 500_000_000
    }

    public static func hasRoom() -> Bool {
        let values = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free > bytesNeeded(in: folder)
    }

    public func download() {
        switch state {
        case .downloading, .preparing, .ready: return
        default: break
        }
        guard Self.hasRoom() else {
            let gigabytes = Double(Self.bytesNeeded(in: Self.folder)) / 1e9
            state = .failed(String(format: "Not enough free space: the model needs about %.0f GB free while it downloads.", gigabytes.rounded(.up)))
            return
        }
        next()
    }

    /// Starts the first file that is not in place yet, or finishes.
    private func next() {
        guard let index = Self.files.indices.first(where: { !Self.isConverted(Self.files[$0], in: Self.folder) }) else {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = Self.folder
            try? excluded.setResourceValues(values)
            state = .ready
            return
        }
        if index != current { resumeData = nil }
        current = index
        doneBytes = Self.files.indices.filter { $0 != index && Self.isConverted(Self.files[$0], in: Self.folder) }
            .reduce(Int64(0)) { $0 + Self.files[$1].byteCount }
        if session == nil {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForResource = 60 * 60 * 6
            configuration.waitsForConnectivity = true
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        }
        let task = resumeData.map { session!.downloadTask(withResumeData: $0) }
            ?? session!.downloadTask(with: Self.source(Self.files[index]))
        resumeData = nil
        self.task = task
        state = .downloading(progress(file: index, fraction: 0))
        task.resume()
    }

    private func progress(file index: Int, fraction: Double) -> Double {
        let now = Double(doneBytes) + fraction * Double(Self.files[index].byteCount)
        return min(max(now / Double(Self.downloadBytes), 0), 1)
    }

    public func cancel() {
        task?.cancel { [weak self] data in
            DispatchQueue.main.async {
                self?.resumeData = data
                self?.state = .missing
            }
        }
        task = nil
    }

    public func remove() {
        cancel()
        resumeData = nil
        session?.invalidateAndCancel()
        session = nil
        try? FileManager.default.removeItem(at: Self.folder)
        state = .missing
    }

    /// The file's SHA-256, read in 16 MB pieces.
    static func digest(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try autoreleasepool(invoking: { try handle.read(upToCount: 16 << 20) }), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// How files are converted; a file converted another way is converted
    /// again.
    static let format = "large weights f16, transformer Linear weights int8 in blocks of 64"
    static let formatKey = "conversion"

    /// Rewrites a float32 safetensors file as float16, one tensor at a time,
    /// recording the source's hash and the format so the result is known for
    /// what it is. With `quantize`, large Linear weights become int8 with a
    /// float16 scale per block of 64 along each row (`GraphWeights.scaleSuffix`),
    /// nearly halving them again.
    public static func convert(_ source: URL, to destination: URL, sourceSHA256: String, quantize: Bool = false) throws {
        let input = try Safetensors(contentsOf: source)
        func quantized(_ name: String) -> Bool {
            guard quantize, let t = input.tensors[name], t.dtype == .float32, t.shape.count == 2,
                  name.hasSuffix(".weight"), t.elementCount >= 1 << 16, t.shape[1] % quantizationBlock == 0 else { return false }
            // The flow's way in and out stay float16.
            return !(name.hasPrefix("proj_in.") || name.hasPrefix("proj_out.") || name.hasPrefix("time_proj."))
        }
        // Only the large weights are halved: norms, biases and position
        // tables are read exactly, and are a few megabytes.
        func halved(_ name: String) -> Bool {
            guard let t = input.tensors[name], t.dtype == .float32 else { return false }
            return name.hasSuffix(".weight") && t.shape.count >= 2 && t.elementCount >= 1 << 16
        }
        var entries: [(name: String, dtype: Safetensors.DType, shape: [Int])] = []
        for name in input.tensors.keys {
            let t = input.tensors[name]!
            if quantized(name) {
                entries.append((name, .int8, t.shape))
                entries.append((name + GraphWeights.scaleSuffix, .float16, [t.shape[0], t.shape[1] / quantizationBlock]))
            } else {
                entries.append((name, halved(name) ? .float16 : t.dtype, t.shape))
            }
        }
        entries.sort { $0.name < $1.name }
        let partial = destination.appendingPathExtension("partial")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: partial)
        try Safetensors.write(to: partial, entries: entries,
                              metadata: [sourceKey: sourceSHA256, formatKey: format]) { name in
            try autoreleasepool {
                if name.hasSuffix(GraphWeights.scaleSuffix) {
                    let weight = String(name.dropLast(GraphWeights.scaleSuffix.count))
                    if quantized(weight) { return half(blockQuantized(try input.bytes(weight)).scales) }
                }
                let bytes = try input.bytes(name)
                if quantized(name) { return blockQuantized(bytes).values }
                return halved(name) ? half(bytes) : bytes
            }
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: partial, to: destination)
    }

    /// Weights per int8 scale, along each row.
    static let quantizationBlock = 64

    /// Symmetric int8 in blocks along each row: each block's largest
    /// magnitude maps to 127. The scales come back as float32 bytes.
    static func blockQuantized(_ bytes: Data) -> (values: Data, scales: Data) {
        let count = bytes.count / 4, block = quantizationBlock, blocks = count / block
        var weights = [Float](repeating: 0, count: count)
        _ = weights.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        var values = Data(count: count)
        var scales = [Float](repeating: 0, count: blocks)
        values.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int8.self)
            weights.withUnsafeBufferPointer { w in
                for b in 0..<blocks {
                    let part = UnsafeBufferPointer(rebasing: w[(b * block)..<((b + 1) * block)])
                    let largest = vDSP.maximumMagnitude(part)
                    // Rounded to float16 first, so the int8 values fit the
                    // scale the network will actually multiply by.
                    let scale = largest > 0 ? Float(Float16(largest / 127)) : 1
                    scales[b] = scale
                    for c in 0..<block {
                        out[b * block + c] = Int8(max(-127, min(127, (part[c] / scale).rounded())))
                    }
                }
            }
        }
        return (values, scales.withUnsafeBufferPointer { Data(buffer: $0) })
    }

    /// Little-endian float32 to float16, clamped to float16's range.
    static func half(_ bytes: Data) -> Data {
        let count = bytes.count / 4
        var raw = [Float](repeating: 0, count: count)
        _ = raw.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
        let values = vDSP.clip(raw, to: -65504...65504)
        var out = Data(count: count * 2)
        values.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBytes { dst in
                var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress), height: 1,
                                      width: vImagePixelCount(count), rowBytes: count * 4)
                var d = vImage_Buffer(data: dst.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&s, &d, 0)
            }
        }
        return out
    }

    fileprivate func arrived(at temporary: URL) {
        let index = current
        let file = Self.files[index]
        let destination = Self.folder.appendingPathComponent(file.path)
        // The temporary file is deleted when the delegate call returns, so it
        // is moved first and checked afterwards.
        let staging = destination.appendingPathExtension("download")
        do {
            try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.moveItem(at: temporary, to: staging)
        } catch {
            state = .failed("Could not keep the download: \(error.localizedDescription)")
            return
        }
        state = .preparing(index)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var failure: String?
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value
                guard size == file.byteCount else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                        "A download was \(size ?? 0) bytes, not \(file.byteCount)."])
                }
                guard try Self.digest(of: staging) == file.sha256 else {
                    throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey:
                        "A download does not match the published checksum."])
                }
                try Self.convert(staging, to: destination, sourceSHA256: file.sha256,
                                 quantize: file.path.hasPrefix("transformer/"))
            } catch {
                failure = error.localizedDescription
            }
            try? FileManager.default.removeItem(at: staging)
            DispatchQueue.main.async {
                guard let self else { return }
                if let failure { self.state = .failed(failure) } else { self.next() }
            }
        }
    }
}

extension TripoSGWeights: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Self.files[current].byteCount
        let fraction = progress(file: current, fraction: Double(totalBytesWritten) / Double(expected))
        // Only when the displayed percentage would change.
        if case .downloading(let shown) = state, (fraction * 100).rounded() == (shown * 100).rounded() { return }
        state = .downloading(fraction)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            state = .failed("The server answered \(response.statusCode).")
            return
        }
        arrived(at: location)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled { return }
        resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        state = .failed("The download stopped: \(error.localizedDescription). Try again to resume it.")
    }
}
