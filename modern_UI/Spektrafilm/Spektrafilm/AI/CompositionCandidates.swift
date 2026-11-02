//  CompositionCandidates.swift — crops worth looking at, built by rule from
//  what the frame contains (AI assistant, ARCHITECTURE §7.14).
//
//  Pure: a frame size, the current geometry and a `CompositionAnalysis` in, a
//  short list of `Geometry`s out, each one that `Geometry.fits` and that
//  `AgentDocument.validate` will take. The rules are the ordinary ones — a
//  subject on a third, or centred for symmetry; a scene (a salient region over
//  `sceneArea`) as the largest crop slid to keep its top or bottom, or a side —
//  at a few common ratios in the picture's own orientation, levelled when the
//  horizon is tilted — and the
//  list always starts with the framing the frame has now, so "leave it" is one
//  of the answers. Which of them is best is the model's call, made on the
//  rendered crops.

import CoreGraphics
import CoreImage
import Foundation

struct CompositionCandidate: Equatable, Sendable {
    enum Kind: String, Sendable {
        case current, level, thirds, thirdsTight, centred, ratio, anchored
    }
    let geometry: Geometry
    let kind: Kind
    /// The ratio as the person sees it: "Original", "4:5", "1:1"…
    let label: String

    var straightened: Bool { geometry.angle != 0 }
}

enum CompositionCandidates {
    /// The smallest crop worth offering, as a fraction of the frame's area.
    static let minimumArea = 0.4
    /// Two crops this alike are one crop.
    static let duplicateIoU = 0.9

    /// The ratios offered, in the orientation the picture is seen in.
    static func aspects(landscape: Bool) -> [CropAspect] {
        landscape ? [.original, .r3x2, .r5x4, .square, .r16x9]
                  : [.original, .r2x3, .r4x5, .square, .r9x16]
    }

    static func make(current: Geometry, analysis a: CompositionAnalysis, imageSize: CGSize,
                     limit: Int = 12) -> [CompositionCandidate] {
        let size = CGSize(width: max(imageSize.width, 1), height: max(imageSize.height, 1))
        let sourceAspect = Double(size.width / size.height)
        let oddTurns = current.quarterTurns % 2 != 0
        // The ratio the person sees is after the quarter turns; the crop's is before.
        let landscape = (sourceAspect >= 1) != oddTurns
        let angle = a.straighten

        var out: [CompositionCandidate] = [
            CompositionCandidate(geometry: current, kind: .current, label: label(for: current.aspect)),
        ]
        func add(_ g: Geometry?, _ kind: CompositionCandidate.Kind, _ shown: CropAspect) {
            guard let g, acceptable(g, kind: kind, analysis: a, in: size) else { return }
            let c = CompositionCandidate(geometry: g, kind: kind, label: label(for: shown))
            guard !out.contains(where: { alike($0.geometry, g) }) else { return }
            out.append(c)
        }
        // The whole frame, levelled.
        if angle != 0 {
            add(place(current: current, aspect: .original, sourceAspect: sourceAspect, fraction: 1,
                      centre: CGPoint(x: 0.5, y: 0.5), angle: angle, in: size), .level, .original)
        }
        let ratios = aspects(landscape: landscape).map { shown in
            (shown: shown, crop: oddTurns && shown != .original ? shown.transposed : shown)
        }
        if let s = a.subject, !isScene(s) {
            // A subject: on a third, tighter on a third, or centred.
            let sc = CGPoint(x: s.midX, y: s.midY)
            for r in ratios {
                for (fraction, kind) in [(1.0, CompositionCandidate.Kind.thirds), (0.8, .thirdsTight)] {
                    add(thirds(current: current, aspect: r.crop, sourceAspect: sourceAspect, fraction: fraction,
                               subject: sc, eyes: !a.faces.isEmpty, angle: angle, in: size), kind, r.shown)
                }
                add(place(current: current, aspect: r.crop, sourceAspect: sourceAspect, fraction: 0.85,
                          centre: sc, angle: angle, in: size), .centred, r.shown)
            }
        } else {
            // A scene, or nothing in particular: what a crop decides is how much
            // sky and how much foreground (or of each side) it keeps. Placement
            // by placement across the ratios, so the limit drops a placement
            // rather than a whole ratio.
            func largest(_ r: CropAspect, _ c: CGPoint) -> Geometry? {
                place(current: current, aspect: r, sourceAspect: sourceAspect, fraction: 1, centre: c, angle: angle, in: size)
            }
            let centred = ratios.map { (r: $0, g: largest($0.crop, CGPoint(x: 0.5, y: 0.5))) }
            for x in centred { add(x.g, .ratio, x.r.shown) }
            for x in centred {
                guard let g = x.g else { continue }
                let cw = Double(g.crop.width), ch = Double(g.crop.height)
                if ch < 0.97 {
                    add(largest(x.r.crop, CGPoint(x: 0.5, y: ch / 2)), .anchored, x.r.shown)       // keeps the top
                    add(largest(x.r.crop, CGPoint(x: 0.5, y: 1 - ch / 2)), .anchored, x.r.shown)   // keeps the bottom
                }
                if cw < 0.97 {
                    add(largest(x.r.crop, CGPoint(x: cw / 2, y: 0.5)), .anchored, x.r.shown)
                    add(largest(x.r.crop, CGPoint(x: 1 - cw / 2, y: 0.5)), .anchored, x.r.shown)
                }
            }
            for r in ratios {
                add(place(current: current, aspect: r.crop, sourceAspect: sourceAspect, fraction: 0.85,
                          centre: CGPoint(x: 0.5, y: 0.5), angle: angle, in: size), .centred, r.shown)
            }
        }
        return Array(out.prefix(limit))
    }

