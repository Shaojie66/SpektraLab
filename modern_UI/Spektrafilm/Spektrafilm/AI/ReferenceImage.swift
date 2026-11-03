//  ReferenceImage.swift — the picture Refine is asked to come close to (AI
//  assistant, ARCHITECTURE §7.14).
//
//  Somebody else's print, a frame of one's own from another roll, a digital
//  photograph: its look, not its subject. It is read once, upright and at the
//  size the print is sent at, so the model compares two pictures of the same
//  scale, and measured with the same `ImageMetrics` the print is — a local
//  model judges a colour difference between two images unreliably by eye, and
//  the gap in numbers is what lets it converge.
//
//  Held in memory by the assistant only: it is an instruction, not part of the
//  edit, so it is never written into a sidecar.

import CoreGraphics
import Foundation
import ImageIO

struct ReferenceImage: Sendable {
    let name: String
    let image: CGImage
    let jpeg: Data
    let metrics: ImageMetrics

    /// How far a print looks from this reference: each measured gap over
    /// the size of a difference one sees side by side, summed. Lower is
    /// closer, 0 is the same numbers. What Refine keeps a round by.
    func distance(to print: ImageMetrics) -> Double {
        let r = metrics
        return abs(r.meanLuma - print.meanLuma) / 0.05 + abs(r.contrast - print.contrast) / 0.03
            + abs(r.colorfulness - print.colorfulness) / 8
            + abs(r.castRG - print.castRG) / 0.02 + abs(r.castYB - print.castYB) / 0.02
    }

    enum Failure: Error, CustomStringConvertible {
        case unreadable(String)
        var description: String {
            switch self {
            case .unreadable(let name): "\(name) could not be read as an image."
            }
        }
        @MainActor var localized: String {
            switch self {
            case .unreadable(let name): L(description, zh: "无法把 \(name) 读取为图片。")
            }
        }
    }

    /// Any file ImageIO reads; a RAW gives its embedded preview, which is the
    /// camera's look rather than this app's and is good enough for a target.
    static func load(_ url: URL, longEdge: Int = AISettings.sentLongEdge) throws -> ReferenceImage {
        let name = url.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: longEdge,
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary),
              let image = sRGB(thumb),
              let metrics = ImageMetrics(image),
              let jpeg = encode(image)
        else { throw Failure.unreadable(name) }
        return ReferenceImage(name: name, image: image, jpeg: jpeg, metrics: metrics)
    }

    /// In memory, at the quality the proofs are sent at (`ProofSheet.writeJPEG`),
    /// and off the main actor: `Exporter` is main-actor bound.
    private static func encode(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Drawn into 8-bit sRGB, the space the print is sent and measured in, so
    /// a Display P3 or ProPhoto file is not compared by its raw code values.
    private static func sRGB(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
