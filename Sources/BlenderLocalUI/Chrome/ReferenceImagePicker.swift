import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
import simd

extension BpyBridge {
    /// Add ▸ Image ▸ Reference..., Background... or Mesh Plane... with the
    /// picture `data`: made into what Blender reads (`ReferenceImages.prepare`:
    /// a PNG or a JPEG, the right way up, at most 4,096 pixels on a side —
    /// Photos gives HEIC, which Blender cannot read), copied to
    /// `ReferenceImages.folder`, then added by Blender's own operator under
    /// the borrowed 3D View, at the 3D cursor, Reference and Background facing
    /// `view` (round 4, group 8). One undo step, named as Blender names it.
    /// The pickers and the `-textimage-ops` hook both come through here.
    @discardableResult
    func addReferenceImage(_ kind: ReferenceImages.Kind, data: Data, name: String,
                           at cursor: SIMD3<Float>, view: ViewportCamera?) -> Outcome {
        let stored: URL
        do {
            let picture = try ReferenceImages.prepare(data, name: name)
            stored = try ReferenceImages.store(picture.data, name: picture.name)
        } catch {
            let row = kind.label.replacingOccurrences(of: "...", with: "")
            let said = "\(row): the picture could not be made ready for Blender: \(error.localizedDescription)."
            return run("raise RuntimeError(\(Bpy.quote(said)))", undo: kind.undo)
        }
        let rotation = view.map { ObjectAddition.eulerXYZ($0.objectRotation) } ?? .zero
        return run(ReferenceImages.add(kind, path: stored.path, location: cursor, rotation: rotation,
                                       orthographic: view?.isOrthographic ?? false),
                   undo: kind.undo)
    }
}

/// Where Reference..., Background... and Mesh Plane... take their picture
/// from: Photos or Files, asked first, as the system's own pickers ask.
/// Whatever either gives is converted before Blender sees it
/// (`BpyBridge.addReferenceImage`).
struct ReferenceImagePicker: ViewModifier {
    @Binding var request: ReferenceImages.Kind?
    /// The picture, read, and the file name it had.
    var picked: (ReferenceImages.Kind, Data, String) -> Void

    @State private var asking = false
    @State private var photos = false
    @State private var files = false
    @State private var kind: ReferenceImages.Kind = .reference
    @State private var selection: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .onChange(of: request) { _, now in
                guard let now else { return }
                kind = now
                asking = true
                request = nil
            }
            .confirmationDialog(kind.label.replacingOccurrences(of: "...", with: ""), isPresented: $asking) {
                Button("Photos") { photos = true }
                Button("Files") { files = true }
                Button("Cancel", role: .cancel) {}
            }
            .photosPicker(isPresented: $photos, selection: $selection, matching: .images)
            .onChange(of: selection) { _, item in
                guard let item else { return }
                selection = nil
                let chosen = kind
                Task { @MainActor in
                    guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                    let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
                    picked(chosen, data, "Photo.\(ext)")
                }
            }
            .fileImporter(isPresented: $files, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { return }
                picked(kind, data, url.lastPathComponent)
            }
    }
}
