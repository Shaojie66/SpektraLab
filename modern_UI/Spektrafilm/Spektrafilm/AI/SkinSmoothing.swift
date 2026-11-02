//  SkinSmoothing.swift — the one retouch, done to the decode before the film
//  (ARCHITECTURE §7.4, §7.14).
//
//  A band-stop on the skin: what lies between a pore and a cheek — blotches,
//  uneven patches, small marks — is taken out; what is finer (pores, fine
//  texture) and what is coarser (the face's own light and shape) is kept.
//
//      out = img + w · (blur(σ₂) − blur(σ₁)),   w = strength × mask
//
//  where each blur is an average **over the skin alone** — weighted by the
//  mask and the edge guard, so a lip, a nostril, an eye or a glasses frame is
//  not averaged into the skin beside it (`weightedBlur`).
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
            // The averages are over this face's skin: what the mask cuts out,
            // what the edge guard holds off, and what is too dark or too
            // light against the skin around it to be a blotch (a nose pad,
            // a lens's glare) is not averaged in, and not smoothed.
            let skin = multiply(m, keep).clampedToExtent()
            let around = weightedBlur(base, weight: skin, sigma: sigma2, region: region)
            // Softened by a share of the face, so its edge is not a line of
            // its own across stubble or a shadow.
            let objects = objectGuard(base.cropped(to: region), around: around, region: region)
                .clampedToExtent().applyingGaussianBlur(sigma: max(1, faceWidth * objectSoftness)).cropped(to: region)
            let weight = multiply(skin, objects.clampedToExtent())
            let b1 = weightedBlur(base, weight: weight, sigma: sigma1, region: region)
            let b2 = weightedBlur(base, weight: weight, sigma: sigma2, region: region)
            var band = add(b2, multiply(b1, constant(-1, over: region)))             // b2 − b1
            if soft > 0 {
                // + softness × share × (b1 − img): the fine texture, softened too.
                let fine = add(b1, multiply(base.cropped(to: region), constant(-1, over: region)))
                band = add(band, multiply(fine, constant(softness * min(1, soft), over: region)))
            }
            let w = multiply(weight.cropped(to: region), constant(s, over: region))       // strength × mask × guards
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

    /// `blur(img · w) / blur(w)`: the Gaussian average of the picture over the
    /// weight alone (normalised convolution). A plain blur took a lip or a
    /// nostril into the skin beside it: on a close selfie at full strength a
    /// quarter of the face moved by more than 6 levels, dark under the nose
    /// and the lip, light round the nose, and jagged along a glasses frame.
    static func weightedBlur(_ image: CIImage, weight: CIImage, sigma: Double, region: CGRect) -> CIImage {
        let num = multiply(image, weight).applyingGaussianBlur(sigma: sigma).cropped(to: region)
        let den = weight.applyingGaussianBlur(sigma: sigma).cropped(to: region)
        return multiply(num, reciprocal(den, over: region)).settingAlphaOne(in: region)
    }

    /// Where less than this share of a blur's reach is skin, the average is
    /// not trusted: the weight there is nearly 0 as well.
    static let weightFloor = 0.02

    /// `1 / d` for d held within `floor`…1.9, by Newton's step
    /// `r ← r(2 − d·r)` from 1: the error squares each step, so from the
    /// floor's 1 − floor it is under 1e-8 after `steps` of them. Not Core
    /// Image's divide: measured 2026-11-02, on the GPU it returned the
    /// quotient less the divisor (0.0203 / 1 → −0.98), and it clamps to 0…1.
    static func reciprocal(_ d: CIImage, floor: Double = weightFloor, over region: CGRect) -> CIImage {
        let held = CIBlendKernel.componentMin.apply(
            foreground: constant(1.9, over: region),
            background: CIBlendKernel.componentMax.apply(foreground: constant(floor, over: region), background: d) ?? d) ?? d
        let steps = Int(ceil(log2(log(1e-8) / log(1 - floor))))
        var r = constant(1, over: region)
        for _ in 0..<steps {
            // Alpha back to 1 each step: the component kernels add and
            // multiply it too, and twelve steps took it past half float's
            // range. A filter that unpremultiplies (CIColorMatrix) then read
            // the colour as nearly 0.
            r = multiply(r, add(constant(2, over: region), multiply(multiply(held, r), constant(-1, over: region))))
                .settingAlphaOne(in: region)
        }
        return r
    }

    /// Where a pixel's luminance lies against the skin around it, as a share
    /// of it, an object begins: below `objectDark` (fully held off by
    /// `objectDark` − `darkWidth`), above `objectLight` (fully by + 0.7). A
    /// blotch or a red mark is within 10–20 % of the skin around it; a
    /// glasses' nose pad is a tenth of it, and the band, which held off only
    /// its rim, filled its inside with skin. Not higher: at 0.6 the shadow
    /// under a lip, stubble and a nostril's rim (0.4–0.6) were held off too,
    /// in hard-edged patches beside smoothed skin, on a close selfie at full
    /// strength. A very dark mole is kept.
    static let objectDark = 0.35
    static let darkWidth = 0.2
    static let objectLight = 1.8
    /// The guard's own softening, as a share of the face's width.
    static let objectSoftness = 0.005

    /// 1 on skin, 0 on what is too dark or too light against `around` to be
    /// skin. Opaque grey.
    static func objectGuard(_ image: CIImage, around: CIImage, region: CGRect) -> CIImage {
        let ratio = multiply(luminance(image), reciprocal(luminance(around), floor: 0.005, over: region))
            .settingAlphaOne(in: region)
        func ramp(_ gain: Double, _ bias: Double) -> CIImage {
            ratio.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: gain, y: 0, z: 0, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 1),
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
            ])
        }
        let lightWidth = 0.7
        let dark = ramp(1 / darkWidth, -(objectDark - darkWidth) / darkWidth)        // 0 at dark − width, 1 at dark
        let light = ramp(-1 / lightWidth, (objectLight + lightWidth) / lightWidth)  // 1 at light, 0 at light + width
        return multiply(dark, light).cropped(to: region)
    }

    /// Rec. 709 luminance in every channel, alpha 1.
    private static func luminance(_ image: CIImage) -> CIImage {
        let v = CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": v, "inputGVector": v, "inputBVector": v,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
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
