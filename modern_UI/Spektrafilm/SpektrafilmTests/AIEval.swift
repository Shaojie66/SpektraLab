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

    /// Five unless the manifest says: three against a baseline's three cannot
    /// reach p < 0.05 (`AIEvalTest.minimumP`), so three is too few to mark.
    static let defaultRuns = 5
    var runCount: Int { runs ?? Self.defaultRuns }
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
    /// The manifest's cases as run, so two evaluations can be held to the
    /// same photographs, references and modes however many runs each had.
    /// Nil in results written before it was kept; the path stands in then.
    var cases: [AIEvalManifest.Case]?
}

/// Is this evaluation further from the reference than the baseline, beyond
/// what the model's own run-to-run spread explains? A one-sided permutation
/// test on the difference of means: the finished runs of both pooled, every
/// way of drawing as many as this evaluation has, and `p` the share of draws
/// at least as far as the one observed (that one included). It replaced a
/// fixed margin of 0.5, which on 2026-11-03/04 marked a case whose prompt had
/// not changed: pooling both days' Refine-alone runs, a 3-against-3 split
/// moved its median by more than 0.5 in 40 % of draws on muted-landscape and
/// in all of them on cool-night, and in none on warm-portrait.
///
/// Means, not medians, though the table shows medians: with three or five
/// runs a median moves in steps, and draws tie with the observed one —
/// 1.0 / 1.1 / 1.2 against five runs of 3.0–3.4, as plain a move as there is,
/// tied with two other draws and came to p = 0.054.
struct AIEvalTest: Equatable, Sendable {
    /// This mean minus the baseline's: positive is further from the reference.
    var difference: Double
    /// One-sided, for further; and for closer.
    var p: Double
    var pCloser: Double
    /// The smallest `p` these numbers of runs allow: 1 over the number of
    /// draws. Three runs against three cannot go below 0.05.
    var minimumP: Double
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
    /// Nil without a baseline, or with fewer than two finished runs on a side.
    var test: AIEvalTest?
    /// Further from the reference than the baseline, p < `AIEval.alpha`.
    var regressed: Bool
    /// Closer, p < `AIEval.alpha`: said, never failed on.
    var improved: Bool
}

enum AIEval {
    /// The level a change must clear to be marked.
    static let alpha = 0.05
    /// Above this many draws the test samples instead of counting them all
    /// (about ten runs a side), with a fixed seed so a table reads the same twice.
    static let exhaustiveLimit = 200_000
    static let sampledDraws = 20_000

    static func median(_ xs: [Double]) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func binomial(_ n: Int, _ k: Int) -> Int {
        guard k >= 0, k <= n else { return 0 }
        var r = 1.0
        for i in 0..<min(k, n - k) { r = r * Double(n - i) / Double(i + 1) }
        return Int(r.rounded())
    }

    static func permutationTest(baseline: [Double], current: [Double]) -> AIEvalTest? {
        guard baseline.count >= 2, current.count >= 2 else { return nil }
        func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
        let observed = mean(current) - mean(baseline)
        let pool = baseline + current
        let n = pool.count, k = current.count
        let tolerance = 1e-9
        var total = 0, further = 0, closer = 0
        func tally(_ chosen: [Int]) {
            var mine: [Double] = [], rest: [Double] = []
            var c = 0
            for i in 0..<n {
                if c < chosen.count, chosen[c] == i { mine.append(pool[i]); c += 1 } else { rest.append(pool[i]) }
            }
            let d = mean(mine) - mean(rest)
            total += 1
            if d >= observed - tolerance { further += 1 }
            if d <= observed + tolerance { closer += 1 }
        }
        let draws = binomial(n, k)
        if draws <= exhaustiveLimit {
            var idx = Array(0..<k)
            while true {
                tally(idx)
                var i = k - 1
                while i >= 0, idx[i] == n - k + i { i -= 1 }
                if i < 0 { break }
                idx[i] += 1
                for j in (i + 1)..<k { idx[j] = idx[j - 1] + 1 }
            }
            return AIEvalTest(difference: observed, p: Double(further) / Double(total),
                              pCloser: Double(closer) / Double(total), minimumP: 1 / Double(total))
        }
        // The observed draw counts as one of the sample, so p is never 0.
        var rng = SplitMix64(seed: 0x5EED_A1E7)
        tally(Array(baseline.count..<n))
        for _ in 0..<sampledDraws {
            var order = Array(0..<n)
            for i in stride(from: n - 1, to: 0, by: -1) { order.swapAt(i, Int(rng.next() % UInt64(i + 1))) }
            tally(Array(order.prefix(k)).sorted())
        }
        return AIEvalTest(difference: observed, p: Double(further) / Double(total),
                          pCloser: Double(closer) / Double(total), minimumP: 1 / Double(total))
    }

