//  SkinMask.swift — where the skin is, found on this Mac (ARCHITECTURE §7.14).
//
//  Vision's face boxes, then landmarks, on a render of the decode: for each face the
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
    /// Faces whose box was found but whose landmarks were not — too small or
    /// turned too far: people the smoothing leaves as they are.
    var missed = 0
    /// The searched picture's width over its height.
    var aspect = 1.0
    static let none = SkinMask(faces: [])

    var isEmpty: Bool { faces.isEmpty }

    /// The largest face's width as a share of the picture's long edge.
    var largestFace: Double {
        (faces.map { Double($0.box.width) }.max() ?? 0) * min(1, aspect)
    }

    /// Below this, even the largest face is small in the picture: on a group
    /// of about 25 at 1440 px the largest face was 3.5 % of the long edge and
    /// the smoothing showed only at 2× and up; a portrait of four, 17 %.
    static let smallFace = 0.05

    /// Every face found is small (`smallFace`): smoothing barely shows.
    var facesAreSmall: Bool { !isEmpty && largestFace < Self.smallFace }

    /// The median face width, as a fraction of the frame's width: what the
    /// smoothing's scales are set from.
    var faceWidth: Double {
        let w = faces.map { Double($0.box.width) }.sorted()
        return w.isEmpty ? 0 : w[w.count / 2]
    }

    /// How far over the brows the forehead is taken, as a share of the face box.
    static let forehead = 0.18

    /// The faces in `image`, in three steps, because Vision's own search
    /// shrinks what it is given and loses the small faces of a group:
    /// face boxes on the whole picture and on `tiles`×`tiles` overlapping
    /// tiles, merged; then each face's landmarks on its own crop, enlarged.
    /// Measured on a 1440 px group of about 25: the landmark request alone
    /// found 6, the boxes on 3×3 tiles 20, each with landmarks on its crop;
    /// on a 1027 px group of 10, 6 against 8. Enlarging the whole picture
    /// found no more — the search shrinks it back.
    static func detect(_ image: CGImage, tiles: Int = 3) throws -> SkinMask {
        let size = CGSize(width: image.width, height: image.height)
        var boxes: [CGRect] = []
        for tile in tileRects(size, n: tiles) {
            guard let crop = image.cropping(to: tile) else { continue }
            let request = VNDetectFaceRectanglesRequest()
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([request])
            boxes += (request.results ?? []).map { pixelRect($0.boundingBox, in: tile, of: size) }
        }
        let found = merged(boxes)
        let faces = found.compactMap { face(in: image, at: $0) }
        return SkinMask(faces: faces, missed: found.count - faces.count,
                        aspect: Double(size.width / max(size.height, 1)))
    }

    /// The whole picture, then `n`×`n` tiles overlapping by `overlap` of a
    /// tile: pixel rects, top-left origin (`CGImage.cropping`'s).
    static func tileRects(_ size: CGSize, n: Int, overlap: CGFloat = 0.3) -> [CGRect] {
        let whole = CGRect(origin: .zero, size: size)
        guard n > 1 else { return [whole] }
        let tw = size.width / (CGFloat(n) - CGFloat(n - 1) * overlap)
        let th = size.height / (CGFloat(n) - CGFloat(n - 1) * overlap)
        var out = [whole]
        for i in 0..<n {
            for j in 0..<n {
                out.append(CGRect(x: CGFloat(i) * tw * (1 - overlap), y: CGFloat(j) * th * (1 - overlap),
                                  width: tw, height: th).integral.intersection(whole))
            }
        }
        return out
    }

    /// The same face found on several tiles is one: largest first, a box
    /// that lies mostly (half of the smaller) inside one kept is dropped —
    /// which also drops the half of a big face a tile's edge cut off.
    static func merged(_ boxes: [CGRect]) -> [CGRect] {
        var kept: [CGRect] = []
        for b in boxes.sorted(by: { $0.width * $0.height > $1.width * $1.height }) {
            let seen = kept.contains { k in
                let i = k.intersection(b)
                return !i.isNull && i.width * i.height > 0.5 * min(k.width * k.height, b.width * b.height)
            }
            if !seen { kept.append(b) }
        }
        return kept
    }

    /// Vision's normalised rect (bottom-left) on `tile` as a pixel rect of
    /// the whole picture (top-left).
    private static func pixelRect(_ r: CGRect, in tile: CGRect, of size: CGSize) -> CGRect {
        CGRect(x: tile.minX + r.minX * tile.width, y: tile.minY + (1 - r.maxY) * tile.height,
               width: r.width * tile.width, height: r.height * tile.height)
    }

    /// The face whose box is `box` (pixels, top-left), from landmarks found
    /// on a crop twice its size enlarged to at least `cropShort` pixels.
    static let cropShort: CGFloat = 256

    private static func face(in image: CGImage, at box: CGRect) -> Face? {
        let size = CGSize(width: image.width, height: image.height)
        let r = box.insetBy(dx: -box.width / 2, dy: -box.height / 2)
            .intersection(CGRect(origin: .zero, size: size)).integral
        guard !r.isEmpty, let crop = image.cropping(to: r) else { return nil }
        let k = max(1, cropShort / CGFloat(min(crop.width, crop.height)))
        var input = CIImage(cgImage: crop)
        if k > 1 {
            input = input.applyingFilter("CILanczosScaleTransform",
                                         parameters: [kCIInputScaleKey: k, kCIInputAspectRatioKey: 1])
        }
        let request = VNDetectFaceLandmarksRequest()
        guard (try? VNImageRequestHandler(ciImage: input, options: [:]).perform([request])) != nil else { return nil }
        // The face nearest the crop's centre: a neighbour's may be in it too.
        let centre = CGPoint(x: 0.5, y: 0.5)
        func distance(_ f: VNFaceObservation) -> CGFloat { hypot(f.boundingBox.midX - centre.x, f.boundingBox.midY - centre.y) }
        guard let f = (request.results ?? []).min(by: { distance($0) < distance($1) }), let l = f.landmarks else { return nil }
        // Crop-normalised (bottom-left) to picture-normalised (bottom-left).
        let x0 = r.minX / size.width, y0 = (size.height - r.maxY) / size.height
        let sx = r.width / size.width, sy = r.height / size.height
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: x0 + p.x * sx, y: y0 + p.y * sy) }
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            (region?.pointsInImage(imageSize: CGSize(width: 1, height: 1)) ?? []).map(map)
        }
        let jaw = points(l.faceContour)
        guard jaw.count >= 3 else { return nil }
        let b = f.boundingBox
        let faceBox = CGRect(x: x0 + b.minX * sx, y: y0 + b.minY * sy, width: b.width * sx, height: b.height * sy)
        // The brows' points lifted over the forehead, right to left, close
        // the outline the jaw opens.
        let lift = faceBox.height * forehead
        let brows = (points(l.leftEyebrow) + points(l.rightEyebrow))
            .map { CGPoint(x: $0.x, y: $0.y + lift) }
            .sorted { $0.x > $1.x }
        let jawLeftToRight = jaw.first!.x <= jaw.last!.x ? jaw : jaw.reversed()
        let features = [l.leftEye, l.rightEye, l.leftEyebrow, l.rightEyebrow, l.outerLips, l.nose]
            .map(points).filter { $0.count >= 3 }
        return Face(box: faceBox, outline: jawLeftToRight + brows, features: features)
    }

    /// What `draw` puts on the page.
    enum Layer { case all, skin, features }

    /// The mask drawn at `width`×`height` (Core Graphics is y-up, as Vision's
    /// points are): skin white, features and outside black, the edge pulled
    /// in by a share of the face. Hard-edged; `ciImage` feathers it.
    func render(width: Int, height: Int) -> CGImage? { draw(width: width, height: height, .all) }

    /// `.skin` is the outline alone, on black; `.features` the features alone,
    /// black on white — the two parts `ciImage` feathers differently.
    func draw(width: Int, height: Int, _ layer: Layer) -> CGImage? {
        guard !isEmpty, width > 0, height > 0,
              let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: layer == .features ? 1 : 0, alpha: 1)
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
            if layer != .features {
                // Skin, pulled in from its edge by a black stroke.
                ctx.addPath(path(f.outline))
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.fillPath()
                ctx.addPath(path(f.outline))
                ctx.setStrokeColor(gray: 0, alpha: 1)
                ctx.setLineWidth(faceW * 0.06)
                ctx.strokePath()
            }
            guard layer != .skin else { continue }
            // Features, cut out a little wider than they are.
            for feature in f.features {
                ctx.addPath(path(feature))
                ctx.setFillColor(gray: 0, alpha: 1)
                ctx.fillPath()
                ctx.addPath(path(feature))
                ctx.setStrokeColor(gray: 0, alpha: 1)
                ctx.setLineWidth(faceW * Self.featureGrow * 2)
                ctx.setLineJoin(.round)
                ctx.strokePath()
            }
        }
        return ctx.makeImage()
    }

    /// How soft the skin's edge is, and the features' edges, as shares of
    /// the face's width. An eye is about a twentieth of a face tall, and one
    /// feather of 3 % over everything filled its hole back in: at full
    /// strength a group portrait's eye band went from 79 to 95 in its darkest
    /// 2 % (8-bit), the irises grey and the lash line gone. So the two are
    /// feathered apart and multiplied. A feature edge of 0.4 % kept the eye
    /// (81) and drew a hard line round the brows; 1 %, cut 2 % wider than the
    /// landmarks so the soft edge lies outside them, keeps both (83).
    static let feather = 0.03
    static let featureFeather = 0.01
    /// How far each feature is cut out past its landmarks, each side.
    static let featureGrow = 0.02

    /// The mask over `extent`, feathered, as a Core Image grey (RGB the mask,
    /// alpha 1) — what `SkinSmoothing` multiplies by.
    func ciImage(over extent: CGRect, drawnAt long: Int = 1024) -> CIImage? {
        let aspect = extent.width / max(extent.height, 1)
        let w = aspect >= 1 ? long : max(1, Int((CGFloat(long) * aspect).rounded()))
        let h = aspect >= 1 ? max(1, Int((CGFloat(long) / aspect).rounded())) : long
        guard let skin = draw(width: w, height: h, .skin),
              let features = draw(width: w, height: h, .features) else { return nil }
        let page = CGRect(x: 0, y: 0, width: w, height: h)
        let faceW = CGFloat(faceWidth) * CGFloat(w)
        // Read as numbers, not as a grey to colour-manage: a feather of 0.5
        // must stay 0.5, not become a linearised 0.21.
        func soft(_ image: CGImage, _ sigma: CGFloat) -> CIImage {
            CIImage(cgImage: image, options: [.colorSpace: NSNull()]).clampedToExtent()
                .applyingGaussianBlur(sigma: Double(max(0.5, sigma)))
                .cropped(to: page)
        }
        let mask = CIBlendKernel.componentMultiply.apply(foreground: soft(features, faceW * Self.featureFeather),
                                                         background: soft(skin, faceW * Self.feather))
        guard let mask else { return nil }
        let scale = CGAffineTransform(scaleX: extent.width / CGFloat(w), y: extent.height / CGFloat(h))
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return mask.samplingLinear().transformed(by: scale).cropped(to: extent)
    }
}
