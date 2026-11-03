//  AIEvalTests.swift — the AI evaluation: every case of a manifest, in every
//  mode, as many times as it says, on a real model, in one process.
//
//  **Opt-in.** `SPK_AI_EVAL=<manifest.json>` and `SPK_AI_EVAL_OUT=<folder>`,
//  with the model as for `AIEndToEndTests`: `SPK_AI_E2E=<OpenAI-compatible
//  base URL>` (or `anthropic`, the key from Settings ▸ AI) and
//  `SPK_AI_MODEL`. `SPK_AI_EVAL_BASELINE=<an earlier results.json>` adds the
//  comparison; `SPK_AI_EVAL_STRICT=1` fails the test on a marked row.
//  `Tools/ai-eval.sh` sets all of it. The manifest's format, and how the
//  references these numbers were first taken with were made, are in
//  `Tools/ai-eval/README.md`.
//
//  Without a manifest, `SPK_AI_IMAGE` and `SPK_AI_REFERENCE` (and
//  `SPK_AI_CHOOSE=1`) are one case run once, which is what the earlier
//  `AIReferenceEndToEndTests` did; `SPK_AI_OUT` is its folder.
//
//  Writes `results.json` (every number), `summary.md` (`AIEval.markdown`)
//  and `sheet.jpg` (each case: reference, before, after choosing, after).

import CoreGraphics
import Foundation
import ImageIO
import XCTest

@MainActor
enum AIEvalRunner {
    /// How long one run may take before it is recorded as failed.
    static let deadline: TimeInterval = 1800

    /// Runs everything and writes the three files into `out`. A run that
    /// fails is recorded and the next one starts; nothing here throws for a
    /// model's failure.
    static func run(_ manifest: AIEvalManifest, manifestPath: String, out: URL, model: String, base: String,
                    baseline: AIEvalResults? = nil,
                    makeClient: @escaping () throws -> AIClient) async throws -> AIEvalResults {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let date = ISO8601DateFormatter().string(from: Date())
        var records: [AIEvalRecord] = []
        let ws = AgentWorkspace()
        for c in manifest.cases {
            for mode in manifest.modes(of: c) {
                for run in 1...(manifest.runs ?? 1) {
                    let folder = out.appending(path: "\(c.name)/\(mode.rawValue)-\(run)")
                    let r = await once(c, mode: mode, run: run, folder: folder, ws: ws, makeClient: makeClient)
                    print("EVAL \(c.name) \(mode.rawValue) \(run): "
                          + [r.start, r.chosen, r.end].map { $0.map { String(format: "%.2f", $0) } ?? "–" }.joined(separator: " → ")
                          + (r.error.map { " FAILED: \($0)" } ?? "") + String(format: " (%.0f s)", r.seconds))
                    records.append(r)
                }
            }
        }
        let results = AIEvalResults(model: model, base: base, host: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                                    manifest: manifestPath, date: date, records: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(results).write(to: out.appending(path: "results.json"))
        try Data(AIEval.markdown(results, baseline: baseline).utf8).write(to: out.appending(path: "summary.md"))
        try writeSheet(manifest, out: out)
        return results
    }

    private static func once(_ c: AIEvalManifest.Case, mode: AIEvalMode, run: Int, folder: URL, ws: AgentWorkspace,
                             makeClient: @escaping () throws -> AIClient) async -> AIEvalRecord {
        let clock = Date()
        var rec = AIEvalRecord(caseName: c.name, mode: mode, run: run)
        // A copy per run, so every run starts from an untouched edit; its
        // sidecar lives in Application Support (AGENTS.md trap 35) and goes
        // with it.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "spk-eval-\(UUID().uuidString)")
        let photo = scratch.appending(path: URL(fileURLWithPath: c.photo).lastPathComponent)
        defer {
            Sidecar.remove(for: photo)
            try? FileManager.default.removeItem(at: scratch)
        }
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: c.photo), to: photo)
            try await ws.open(photo.path)
            try await ws.process()
            let reference = try c.reference.map { try ReferenceImage.load(URL(fileURLWithPath: $0)) }
            if let reference { try? ProofSheet.writeJPEG(reference.image, to: folder.appending(path: "reference.jpg")) }
            func measure(_ name: String) async throws -> ImageMetrics {
                try await ws.settle()
                let file = try await ws.preview(to: folder.appending(path: name), longEdge: AISettings.sentLongEdge)
                return try XCTUnwrap(AIAssistant.metrics(try Data(contentsOf: file)), "\(name) could not be measured")
            }
            let start = try await measure("before.jpg")
            rec.start = reference?.distance(to: start)

