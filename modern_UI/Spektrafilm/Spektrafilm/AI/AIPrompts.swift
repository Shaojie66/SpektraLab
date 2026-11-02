//  AIPrompts.swift — what the models are told, the shapes they answer in, and
//  how an answer is checked before anything is applied (AI assistant,
//  ARCHITECTURE §7.14).
//
//  The schemas are the structured-output subset: every object closed, no
//  numeric bounds (the API takes none). The bounds are enforced where they
//  always were — `AgentDocument.validate`, with the interface's ranges — and
//  a value outside is refused, reported back to the model, and not applied.

import Foundation

@MainActor
enum AIPrompts {
    // MARK: what refining may touch

    /// The fields a refinement may write: the meter, the film's exposure, the enlarger,
    /// the effect strengths, and the whole of Post-Dev. Not the film or paper
    /// (that is the chooser's), not the crop, the film edge, the date or the
    /// decode.
    static let refinable = [
        "params.autoExposure", "params.autoExposureMethod",
        "params.exposureCompensationEV", "params.printBrightnessStops",
        "params.yFilterShift", "params.mFilterShift", "params.preflashExposure",
        "params.grainActive", "params.halationActive", "params.effects.grain", "params.effects.halation",
        "params.retouch.skinSmoothing", "params.retouch.soft",
        "adjustments",
    ]

    static func isRefinable(_ path: String) -> Bool {
        refinable.contains { path == $0 || path.hasPrefix($0 + ".") }
    }

    /// Refuses a patch that writes anything outside `refinable`, by path, and
    /// anything `AgentDocument.validate` refuses.
    static func checkScope(_ patch: JSONValue) throws {
        let leaves = try AgentDocument.validate(patch)
        let outside = leaves.filter { !isRefinable($0) }
        guard outside.isEmpty else {
            throw AgentError.refused("Not yours to change while refining: \(outside.joined(separator: ", ")).")
        }
    }

    private static var language: String {
        Localization.shared.resolved == .simplifiedChinese ? "Simplified Chinese" : "English"
    }

    // MARK: choosing the exposure

    static var exposureSystem: String {
        """
        You are a photographer deciding how a photograph should be exposed onto film in SpektraLab, a \
        physically modelled film and print simulation, before any film is chosen. You are shown one film \
        printed four times, once under each of the camera's meters, numbered, with the Film Exposure each \
        meter chose. The film and the print are the same in all four; only the exposure differs.

        Choose the meter whose print is exposed the way this scene should be: \
        balanced averages the frame to mid-grey and suits ordinary, evenly lit scenes; \
        center weights the middle; \
        protect_highlights keeps the brightest parts from blowing out and lets the rest fall dark — the \
        choice for night scenes, fireworks, lit windows, stage lights and anything against a bright source, \
        where averaging would lift a black sky to grey; \
        protect_shadows keeps dark parts open — for scenes dominated by bright areas such as snow, beach or \
        a bright sky, where averaging would make them grey and the subject too dark. \
        Judge by the pictures: a night sky should stay dark, a bright scene should stay bright, and the \
        subject should read. The reason is one or two sentences in \(language): what the scene is and why \
        this meter's print is right.
        """
    }

    static let exposureSchema: JSONValue = [
        "type": "object", "additionalProperties": false, "required": ["meter", "reason"],
        "properties": [
            "meter": ["type": "string", "enum": .array(ExposureMethod.allCases.map { .string($0.rawValue) })],
            "reason": ["type": "string"],
        ],
    ]

    static func exposureUser(proofs: [ProofSheet.Proof], exif: EXIFReadout?, intent: String) -> String {
        var lines = ["The exposure sheet above, one film under each meter:"]
        for p in proofs {
            let ev = p.exposureEV.map { String(format: "%+.2f", $0) } ?? "?"
            var row = "\(p.index). \(p.candidate.meter ?? "?") — Film Exposure \(ev) EV, luma \(f(p.metrics.meanLuma)), "
                + "highlight clip \(pct(p.metrics.highlightClip)), shadow clip \(pct(p.metrics.shadowClip))"
            if let l = p.latitude { row += ", beyond the medium above \(pct(l.above))" }
            lines.append(row)
        }
        lines.append(shot(exif))
        lines.append(wish(intent))
        return lines.joined(separator: "\n")
    }

