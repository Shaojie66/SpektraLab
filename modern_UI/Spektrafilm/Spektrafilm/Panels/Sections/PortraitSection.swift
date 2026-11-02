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
                    .rowEnabled(session.pair == nil && (faces ?? 0) > 0,
                                because: session.pair != nil
                                    ? L("Not available on a half-frame pair yet.", zh: "暂不支持半格拼接。")
                                    : L("No face was found in this frame.", zh: "这张照片里没有检测到人脸。"))
            }
        }
        .task(id: session.selection) { await session.refreshSkinMask() }
    }

    private var sublabel: String {
        guard let n = faces else { return L("Looking for faces…", zh: "正在检测人脸……") }
        if n == 0 { return L("No face found", zh: "没有检测到人脸") }
        return L(n == 1 ? "1 face · before the film" : "\(n) faces · before the film",
                 zh: "检测到 \(n) 张人脸 · 在胶片之前处理")
    }

    private func set(_ v: Double) {
        var p = session.params
        p.retouch.skinSmoothing = min(1, max(0, v))
        session.params = p
    }
}
