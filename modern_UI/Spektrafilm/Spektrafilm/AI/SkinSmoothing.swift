//  SkinSmoothing.swift — the one retouch, done to the decode before the film
//  (ARCHITECTURE §7.4, §7.14).
//
//  A band-stop on the skin: what lies between a pore and a cheek — blotches,
//  uneven patches, small marks — is taken out; what is finer (pores, fine
//  texture) and what is coarser (the face's own light and shape) is kept.
//
//      out = img + w · (blur(σ₂) − blur(σ₁)),   w = strength × mask
//
//  σ₁ ≈ 0.4 % and σ₂ ≈ 4 % of **each** face's own width, so the same strength
//  means the same thing on a head-and-shoulders and on a face at the back of
//  a group; and the weight falls away at sharp edges (glasses frames, hair). It runs on the linear
//  float decode the engine is about to be handed, so the film adds its grain
//  over it afterwards. Built from Core Image's own component kernels only:
//  values may go negative in the band and nothing here clamps them.

import CoreImage
import Foundation

enum SkinSmoothing {
    /// The band's edges as shares of **each** face's own width. The upper
    /// edge widens with the strength, from `coarse` to `coarse × (1 +
    /// coarseReach)` at 1, so a strong setting takes out more of the blotches:
    /// a blotch a sixth of a face wide goes from about 70 % removed to about
    /// 93 %. Not further: a Gaussian reaches well past its σ, and at 8 % the
    /// face's own shape at half its width (the cheeks' light) lost ~40 %; at
    /// 6 % it keeps ~74 % (`SkinTests.testEachFaceIsSmoothedAtItsOwnScale`).
    static let fine = 0.004
    static let coarse = 0.04
    static let coarseReach = 0.5
    /// Soft skin: how much of the texture finer than σ₁ is softened, at full
    /// strength and a whole share, on top of the band. The share follows the
    /// grain (`RetouchSettings.softShare`).
    static let softness = 0.6
    /// The edge guard: `CIEdges` answers on the one or two pixels of an edge,
    /// and weakly — about 0.04 for a 0.15 step in linear light. Below
    /// `edgeFloor` (pores, fine texture) nothing is held off; above it the
    /// weight falls to 0 within `1 / edgeGain`, and the hold is spread
    /// `edgeReach` pixels each side so a frame's whole line is kept. Measured
    /// on a drawn frame (`SkinTests.testASharpEdgeIsHeldOffTheSmoothing`): a
    /// first guard, unthresholded and blurred instead of spread, kept half
    /// the frame's contrast.
    static let edgeFloor = 0.015
    static let edgeGain = 80.0
    static let edgeReach = 2.0

    /// `linear` with the skin smoothed by `strength` (0…1) where `mask` says
    /// skin, and `soft` (0…1) of soft skin's share on top. The input,
    /// unchanged, when there is nothing to do.
    ///
    /// Each face is done at its own scale. A first version set the band from
    /// the median face, and in a group the small faces at the back were
    /// smoothed at the front faces' scale — their shape taken for blotches,
    /// their glasses' frames softened.
    static func apply(_ linear: CIImage, mask: SkinMask, strength: Double, soft: Double = 0) -> CIImage {
        let s = min(1, max(0, strength))
        let extent = linear.extent
        guard s > 0, !mask.isEmpty, !extent.isInfinite, extent.width > 0 else { return linear }
        let base = linear.clampedToExtent()
        let keep = edgeGuard(base, extent: extent)
        // Every operand opaque: Core Image keeps colour premultiplied, so a
        // constant with alpha 0 would be stored as 0 and multiply everything
        // away. The component kernels add the alphas up as well; the sum is
        // put back to 1 at the end, the colour untouched.
        var out = linear
        for face in mask.faces {
            let one = SkinMask(faces: [face])
            guard let m = one.ciImage(over: extent) else { continue }
            let faceWidth = Double(face.box.width * extent.width)
            let sigma1 = max(0.6, faceWidth * fine)
            let sigma2 = max(sigma1 * 3, faceWidth * coarse * (1 + coarseReach * s))
            // Only around this face: the blurs are as wide as the face needs.
            let box = CGRect(x: extent.minX + face.box.minX * extent.width,
                             y: extent.minY + face.box.minY * extent.height,
                             width: face.box.width * extent.width, height: face.box.height * extent.height)
            let region = box.insetBy(dx: -box.width * 0.4 - sigma2 * 3, dy: -box.height * 0.4 - sigma2 * 3)
                .intersection(extent)
            guard !region.isEmpty else { continue }
            let b1 = base.applyingGaussianBlur(sigma: sigma1).cropped(to: region)
            let b2 = base.applyingGaussianBlur(sigma: sigma2).cropped(to: region)
            var band = add(b2, multiply(b1, constant(-1, over: region)))             // b2 − b1
            if soft > 0 {
                // + softness × share × (b1 − img): the fine texture, softened too.
                let fine = add(b1, multiply(base.cropped(to: region), constant(-1, over: region)))
                band = add(band, multiply(fine, constant(softness * min(1, soft), over: region)))
            }
            let w = multiply(multiply(m.cropped(to: region), keep.cropped(to: region)),
                             constant(s, over: region))                               // strength × mask × guard
            out = add(out, multiply(band, w))
        }
        return out.settingAlphaOne(in: extent).cropped(to: extent)
    }

    /// 1 on smooth skin, 0 on and beside a sharp edge:
    /// 1 − clamp(gain·(|∇| − floor)), then spread by a minimum filter.
    /// Opaque grey.
    static func edgeGuard(_ base: CIImage, extent: CGRect) -> CIImage {
        let edges = base.applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: 1.0])
        let g = edgeGain / 3
        // 1 + gain·floor − gain × the mean of the channels, in every channel; alpha 1.
        let bias = 1 + edgeGain * edgeFloor
        let inverted = edges.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: -g, y: -g, z: -g, w: 0),
            "inputGVector": CIVector(x: -g, y: -g, z: -g, w: 0),
            "inputBVector": CIVector(x: -g, y: -g, z: -g, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
        ])
        return inverted.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
        ])
        .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: edgeReach])
        .cropped(to: extent)
    }

    // MARK: component arithmetic

    /// A grey constant, opaque. Grey is neutral in every linear RGB space the
    /// working space might be, so −1 and the strength arrive as themselves.
    private static func constant(_ v: Double, over extent: CGRect) -> CIImage {
        CIImage(color: CIColor(red: v, green: v, blue: v, alpha: 1,
                               colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: extent)
    }

    private static func add(_ a: CIImage, _ b: CIImage) -> CIImage {
        CIBlendKernel.componentAdd.apply(foreground: b, background: a) ?? a
    }

    private static func multiply(_ a: CIImage, _ b: CIImage) -> CIImage {
        CIBlendKernel.componentMultiply.apply(foreground: b, background: a) ?? a
    }
}
