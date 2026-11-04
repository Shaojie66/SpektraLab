//  AIEval.swift — the AI evaluation's manifest, what one run records, and how
//  runs are summed up and held against the last evaluation (AGENTS.md, "The
//  AI assistant"). No model and no engine here: this is the part a test can
//  pin with numbers it wrote itself. `AIEvalTests` runs the evaluation.
//
//  Why it exists: two bugs that every unit test passed — the refiner told the
//  filters' direction backwards, and Apply printing the film before — were
//  found only by measuring how far Refine left a print from a reference.
//  Those measurements were scripts in /tmp, gone when the session ended.

import Foundation

enum AIEvalMode: String, Codable, CaseIterable, Sendable {
    case refine
    case chooseRefine = "choose+refine"
}

struct AIEvalError: Error, CustomStringConvertible, Equatable {
    let description: String
}

/// Photographs, the reference each is brought toward, how, and how often.
/// Paths are absolute or relative to the manifest; nothing is copied into
/// the repository, so FiveK and other licensed pictures stay where they are.
struct AIEvalManifest: Codable, Equatable, Sendable {
    struct Case: Codable, Equatable, Sendable {
        var name: String
        var photo: String
        var reference: String?
        var intent: String?
        var modes: [AIEvalMode]?
    }

    var runs: Int?
    var cases: [Case]

    /// Refused before anything runs, by name: a missing file, a mode that
    /// needs a reference without one, two cases of one name.
    static func load(_ url: URL) throws -> AIEvalManifest {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw AIEvalError(description: "No manifest at \(url.path).") }
        var m: AIEvalManifest
        do { m = try JSONDecoder().decode(AIEvalManifest.self, from: data) } catch {
            throw AIEvalError(description: "\(url.lastPathComponent) is not a manifest: \(error)")
        }
        let base = url.deletingLastPathComponent()
        func resolve(_ path: String) -> String {
            let p = (path as NSString).expandingTildeInPath
            return p.hasPrefix("/") ? p : base.appending(path: p).path
        }
        for i in m.cases.indices {
            m.cases[i].photo = resolve(m.cases[i].photo)
            m.cases[i].reference = m.cases[i].reference.map(resolve)
        }
        try m.validate()
        return m
    }

    func validate() throws {
        guard !cases.isEmpty else { throw AIEvalError(description: "The manifest has no cases.") }
        if let runs, runs < 1 { throw AIEvalError(description: "runs must be at least 1.") }
        var names = Set<String>()
        for c in cases {
            guard names.insert(c.name).inserted else { throw AIEvalError(description: "Two cases are called \(c.name).") }
            guard FileManager.default.fileExists(atPath: c.photo) else {
                throw AIEvalError(description: "\(c.name): no photo at \(c.photo).")
            }
            if let r = c.reference, !FileManager.default.fileExists(atPath: r) {
                throw AIEvalError(description: "\(c.name): no reference at \(r).")
            }
            if c.reference == nil, modes(of: c).contains(.chooseRefine) {
                throw AIEvalError(description: "\(c.name): choose+refine needs a reference.")
            }
        }
    }

    func modes(of c: Case) -> [AIEvalMode] { c.modes ?? [.refine] }
}

/// One run of one case in one mode. Distances are `ReferenceImage.distance`
/// (lower is closer) and are nil without a reference; a run that failed keeps
/// what it measured before it did, and says why.
struct AIEvalRecord: Codable, Equatable, Sendable {
    struct FilmChoice: Codable, Equatable, Sendable {
        var pick: String
        /// `ReferenceImage.filmDistance` of the pick, of the film the photo
        /// had, and of the nearest proof; the pick's place among them, 1 first.
        var distance: Double
        var current: Double
        var best: Double
        var rank: Int
        var of: Int
    }

