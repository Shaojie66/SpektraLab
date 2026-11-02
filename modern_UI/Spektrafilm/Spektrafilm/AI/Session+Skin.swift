//  Session+Skin.swift — the faces in the open frame, for skin smoothing
//  (ARCHITECTURE §7.4, §7.14).
//
//  Found once per frame and decode on a 2048 px render of Apple's own
//  rendering of the decode (what Vision's face models are trained on), and
//  kept, so a change of strength is a re-open and not a re-detection.

import CoreGraphics
import CoreImage
import Foundation

extension Session {
    /// The long edge faces are looked for at: tiled (`SkinMask.detect`), so
    /// the faces at the back of a group keep enough pixels to be found.
    nonisolated static let skinDetectionLongEdge: CGFloat = 2048

    /// The skin in `d`, the decode of `url`: from the cache when the frame
    /// and its decode settings are the same, found otherwise. Empty when no
    /// face is found or the search fails — smoothing then does nothing.
    func skinMask(for d: DecodedImage, url: URL) async -> SkinMask {
        let key = CacheKey.encodedConfiguration(sidecar.decode)
        if let s = skinMaskState, s.url == url, s.key == key { return s.mask }
        let display = d.display
        let mask = await Task.detached(priority: .userInitiated) { () -> SkinMask in
            let long = max(display.extent.width, display.extent.height)
            guard long > 0 else { return .none }
            let scale = min(1, Session.skinDetectionLongEdge / long)
            let small = display.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let cg = ImageDecoder.context.createCGImage(small, from: small.extent.integral,
                                                              format: .RGBA8, colorSpace: srgb)
            else { return .none }
            return (try? SkinMask.detect(cg)) ?? .none
        }.value
        guard selection == url else { return mask }
        skinMaskState = (url, key, mask)
        return mask
    }

    /// Find the faces in the open frame, for the Portrait section's count and
    /// the refiner's notes. Nil when nothing is open or it is a pair.
    @discardableResult
    func refreshSkinMask() async -> SkinMask? {
        guard pair == nil, let url = selection, let d = await ensureDecoded() else { return nil }
        return await skinMask(for: d, url: url)
    }

    /// The faces found in the open frame, or nil when not looked for yet.
    var skinFaceCount: Int? {
        guard let s = skinMaskState, s.url == selection else { return nil }
        return s.mask.faces.count
    }
}