    /// Rows in the manifest's order. A failed run counts as failed, not as
    /// worse: a timeout says nothing about how far a print would have got.
    static func summarize(_ results: AIEvalResults, baseline: AIEvalResults? = nil) -> [AIEvalRow] {
        var order: [(String, AIEvalMode)] = []
        for r in results.records where !order.contains(where: { $0 == (r.caseName, r.mode) }) {
            order.append((r.caseName, r.mode))
        }
        func ends(_ records: [AIEvalRecord], _ name: String, _ mode: AIEvalMode) -> [Double] {
            records.filter { $0.caseName == name && $0.mode == mode && $0.error == nil }.compactMap(\.end)
        }
        return order.map { name, mode in
            let rs = results.records.filter { $0.caseName == name && $0.mode == mode }
            let ok = rs.filter { $0.error == nil }
            let mine = ends(results.records, name, mode)
            let theirs = baseline.map { ends($0.records, name, mode) } ?? []
            let test = baseline == nil ? nil : permutationTest(baseline: theirs, current: mine)
            return AIEvalRow(
                caseName: name, mode: mode, runs: rs.count, failed: rs.count - ok.count,
                start: median(rs.compactMap(\.start)), end: median(mine),
                endRange: mine.min().flatMap { lo in mine.max().map { lo...$0 } },
                chosen: median(ok.compactMap(\.chosen)),
                picks: ok.compactMap { $0.film?.pick },
                rank: median(ok.compactMap { $0.film.map { Double($0.rank) } }),
                retracted: rs.reduce(0) { $0 + $1.retracted }, unreadable: rs.reduce(0) { $0 + $1.unreadable },
                baselineEnd: median(theirs), test: test,
                regressed: test.map { $0.difference > 0 && $0.p < alpha } ?? false,
                improved: test.map { $0.difference < 0 && $0.pCloser < alpha } ?? false)
        }
    }

    /// Two evaluations ran the same thing when their cases — photographs,
    /// references, modes — match; the number of runs may differ. Results
    /// without their cases are held to the manifest's path.
    static func sameCases(_ a: AIEvalResults, _ b: AIEvalResults) -> Bool {
        if let x = a.cases, let y = b.cases { return x == y }
        return a.manifest == b.manifest
    }