    var caseName: String
    var mode: AIEvalMode
    var run: Int
    var start: Double?
    var chosen: Double?
    var end: Double?
    /// Reference minus the finished print, by field, as absolutes.
    var gaps: [String: Double]?
    var film: FilmChoice?
    var rounds = 0
    var retracted = 0
    /// Rounds whose answer could not be read, and rounds refused for scope or range.
    var unreadable = 0
    var refused = 0
    /// Every field the model wrote over the run, taken back or not: what it
    /// reached for. Nil in results written before it was kept.
    var fields: [String]?
    var seconds = 0.0
    var error: String?
}

struct AIEvalResults: Codable, Equatable, Sendable {
    var model: String
    var base: String
    var host: String
    var manifest: String
    var date: String
    var records: [AIEvalRecord]
}

/// One case in one mode, over its runs.
struct AIEvalRow: Equatable, Sendable {
    var caseName: String
    var mode: AIEvalMode
    var runs: Int
    var failed: Int
    var start: Double?
    var end: Double?
    var endRange: ClosedRange<Double>?
    var chosen: Double?
    var picks: [String]
    var rank: Double?
    var retracted: Int
    var unreadable: Int
    var baselineEnd: Double?
    /// Ended further from the reference than the baseline by more than the margin.
    var regressed: Bool
}

enum AIEval {
    /// How much further a median may end than last time before it is marked:
    /// the run-to-run spread of one model on these cases was about that.
    static let margin = 0.5

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Rows in the manifest's order. A failed run counts as failed, not as
    /// worse: a timeout says nothing about how far a print would have got.
    static func summarize(_ results: AIEvalResults, baseline: AIEvalResults? = nil, margin: Double = margin) -> [AIEvalRow] {
        var order: [(String, AIEvalMode)] = []
        for r in results.records where !order.contains(where: { $0 == (r.caseName, r.mode) }) {
            order.append((r.caseName, r.mode))
        }
        func endMedian(_ records: [AIEvalRecord]) -> Double? {
            median(records.filter { $0.error == nil }.compactMap(\.end))
        }
        return order.map { name, mode in
            let rs = results.records.filter { $0.caseName == name && $0.mode == mode }
            let ok = rs.filter { $0.error == nil }
            let ends = ok.compactMap(\.end)
            let end = median(ends)
            let base = baseline.flatMap { b in endMedian(b.records.filter { $0.caseName == name && $0.mode == mode }) }
            return AIEvalRow(
                caseName: name, mode: mode, runs: rs.count, failed: rs.count - ok.count,
                start: median(rs.compactMap(\.start)), end: end,
                endRange: ends.min().flatMap { lo in ends.max().map { lo...$0 } },
                chosen: median(ok.compactMap(\.chosen)),
                picks: ok.compactMap { $0.film?.pick },
                rank: median(ok.compactMap { $0.film.map { Double($0.rank) } }),
                retracted: rs.reduce(0) { $0 + $1.retracted }, unreadable: rs.reduce(0) { $0 + $1.unreadable },
                baselineEnd: base,
                regressed: end != nil && base != nil && end! > base! + margin)
        }
    }

