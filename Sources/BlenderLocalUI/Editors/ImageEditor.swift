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

    var body: some View {
        VStack(spacing: 0) {
            BHeader {
                Image(systemName: "photo").font(.system(size: 11))
                    .foregroundStyle(BTheme.textDim)
                Text(title).font(BTheme.Font.ui(12)).foregroundStyle(BTheme.text)
                if let image {
                    Text("\(image.name)  \(image.width)×\(image.height)")
                        .font(BTheme.Font.mono(10)).foregroundStyle(BTheme.textDim)
                }
                Spacer()
                if let headerContent { headerContent }
            }

            if let image, let cg = Self.cgImage(from: image) {
                GeometryReader { geo in
                    Image(decorative: cg, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .id(version)
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
            }
        }
        .background(Color(hex: 0x1D1D1D))
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
