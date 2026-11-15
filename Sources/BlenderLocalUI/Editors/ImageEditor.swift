import SwiftUI
import UIKit

/// Blender's Image Editor: shows a `TextureImage` — either the paint target or
/// the render result.
struct ImageEditor: View {
    var title: String
    var image: TextureImage?
    /// Changes when the buffer does, so SwiftUI redraws.
    var version: Int
    var emptyMessage: String
    /// Extra controls for the header, per use.
    var headerContent: AnyView?
    /// Shown under the empty message. An empty editor that names a menu path
    /// makes the reader go find it; one that offers the button does not.
    var emptyAction: AnyView?
    /// Blender's render stats over the image's top left ("Frame:1 | Time:00:13.02 |
    /// Mem:2.8G, Peak:2.9G | Sample 128/128"), as its Image Editor draws them
    /// on a Render Result.
    var stats: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            BHeader {
                Image(systemName: "photo").font(.system(size: 11))
                    .foregroundStyle(BTheme.textDim)
                Text(title).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                if let image {
                    Text("\(image.name)  \(image.width)×\(image.height)")
                        .font(BTheme.Font.mono(10)).foregroundStyle(BTheme.textDim)
                        // A dated render's name is long: it gives way to the
                        // header's controls rather than pushing them off.
                        .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
                }
                Spacer(minLength: 4)
                if let headerContent { headerContent }
            }

            if let image, let cg = Self.cachedImage(image, version: version) {
                GeometryReader { geo in
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .id(version)
                .overlay(alignment: .topLeading) { statsLine }
            } else {
                VStack(spacing: 12) {
                    Spacer()
                    Text(emptyMessage)
                        .font(BTheme.Font.ui(12)).foregroundStyle(BTheme.textDim)
                        .multilineTextAlignment(.center)
                    if let emptyAction { emptyAction }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .overlay(alignment: .topLeading) { statsLine }
            }
        }
        .background(Color(hex: 0x1D1D1D))
    }

    @ViewBuilder private var statsLine: some View {
        if let stats, !stats.isEmpty {
            Text(stats)
                .font(BTheme.Font.mono(11))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.9), radius: 1, x: 1, y: 1)
                .lineLimit(2)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .allowsHitTesting(false)
        }
    }

    /// The last image made, by buffer and version: the body is evaluated on
    /// every change around it (the Render panel's progress, four times a
    /// second while it renders), and each evaluation copied the whole buffer
    /// (8 MB at 1920×1080) into a new CGImage.
    nonisolated(unsafe) private static var cache: (id: ObjectIdentifier, version: Int, size: Int, image: CGImage)?

    static func cachedImage(_ image: TextureImage, version: Int) -> CGImage? {
        let id = ObjectIdentifier(image)
        if let cache, cache.id == id, cache.version == version, cache.size == image.pixels.count {
            return cache.image
        }
        guard let made = cgImage(from: image) else { return nil }
        cache = (id, version, image.pixels.count, made)
        return made
    }

    /// The buffer is RGBA8, which is what CGImage wants given the right flags.
    static func cgImage(from image: TextureImage) -> CGImage? {
        let data = Data(image.pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: image.width, height: image.height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: image.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }
}