    /// The table a person reads, with what makes two evaluations comparable
    /// said above it — and said again when the baseline differs in any.
    static func markdown(_ results: AIEvalResults, baseline: AIEvalResults? = nil, margin: Double = margin) -> String {
        let rows = summarize(results, baseline: baseline, margin: margin)
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
        var out = ["# AI evaluation", "",
                   "- Model: `\(results.model)` at `\(results.base)`",
                   "- Machine: \(results.host)",
                   "- Manifest: `\(results.manifest)`",
                   "- Date: \(results.date)",
                   "- Distance to the reference: lower is closer; medians over the runs that finished.", ""]
        if let b = baseline {
            out.append("- Baseline: \(b.date), `\(b.model)` at `\(b.base)` on \(b.host)")
            var differs: [String] = []
            if b.model != results.model { differs.append("model") }
            if b.host != results.host { differs.append("machine") }
            if b.manifest != results.manifest { differs.append("manifest") }
            if !differs.isEmpty {
                out.append("- **Not like for like:** the \(differs.joined(separator: ", ")) differs from the baseline's.")
            }
            out.append("")
        }
        var header = "| Case | Mode | Runs | Start | End (median, range) | After choosing | Film picked (rank) | Retracted | Unreadable |"
        var rule = "|---|---|---|---|---|---|---|---|---|"
        if baseline != nil { header += " Baseline end | |"; rule += "---|---|" }
        out += [header, rule]
        for r in rows {
            let runs = r.failed == 0 ? "\(r.runs)" : "\(r.runs - r.failed) of \(r.runs) (\(r.failed) failed)"
            let end = r.end.map { e in
                r.endRange.map { $0.lowerBound == $0.upperBound ? f(e) : "\(f(e)) (\(f($0.lowerBound))–\(f($0.upperBound)))" } ?? f(e)
            } ?? "–"
            let picks = Array(Set(r.picks)).sorted().joined(separator: ", ")
            let film = r.picks.isEmpty ? "–" : "\(picks) (\(r.rank.map { String(format: "%.0f", $0) } ?? "–"))"
            var line = "| \(r.caseName) | \(r.mode.rawValue) | \(runs) | \(f(r.start)) | \(end) | \(f(r.chosen)) | \(film) | \(r.retracted) | \(r.unreadable) |"
            if baseline != nil {
                line += " \(f(r.baselineEnd)) | \(r.regressed ? String(format: "**further by more than %.1f**", margin) : "") |"
            }
            out.append(line)
        }
        let failures = results.records.filter { $0.error != nil }
        if !failures.isEmpty {
            out += ["", "Failed runs:"]
            for r in failures { out.append("- \(r.caseName) \(r.mode.rawValue) run \(r.run): \(r.error ?? "")") }
        }
        return out.joined(separator: "\n") + "\n"
    }
}

import XCTest

/// The summary and the manifest, on records and files these tests write.
final class AIEvalSummaryTests: XCTestCase {
    private func record(_ name: String, _ mode: AIEvalMode, _ run: Int, end: Double?, start: Double = 10,
                        error: String? = nil, pick: String? = nil, rank: Int = 1) -> AIEvalRecord {
        var r = AIEvalRecord(caseName: name, mode: mode, run: run, start: start, end: end)
        r.error = error
        if let pick { r.film = .init(pick: pick, distance: 1, current: 2, best: 0.5, rank: rank, of: 19) }
        return r
    }
    private func results(_ records: [AIEvalRecord], model: String = "m") -> AIEvalResults {
        AIEvalResults(model: model, base: "http://x/v1", host: "pro", manifest: "/e.json", date: "d", records: records)
    }

    func testTheMedianOfOddAndEvenCountsAndNothing() {
        XCTAssertEqual(AIEval.median([3, 1, 2]), 2)
        XCTAssertEqual(AIEval.median([4, 1, 3, 2]), 2.5)
        XCTAssertNil(AIEval.median([]))
    }

    /// Medians over the runs that finished; a failed run is counted, not
    /// scored; further than the baseline by more than the margin is marked,
    /// and by less is not.
    func testAFailedRunIsCountedAndAWorseMedianIsMarked() {
        let now = results([
            record("warm", .refine, 1, end: 5), record("warm", .refine, 2, end: 7), record("warm", .refine, 3, end: nil, error: "timed out"),
            record("cool", .chooseRefine, 1, end: 8, pick: "fujifilm_provia_100f", rank: 2),
            record("cool", .chooseRefine, 2, end: 9, pick: "fujifilm_provia_100f", rank: 4),
        ])
        let before = results([record("warm", .refine, 1, end: 5.8), record("cool", .chooseRefine, 1, end: 7.9)])
        let rows = AIEval.summarize(now, baseline: before)
        XCTAssertEqual(rows.map(\.caseName), ["warm", "cool"], "the manifest's order")
        XCTAssertEqual(rows[0].runs, 3)
        XCTAssertEqual(rows[0].failed, 1)
        XCTAssertEqual(rows[0].end, 6, "the median of the two that finished")
        XCTAssertEqual(rows[0].endRange, 5...7)
        XCTAssertFalse(rows[0].regressed, "6 is within 0.5 of 5.8")
        XCTAssertEqual(rows[1].end, 8.5)
        XCTAssertEqual(rows[1].rank, 3)
        XCTAssertTrue(rows[1].regressed, "8.5 is more than 0.5 past 7.9")
        XCTAssertFalse(AIEval.summarize(now).contains(where: \.regressed), "nothing is marked without a baseline")
    }

