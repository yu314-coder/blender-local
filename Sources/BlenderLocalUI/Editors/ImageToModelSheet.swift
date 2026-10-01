import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO
import Vision
import CoreML
import Accelerate
import simd
import os

/// Everything between a picture and `ImageToModel.build`: reading it upright,
/// finding the subject, and handing the model to Blender.
///
/// The subject comes from the picture's own transparency when it has any — a
/// cut-out PNG or a drawing on a clear background says exactly where the
/// subject is — and otherwise from Vision's subject lifting, the same cut-out
/// Photos makes when you lift a subject from a photo. With neither, the whole
/// picture is the shape.
public enum ImageToModelImport {
    /// Posted on the main thread with the new object's name, so the 3D View
    /// can switch to Material Preview and frame it.
    public static let didCreate = Notification.Name("ImageToModelImport.didCreate")

    /// The texture's longer side. A 1024 image is 4 MB in Blender, packed.
    static let textureSize = 1024

    public enum Source: String, Sendable {
        case transparency = "the picture's transparency"
        case subject = "the subject Vision found"
        case whole = "the whole picture"
    }

    public struct Prepared: @unchecked Sendable {
        public let image: CGImage
        public let name: String
        public let transparency: ImageToModel.Mask?
        public let subject: ImageToModel.Mask?

        /// The shape to build: the cut-out when there is one and it is wanted.
        public func mask(cutOut: Bool) -> (ImageToModel.Mask, Source) {
            if cutOut, let transparency { return (transparency, .transparency) }
            if cutOut, let subject { return (subject, .subject) }
            return (.whole(width: image.width, height: image.height), .whole)
        }
    }

    public enum Failure: LocalizedError {
        case unreadable, noShape, needsBlender, blender(String), files(String)
        public var errorDescription: String? {
            switch self {
            case .unreadable: return "That file is not a picture this device can read."
            case .noShape: return "The cut-out has nothing in it to build."
            case .needsBlender: return "Image to 3D Model needs Blender's own module, which runs on an iPad or iPhone."
            case .blender(let message): return message
            case .files(let message): return "Could not write the model: \(message)"
            }
        }
    }

