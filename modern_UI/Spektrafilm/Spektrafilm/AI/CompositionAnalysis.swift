//  CompositionAnalysis.swift — what the frame contains, measured on this Mac
//  (AI assistant, ARCHITECTURE §7.14).
//
//  Apple's Vision framework, on the whole-frame proof: the horizon's tilt, the
//  regions that draw the eye, and faces. No network and no model. Everything
//  is returned in `Geometry`'s own frame — normalised to the photograph, top
//  left origin, y down, angles clockwise-positive — so the candidates built
//  from it need no conversion; Vision's bottom-left origin is turned around
//  here, once.
//
//  A vision model is good at judging pictures and poor at naming exact
//  coordinates, so it never names them: geometry is measured and built here
//  (`CompositionCandidates`), and the model only picks among rendered crops.

import CoreGraphics
import Foundation
import Vision

struct CompositionAnalysis: Sendable {
    /// The straighten that levels the horizon, in `Geometry.angle`'s degrees,
    /// or 0 when there is no horizon or it is within `levelTolerance`.
    var straighten: Double
    /// The horizon's tilt as measured, before the tolerance: nil with no horizon.
    var horizonTilt: Double?
    /// Regions that draw the eye, normalised, top-left origin.
    var salient: [CGRect]
    var faces: [CGRect]

    /// Below this a tilt is noise, or the photographer's choice.
    static let levelTolerance = 0.5

    /// Where the subject is: the faces when there are any, else the salient
    /// regions; nil when neither was found.
    var subject: CGRect? {
        let boxes = faces.isEmpty ? salient : faces
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Vision's normalised rectangle (bottom-left origin) in the frame's own
    /// top-left one.
    static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    /// Vision's horizon angle (radians) as the straighten that levels it
    /// (`Geometry.angle`'s degrees, clockwise-positive). Measured, not taken
    /// from the documentation: a horizon descending to the right comes back
    /// from Vision positive, and is levelled by turning the crop the same way
    /// by the same amount — so the conversion is units only.
    /// `CompositionTests.testATiltedHorizonIsLevelledTheRightWay` holds the
    /// sign; the first version negated it and levelled every horizon twice
    /// as crooked.
    static func straighten(fromVisionAngle radians: Double) -> Double {
        radians * 180 / .pi
    }

    static func analyse(_ image: CGImage) throws -> CompositionAnalysis {
        let horizon = VNDetectHorizonRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        let faces = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([horizon, saliency, faces])

        let tilt = (horizon.results?.first).map { straighten(fromVisionAngle: Double($0.angle)) }
        var level = 0.0
        if let t = tilt, abs(t) >= levelTolerance, abs(t) <= Geometry.maxAngle { level = t }
        let salient = (saliency.results?.first?.salientObjects ?? []).map { topLeft($0.boundingBox) }
        let faceBoxes = (faces.results ?? []).map { topLeft($0.boundingBox) }
        return CompositionAnalysis(straighten: level, horizonTilt: tilt, salient: salient, faces: faceBoxes)
    }
}
