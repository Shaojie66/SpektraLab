//  PortraitSection.swift — Pre-Dev ▸ Portrait: skin smoothing (ARCHITECTURE
//  §7.4, §7.14).
//
//  On the Pre-Dev tab because that is where it runs: on the decode, before
//  the film. A change re-develops the frame, so the slider moves freely and
//  writes once, on release — the Camera rows' rule for anything that costs an
//  open.

import SwiftUI

struct PortraitSection: View {
    @Bindable var session: Session
    /// The value under the hand while the slider is dragged; nil otherwise.
    @State private var draft: Double?

    private var committed: Double { session.params.retouch.skinSmoothing * 100 }
    private var faces: Int? { session.skinFaceCount }

    var body: some View {
        PanelSection(L("Portrait", zh: "人像"), key: "portrait",
                     action: SectionAction(help: L("Turn skin smoothing off.", zh: "关闭磨皮。"),
                                           enabled: session.params.retouch.isActive) { set(0) }) {
            RailRows {
                ScrubSlider(label: L("Skin smoothing", zh: "磨皮"), sublabel: sublabel,
                            value: Binding(get: { draft ?? committed }, set: { draft = $0 }),
                            range: 0...100, zero: 0, snap: 5,
                            format: { String(format: "%.0f", $0) },
                            onCommit: { if let d = draft { set(d / 100) }; draft = nil })
                    .rowEnabled(usable, because: reason)
                ToggleRow(label: L("Soft skin", zh: "柔肤"),
                          isOn: Binding(get: { session.params.retouch.soft },
                                        set: { on in var p = session.params; p.retouch.soft = on; session.params = p }),
                          enabled: usable && session.params.retouch.isActive,
                          reason: usable ? L("Turn skin smoothing up first.", zh: "先调高磨皮强度。") : reason,
                          sublabel: softSublabel)
            }
        }
        .task(id: session.selection) { await session.refreshSkinMask() }
    }

    private var unavailable: String? {
        Self.unavailable(pair: session.pair != nil, noFilm: session.noFilm, faces: faces)
    }
    private var usable: Bool { unavailable == nil }
    private var reason: String { unavailable ?? "" }

    /// Why skin smoothing cannot be used on this frame; nil when it can.
    /// With the film simulation off the canvas shows the untouched decode —
    /// the smoothing is done to the frame handed to the film — so a slider
    /// left live there moved nothing on screen.
    static func unavailable(pair: Bool, noFilm: Bool, faces: Int?) -> String? {
        if pair { return L("Not available on a half-frame pair yet.", zh: "暂不支持半格拼接。") }
        if noFilm {
            return L("Smoothing is done before the film, so it does not apply with the film simulation off.",
                     zh: "磨皮在胶片之前处理，关闭胶片模拟时不生效。")
        }
        if (faces ?? 0) == 0 { return L("No face was found in this frame.", zh: "这张照片里没有检测到人脸。") }
        return nil
    }

    private var sublabel: String {
        // Said on the row, not only in the disabled row's help: it is why
        // the slider is grey.
        if session.noFilm, let why = unavailable { return why }
        guard let mask = session.skinFaces else { return L("Looking for faces…", zh: "正在检测人脸……") }
        return Self.note(mask)
    }

    /// The faces line: how many, how many are left alone and why, and when
    /// they are all too small for the smoothing to show.
    static func note(_ mask: SkinMask) -> String {
        let n = mask.faces.count
        if n == 0 {
            return mask.missed > 0
                ? L("\(mask.missed) face(s) whose features cannot be read (too small, turned or covered)",
                    zh: "有 \(mask.missed) 张脸看不清五官（太小、太偏或被遮挡），无法磨皮")
                : L("No face found", zh: "没有检测到人脸")
        }
        var en = n == 1 ? "1 face" : "\(n) faces", zh = "检测到 \(n) 张人脸"
        if mask.missed > 0 {
            en += " · \(mask.missed) more with features that cannot be read, left as they are"
            zh += " · 另有 \(mask.missed) 张看不清五官，不处理"
        }
        if mask.facesAreSmall {
            en += " · all small, so it barely shows"
            zh += " · 人脸都很小，磨皮效果有限"
        } else if mask.missed == 0 {
            en += " · before the film"
            zh += " · 在胶片之前处理"
        }
        return L(en, zh: zh)
    }

    /// Says when the grain holds soft skin back (`RetouchSettings.softShare`).
    private var softSublabel: String {
        let share = session.params.softSkinShare
        guard share > 0, share < 1 else {
            return L("Softens the finer texture too; the film's grain still lands on it.",
                     zh: "连更细的肤质纹理一起柔化；胶片颗粒仍会覆盖在上面。")
        }
        let pct = Int((share * 100).rounded())
        return L("Held to \(pct)%: the grain is too fine to put the texture back.",
                 zh: "按 \(pct)% 生效：颗粒太细，盖不回被柔化的纹理。")
    }

    private func set(_ v: Double) {
        var p = session.params
        p.retouch.skinSmoothing = min(1, max(0, v))
        session.params = p
    }
}