    /// Reads the picture upright at texture size and finds its subject.
    /// Slow — Vision takes a moment — so it runs off the main thread.
    public static func prepare(data: Data, fileName: String?) async throws -> Prepared {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: textureSize,
                  ] as CFDictionary)
            else { throw Failure.unreadable }
            return Prepared(image: image, name: ImageToModel.objectName(forFile: fileName),
                            transparency: transparencyMask(image), subject: subjectMask(image))
        }.value
    }

    /// The alpha channel as a mask, when the picture really uses it.
    static func transparencyMask(_ image: CGImage) -> ImageToModel.Mask? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return nil
        default: break
        }
        let width = image.width, height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var values = [UInt8](repeating: 0, count: width * height)
        for i in values.indices { values[i] = rgba[i * 4 + 3] }
        let mask = ImageToModel.Mask(width: width, height: height, values: values)
        // A PNG with an alpha channel it does not use is an opaque picture.
        let coverage = mask.coverage
        return coverage > 0.001 && coverage < 0.99 ? mask : nil
    }

    /// Vision's subject lifting, as a mask the size of the picture.
    static func subjectMask(_ image: CGImage) -> ImageToModel.Mask? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let observation = request.results?.first,
              let buffer = try? observation.generateScaledMaskForImage(
                forInstances: observation.allInstances, from: handler)
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let perRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width == image.width, height == image.height,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var values = [UInt8](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent32Float:
            let floats = base.assumingMemoryBound(to: Float32.self)
            for y in 0..<height {
                let row = floats.advanced(by: y * perRow / 4)
                for x in 0..<width { values[y * width + x] = UInt8(min(max(row[x], 0), 1) * 255) }
            }
        case kCVPixelFormatType_OneComponent8:
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width { values[y * width + x] = bytes[y * perRow + x] }
            }
        default:
            return nil
        }
        let mask = ImageToModel.Mask(width: width, height: height, values: values)
        return mask.coverage > 0.002 ? mask : nil
    }

    /// The picture with everything outside the mask cleared, to show what will
    /// be built.
    public static func preview(_ image: CGImage, mask: ImageToModel.Mask) -> CGImage? {
        let width = image.width, height = image.height
        guard mask.width == width, mask.height == height,
              let provider = CGDataProvider(data: Data(mask.values) as CFData),
              let maskImage = CGImage(width: width, height: height, bitsPerComponent: 8,
                                      bitsPerPixel: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: rect, mask: maskImage)
        context.draw(image, in: rect)
        return context.makeImage()
    }

    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case full = "Full 3D"
        case relief = "Relief"
        public var id: String { rawValue }
    }

    public struct Made: Sendable {
        public let name: String
        public let source: Source
        public let detail: String
    }

    /// Relief: the subject's outline shaped by the picture's own depth, with
    /// the photo as its texture. One undo step.
    @MainActor
    public static func createRelief(_ prepared: Prepared, cutOut: Bool, options: ImageToModel.Options,
                                    bridge: BpyBridge, session: BpySession, scene: BKScene) async throws -> Made {
        guard session.usesRealBlender else { throw Failure.needsBlender }
        let (mask, source) = prepared.mask(cutOut: cutOut)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageToModel-" + UUID().uuidString)
        let texture = folder.appendingPathComponent("texture.png")
        defer { try? FileManager.default.removeItem(at: folder) }

        let image = prepared.image
        let usedDepth = try await Task.detached(priority: .userInitiated) { () -> Bool in
            let depth = DepthRelief.depth(for: image)
            guard let mesh = ImageToModel.build(mask: mask, depth: depth, options: options) else {
                throw Failure.noShape
            }
            do {
                try mesh.write(to: folder)
                guard let destination = CGImageDestinationCreateWithURL(
                        texture as CFURL, UTType.png.identifier as CFString, 1, nil)
                else { throw Failure.files("no PNG writer") }
                CGImageDestinationAddImage(destination, image, nil)
                guard CGImageDestinationFinalize(destination) else { throw Failure.files("the PNG") }
            } catch let failure as Failure {
                throw failure
            } catch {
                throw Failure.files(error.localizedDescription)
            }
            return depth != nil
        }.value

        let python = ImageToModel.python(folder: folder.path, texture: texture.path,
                                         name: prepared.name, location: scene.cursor)
        let outcome = bridge.run(python, undo: "Image to 3D Model")
        guard outcome.succeeded else {
            throw Failure.blender(outcome.error ?? "Blender could not build the model.")
        }
        let name = scene.active?.name ?? prepared.name
        NotificationCenter.default.post(name: didCreate, object: name)
        return Made(name: name, source: source, detail: usedDepth ? "depth" : "no depth model")
    }

    /// The pieces of a full 3D run that cross between the background and the
    /// main thread. Used from one task at a time.
    final class FullRun: @unchecked Sendable {
        var picture: TripoSGPipeline.Prepared?
        var timings: [String] = []
    }

    /// Memory Full 3D needs free as it starts: the transformer's weights and
    /// their working space at the peak, measured on the device's own GPU
    /// memory, with a margin.
    static let fullMemoryNeeded: UInt64 = 2_800_000_000

    /// Full 3D: TripoSG's shape of the whole object, sides and back included,
    /// extracted at `resolution` cells across, decimated to `faces`, painted
    /// from the photo. One undo step. `progress` is told each stage.
    @MainActor
    public static func createFull(_ prepared: Prepared, cutOut: Bool, resolution: Int, faces: Int, textureSize: Int = 1024,
                                  steps: Int = 20, seed: UInt64 = .random(in: 0...UInt64(UInt32.max)),
                                  bridge: BpyBridge, session: BpySession, scene: BKScene,
                                  progress: @escaping @MainActor (String) -> Void) async throws -> Made {
        guard session.usesRealBlender else { throw Failure.needsBlender }
        let weights = TripoSGWeights.shared
        weights.refresh()
        guard weights.state == .ready else {
            throw Failure.blender("Download the Full 3D model first.")
        }
        #if os(iOS)
        let available = UInt64(os_proc_available_memory())
        if available > 0, available < fullMemoryNeeded {
            throw Failure.blender(String(format: "Full 3D needs about %.1f GB of memory free and %.1f GB is. Close other apps, or use Relief.",
                                         Double(fullMemoryNeeded) / 1e9, Double(available) / 1e9))
        }
        #endif
        let (mask, source) = prepared.mask(cutOut: cutOut)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageToModel-" + UUID().uuidString)
        let texturePath = folder.appendingPathComponent("texture.png")
        defer { try? FileManager.default.removeItem(at: folder) }
        let image = prepared.image
        let weightsFolder = TripoSGWeights.folder
        let report: @Sendable (String) -> Void = { text in Task { @MainActor in progress(text) } }

        progress("Reading the picture…")
        let run: FullRun = try await Task.detached(priority: .userInitiated) {
            let run = FullRun()
            var clock = Date()
            func lap(_ what: String) {
                run.timings.append(String(format: "%@ %.1fs", what, Date().timeIntervalSince(clock)))
                clock = Date()
            }
            guard let picture = TripoSGPipeline.prepare(image: image, mask: mask) else { throw Failure.noShape }
            run.picture = picture
            let model: TripoSGModel
            do { model = try TripoSGModel(folder: weightsFolder) } catch {
                throw Failure.blender("The Full 3D model could not be opened: \(error)")
            }
            var latents: [Float]
            do {
                let embeds = try model.imageEmbeddings(pixels: picture.pixels)
                lap("picture")
                // The first step compiles the transformer, so it is slower.
                report("Shaping the model: step 1 of \(steps)…")
                let flow = try model.flow(embeds: embeds)
                latents = flow.sample(noise: TripoSGModel.noise(seed: seed), steps: steps) { step in
                    if step < steps { report("Shaping the model: step \(step + 1) of \(steps)…") }
                }
            } catch {
                throw Failure.blender("TripoSG could not run: \(error)")
            }
            lap("shape")
            report("Finding the surface…")
            let mesh: MarchingCubes.Mesh
            do {
                let geometry = try model.geometry(latents: latents)
                mesh = TripoSGPipeline.surface(resolution: resolution, logits: geometry.query).mesh
            } catch {
                throw Failure.blender("TripoSG could not run: \(error)")
            }
            guard mesh.triangleCount > 0 else { throw Failure.noShape }
            do { try TripoSGPipeline.write(mesh, to: folder) } catch { throw Failure.files(error.localizedDescription) }
            lap("surface")
            return run
        }.value

        progress("Unwrapping the surface…")
        var clock = Date()
        let prepare = bridge.run(TripoSGPipeline.preparePython(folder: folder.path, faces: faces), quiet: true)
        guard prepare.succeeded else {
            throw Failure.blender(prepare.error ?? "Blender could not unwrap the model.")
        }
        run.timings.append(String(format: "unwrap %.1fs", Date().timeIntervalSince(clock)))

        progress("Painting the texture…")
        let photoFraction: Float = try await Task.detached(priority: .userInitiated) {
            let started = Date()
            guard let picture = run.picture else { throw Failure.noShape }
            let unwrapped: TripoSGPipeline.Unwrapped
            do { unwrapped = try TripoSGPipeline.Unwrapped(folder: folder) } catch {
                throw Failure.files("the unwrapped surface")
            }
            let pose = TripoSGPipeline.fitPose(vertices: unwrapped.corners, alpha: picture.alpha)
            let mirror = TripoSGPipeline.mirrorSymmetry(vertices: unwrapped.corners) > 0.8
            let texture = TripoSGPipeline.bake(unwrapped, prepared: picture, pose: pose, mirror: mirror, size: textureSize)
            do { try texture.writePNG(to: texturePath) } catch { throw Failure.files("the texture") }
            run.timings.append(String(format: "texture %.1fs (seen from %.0f°, %.0f° up%@)", Date().timeIntervalSince(started),
                                      pose.azimuth, pose.elevation, mirror ? ", mirrored" : ""))
            return texture.photoFraction
        }.value

        clock = Date()
        let finish = bridge.run(TripoSGPipeline.finishPython(folder: folder.path, texture: texturePath.path,
                                                             name: prepared.name, location: scene.cursor),
                                undo: "Image to 3D Model")
        guard finish.succeeded else {
            _ = bridge.run("import bpy\n_m = bpy.data.meshes.get('_bk_image3d_pending')\nif _m is not None:\n    bpy.data.meshes.remove(_m)", quiet: true)
            throw Failure.blender(finish.error ?? "Blender could not build the model.")
        }
        run.timings.append(String(format: "object %.1fs", Date().timeIntervalSince(clock)))
        let name = scene.active?.name ?? prepared.name
        NotificationCenter.default.post(name: didCreate, object: name)
        return Made(name: name, source: source,
                    detail: run.timings.joined(separator: ", ")
                        + String(format: ", photo on %.0f%% of the texture, seed %llu", photoFraction * 100, seed))
    }
}

