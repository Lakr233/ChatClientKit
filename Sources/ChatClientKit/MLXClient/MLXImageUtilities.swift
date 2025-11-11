//
//  MLXImageUtilities.swift
//  ChatClientKit
//
//  Created by GPT-5 Codex on 2025/11/10.
//

import CoreGraphics
import CoreImage
import Foundation
import ImageIO

enum MLXImageContentMode {
    case contentFill
    case contentAspectFill
    case contentAspectFit
}

enum MLXImageUtilities {
    private static let defaultColor = CGColor(gray: 1.0, alpha: 1.0)

    static func placeholderImage(
        size: CGSize,
        color: CGColor = defaultColor
    ) -> CIImage {
        let ciColor = CIColor(cgColor: color)
        let image = CIImage(color: ciColor)
        return crop(image: image, to: CGRect(origin: .zero, size: size))
    }

    static func decodeImage(data: Data) -> CIImage? {
        if let image = CIImage(
            data: data,
            options: [.applyOrientationProperty: true]
        ) {
            return normalize(image: image)
        }

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            return nil
        }

        return normalize(image: CIImage(cgImage: cgImage))
    }

    static func resize(
        image: CIImage,
        targetSize: CGSize,
        contentMode: MLXImageContentMode
    ) -> CIImage? {
        guard targetSize.width > 0, targetSize.height > 0 else { return nil }

        let normalized = normalize(image: image)
        let extent = normalized.extent.integral

        guard extent.width > 0, extent.height > 0 else { return nil }

        let scaleX = targetSize.width / extent.width
        let scaleY = targetSize.height / extent.height

        switch contentMode {
        case .contentFill:
            let scaled = normalized.transformed(by: .init(scaleX: scaleX, y: scaleY))
            let rect = CGRect(origin: .zero, size: targetSize)
            return crop(image: scaled, to: rect)
        case .contentAspectFit:
            let scale = min(scaleX, scaleY)
            let scaled = normalized.transformed(by: .init(scaleX: scale, y: scale))
            return normalize(image: scaled)
        case .contentAspectFill:
            let scale = max(scaleX, scaleY)
            let scaled = normalized.transformed(by: .init(scaleX: scale, y: scale))
            let cropOrigin = CGPoint(
                x: (scaled.extent.width - targetSize.width) / 2,
                y: (scaled.extent.height - targetSize.height) / 2
            )
            let cropRect = CGRect(origin: cropOrigin, size: targetSize)
            return crop(image: scaled, to: cropRect)
        }
    }

    static func normalize(image: CIImage) -> CIImage {
        let extent = image.extent.integral
        guard extent.origin != .zero else {
            return image
        }
        return image.transformed(by: .init(
            translationX: -extent.origin.x,
            y: -extent.origin.y
        ))
    }

    private static func crop(image: CIImage, to rect: CGRect) -> CIImage {
        let cropped = image.cropped(to: rect)
        return normalize(image: cropped)
    }
}