            let assistant = AIAssistant(session: ws.session)
            assistant.makeClient = makeClient
            assistant.intent = c.intent ?? ""
            assistant.reference = reference
            func finish(_ what: String) async throws {
                try await Task.sleep(for: .milliseconds(50))
                while assistant.busy {
                    if Date().timeIntervalSince(clock) > deadline {
                        assistant.cancel()
                        throw AIEvalError(description: "\(what) did not finish in \(Int(deadline)) s")
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                if let e = assistant.error { throw AIEvalError(description: "\(what): \(e)") }
            }

            if mode == .chooseRefine, let reference {
                assistant.recommendFilm()
                try await finish("Recommend")
                guard let rec0 = assistant.recommendation, let pick = rec0.picks.first, let d = rec0.filmDistances else {
                    throw AIEvalError(description: "Recommend gave no ranking")
                }
                let mine = d[pick.index - 1]
                rec.film = .init(pick: pick.candidate.film, distance: mine, current: d[0], best: d.min() ?? mine,
                                 rank: d.filter { $0 < mine }.count + 1, of: d.count)
                assistant.apply(pick)
                try await Task.sleep(for: .milliseconds(50))
                while ws.session.busy { try await Task.sleep(for: .milliseconds(50)) }
                rec.chosen = reference.distance(to: try await measure("chosen.jpg"))
            }

            assistant.refine()
            try await finish("Refine")
            rec.rounds = assistant.steps.count
            rec.retracted = assistant.steps.filter(\.retracted).count
            rec.unreadable = assistant.steps.filter { $0.refused?.contains("could not be read") == true }.count
            rec.refused = assistant.steps.filter { $0.refused != nil && $0.refused?.contains("could not be read") != true }.count
            let end = try await measure("after.jpg")
            if let reference {
                rec.end = reference.distance(to: end)
                let r = reference.metrics
                rec.gaps = ["meanLuma": abs(r.meanLuma - end.meanLuma), "contrast": abs(r.contrast - end.contrast),
                            "colorfulness": abs(r.colorfulness - end.colorfulness),
                            "castRG": abs(r.castRG - end.castRG), "castYB": abs(r.castYB - end.castYB)]
            }
        } catch {
            rec.error = "\(error)"
        }
        rec.seconds = Date().timeIntervalSince(clock)
        return rec
    }

    /// One row per case: the reference, then each mode's first run before,
    /// after choosing, after. A picture a run did not get to is left out of
    /// its row rather than drawn as something it is not.
    private static func writeSheet(_ manifest: AIEvalManifest, out: URL) throws {
        func image(_ url: URL) -> CGImage? {
            CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        }
        var rows: [[ProofSheet.Tile]] = []
        for c in manifest.cases {
            var row: [ProofSheet.Tile] = []
            let modes = manifest.modes(of: c)
            if let first = modes.first, let r = image(out.appending(path: "\(c.name)/\(first.rawValue)-1/reference.jpg")) {
                row.append(.init(image: r, title: c.name, subtitle: "reference"))
            }
            for (i, mode) in modes.enumerated() {
                let dir = out.appending(path: "\(c.name)/\(mode.rawValue)-1")
                if i == 0, let b = image(dir.appending(path: "before.jpg")) { row.append(.init(image: b, title: c.name, subtitle: "before")) }
                if let x = image(dir.appending(path: "chosen.jpg")) { row.append(.init(image: x, title: mode.rawValue, subtitle: "after choosing")) }
                if let a = image(dir.appending(path: "after.jpg")) { row.append(.init(image: a, title: mode.rawValue, subtitle: "after")) }
            }
            if !row.isEmpty { rows.append(row) }
        }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        // Short rows are padded with a blank tile so every case starts a row.
        let blank = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        var tiles: [ProofSheet.Tile] = []
        for row in rows {
            tiles += row
            if let blank { tiles += Array(repeating: .init(image: blank, title: "", subtitle: ""), count: columns - row.count) }
        }
        if let sheet = ProofSheet.sheet(tiles, tile: 260, columns: columns) {
            try ProofSheet.writeJPEG(sheet, to: out.appending(path: "sheet.jpg"))
        }
    }
}