/// Depth Anything V2 Small (Apache 2.0; Apple's Core ML conversion), bundled.
/// How near each pixel of a picture is, 0 far to 1 near, at 518 × 392.
public enum DepthRelief {
    private static let model: MLModel? = {
        guard let url = Bundle.main.url(forResource: "DepthAnythingV2SmallF16", withExtension: "mlmodelc") else {
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try? MLModel(contentsOf: url, configuration: configuration)
    }()

    public static func depth(for image: CGImage) -> ImageToModel.Depth? {
        guard let model,
              let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint,
              let input = try? MLFeatureValue(cgImage: image, constraint: constraint,
                                              options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input])),
              let buffer = output.featureValue(for: "depth")?.imageBufferValue
        else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let perRow = CVPixelBufferGetBytesPerRow(buffer)
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        var values = [Float](repeating: 0, count: width * height)
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent16Half:
            values.withUnsafeMutableBufferPointer { v in
                for y in 0..<height {
                    var src = vImage_Buffer(data: base + y * perRow, height: 1,
                                            width: vImagePixelCount(width), rowBytes: perRow)
                    var dst = vImage_Buffer(data: v.baseAddress! + y * width, height: 1,
                                            width: vImagePixelCount(width), rowBytes: width * 4)
                    _ = vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
                }
            }
        case kCVPixelFormatType_OneComponent32Float:
            let floats = base.assumingMemoryBound(to: Float32.self)
            for y in 0..<height { for x in 0..<width { values[y * width + x] = floats[y * perRow / 4 + x] } }
        case kCVPixelFormatType_OneComponent8:
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height { for x in 0..<width { values[y * width + x] = Float(bytes[y * perRow + x]) / 255 } }
        default:
            return nil
        }
        // Scaled 0...1 here; ImageToModel stretches the subject's own range.
        guard let lo = values.min(), let hi = values.max(), hi > lo else { return nil }
        return ImageToModel.Depth(width: width, height: height, values: values.map { ($0 - lo) / (hi - lo) })
    }
}

