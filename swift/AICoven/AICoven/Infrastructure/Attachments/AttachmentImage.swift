import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An attached file made ready to keep. A still picture is written out
/// afresh: upright, without what the camera or an editor wrote into it
/// (where and when it was taken, on what), and no larger than a model
/// takes. Anything else is kept as it is, a picture that moves included.
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
        // Whether the picture itself can be seen through, as it says of
        // itself: the redrawn copy can carry an alpha channel the source
        // did not have, and a photo is not to be kept as a PNG for that.
        let hasAlpha = (properties?[kCGImagePropertyHasAlpha] as? Bool)
            ?? ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
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

    // MARK: - For a model

    /// The most bytes a picture sent to a model has: under the 5 MB a
    /// provider takes of one once it is written as base64.
    static let largestForModel = 3_500_000

    /// The sizes (longest edge, in pixels) and JPEG qualities a picture is
    /// tried at for a model, until one is small enough to send.
    static let triesForModel: [(edge: Int, quality: Double)] = [(4096, 0.85), (3072, 0.8), (2048, 0.8), (1568, 0.7), (1024, 0.6)]

    /// A picture as a model is sent it: its first frame, upright, on white
    /// where it can be seen through, with nothing of what was written into
    /// the file beside the picture, as a JPEG no longer than 4096 pixels on
    /// its longest edge and no larger than `largest` bytes (made smaller
    /// until it is). nil if the bytes are not a picture that can be drawn,
    /// or it cannot be made small enough.
    static func forModel(_ data: Data, largest: Int = largestForModel) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = (CGImageSourceGetType(source) as String?).flatMap(UTType.init),
              type.conforms(to: .image), CGImageSourceGetCount(source) > 0 else {
            return nil
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceEdge = max(properties?[kCGImagePropertyPixelWidth] as? Int ?? longestEdge, properties?[kCGImagePropertyPixelHeight] as? Int ?? longestEdge)
        for attempt in triesForModel {
            // Never drawn larger than it is.
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(max(sourceEdge, 1), attempt.edge),
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let flat = onWhite(image) else {
                return nil
            }
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(destination, flat, [kCGImageDestinationLossyCompressionQuality: attempt.quality] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { return nil }
            if output.length <= largest {
                return output as Data
            }
        }
        return nil
    }

    /// The picture drawn on white, with no alpha channel: a JPEG has none,
    /// and what could be seen through would otherwise come out black.
    private static func onWhite(_ image: CGImage) -> CGImage? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else {
            return nil
        }
        let whole = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(whole)
        context.draw(image, in: whole)
        return context.makeImage()
    }

    /// The kind of file a name says it is.
    static func mimeType(forFileNamed name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
}