    /// The ratio as it is seen: `CropAspect.label` names a ratio once for
    /// both orientations ("3:2" for 2:3 too), which on a portrait crop read as
    /// the wrong way round — the model called a 2:3 crop "3:2". Upright
    /// ratios are written upright.
    static func label(for aspect: CropAspect) -> String {
        let l = aspect.label
        guard aspect.isPortrait, aspect.fixedRatio != nil else { return l }
        let parts = l.split(separator: ":")
        return parts.count == 2 ? "\(parts[1]):\(parts[0])" : l
    }

    // MARK: building one

    /// A crop of `aspect` at `fraction` of the largest that fits at the frame's
    /// centre, centred as near `centre` as it can be while still fitting.
    static func place(current: Geometry, aspect: CropAspect, sourceAspect: Double, fraction: Double,
                      centre: CGPoint, angle: Double, in size: CGSize) -> Geometry? {
        guard let r = aspect.ratio(sourceAspect: sourceAspect), r > 0 else { return nil }
        let w = Double(size.width), h = Double(size.height)
        let s0 = Geometry.maxScale(halfExtents: CGSize(width: r / 2, height: 0.5),
                                   centre: CGPoint(x: w / 2, y: h / 2), angle: angle, in: size)
        guard s0 > 0 else { return nil }
        let heightPx = s0 * min(1, fraction), widthPx = r * heightPx
        let cw = widthPx / w, ch = heightPx / h
        func geometry(_ c: CGPoint) -> Geometry {
            var g = current
            g.crop = CropRect(x: c.x - cw / 2, y: c.y - ch / 2, width: cw, height: ch)
            g.angle = angle
            g.aspect = aspect
            g.intendedSize = nil
            g.lockedRatio = nil
            return g
        }
        let frame = CGPoint(x: 0.5, y: 0.5)
        // Walk from the wanted centre toward the frame's until it fits; the
        // frame's centre always does, by the size chosen above.
        var lo = 0.0, hi = 1.0
        if geometry(centre).fits(in: size) { hi = 0 } else {
            for _ in 0..<30 {
                let mid = (lo + hi) / 2
                let c = CGPoint(x: centre.x + (frame.x - centre.x) * mid, y: centre.y + (frame.y - centre.y) * mid)
                if geometry(c).fits(in: size) { hi = mid } else { lo = mid }
            }
        }
        let c = CGPoint(x: centre.x + (frame.x - centre.x) * hi, y: centre.y + (frame.y - centre.y) * hi)
        return geometry(c).snappedToFrame()
    }

    /// The subject on the nearest third: left or right by which half it is in,
    /// and for a face the upper third, where the eyes go.
    static func thirds(current: Geometry, aspect: CropAspect, sourceAspect: Double, fraction: Double,
                       subject: CGPoint, eyes: Bool, angle: Double, in size: CGSize) -> Geometry? {
        guard let probe = place(current: current, aspect: aspect, sourceAspect: sourceAspect, fraction: fraction,
                                centre: CGPoint(x: 0.5, y: 0.5), angle: angle, in: size) else { return nil }
        let cw = probe.crop.width, ch = probe.crop.height
        let tx = subject.x < 0.5 ? 1.0 / 3 : 2.0 / 3
        let ty = eyes ? 1.0 / 3 : (subject.y < 0.5 ? 1.0 / 3 : 2.0 / 3)
        let centre = CGPoint(x: subject.x - (tx - 0.5) * cw, y: subject.y - (ty - 0.5) * ch)
        return place(current: current, aspect: aspect, sourceAspect: sourceAspect, fraction: fraction,
                     centre: centre, angle: angle, in: size)
    }