    func testTheTableSaysWhatItWasMeasuredWithAndWhenTheBaselineDiffers() {
        let now = results([record("warm", .refine, 1, end: 5), record("warm", .refine, 2, end: nil, error: "timed out")])
        let md = AIEval.markdown(now, baseline: results([record("warm", .refine, 1, end: 4)], model: "other"))
        XCTAssertTrue(md.contains("Model: `m` at `http://x/v1`"))
        XCTAssertTrue(md.contains("Not like for like:** the model differs"), md)
        XCTAssertTrue(md.contains("1 of 2 (1 failed)"))
        XCTAssertTrue(md.contains("further by more than 0.5"))
        XCTAssertTrue(md.contains("warm refine run 2: timed out"))
        XCTAssertFalse(AIEval.markdown(now).contains("Baseline"), "no baseline column without one")
    }

    /// Results written before `fields` was kept still read, so an old run
    /// stays a baseline.
    func testResultsWithoutFieldsStillRead() throws {
        let old = #"{"model":"m","base":"b","host":"h","manifest":"x","date":"d","records":[{"caseName":"a","mode":"refine","run":1,"rounds":1,"retracted":0,"unreadable":0,"refused":0,"seconds":1,"start":2,"end":1}]}"#
        let r = try JSONDecoder().decode(AIEvalResults.self, from: Data(old.utf8))
        XCTAssertNil(r.records[0].fields)
        XCTAssertEqual(r.records[0].end, 1)
    }

    /// Refused before anything runs, by name; relative paths are the manifest's.
    func testAManifestIsCheckedBeforeAnythingRuns() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-eval-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try Data("x".utf8).write(to: dir.appending(path: "photo.dng"))
        func load(_ json: String) -> Result<AIEvalManifest, Error> {
            let url = dir.appending(path: "m.json")
            try? Data(json.utf8).write(to: url)
            return Result { try AIEvalManifest.load(url) }
        }
        func refusal(_ json: String) -> String {
            if case .failure(let e) = load(json) { return "\(e)" }
            return "accepted"
        }
        let ok = try load(#"{"runs": 2, "cases": [{"name": "a", "photo": "photo.dng"}]}"#).get()
        XCTAssertEqual(ok.cases[0].photo, dir.appending(path: "photo.dng").path)
        XCTAssertEqual(ok.modes(of: ok.cases[0]), [.refine])
        XCTAssertEqual(refusal(#"{"cases": [{"name": "a", "photo": "nope.dng"}]}"#),
                       "a: no photo at \(dir.appending(path: "nope.dng").path).")
        XCTAssertEqual(refusal(#"{"cases": [{"name": "a", "photo": "photo.dng", "modes": ["choose+refine"]}]}"#),
                       "a: choose+refine needs a reference.")
        XCTAssertEqual(refusal(#"{"cases": [{"name": "a", "photo": "photo.dng"}, {"name": "a", "photo": "photo.dng"}]}"#),
                       "Two cases are called a.")
        XCTAssertEqual(refusal(#"{"cases": []}"#), "The manifest has no cases.")
        XCTAssertTrue(refusal(#"{"cases": [{"name": "a", "photo": "photo.dng", "modes": ["fast"]}]}"#).contains("is not a manifest"))
    }
}
