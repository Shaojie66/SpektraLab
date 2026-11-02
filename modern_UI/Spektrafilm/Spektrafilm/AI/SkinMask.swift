//  SkinMask.swift — where the skin is, found on this Mac (ARCHITECTURE §7.14).
//
//  Vision's face landmarks on a small render of the decode: for each face the
//  jaw line and brows give the face's outline, raised over the forehead; the
//  eyes, brows, lips and nose are cut out of it so they stay sharp; the edge
//  is pulled in and feathered so the hairline and the background are left
//  alone. No network, no model. Coordinates stay Vision's — normalised,
//  bottom-left origin — which is also Core Image's, so the mask lands on the
//  linear decode with a scale and nothing else.

import CoreGraphics
import CoreImage
import Foundation
import Vision

struct SkinMask: Sendable {
    struct Face: Sendable, Equatable {
        /// Normalised, bottom-left origin.
        let box: CGRect
        /// The skin's outline: jaw, then the forehead over the brows.
        let outline: [CGPoint]
        /// Eyes, brows, lips, nose: kept out of the mask.
        let features: [[CGPoint]]
    }

    let faces: [Face]
    static let none = SkinMask(faces: [])

    var isEmpty: Bool { faces.isEmpty }

    /// The median face width, as a fraction of the frame's width: what the
    /// smoothing's scales are set from.
    var faceWidth: Double {
        let w = faces.map { Double($0.box.width) }.sorted()
        return w.isEmpty ? 0 : w[w.count / 2]
    }

    /// How far over the brows the forehead is taken, as a share of the face box.
    static let forehead = 0.18

    static func detect(_ image: CGImage) throws -> SkinMask {
        let request = VNDetectFaceLandmarksRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let size = CGSize(width: image.width, height: image.height)
        func points(_ r: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (r?.pointsInImage(imageSize: size) ?? []).map { CGPoint(x: $0.x / size.width, y: $0.y / size.height) }
        }
        let faces: [Face] = (request.results ?? []).compactMap { f in
            guard let l = f.landmarks else { return nil }
            let jaw = points(l.faceContour)
            guard jaw.count >= 3 else { return nil }
            let box = f.boundingBox
            // The brows' points lifted over the forehead, right to left, close
            // the outline the jaw opens.
            let lift = box.height * forehead
            let brows = (points(l.leftEyebrow) + points(l.rightEyebrow))
                .map { CGPoint(x: $0.x, y: $0.y + lift) }
                .sorted { $0.x > $1.x }
            let jawLeftToRight = jaw.first!.x <= jaw.last!.x ? jaw : jaw.reversed()
            let features = [l.leftEye, l.rightEye, l.leftEyebrow, l.rightEyebrow, l.outerLips, l.nose]
                .map(points).filter { $0.count >= 3 }
            return Face(box: box, outline: jawLeftToRight + brows, features: features)
        }
        return SkinMask(faces: faces)
    }

    /// The mask drawn at `width`×`height` (Core Graphics is y-up, as Vision's
    /// points are): skin white, features and outside black, the edge pulled in
    /// and feathered by a share of the face.
    func render(width: Int, height: Int) -> CGImage? {
        guard !isEmpty, width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let w = CGFloat(width), h = CGFloat(height)
        func path(_ pts: [CGPoint]) -> CGPath {
            let p = CGMutablePath()
            p.addLines(between: pts.map { CGPoint(x: $0.x * w, y: $0.y * h) })
            p.closeSubpath()
            return p
        }
        for f in faces {
            let faceW = f.box.width * w
            // Skin, pulled in from its edge by a black stroke.
            ctx.addPath(path(f.outline))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fillPath()
            ctx.addPath(path(f.outline))
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(faceW * 0.06)
            ctx.strokePath()
            // Features, cut out a little wider than they are.
            for feature in f.features {
                ctx.addPath(path(feature))
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fillPath()
                ctx.addPath(path(feature))
                ctx.setLineWidth(faceW * 0.035)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    /// The mask over `extent`, feathered, as a Core Image grey (RGB the mask,
    /// alpha 1) — what `SkinSmoothing` multiplies by.
    func ciImage(over extent: CGRect, drawnAt long: Int = 1024) -> CIImage? {
        let aspect = extent.width / max(extent.height, 1)
        let w = aspect >= 1 ? long : max(1, Int((CGFloat(long) * aspect).rounded()))
        let h = aspect >= 1 ? max(1, Int((CGFloat(long) / aspect).rounded())) : long
        guard let drawn = render(width: w, height: h) else { return nil }
        let feather = CGFloat(faceWidth) * CGFloat(w) * 0.03
        // Read as numbers, not as a grey to colour-manage: a feather of 0.5
        // must stay 0.5, not become a linearised 0.21.
        let soft = CIImage(cgImage: drawn, options: [.colorSpace: NSNull()]).clampedToExtent()
            .applyingGaussianBlur(sigma: Double(max(1, feather)))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
        let scale = CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return soft.samplingLinear().transformed(by: scale).cropped(to: extent)
    }
}