    /// The table a person reads, with what makes two evaluations comparable
    /// said above it — and said again when the baseline differs in any.
    static func markdown(_ results: AIEvalResults, baseline: AIEvalResults? = nil) -> String {
        let rows = summarize(results, baseline: baseline)
        func f(_ v: Double?) -> String { v.map { String(format: "%.2f", $0) } ?? "–" }
        func pf(_ v: Double) -> String { v < 0.001 ? "< 0.001" : String(format: "%.3f", v) }
        var out = ["# AI evaluation", "",
                   "- Model: `\(results.model)` at `\(results.base)`",
                   "- Machine: \(results.host)",
                   "- Manifest: `\(results.manifest)`",
                   "- Date: \(results.date)",
                   "- Distance to the reference: lower is closer; medians over the runs that finished.", ""]
        if let b = baseline {
            out.append("- Baseline: \(b.date), `\(b.model)` at `\(b.base)` on \(b.host)")
            out.append(String(format: "- Against it: a one-sided permutation test on the change of the mean; a row is marked "
                              + "when p < %.2f, the chance of a change at least that large from the model's run-to-run "
                              + "spread alone. Fewer runs allow a smaller change to pass unmarked; the smallest p the "
                              + "runs allow is said where it is not below %.2f.", alpha, alpha))
            var differs: [String] = []
            if b.model != results.model { differs.append("model") }
            if b.host != results.host { differs.append("machine") }
            if !sameCases(b, results) { differs.append("cases") }
            if !differs.isEmpty {
                out.append("- **Not like for like:** the \(differs.joined(separator: ", ")) differs from the baseline's.")
            }
            out.append("")
        }
        var header = "| Case | Mode | Runs | Start | End (median, range) | After choosing | Film picked (rank) | Retracted | Unreadable |"
        var rule = "|---|---|---|---|---|---|---|---|---|"
        if baseline != nil { header += " Baseline end | Mean change | p | |"; rule += "---|---|---|---|" }
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
                if let t = r.test {
                    let p = t.difference >= 0 ? t.p : t.pCloser
                    let verdict = r.regressed ? "**further** (p = \(pf(t.p)))"
                        : r.improved ? "closer (p = \(pf(t.pCloser)))"
                        : t.minimumP >= alpha ? "these runs cannot reach p < \(alpha) (smallest \(pf(t.minimumP)))" : ""
                    line += " \(f(r.baselineEnd)) | \(String(format: "%+.2f", t.difference)) | \(pf(p)) | \(verdict) |"
                } else {
                    line += " \(f(r.baselineEnd)) | – | – | too few finished runs to test |"
                }
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

/// A small, fixed-seed generator: the sampled test reads the same every time.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
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
    /// scored; without a baseline nothing is tested.
    func testAFailedRunIsCountedAndNotScored() {
        let now = results([
            record("warm", .refine, 1, end: 5), record("warm", .refine, 2, end: 7), record("warm", .refine, 3, end: nil, error: "timed out"),
            record("cool", .chooseRefine, 1, end: 8, pick: "fujifilm_provia_100f", rank: 2),
            record("cool", .chooseRefine, 2, end: 9, pick: "fujifilm_provia_100f", rank: 4),
        ])
        let rows = AIEval.summarize(now)
        XCTAssertEqual(rows.map(\.caseName), ["warm", "cool"], "the manifest's order")
        XCTAssertEqual(rows[0].runs, 3)
        XCTAssertEqual(rows[0].failed, 1)
        XCTAssertEqual(rows[0].end, 6, "the median of the two that finished")
        XCTAssertEqual(rows[0].endRange, 5...7)
        XCTAssertEqual(rows[1].rank, 3)
        XCTAssertNil(rows[0].test, "nothing is tested without a baseline")
        XCTAssertFalse(rows.contains(where: \.regressed))
    }

    func testThePermutationTestCountsEveryDraw() throws {
        XCTAssertEqual(AIEval.binomial(8, 3), 56)
        XCTAssertEqual(AIEval.binomial(6, 3), 20)
        // The same numbers on both sides: nothing to see.
        let same = try XCTUnwrap(AIEval.permutationTest(baseline: [4, 5, 6], current: [4, 5, 6, 5, 5]))
        XCTAssertEqual(same.difference, 0)
        XCTAssertGreaterThan(same.p, 0.5)
        // Plainly further: of 56 draws only the observed one is this far.
        let far = try XCTUnwrap(AIEval.permutationTest(baseline: [1.0, 1.1, 1.2], current: [3.0, 3.1, 3.2, 3.3, 3.4]))
        XCTAssertEqual(far.difference, 2.1, accuracy: 1e-9, "3.2 against 1.1, means")
        XCTAssertEqual(far.p, 1.0 / 56, accuracy: 1e-12)
        XCTAssertEqual(far.minimumP, 1.0 / 56, accuracy: 1e-12)
        XCTAssertEqual(far.pCloser, 1, accuracy: 1e-12)
        // Three against three cannot go below 0.05, however far apart.
        let three = try XCTUnwrap(AIEval.permutationTest(baseline: [1, 1.1, 1.2], current: [9, 9.1, 9.2]))
        XCTAssertEqual(three.minimumP, 0.05, accuracy: 1e-12)
        XCTAssertEqual(three.p, 0.05, accuracy: 1e-12)
        XCTAssertNil(AIEval.permutationTest(baseline: [1], current: [2, 3]), "one run is no spread")
    }

    /// **The false alarm it replaced.** Refine alone on muted-landscape, its
    /// prompt unchanged between the two days, moved 4.01 → 5.08: past the old
    /// 0.5, but at p = 0.10 against the spread of its own six runs: one other
    /// draw of the twenty (4.86, 5.08, 5.38) is further still.
    func testTheMutedLandscapeShiftIsNotMarked() throws {
        let t = try XCTUnwrap(AIEval.permutationTest(baseline: [3.83, 4.01, 4.86], current: [4.79, 5.38, 5.08]))
        XCTAssertEqual(t.difference, (4.79 + 5.38 + 5.08 - 3.83 - 4.01 - 4.86) / 3, accuracy: 1e-9)
        XCTAssertEqual(t.p, 0.10, accuracy: 1e-12)
        let rows = AIEval.summarize(
            results([record("m", .refine, 1, end: 4.79), record("m", .refine, 2, end: 5.38), record("m", .refine, 3, end: 5.08)]),
            baseline: results([record("m", .refine, 1, end: 3.83), record("m", .refine, 2, end: 4.01), record("m", .refine, 3, end: 4.86)]))
        XCTAssertFalse(rows[0].regressed, "not below 0.05")
    }

    /// Five runs against three: far enough is marked, closer is said and
    /// not failed on, and a sample too large to count is drawn the same way
    /// twice.
    func testFurtherIsMarkedCloserIsSaidAndSamplingRepeats() throws {
        let base = results([1.0, 1.1, 1.2].enumerated().map { record("w", .refine, $0.offset + 1, end: $0.element) })
        let worse = results([3.0, 3.1, 3.2, 3.3, 3.4].enumerated().map { record("w", .refine, $0.offset + 1, end: $0.element) })
        let better = results([0.1, 0.2, 0.3, 0.4, 0.5].enumerated().map { record("w", .refine, $0.offset + 1, end: $0.element) })
        let w = AIEval.summarize(worse, baseline: base)[0], b = AIEval.summarize(better, baseline: base)[0]
        XCTAssertTrue(w.regressed)
        XCTAssertFalse(w.improved)
        XCTAssertTrue(b.improved)
        XCTAssertFalse(b.regressed, "closer is never a failure")
        XCTAssertTrue(AIEval.markdown(worse, baseline: base).contains("**further** (p = 0.018)"))
        XCTAssertTrue(AIEval.markdown(better, baseline: base).contains("closer (p = 0.018)"))

        let a = (0..<12).map { Double($0) * 0.1 }, c = (0..<12).map { 0.3 + Double($0) * 0.1 }
        XCTAssertGreaterThan(AIEval.binomial(24, 12), AIEval.exhaustiveLimit)
        let s1 = try XCTUnwrap(AIEval.permutationTest(baseline: a, current: c))
        let s2 = try XCTUnwrap(AIEval.permutationTest(baseline: a, current: c))
        XCTAssertEqual(s1, s2, "a fixed seed")
        XCTAssertEqual(s1.minimumP, 1.0 / Double(AIEval.sampledDraws + 1), accuracy: 1e-12)
    }

    func testTheTableSaysWhatItWasMeasuredWithAndWhenTheBaselineDiffers() {
        let now = results([record("warm", .refine, 1, end: 5), record("warm", .refine, 2, end: 6),
                           record("warm", .refine, 3, end: nil, error: "timed out")])
        let md = AIEval.markdown(now, baseline: results([record("warm", .refine, 1, end: 4), record("warm", .refine, 2, end: 4.5)],
                                                        model: "other"))
        XCTAssertTrue(md.contains("Model: `m` at `http://x/v1`"))
        XCTAssertTrue(md.contains("Not like for like:** the model differs"), md)
        XCTAssertTrue(md.contains("2 of 3 (1 failed)"))
        XCTAssertTrue(md.contains("one-sided permutation test"))
        XCTAssertTrue(md.contains("these runs cannot reach p < 0.05"), md)
        XCTAssertTrue(md.contains("warm refine run 3: timed out"))
        XCTAssertTrue(AIEval.markdown(now, baseline: results([record("warm", .refine, 1, end: 4)])).contains("too few finished runs to test"))
        XCTAssertFalse(AIEval.markdown(now).contains("Baseline"), "no baseline column without one")
    }

    /// The same photographs, references and modes are like for like however
    /// many runs each had; older results fall back to the manifest's path.
    func testCasesNotRunsMakeTwoEvaluationsComparable() {
        let c = AIEvalManifest.Case(name: "a", photo: "/p", reference: "/r", intent: nil, modes: [.refine])
        var x = results([]), y = results([])
        x.cases = [c]; y.cases = [c]; y.manifest = "/elsewhere.json"
        XCTAssertTrue(AIEval.sameCases(x, y), "a manifest moved, or its runs changed, runs the same cases")
        var z = y; z.cases = [AIEvalManifest.Case(name: "a", photo: "/other", reference: "/r", intent: nil, modes: [.refine])]
        XCTAssertFalse(AIEval.sameCases(x, z))
        var old = results([]); old.cases = nil
        XCTAssertTrue(AIEval.sameCases(old, x), "same path, no cases kept")
        XCTAssertEqual(AIEvalManifest(runs: nil, cases: [c]).runCount, 5)
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