/// Add ▸ Image to 3D Model: choose a picture, see the cut-out, pick Full 3D
/// or Relief, and make the model.
struct ImageToModelSheet: View {
    var scene: BKScene
    var session: BpySession
    var bridge: BpyBridge?
    var onDone: () -> Void

    enum Detail: String, CaseIterable, Identifiable {
        case low = "Low", medium = "Medium", high = "High"
        var id: String { rawValue }
        /// Relief lattice cells across the subject.
        var cells: Int {
            switch self {
            case .low: return 48
            case .medium: return 96
            case .high: return 160
            }
        }
        /// Full 3D surface cells across the shape's bounds.
        var resolution: Int { self == .low ? 128 : 256 }
        /// Full 3D triangles after decimation.
        var faces: Int {
            switch self {
            case .low: return 20_000
            case .medium: return 50_000
            case .high: return 100_000
            }
        }
        var textureSize: Int { self == .high ? 2048 : 1024 }
    }

    @State private var photo: PhotosPickerItem?
    @State private var choosingFile = false
    @State private var prepared: ImageToModelImport.Prepared?
    @State private var preview: CGImage?
    @State private var cutOut = true
    @State private var mode = ImageToModelImport.Mode.full
    @State private var thickness = 0.6
    @State private var detail = Detail.medium
    @State private var working: String?
    @State private var problem: String?
    private var weights: TripoSGWeights { TripoSGWeights.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                picture
                HStack(spacing: 8) {
                    PhotosPicker(selection: $photo, matching: .images) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                    Button { choosingFile = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                    Spacer()
                }
                .buttonStyle(.bordered)

                if let prepared {
                    let (_, source) = prepared.mask(cutOut: cutOut)
                    Toggle("Cut out the subject", isOn: $cutOut)
                        .disabled(prepared.transparency == nil && prepared.subject == nil)
                    Text(prepared.transparency == nil && prepared.subject == nil
                         ? "No subject found, so the whole picture is used. A single object on a plain background works best."
                         : "Shape from \(source.rawValue).")
                        .font(.footnote)
                        .foregroundStyle(BTheme.textDim)
                }

                Picker("Mode", selection: $mode) {
                    ForEach(ImageToModelImport.Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                switch mode {
                case .full:
                    Text("The whole object, sides and back included, generated by TripoSG and painted from the photo. About two minutes.")
                        .font(.footnote).foregroundStyle(BTheme.textDim)
                    weightsRow
                case .relief:
                    Text("The picture's own depth as a relief, with the photo at full sharpness. Best seen from the front. A few seconds.")
                        .font(.footnote).foregroundStyle(BTheme.textDim)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Thickness")
                            Spacer()
                            Text(String(format: "%.2f", thickness)).monospacedDigit()
                                .foregroundStyle(BTheme.textDim)
                        }
                        Slider(value: $thickness, in: 0.1...1.5)
                    }
                }
                Picker("Detail", selection: $detail) {
                    ForEach(Detail.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)

                if !session.usesRealBlender {
                    Text(ImageToModelImport.Failure.needsBlender.errorDescription ?? "")
                        .font(.footnote).foregroundStyle(.orange)
                }
                if let problem {
                    Text(problem).font(.footnote).foregroundStyle(.orange)
                }

                HStack {
                    Spacer()
                    if let working {
                        ProgressView().padding(.trailing, 6)
                        Text(working).foregroundStyle(BTheme.textDim)
                    } else {
                        BPrimaryButton("Create Model", icon: "cube.fill") { create() }
                            .disabled(!canCreate)
                    }
                }
            }
            .padding(16)
        }
        .foregroundStyle(BTheme.text)
        .background(BTheme.header)
        .onAppear { weights.refresh() }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            load(name: nil) { try await item.loadTransferable(type: Data.self) }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                load(name: url.lastPathComponent) {
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    return try Data(contentsOf: url)
                }
            case .failure(let error):
                problem = error.localizedDescription
            }
        }
        .onChange(of: cutOut) { _, _ in refreshPreview() }
    }

    private var canCreate: Bool {
        guard prepared != nil, bridge != nil, session.usesRealBlender else { return false }
        return mode == .relief || weights.state == .ready
    }

    @ViewBuilder private var weightsRow: some View {
        let download = ByteCountFormatter.string(fromByteCount: TripoSGWeights.downloadBytes, countStyle: .file)
        let stored = ByteCountFormatter.string(fromByteCount: TripoSGWeights.storedBytes, countStyle: .file)
        switch weights.state {
        case .ready:
            HStack {
                Label("Model ready on this device", systemImage: "checkmark.circle")
                    .font(.footnote).foregroundStyle(BTheme.textDim)
                Spacer()
                Button("Remove (\(stored))", role: .destructive) { weights.remove() }
                    .font(.footnote)
                    .disabled(working != nil)
            }
        case .missing:
            VStack(alignment: .leading, spacing: 6) {
                Text("Full 3D needs TripoSG's weights (VAST AI, MIT licence): a one-time \(download) download from Hugging Face, stored as \(stored) on this device and never backed up. Wi-Fi recommended.")
                    .font(.footnote).foregroundStyle(BTheme.textDim)
                Button { weights.download() } label: {
                    Label("Download Model (\(download))", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
            }
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction)
                Text(String(format: "%.0f%%", fraction * 100)).monospacedDigit().font(.footnote)
                Button("Cancel") { weights.cancel() }.font(.footnote)
            }
        case .preparing(let index):
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking and converting part \(index + 1) of \(TripoSGWeights.files.count)…")
                    .font(.footnote).foregroundStyle(BTheme.textDim)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Text(message).font(.footnote).foregroundStyle(.orange)
                Button { weights.download() } label: {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var picture: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(BTheme.widget)
            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable().scaledToFit().padding(8)
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo.artframe").font(.system(size: 30))
                    Text("Choose a photo or drawing of one object. Its subject is cut out and made into a textured 3D model.")
                        .font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(BTheme.textDim)
                .padding()
            }
        }
        .frame(height: 180)
    }

    private func load(name: String?, _ read: @escaping () async throws -> Data?) {
        problem = nil
        working = "Finding the subject…"
        Task {
            defer { working = nil }
            do {
                guard let data = try await read() else { throw ImageToModelImport.Failure.unreadable }
                let ready = try await ImageToModelImport.prepare(data: data, fileName: name)
                prepared = ready
                cutOut = ready.transparency != nil || ready.subject != nil
                refreshPreview()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func refreshPreview() {
        guard let prepared else { preview = nil; return }
        let (mask, source) = prepared.mask(cutOut: cutOut)
        preview = source == .whole ? prepared.image
            : ImageToModelImport.preview(prepared.image, mask: mask) ?? prepared.image
    }

    private func create() {
        guard let prepared, let bridge else { return }
        problem = nil
        working = "Building the model…"
        let mode = self.mode, detail = self.detail, thickness = self.thickness, cutOut = self.cutOut
        Task {
            defer { working = nil }
            do {
                switch mode {
                case .relief:
                    let options = ImageToModel.Options(detail: detail.cells, thickness: Float(thickness))
                    _ = try await ImageToModelImport.createRelief(prepared, cutOut: cutOut, options: options,
                                                                  bridge: bridge, session: session, scene: scene)
                case .full:
                    _ = try await ImageToModelImport.createFull(prepared, cutOut: cutOut, resolution: detail.resolution,
                                                                faces: detail.faces, textureSize: detail.textureSize,
                                                                bridge: bridge, session: session, scene: scene) { stage in
                        working = stage
                    }
                }
                onDone()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