    /// The meter the model chose, refused unless it is one of the four.
    static func readMeter(_ answer: JSONValue) throws -> (meter: ExposureMethod, reason: String) {
        guard let raw = answer["meter"]?.string, let m = ExposureMethod(rawValue: raw) else {
            throw AIError.badReply("meter is not one of \(ExposureMethod.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return (m, answer["reason"]?.string ?? "")
    }

    // MARK: choosing a crop

    static var compositionSystem: String {
        """
        You are a photographer and picture editor choosing how to crop a photograph. You are shown a \
        numbered sheet of crops of the same photograph, each already rendered: tile 1 is the framing it has \
        now, and some tiles are levelled where the horizon was measured as tilted. Every crop was built by \
        rule (the subject on a third, or centred, at a common ratio); you judge which work as pictures.

        Weigh: where the subject sits and whether it has room to look or move into; a level horizon, or a \
        tilt that is clearly intended; nothing important cut at an edge — heads, hands, feet, the top of a \
        firework; distractions pushed out or kept in; balance and breathing room; a ratio that suits the \
        content (tall for a standing figure or a tree, wide for a landscape or a crowd, square for a strong \
        centred form). Prefer a crop that improves the picture over one that only changes it, and choose \
        tile 1 if the framing is already best.

        Return the best 3, best first, each with a score from 0 to 100 and a reason of one or two sentences \
        that names what the crop does for this picture. The summary is one sentence on the photograph's \
        composition. Write the summary and reasons in \(language).
        """
    }

    static func compositionUser(candidates: [CompositionCandidate], analysis: CompositionAnalysis,
                                exif: EXIFReadout?, intent: String) -> String {
        var lines = ["The crops above:"]
        for (i, c) in candidates.enumerated() {
            let area = Int((c.geometry.crop.width * c.geometry.crop.height * 100).rounded())
            var row = "\(i + 1). \(c.kind == .current ? "the current framing" : c.label) — \(area)% of the frame"
            if c.straightened { row += String(format: ", levelled %+.1f°", c.geometry.angle) }
            lines.append(row)
        }
        if let tilt = analysis.horizonTilt {
            lines.append(String(format: "Horizon measured at %+.1f°%@.", tilt,
                                analysis.straighten == 0 ? " (within tolerance, left as is)" : ""))
        } else {
            lines.append("No horizon was found.")
        }
        lines.append(analysis.faces.isEmpty ? "No faces were found." : "\(analysis.faces.count) face(s) found; no crop cuts one.")
        lines.append(shot(exif))
        lines.append(wish(intent))
        return lines.joined(separator: "\n")
    }

    // MARK: choosing a film

    static var chooserSystem: String {
        """
        You are a film photographer and darkroom printer choosing a film stock for a photograph in SpektraLab, \
        a physically modelled film and print simulation. You are shown a numbered contact sheet: the same \
        photograph printed on several film and paper pairs through one identical neutral print — the same \
        exposure for every film (already chosen for this scene), the enlarger's filter pack solved to neutral, \
        no grade, no grain. So differences between tiles are the films' and papers' own colour, contrast and \
        latitude.

        Judge which films suit this photograph: its subject (skin, foliage, sky, interiors, night), its light \
        (daylight, tungsten, mixed, dim), its contrast, and the person's intent when they give one. Prefer films \
        whose rendering flatters the subject and that hold the scene (latitude.within near 1, little clipping). \
        A tungsten-balanced film (names ending in T) under daylight goes blue, a daylight film under tungsten \
        goes warm; slide films are contrasty and unforgiving; cine stocks print on 2383 with a cinematic curve.

        Return the best 3 to 5, best first, each with a score from 0 to 100 and a reason of one or two sentences \
        that names what you see in that tile. The summary is one or two sentences on the photograph and what \
        decided the ranking. Write the summary and reasons in \(language).
        """
    }

    static let chooserSchema: JSONValue = [
        "type": "object", "additionalProperties": false, "required": ["summary", "ranking"],
        "properties": [
            "summary": ["type": "string"],
            "ranking": ["type": "array", "items": [
                "type": "object", "additionalProperties": false, "required": ["index", "score", "reason"],
                "properties": ["index": ["type": "integer"], "score": ["type": "integer"], "reason": ["type": "string"]],
            ]],
        ],
    ]

    static func chooserUser(proofs: [ProofSheet.Proof], catalog: StockCatalog, exif: EXIFReadout?, intent: String) -> String {
        var lines = ["The contact sheet above. Measurements per tile (clip = fraction of pixels; luma, contrast 0–1; "
                     + "colourfulness: ~15 muted, ~45 moderate, >80 vivid; cast: + is magenta/warm, − green/cool; "
                     + "within = fraction of the scene the film and paper hold):"]
        for p in proofs {
            let m = p.metrics
            var row = "\(p.index). \(p.candidate.name(in: catalog)) — highlight clip \(pct(m.highlightClip)), "
                + "shadow clip \(pct(m.shadowClip)), luma \(f(m.meanLuma)), contrast \(f(m.contrast)), "
                + "colourfulness \(String(format: "%.0f", m.colorfulness)), cast RG \(signed(m.castRG)) YB \(signed(m.castYB))"
            if let l = p.latitude { row += ", within \(pct(l.within))" }
            lines.append(row)
        }
        lines.append(shot(exif))
        lines.append(wish(intent))
        return lines.joined(separator: "\n")
    }

    struct Ranked: Equatable {
        let index: Int
        let score: Int
        let reason: String
    }

    /// The ranking, kept to tiles that exist, each once, at most five.
    static func readRanking(_ answer: JSONValue, count: Int) throws -> (summary: String, ranked: [Ranked]) {
        guard case .array(let items)? = answer["ranking"] else { throw AIError.badReply("no ranking") }
        var seen = Set<Int>()
        var out: [Ranked] = []
        for item in items {
            guard let i = item["index"]?.number.map({ Int($0) }), (1...count).contains(i), seen.insert(i).inserted
            else { continue }
            let score = max(0, min(100, Int(item["score"]?.number ?? 0)))
            out.append(Ranked(index: i, score: score, reason: item["reason"]?.string ?? ""))
            if out.count == 5 { break }
        }
        guard !out.isEmpty else { throw AIError.badReply("the ranking named no tile on the sheet") }
        return (answer["summary"]?.string ?? "", out)
    }

    // MARK: refining

    static var refinerSystem: String {
        """
        You are a darkroom printer refining a print in SpektraLab, a physically modelled film and print \
        simulation. The film and paper are chosen; you change only the fields listed, never others.

        The process runs in order. First the physical stages: the meter and Film Exposure (stops on the \
        negative), the \
        enlarger's print brightness (stops) and its yellow and magenta filter shifts (the print's colour \
        balance: +Y is yellower, −Y bluer; +M more magenta, −M greener), and Scene Placement, which pulls \
        highlights or shadows the medium cannot hold back inside it. Then Post-Dev, a grade on the scan: white \
        balance, exposure, contrast, brightness, highlights, shadows, black and white point, saturation, colour \
        balance, curves, vignette. Correct colour with the filter shifts and density with print brightness \
        before reaching for Post-Dev; use Post-Dev for taste.

        Exposure first, and on the negative. If the print is too bright or too dark overall — a night sky gone \
        grey, a snow scene gone dull — fix it with the meter (autoExposure on, autoExposureMethod: \
        protect_highlights for night, fireworks, stage and backlit scenes; protect_shadows for snow, beach and \
        bright skies; balanced or center otherwise) or with Film Exposure, not with print brightness: print \
        brightness only fine-tunes a print whose negative is right. Scene Placement is for a scene the medium \
        cannot hold even when well exposed, never a cure for an overexposed negative.

        A filter shift moves every colour in the print, not only the ones the intent names. Each round, \
        check what lies outside the intent — a blue sky, whites and greys, skin, foliage that is not the \
        subject — and keep it true: a sky that turns pale or grey, or whites that go yellow, mean the global \
        move has gone far enough. Then hold the rest with Post-Dev colour balance by tonal zone (for example \
        a touch of blue back into the highlights) instead of pushing the filters further.

        Skin smoothing (params.retouch.skinSmoothing, 0 to 1) evens out skin on the faces that were found, \
        before the film, so the grain stays. Use it only when faces were found and the person wants a \
        portrait cleaned up or the skin is clearly blotchy: about 0.2–0.4 for a natural portrait, rarely \
        above 0.6, and leave it at 0 for a scene where people are small or incidental. params.retouch.soft \
        softens the finer texture as well — only when the person asks for clean, soft or beauty-style skin; \
        on fine grain or none it is held back by itself, since no grain is left to put the texture back. \
        Skin that looks waxy or flat has been smoothed too far. Changing it re-develops the frame, so set it once rather than \
        nudging it every round.

        Look at the print. Make small, deliberate moves — a filter shift of 0.02 to 0.08, a few points on a \
        slider — because you will see the result and can go further next round. Values you write are the new \
        absolute values, not offsets. Honour the person's intent; with none, aim for a natural, well-exposed \
        print that keeps the film's character rather than erasing it. When the print needs nothing more, \
        change nothing and set done to true.

        patch_json is a JSON merge patch over the edit document, as a string, e.g. \
        {"params":{"yFilterShift":0.04},"adjustments":{"contrast":6}} — or {} for no change. placement is null \
        unless the latitude report shows the scene beyond the medium and pulling it in would help; then give \
        stops from 0 to 6 for each side (0 leaves that side). These are the total pull-backs, not additions: \
        the current ones are in the latitude report's placement, so repeating them changes nothing — to pull \
        further, give a larger number, at least the fit's minimumPullBack. The rationale is two or three sentences in \
        \(language): what you see, and what you changed and why.
        """
    }

    static let refinerSchema: JSONValue = [
        "type": "object", "additionalProperties": false, "required": ["rationale", "patch_json", "placement", "done"],
        "properties": [
            "rationale": ["type": "string"],
            "patch_json": ["type": "string"],
            "placement": ["anyOf": [
                ["type": "null"],
                ["type": "object", "additionalProperties": false, "required": ["highlight", "shadow"],
                 "properties": ["highlight": ["type": "number"], "shadow": ["type": "number"]]],
            ]],
            "done": ["type": "boolean"],
        ],
    ]

    @MainActor
    static func refinerUser(document: JSONValue, latitude: JSONValue?, film: String?, exif: EXIFReadout?,
                            intent: String, history: [AIAssistant.Step], feedback: String?,
                            round: Int, of total: Int, faces: SkinMask? = nil) -> String {
        var lines = ["The print above, round \(round) of \(total). Film: \(film ?? "?")."]
        if let faces {
            if faces.isEmpty {
                lines.append("No faces were found: leave skin smoothing at 0.")
            } else {
                var line = "\(faces.faces.count) face(s) found, so skin smoothing applies to them."
                if faces.missed > 0 {
                    line += " \(faces.missed) more were too small or turned to smooth, so it would treat people unevenly."
                }
                if faces.facesAreSmall {
                    line += String(format: " All are small (the largest is %.0f%% of the long edge): it barely shows; leave it at 0 unless asked.",
                                   faces.largestFace * 100)
                }
                lines.append(line)
            }
        }
        lines.append("Fields you may write (path, type and range, meaning):")
        for field in AgentSchema.fields where field.readOnly == nil && isRefinable(field.path) {
            let j = field.json
            var kind = j["type"]?.string ?? ""
            if let lo = j["min"]?.number, let hi = j["max"]?.number { kind += " \(g(lo))…\(g(hi))" }
            lines.append("- \(field.path): \(kind). \(field.doc)")
        }
        var now: [String: JSONValue] = [:]
        for path in refinable {
            now[path] = path.split(separator: ".").reduce(Optional(document)) { $0?[String($1)] }
        }
        lines.append("Current values: " + JSONValue.object(now).text())
        if let latitude {
            lines.append("Latitude: " + JSONValue.object(["medium": latitude["medium"] ?? .null,
                                                          "fractionOfFrame": latitude["fractionOfFrame"] ?? .null,
                                                          "suggested": latitude["suggested"] ?? .null,
                                                          "fit": latitude["fit"] ?? .null,
                                                          "placement": latitude["placement"] ?? .null]).text())
        }
        lines.append(shot(exif))
        lines.append(wish(intent))
        if !history.isEmpty {
            lines.append("Earlier rounds:")
            for s in history {
                lines.append("- round \(s.round): \(s.rationale) Changed: \(s.changed.isEmpty ? "nothing" : s.changed.joined(separator: ", "))."
                             + (s.refused.map { " Refused: \($0)" } ?? ""))
            }
        }
        if let feedback { lines.append("Your last patch was refused, so it was not applied: \(feedback) Fix it this round.") }
        return lines.joined(separator: "\n")
    }

    struct Move: Equatable {
        let rationale: String
        /// Nil for no change.
        let patch: JSONValue?
        let placement: (highlight: Double, shadow: Double)?
        let done: Bool

        static func == (a: Move, b: Move) -> Bool {
            a.rationale == b.rationale && a.patch == b.patch && a.done == b.done
                && a.placement?.highlight == b.placement?.highlight && a.placement?.shadow == b.placement?.shadow
        }
    }

    static func readMove(_ answer: JSONValue) throws -> Move {
        var patch: [String: JSONValue] = [:]
        // The compatible servers do not hold the schema, and a model there may
        // hand the patch over as an object rather than as a string of one.
        let text = (answer["patch_json"]?.string ?? "{}").trimmingCharacters(in: .whitespacesAndNewlines)
        if case .object(let o)? = answer["patch_json"] {
            patch = o
        } else if !(text.isEmpty || text == "{}" || text == "null") {
            guard let o = (try? JSONValue.parse(text))?.object else {
                throw AIError.badReply("patch_json is not a JSON object")
            }
            patch = o
        }
        // The placement field wins; otherwise a placement written into the
        // patch is lifted out of it rather than refused as an unknown section.
        var placement = side(answer["placement"])
        let lifted = liftPlacement(&patch)
        if answer["placement"]?.object == nil { placement = lifted }
        return Move(rationale: answer["rationale"]?.string ?? "", patch: patch.isEmpty ? nil : .object(patch),
                    placement: placement, done: answer["done"]?.bool ?? false)
    }

    /// `{highlight, shadow}` in stops, clamped to the Fit's 0…6; nil when
    /// absent or both 0 (no placement, not a reset).
    private static func side(_ v: JSONValue?) -> (highlight: Double, shadow: Double)? {
        guard let o = v?.object else { return nil }
        let h = (o["highlight"] ?? o["highlightPullBack"])?.number ?? 0
        let s = (o["shadow"] ?? o["shadowPullBack"])?.number ?? 0
        guard h > 0 || s > 0 else { return nil }
        return (min(6, max(0, h)), min(6, max(0, s)))
    }

    /// The places a model puts a Scene Placement when it does not use the
    /// `placement` field: a top-level `placement` (or `place`) section, or the
    /// read-only `params.sceneLatitude` pull-backs, which go through the Fit
    /// and never through the patch. Removed from `patch`; the first found is
    /// returned.
    static func liftPlacement(_ patch: inout [String: JSONValue]) -> (highlight: Double, shadow: Double)? {
        var found: (highlight: Double, shadow: Double)?
        for key in ["placement", "place", "scenePlacement"] {
            if let v = patch.removeValue(forKey: key), found == nil { found = side(v) }
        }
        if var params = patch["params"]?.object, let sl = params.removeValue(forKey: "sceneLatitude") {
            if found == nil { found = side(sl) }
            if params.isEmpty { patch.removeValue(forKey: "params") } else { patch["params"] = .object(params) }
        }
        return found
    }

    // MARK: shared lines

    private static func shot(_ exif: EXIFReadout?) -> String {
        let parts = [exif?.iso, exif?.shutter, exif?.aperture].compactMap { $0 }
        return parts.isEmpty ? "Shooting data: unknown." : "Shooting data: \(parts.joined(separator: ", "))."
    }

    private static func wish(_ intent: String) -> String {
        let t = intent.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "The person gave no particular intent." : "The person's intent: \(t)"
    }

    private static func pct(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    private static func f(_ v: Double) -> String { String(format: "%.2f", v) }
    private static func signed(_ v: Double) -> String { String(format: "%+.2f", v) }
    private static func g(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(v) }
}