    // MARK: keeping one

    static func acceptable(_ g: Geometry, kind: CompositionCandidate.Kind, analysis a: CompositionAnalysis,
                           in size: CGSize) -> Bool {
        let c = g.crop
        // What the edit document will take: the rectangle itself inside 0…1.
        guard c.x >= -1e-6, c.y >= -1e-6, c.x + c.width <= 1 + 1e-6, c.y + c.height <= 1 + 1e-6,
              g.fits(in: size) else { return false }
        if kind != .level, c.width * c.height < minimumArea { return false }
        // A face is never cut; what draws the eye is kept almost whole. Only
        // the subject's centre was required at first, and a tight crop of a
        // night sky took the top off the firework the whole picture is of.
        for f in a.faces where !contains(g, f, in: size) { return false }
        if let s = a.subject, a.faces.isEmpty,
           coverage(g, s, in: size) < (isScene(s) ? sceneKept : subjectKept) { return false }
        return true
    }

    /// The share of the subject a crop must keep.
    static let subjectKept = 0.9
    /// A salient region larger than this share of the frame is the scene, not
    /// a subject: a landscape's came back the whole width and 75 % of the
    /// frame, and keeping 90 % of it left three crops. A firework's (about a
    /// third) is still a subject.
    static let sceneArea = 0.35
    /// The share of a scene a crop must keep.
    static let sceneKept = 0.6

    static func isScene(_ r: CGRect) -> Bool { Double(r.width * r.height) > sceneArea }

    /// The fraction of `r` (normalised, top-left) inside the crop at its
    /// angle, sampled on a grid — exact enough for a 10 % threshold.
    static func coverage(_ g: Geometry, _ r: CGRect, in size: CGSize) -> Double {
        guard r.width > 0, r.height > 0 else {
            return contains(g, CGRect(x: r.midX, y: r.midY, width: 0, height: 0), in: size) ? 1 : 0
        }
        let n = 12
        var inside = 0
        for i in 0..<n {
            for j in 0..<n {
                let p = CGRect(x: r.minX + r.width * (Double(i) + 0.5) / Double(n),
                               y: r.minY + r.height * (Double(j) + 0.5) / Double(n), width: 0, height: 0)
                if contains(g, p, in: size) { inside += 1 }
            }
        }
        return Double(inside) / Double(n * n)
    }

    /// Whether every corner of `r` (normalised, top-left) lands inside the
    /// crop once the crop's rotation is taken out.
    static func contains(_ g: Geometry, _ r: CGRect, in size: CGSize) -> Bool {
        let c = g.crop
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)].allSatisfy { p in
            let q = g.unrotated(p, in: size)
            return q.x >= c.x - 1e-6 && q.x <= c.x + c.width + 1e-6 && q.y >= c.y - 1e-6 && q.y <= c.y + c.height + 1e-6
        }
    }

    /// The same angle and an IoU above `duplicateIoU` of the unrotated crops.
    static func alike(_ a: Geometry, _ b: Geometry) -> Bool {
        guard abs(a.angle - b.angle) < 0.05 else { return false }
        let ra = CGRect(x: a.crop.x, y: a.crop.y, width: a.crop.width, height: a.crop.height)
        let rb = CGRect(x: b.crop.x, y: b.crop.y, width: b.crop.width, height: b.crop.height)
        let i = ra.intersection(rb)
        guard !i.isNull else { return false }
        let inter = Double(i.width * i.height)
        let union = Double(ra.width * ra.height + rb.width * rb.height) - inter
        return union > 0 && inter / union > duplicateIoU
    }
}

// MARK: - the crops, rendered

extension CompositionCandidates {
    private static let context = CIContext(options: [.cacheIntermediates: false])

    /// `geometry` applied to the whole-frame `proof` through the transform the
    /// engine is handed a cut frame with (`Session.engineImage`) — so a tile
    /// is the crop Apply will make, turns and flips included — at `longEdge`.
    static func render(_ geometry: Geometry, from proof: CGImage, longEdge: Int) -> CGImage? {
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let size = CGSize(width: proof.width, height: proof.height)
        var image = Session.engineImage(CIImage(cgImage: proof), size: size,
                                        cut: geometry.isIdentity ? nil : geometry)
        let long = max(image.extent.width, image.extent.height)
        guard long > 0 else { return nil }
        if long > CGFloat(longEdge) {
            image = image.applyingFilter("CILanczosScaleTransform",
                                         parameters: [kCIInputScaleKey: CGFloat(longEdge) / long,
                                                      kCIInputAspectRatioKey: 1])
        }
        return context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: srgb)
    }
}