@MainActor
final class AIEvalTests: XCTestCase {
    func testEvaluate() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SPK_AI_E2E"], let model = env["SPK_AI_MODEL"] else {
            throw XCTSkip("SPK_AI_E2E and SPK_AI_MODEL are not set")
        }
        let manifest: AIEvalManifest, manifestPath: String
        if let path = env["SPK_AI_EVAL"] {
            manifest = try AIEvalManifest.load(URL(fileURLWithPath: path))
            manifestPath = path
        } else if let photo = env["SPK_AI_IMAGE"], let reference = env["SPK_AI_REFERENCE"] {
            manifest = AIEvalManifest(runs: 1, cases: [.init(
                name: URL(fileURLWithPath: photo).deletingPathExtension().lastPathComponent, photo: photo,
                reference: reference, intent: env["SPK_AI_INTENT"],
                modes: [env["SPK_AI_CHOOSE"] != nil ? .chooseRefine : .refine])])
            try manifest.validate()
            manifestPath = "(SPK_AI_IMAGE, SPK_AI_REFERENCE)"
        } else {
            throw XCTSkip("SPK_AI_EVAL, or SPK_AI_IMAGE and SPK_AI_REFERENCE, are not set")
        }
        let out = URL(fileURLWithPath: env["SPK_AI_EVAL_OUT"] ?? env["SPK_AI_OUT"]
                      ?? FileManager.default.temporaryDirectory.appending(path: "spk-ai-eval").path, isDirectory: true)
        let baseline = try env["SPK_AI_EVAL_BASELINE"].map {
            try JSONDecoder().decode(AIEvalResults.self, from: Data(contentsOf: URL(fileURLWithPath: $0)))
        }

        let saved = (AISettings.enabled, AISettings.provider, AISettings.openAIBaseURL, AISettings.openAIModel,
                     AISettings.anthropicModel)
        addTeardownBlock { @MainActor in
            (AISettings.enabled, AISettings.provider, AISettings.openAIBaseURL, AISettings.openAIModel,
             AISettings.anthropicModel) = saved
        }
        AISettings.enabled = true
        if base == "anthropic" {
            try XCTSkipUnless(AIKeychain.has(.anthropic), "no Anthropic key in Settings ▸ AI")
            AISettings.provider = .anthropic
            AISettings.anthropicModel = model
        } else {
            AISettings.provider = .openAICompatible
            AISettings.openAIBaseURL = base
            AISettings.openAIModel = model
        }

        let results = try await AIEvalRunner.run(manifest, manifestPath: manifestPath, out: out, model: model, base: base,
                                                 baseline: baseline, makeClient: { try AISettings.client() })
        print(AIEval.markdown(results, baseline: baseline))
        print("EVAL out:", out.path)
        if env["SPK_AI_EVAL_STRICT"] != nil {
            let marked = AIEval.summarize(results, baseline: baseline).filter(\.regressed)
            XCTAssertTrue(marked.isEmpty, "further from the reference than the baseline: "
                          + marked.map { "\($0.caseName) \($0.mode.rawValue)" }.joined(separator: ", "))
        }
    }
}
