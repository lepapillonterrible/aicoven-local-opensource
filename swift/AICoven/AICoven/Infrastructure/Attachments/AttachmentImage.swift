import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An attached file made ready to keep. A picture is written out afresh:
/// upright, without what the camera or an editor wrote into it (where and
/// when it was taken, on what), and no larger than a model takes. Anything
/// else is kept as it is.
nonisolated enum AttachmentImage {
    struct Prepared: Equatable {
        let data: Data
        let name: String
        let mimeType: String?
        var width: Int?
        var height: Int?
    }

    enum Failure: Error {
        /// A picture that could not be written out afresh: it is not kept
        /// as it came, with what was written into it.
        case cannotBeRewritten
    }

    /// The longest edge a kept picture has, in pixels.
    static let longestEdge = 4096
    static let jpegQuality = 0.9

    static func prepared(_ data: Data, name: String, mimeType: String?) throws -> Prepared {
        let unchanged = Prepared(data: data, name: name, mimeType: mimeType)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init),
              type.conforms(to: .image), CGImageSourceGetCount(source) > 0 else {
            return unchanged
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        // A picture that moves is kept as it is: writing it out afresh
        // would keep one frame of it.
        if CGImageSourceGetCount(source) > 1 {
            var kept = Prepared(data: data, name: name, mimeType: type.preferredMIMEType ?? mimeType)
            kept.width = properties?[kCGImagePropertyPixelWidth] as? Int
            kept.height = properties?[kCGImagePropertyPixelHeight] as? Int
            return kept
        }
        // Drawn upright at its own size, or smaller if it is larger than a
        // kept picture is, without reading the whole of it into memory at
        // full size first.
        let sourceEdge = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? longestEdge, properties?[kCGImagePropertyPixelHeight] as? Int ?? longestEdge)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(max(sourceEdge, 1), longestEdge),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw Failure.cannotBeRewritten
        }
        let hasAlpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        let written: UTType = hasAlpha ? .png : .jpeg
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, written.identifier as CFString, 1, nil) else {
            throw Failure.cannotBeRewritten
        }
        // Only the picture: nothing the source carried beside it is passed on.
        let quality: [CFString: Any] = hasAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: jpegQuality]
        CGImageDestinationAddImage(destination, image, quality as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.cannotBeRewritten }

        let fileExtension = hasAlpha ? "png" : "jpg"
        let base = (name as NSString).deletingPathExtension
        return Prepared(
            data: output as Data,
            name: "\(base.isEmpty ? "image" : base).\(fileExtension)",
            mimeType: hasAlpha ? "image/png" : "image/jpeg",
            width: image.width,
            height: image.height
        )
    }

    /// The kind of file a name says it is.
    static func mimeType(forFileNamed name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
