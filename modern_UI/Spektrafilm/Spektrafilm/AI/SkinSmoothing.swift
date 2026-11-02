//  SkinSmoothing.swift — the one retouch, done to the decode before the film
//  (ARCHITECTURE §7.4, §7.14).
//
//  A band-stop on the skin: what lies between a pore and a cheek — blotches,
//  uneven patches, small marks — is taken out; what is finer (pores, fine
//  texture) and what is coarser (the face's own light and shape) is kept.
//
//      out = img + w · (blur(σ₂) − blur(σ₁)),   w = strength × mask
//
//  σ₁ ≈ 0.4 % and σ₂ ≈ 4 % of the face's width, so the same strength means the
//  same thing on a head-and-shoulders and on a group. It runs on the linear
//  float decode the engine is about to be handed, so the film adds its grain
//  over it afterwards. Built from Core Image's own component kernels only:
//  values may go negative in the band and nothing here clamps them.

import CoreImage
import Foundation

enum SkinSmoothing {
    /// The band's edges as shares of the median face's width.
    static let fine = 0.004
    static let coarse = 0.04

    /// `linear` with the skin smoothed by `strength` (0…1) where `mask` says
    /// skin. The input, unchanged, when there is nothing to do.
    static func apply(_ linear: CIImage, mask: SkinMask, strength: Double) -> CIImage {
        let s = min(1, max(0, strength))
        let extent = linear.extent
        guard s > 0, !mask.isEmpty, !extent.isInfinite, extent.width > 0,
              let m = mask.ciImage(over: extent) else { return linear }
        let faceWidth = mask.faceWidth * Double(extent.width)
        let sigma1 = max(0.6, faceWidth * fine)
        let sigma2 = max(sigma1 * 3, faceWidth * coarse)
        let base = linear.clampedToExtent()
        let b1 = base.applyingGaussianBlur(sigma: sigma1).cropped(to: extent)
        let b2 = base.applyingGaussianBlur(sigma: sigma2).cropped(to: extent)
        // Every operand opaque: Core Image keeps colour premultiplied, so a
        // constant with alpha 0 would be stored as 0 and multiply everything
        // away. The component kernels add the alphas up as well; the sum is
        // put back to 1 at the end, the colour untouched.
        let band = add(b2, multiply(b1, constant(-1, over: extent)))      // b2 − b1
        let w = multiply(m, constant(s, over: extent))                    // strength × mask
        return add(linear, multiply(band, w)).settingAlphaOne(in: extent).cropped(to: extent)
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
