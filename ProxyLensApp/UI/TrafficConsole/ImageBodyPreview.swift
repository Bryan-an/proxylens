import AppKit
import Foundation
import ImageIO
import ProxyLensCore
import UniformTypeIdentifiers

enum ImageBodyPreviewBuilder: Sendable {
    static let maximumEncodedByteCount = 16 * 1_024 * 1_024
    static let maximumDecodedByteCount = 16 * 1_024 * 1_024
    static let maximumThumbnailPixelDimension = 2_048

    static let noBodyReason = "No image body was captured."
    static let truncatedImageReason =
        "Image preview is unavailable because the captured body is truncated."
    static let exceedsPreviewLimitReason =
        "Image preview is unavailable because the body exceeds the 16 MB preview limit."
    static let invalidImageReason = "This body is not a supported image."

    static func render(
        _ data: Data,
        reference: BodyReference,
        metadata: String
    ) -> TrafficImagePresentation {
        guard !reference.isTruncated else {
            return .none(truncatedImageReason)
        }
        guard data.count <= maximumEncodedByteCount else {
            return .none(exceedsPreviewLimitReason)
        }

        let decoded: Data
        do {
            decoded = try HTTPContentCoding.decode(
                data,
                contentEncoding: reference.contentEncoding,
                maximumOutputByteCount: maximumDecodedByteCount
            )
        } catch HTTPContentCoding.CodingError.exceedsLimit {
            return .none(exceedsPreviewLimitReason)
        } catch {
            return .none(
                "Image preview could not decode the captured body: \(error.localizedDescription)"
            )
        }

        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard
            let source = CGImageSourceCreateWithData(decoded as CFData, sourceOptions),
            CGImageSourceGetCount(source) > 0
        else {
            return .none(invalidImageReason)
        }

        let frameCount = CGImageSourceGetCount(source)
        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumThumbnailPixelDimension,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
        else {
            return .none(invalidImageReason)
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelWidth =
            integerProperty(kCGImagePropertyPixelWidth, in: properties)
            ?? thumbnail.width
        let pixelHeight =
            integerProperty(kCGImagePropertyPixelHeight, in: properties)
            ?? thumbnail.height
        guard pixelWidth > 0, pixelHeight > 0, let pngData = encodePNG(thumbnail) else {
            return .none(invalidImageReason)
        }

        let format = imageFormat(CGImageSourceGetType(source))
        let frameDescription = frameCount == 1 ? "1 frame" : "\(frameCount) frames • first shown"
        let previewMetadata =
            "\(format) • \(pixelWidth) × \(pixelHeight) px • \(frameDescription)\n\(metadata)"
        return .content(
            TrafficImagePreview(
                metadata: previewMetadata,
                thumbnailPNGData: pngData,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                thumbnailPixelWidth: thumbnail.width,
                thumbnailPixelHeight: thumbnail.height,
                format: format,
                frameCount: frameCount
            )
        )
    }

    private static func integerProperty(
        _ key: CFString,
        in properties: [CFString: Any]?
    ) -> Int? {
        if let value = properties?[key] as? NSNumber {
            return value.intValue
        }
        return properties?[key] as? Int
    }

    private static func imageFormat(_ typeIdentifier: CFString?) -> String {
        guard let typeIdentifier else {
            return "IMAGE"
        }
        let identifier = typeIdentifier as String
        let extensionName = UTType(identifier)?.preferredFilenameExtension?.uppercased()
        switch extensionName {
        case "JPG":
            return "JPEG"
        case "TIF":
            return "TIFF"
        case .some(let extensionName):
            return extensionName
        case nil:
            return "IMAGE"
        }
    }

    private static func encodePNG(_ image: CGImage) -> Data? {
        let encoded = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                encoded,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return encoded as Data
    }
}

@MainActor
final class ImagePreviewView: NSView {
    private let metadataField = NSTextField(labelWithString: "")
    private let imageView = NSImageView()
    private let messageField = NSTextField(wrappingLabelWithString: "")

    init(accessibilityPrefix: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("\(accessibilityPrefix).preview")

        metadataField.translatesAutoresizingMaskIntoConstraints = false
        metadataField.font = .systemFont(ofSize: 11)
        metadataField.textColor = .secondaryLabelColor
        metadataField.maximumNumberOfLines = 2
        metadataField.lineBreakMode = .byTruncatingMiddle
        metadataField.setAccessibilityIdentifier("\(accessibilityPrefix).preview.metadata")
        metadataField.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyDown
        imageView.setAccessibilityIdentifier("\(accessibilityPrefix).preview.image")
        imageView.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)

        messageField.translatesAutoresizingMaskIntoConstraints = false
        messageField.alignment = .center
        messageField.textColor = .secondaryLabelColor
        messageField.maximumNumberOfLines = 0
        messageField.setAccessibilityIdentifier("\(accessibilityPrefix).preview.message")
        messageField.setContentHuggingPriority(.init(rawValue: 1), for: .horizontal)

        addSubview(metadataField)
        addSubview(imageView)
        addSubview(messageField)
        NSLayoutConstraint.activate([
            metadataField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            metadataField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            metadataField.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            imageView.topAnchor.constraint(equalTo: metadataField.bottomAnchor, constant: 10),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            messageField.leadingAnchor.constraint(
                greaterThanOrEqualTo: leadingAnchor, constant: 24),
            messageField.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -24),
            messageField.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        display(.none(ImageBodyPreviewBuilder.noBodyReason))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func display(_ presentation: TrafficImagePresentation) {
        switch presentation {
        case .content(let preview):
            guard let image = NSImage(data: preview.thumbnailPNGData) else {
                showMessage(ImageBodyPreviewBuilder.invalidImageReason)
                return
            }
            metadataField.stringValue = preview.metadata
            metadataField.isHidden = false
            imageView.image = image
            imageView.setAccessibilityLabel(
                "\(preview.format) image, \(preview.pixelWidth) by \(preview.pixelHeight) pixels"
            )
            imageView.isHidden = false
            messageField.isHidden = true
        case .loading(let metadata):
            showMessage("Loading image preview…\n\(metadata)")
        case .none(let reason):
            showMessage(reason)
        case .failed(let metadata, let message):
            showMessage("\(metadata)\n\(message)")
        }
    }

    private func showMessage(_ message: String) {
        metadataField.isHidden = true
        imageView.image = nil
        imageView.setAccessibilityLabel(nil)
        imageView.isHidden = true
        messageField.stringValue = message
        messageField.isHidden = false
    }
}
