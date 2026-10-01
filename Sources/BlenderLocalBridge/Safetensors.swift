import Foundation

/// The tensors in a `.safetensors` file.
///
/// The format is an 8-byte little-endian header length, a JSON header naming
/// each tensor's dtype, shape and byte range after the header, then the raw
/// bytes. Opening a file reads only the header; tensors are read when asked
/// for, straight into the caller's memory. Nothing is memory-mapped: a
/// mapping of a multi-gigabyte file beside the Metal buffers made from it
/// would ask an iPad for twice the address space.
public final class Safetensors {

    public enum DType: String, Sendable {
        case float32 = "F32", float16 = "F16", bfloat16 = "BF16", int8 = "I8"
        public var byteCount: Int {
            switch self {
            case .float32: return 4
            case .float16, .bfloat16: return 2
            case .int8: return 1
            }
        }
    }

    public struct Tensor: Sendable {
        public let dtype: DType
        public let shape: [Int]
        /// Byte range in the file.
        public let offset: Int
        public let count: Int
        public var elementCount: Int { shape.reduce(1, *) }
    }

    public enum Failure: Error, CustomStringConvertible {
        case header(String), missing(String), unsupported(String), read(String)
        public var description: String {
            switch self {
            case .header(let why): return "not a safetensors file: \(why)"
            case .missing(let name): return "no tensor \(name)"
            case .unsupported(let what): return "unsupported tensor: \(what)"
            case .read(let why): return "could not read the tensors: \(why)"
            }
        }
    }

    private enum Storage {
        case memory(Data)
        case file(FileHandle)
    }

    private let storage: Storage
    public let tensors: [String: Tensor]
    /// `__metadata__`, if the file has any.
    public let metadata: [String: String]

    public convenience init(contentsOf url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        let size = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)
        guard size >= 8, let prefix = try handle.read(upToCount: 8), prefix.count == 8 else {
            throw Failure.header("too short")
        }
        let length = Self.headerLength(prefix)
        guard length > 0, 8 + length <= size, let json = try handle.read(upToCount: length), json.count == length else {
            throw Failure.header("header length \(length)")
        }
        try self.init(storage: .file(handle), header: json, size: size)
    }

    public convenience init(data: Data) throws {
        guard data.count >= 8 else { throw Failure.header("too short") }
        let length = Self.headerLength(data.prefix(8))
        guard length > 0, 8 + length <= data.count else { throw Failure.header("header length \(length)") }
        let json = data.subdata(in: (data.startIndex + 8)..<(data.startIndex + 8 + length))
        try self.init(storage: .memory(data), header: json, size: data.count)
    }

    private static func headerLength(_ prefix: Data) -> Int {
        var length = 0
        for (k, byte) in prefix.prefix(8).enumerated() { length |= Int(byte) << (8 * k) }
        return length
    }

    private init(storage: Storage, header json: Data, size: Int) throws {
        guard let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw Failure.header("the header is not an object")
        }
        var tensors: [String: Tensor] = [:]
        var metadata: [String: String] = [:]
        let base = 8 + json.count
        for (name, value) in object {
            if name == "__metadata__" {
                metadata = value as? [String: String] ?? [:]
                continue
            }
            guard let entry = value as? [String: Any],
                  let dtypeName = entry["dtype"] as? String,
                  let shape = entry["shape"] as? [Int],
                  let range = entry["data_offsets"] as? [Int], range.count == 2 else {
                throw Failure.header("entry \(name)")
            }
            guard let dtype = DType(rawValue: dtypeName) else {
                throw Failure.unsupported("\(name) is \(dtypeName)")
            }
            let count = range[1] - range[0]
            guard count == shape.reduce(1, *) * dtype.byteCount, base + range[1] <= size else {
                throw Failure.header("\(name)'s byte range")
            }
            tensors[name] = Tensor(dtype: dtype, shape: shape, offset: base + range[0], count: count)
        }
        self.storage = storage
        self.tensors = tensors
        self.metadata = metadata
    }

    deinit {
        if case .file(let handle) = storage { try? handle.close() }
    }

    /// Copies `count` bytes from `offset` in the file to `destination`.
    public func read(offset: Int, count: Int, into destination: UnsafeMutableRawPointer) throws {
        switch storage {
        case .memory(let data):
            data.withUnsafeBytes { raw in _ = memcpy(destination, raw.baseAddress! + offset, count) }
        case .file(let handle):
            var done = 0
            while done < count {
                let n = pread(handle.fileDescriptor, destination + done, count - done, off_t(offset + done))
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw Failure.read(n == 0 ? "the file ended early" : String(cString: strerror(errno))) }
                done += n
            }
        }
    }

    /// A tensor's raw bytes.
    public func bytes(_ name: String) throws -> Data {
        guard let t = tensors[name] else { throw Failure.missing(name) }
        var out = Data(count: t.count)
        try out.withUnsafeMutableBytes { try read(offset: t.offset, count: t.count, into: $0.baseAddress!) }
        return out
    }

    /// Writes `tensors` (name → dtype, shape, bytes) as a safetensors file,
    /// in name order, one at a time from `bytes` so a large file is never
    /// held whole in memory.
    public static func write(to url: URL, entries: [(name: String, dtype: DType, shape: [Int])],
                             metadata: [String: String] = [:],
                             bytes: (String) throws -> Data) throws {
        var header: [String: Any] = [:]
        if !metadata.isEmpty { header["__metadata__"] = metadata }
        var offset = 0
        for entry in entries {
            let count = entry.shape.reduce(1, *) * entry.dtype.byteCount
            header[entry.name] = ["dtype": entry.dtype.rawValue, "shape": entry.shape, "data_offsets": [offset, offset + count]]
            offset += count
        }
        var json = try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        // Padded with spaces to a multiple of 8, as the reference writer does.
        while json.count % 8 != 0 { json.append(0x20) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var length = UInt64(json.count).littleEndian
        try handle.write(contentsOf: Data(bytes: &length, count: 8))
        try handle.write(contentsOf: json)
        for entry in entries {
            let chunk = try bytes(entry.name)
            guard chunk.count == entry.shape.reduce(1, *) * entry.dtype.byteCount else {
                throw Failure.header("\(entry.name) has \(chunk.count) bytes")
            }
            try handle.write(contentsOf: chunk)
        }
    }
}
