//  AIAssistant.swift — the AI tab: choose a film from proofs, then refine the
//  print by its own controls (AI assistant, ARCHITECTURE §7.14).
//
//  **A model moves the sliders a person would.** Choosing a film is the film
//  list's own rule (`selectFilmStock`, then Solve); refining is a JSON merge
//  patch through `Session.applyAgentEdit`, the same validated door the CLI
//  and MCP agents use, with the interface's ranges. Nothing here writes a
//  pixel or touches a profile ("do not pollute the material model"): the
//  result is an ordinary edit, in the ordinary sidecar, that opens the same
//  in any build of the app with no AI at all.
//
//  **One way back.** The edit as it was before the first AI change on this
//  frame is kept, and "Undo AI changes" restores it as a single step
//  (`Session.restoreSidecar`), however many coalesced steps the rounds made.

import CoreGraphics
import Foundation
import ImageIO
import Observation

@MainActor
@Observable
final class AIAssistant {
    enum Phase: Equatable {
        case idle
        case metering
        case analysing
        case proofing(done: Int, total: Int)
        case asking
        case refining(round: Int, of: Int)
    }

    struct Pick: Identifiable {
        let index: Int
        let candidate: ProofCandidate
        let score: Int
        let reason: String
        let thumbnail: CGImage
        var id: Int { index }
    }

    struct Recommendation {
        let url: URL
        let summary: String
        let picks: [Pick]
        let compared: Int
        /// Each proof's `ReferenceImage.filmDistance`, by tile number less
        /// one; nil when no reference was chosen.
        var filmDistances: [Double]? = nil
        /// Black and white was added because the reference has no colour.
        var addedMonochrome = false
    }

    struct Step: Identifiable {
        let round: Int
        let rationale: String
        /// Leaf paths written this round.
        let changed: [String]
        /// Why some or all of the round was not applied.
        let refused: String?
        /// Taken back because it left the print further from the reference.
        var retracted = false
        var id: Int { round }
    }

    let session: Session
    var phase: Phase = .idle
    /// What the person wants, in their words. May be empty.
    var intent = ""
    var includeMonochrome = false
    /// A picture Refine brings the print's look toward. Kept across frames,
    /// so a roll can be refined toward one reference, and never saved: it is
    /// an instruction, not part of any frame's edit.
    var reference: ReferenceImage?
    var recommendation: Recommendation?
    /// How the frame is exposed for its proofs, and who decided.
    struct ExposureChoice {
        let url: URL
        let meter: AEMethod
        /// The model's words; empty when the person's own setting was kept.
        let reason: String
        let byAI: Bool
    }
    var exposureChoice: ExposureChoice?

    struct CompositionPick: Identifiable {
        let index: Int
        let candidate: CompositionCandidate
        let score: Int
        let reason: String
        let thumbnail: CGImage
        var id: Int { index }
    }
    struct CompositionRecommendation {
        let url: URL
        let summary: String
        let picks: [CompositionPick]
        let compared: Int
    }
    var composition: CompositionRecommendation?
    var steps: [Step] = []
    var error: String?
    private(set) var before: (url: URL, sidecar: Sidecar)?
    private var task: Task<Void, Never>?
    /// Where a call's client comes from: the settings, or a test's script.
    var makeClient: () throws -> AIClient = AISettings.client

    static let maxRounds = 3
    /// How much further from the reference a round must leave the print to be
    /// taken back, in `ReferenceImage.distance` steps: the same edit printed
    /// twice does not measure exactly the same, and that is not a round
    /// going wrong.
    static let retractionMargin = 0.15
    /// Proofs for a recommendation are smaller than the CLI's: they are
    /// shown as 300 px tiles.
    static let proofLongEdge = 512
    /// The whole-frame proof composition is measured and cropped from.
    static let compositionLongEdge = 1024

    init(session: Session) {
        self.session = session
    }

    /// From the moment a run is started, not from when its first phase is
    /// set: work done before that (finding the faces, a Process) left a
    /// window where the run looked finished — a second press could start
    /// another, and Undo AI changes was refused under a run still going.
    var busy: Bool { phase != .idle || task != nil }
    var canUndo: Bool {
        guard let before, before.url == session.selection else { return false }
        return before.sidecar != session.sidecar
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    // MARK: choosing a film

    func recommendFilm() {
        start { [self] in
            let client = try makeClient()
            let catalog = session.catalog
            guard let url = session.selection else { throw ProofSheet.Failure.nothingOpen }
            guard session.pair == nil else { throw ProofSheet.Failure.pair }
            // The one chosen when Recommend was pressed. The exposure is the
            // scene's and is chosen without it.
            let reference = self.reference
            try await chooseExposure(client: client, url: url)
            try Task.checkCancellation()
            let addedMonochrome = !includeMonochrome && reference?.isMonochrome == true
            let candidates = ProofSheet.defaultCandidates(catalog: catalog, current: session.params,
                                                          includeMonochrome: includeMonochrome || addedMonochrome)
            phase = .proofing(done: 0, total: candidates.count)
            let proofs = try await ProofSheet.render(session: session, candidates: candidates,
                                                     longEdge: Self.proofLongEdge) { [weak self] done, total in
                self?.phase = .proofing(done: done, total: total)
            }
            guard let sheet = ProofSheet.contactSheet(proofs, catalog: catalog),
                  let jpeg = Self.jpeg(sheet) else { throw ProofSheet.Failure.noPixels("contact sheet") }
            phase = .asking
            let user = AIPrompts.chooserUser(proofs: proofs, catalog: catalog, exif: session.exif, intent: intent,
                                             reference: reference)
            let parts: [AIRequest.Part] = reference.map {
                [.text("Reference:"), .jpeg($0.jpeg), .text("Contact sheet:"), .jpeg(jpeg), .text(user)]
            } ?? [.jpeg(jpeg), .text(user)]
            let answer = try await client.complete(AIRequest(
                system: AIPrompts.chooserSystem, parts: parts, schema: AIPrompts.chooserSchema))
            try Task.checkCancellation()
            let (summary, ranked) = try AIPrompts.readRanking(answer, count: proofs.count)
            let picks = ranked.map { r in
                let p = proofs[r.index - 1]
                return Pick(index: r.index, candidate: p.candidate, score: r.score, reason: r.reason, thumbnail: p.image)
            }
            guard session.selection == url else { return }
            recommendation = Recommendation(url: url, summary: summary, picks: picks, compared: proofs.count,
                                            filmDistances: reference.map { r in proofs.map { r.filmDistance(to: $0.metrics, scanned: $0.candidate.paper == nil) } },
                                            addedMonochrome: addedMonochrome)
        }
    }

    /// The exposure the films are proofed at, decided for the scene before
    /// any film is: one film under each of the four meters, on one sheet, and
    /// the model picks the print that is exposed the way the scene should be.
    /// A night frame averaged to mid-grey is no film's look, and every proof
    /// after it would be compared at the wrong exposure.
    ///
    /// Only while the frame is on the untouched default (balanced, no Exp.
    /// Comp.): an exposure the person set is theirs and is kept. The choice
    /// goes through `applyAgentEdit` like any edit, so Undo AI changes takes
    /// it back with the rest.
    private func chooseExposure(client: AIClient, url: URL) async throws {
        let p = session.params
        let untouched = p.autoExposure && p.exposureCompensationEV == 0
            && (p.autoExposureMethod ?? ExposureMethod.balanced.rawValue) == ExposureMethod.balanced.rawValue
        guard untouched else {
            exposureChoice = ExposureChoice(url: url, meter: AEMethod.of(p), reason: "", byAI: false)
            return
        }
        let base = ProofSheet.candidate(film: p.filmStock, paper: p.scanFilm ? nil : p.printStock, catalog: session.catalog)
            ?? ProofSheet.candidate(film: FilmParams.default.filmStock, paper: nil, catalog: session.catalog, declared: true)
        guard let base else { return }
        phase = .metering
        let candidates = ExposureMethod.allCases.map {
            ProofCandidate(film: base.film, paper: base.paper, meter: $0.rawValue)
        }
        let proofs = try await ProofSheet.render(session: session, candidates: candidates, longEdge: Self.proofLongEdge)
        guard let sheet = ProofSheet.contactSheet(proofs, catalog: session.catalog, columns: 2),
              let jpeg = Self.jpeg(sheet) else { throw ProofSheet.Failure.noPixels("exposure sheet") }
        let answer = try await client.complete(AIRequest(
            system: AIPrompts.exposureSystem,
            parts: [.jpeg(jpeg), .text(AIPrompts.exposureUser(proofs: proofs, exif: session.exif, intent: intent))],
            schema: AIPrompts.exposureSchema))
        try Task.checkCancellation()
        guard session.selection == url else { return }
        // An unreadable answer keeps the default rather than ending the run:
        // the films can still be compared, at the exposure the frame has.
        guard let (meter, reason) = try? AIPrompts.readMeter(answer) else {
            exposureChoice = ExposureChoice(url: url, meter: AEMethod.of(p), reason: "", byAI: false)
            return
        }
        if meter != .balanced {
            remember()
            _ = try session.applyAgentEdit(["params": ["autoExposure": true, "autoExposureMethod": .string(meter.rawValue)]])
        }
        exposureChoice = ExposureChoice(url: url, meter: .metered(meter), reason: reason, byAI: true)
    }

    // MARK: composing

    enum CompositionRefusal: Error, CustomStringConvertible {
        case filmEdge
        var description: String {
            "Composition is not offered while Film Edge is on: the gate holds the crop's ratio."
        }
    }

    /// Crops of this frame built from what Vision measured in it, rendered on
    /// one sheet, and the model's three best. See `CompositionCandidates`.
    func recommendComposition() {
        start { [self] in
            let client = try makeClient()
            guard let url = session.selection else { throw ProofSheet.Failure.nothingOpen }
            guard session.pair == nil else { throw ProofSheet.Failure.pair }
            guard !session.params.filmEdge.active else { throw CompositionRefusal.filmEdge }
            phase = .analysing
            let p = session.params
            let catalog = session.catalog
            guard let base = ProofSheet.candidate(film: p.filmStock, paper: p.scanFilm ? nil : p.printStock, catalog: catalog)
                    ?? ProofSheet.candidate(film: FilmParams.default.filmStock, paper: nil, catalog: catalog, declared: true)
            else { throw ProofSheet.Failure.nothingOpen }
            // The whole frame, so the measurements are in the crop's own coordinates.
            let proofs = try await ProofSheet.render(session: session, candidates: [base],
                                                     longEdge: Self.compositionLongEdge, wholeFrame: true)
            guard let proof = proofs.first?.image else { throw ProofSheet.Failure.noPixels(base.film) }
            let analysis = try await Task.detached(priority: .userInitiated) { try CompositionAnalysis.analyse(proof) }.value
            try Task.checkCancellation()
            let candidates = CompositionCandidates.make(current: session.geometry, analysis: analysis,
                                                        imageSize: CGSize(width: proof.width, height: proof.height))
            var tiles: [ProofSheet.Tile] = []
            for (i, c) in candidates.enumerated() {
                guard let image = CompositionCandidates.render(c.geometry, from: proof, longEdge: 400)
                else { throw ProofSheet.Failure.noPixels("crop \(i + 1)") }
                let area = Int((c.geometry.crop.width * c.geometry.crop.height * 100).rounded())
                tiles.append(ProofSheet.Tile(image: image,
                                             title: "\(i + 1)  \(c.kind == .current ? "current" : c.label)",
                                             subtitle: c.straightened ? String(format: "levelled %+.1f°", c.geometry.angle)
                                                                      : "\(area)% of frame"))
            }
            guard let sheet = ProofSheet.sheet(tiles), let jpeg = Self.jpeg(sheet) else {
                throw ProofSheet.Failure.noPixels("composition sheet")
            }
            phase = .asking
            let answer = try await client.complete(AIRequest(
                system: AIPrompts.compositionSystem,
                parts: [.jpeg(jpeg), .text(AIPrompts.compositionUser(candidates: candidates, analysis: analysis,
                                                                     exif: session.exif, intent: intent))],
                schema: AIPrompts.chooserSchema))
            try Task.checkCancellation()
            let (summary, ranked) = try AIPrompts.readRanking(answer, count: candidates.count)
            let picks = ranked.prefix(3).map { r in
                CompositionPick(index: r.index, candidate: candidates[r.index - 1], score: r.score,
                                reason: r.reason, thumbnail: tiles[r.index - 1].image)
            }
            guard session.selection == url else { return }
            composition = CompositionRecommendation(url: url, summary: summary, picks: Array(picks),
                                                    compared: candidates.count)
        }
    }

    /// The crop's own rectangle, angle and ratio through `applyAgentEdit`,
    /// which fits it in the frame as a person's crop is fitted. Turns and
    /// flips are the person's and are not touched.
    func applyComposition(_ pick: CompositionPick) {
        guard !busy, !session.batchExporting, session.selection != nil else { return }
        let g = pick.candidate.geometry
        remember()
        do {
            _ = try session.applyAgentEdit(["geometry": [
                "crop": ["x": .number(Double(g.crop.x)), "y": .number(Double(g.crop.y)),
                         "width": .number(Double(g.crop.width)), "height": .number(Double(g.crop.height))],
                "angle": .number(g.angle),
                "aspect": .string(g.aspect.rawValue),
            ]])
        } catch {
            self.error = "\(error)"
        }
    }

    /// Whether the frame is framed as `pick` frames it.
    func isCurrent(_ pick: CompositionPick) -> Bool {
        let a = session.geometry, b = pick.candidate.geometry
        return abs(a.angle - b.angle) < 0.05 && abs(a.crop.x - b.crop.x) < 0.002 && abs(a.crop.y - b.crop.y) < 0.002
            && abs(a.crop.width - b.crop.width) < 0.002 && abs(a.crop.height - b.crop.height) < 0.002
    }

    /// The film list's rule, then Solve — what choosing it by hand and
    /// pressing Process does.
    func apply(_ pick: Pick) {
        guard !busy, !session.batchExporting, session.selection != nil else { return }
        remember()
        session.selectFilmStock(pick.candidate.film)
        // Always, when there is a paper: coming from a slide film, the film
        // list leaves `scanFilm` on, and only choosing a paper turns it off —
        // even when the paper kept from before is already this one.
        if let paper = pick.candidate.paper {
            session.selectPrintStock(paper)
        }
        session.solveNow()
    }

    // MARK: refining

    func refine() {
        start { [self] in
            let client = try makeClient()
            guard let url = session.selection else { throw ProofSheet.Failure.nothingOpen }
            guard session.pair == nil else { throw ProofSheet.Failure.pair }
            remember()
            steps = []
            // The one chosen when Refine was pressed, for every round.
            let reference = self.reference
            let ws = AgentWorkspace(attachedTo: session)
            // Judge colour on a solved print, as the MCP instructions ask.
            if (session.frameStates[url] ?? .unprocessed) == .unprocessed {
                phase = .refining(round: 0, of: Self.maxRounds)
                try await ws.process()
            }
            var feedback: String?
            let faces = await session.refreshSkinMask()
            // With a reference, the closest print so far, by measurement. A
            // round that leaves the print further from it is taken back, so a
            // run toward a reference never ends further away than it began.
            var best: (distance: Double, sidecar: Sidecar)?
            var retraction: (from: Double, to: Double)?
            @MainActor func shoot() async throws -> (jpeg: Data, metrics: ImageMetrics?) {
                let preview = try await ws.preview(longEdge: AISettings.sentLongEdge)
                defer { try? FileManager.default.removeItem(at: preview) }
                let jpeg = try Data(contentsOf: preview)
                return (jpeg, reference == nil ? nil : Self.metrics(jpeg))
            }
            /// Measures the print the last round left; true when it was taken back.
            @MainActor func keepOrRetract(_ shot: (jpeg: Data, metrics: ImageMetrics?)) async throws -> Bool {
                guard let reference, let m = shot.metrics else { return false }
                let d = reference.distance(to: m)
                guard let b = best, d > b.distance + Self.retractionMargin, let last = steps.indices.last else {
                    best = (d, session.sidecar)
                    return false
                }
                session.restoreSidecar(b.sidecar)
                try await ws.settle()
                steps[last].retracted = true
                retraction = (b.distance, d)
                return true
            }
            for round in 1...Self.maxRounds {
                try Task.checkCancellation()
                guard session.selection == url else { return }
                phase = .refining(round: round, of: Self.maxRounds)
                var shot = try await shoot()
                if try await keepOrRetract(shot) { shot = try await shoot() }
                let jpeg = shot.jpeg
                let latitude = try? await ws.latitude()
                let user = AIPrompts.refinerUser(
                    document: try ws.document, latitude: latitude, film: session.catalog.stock(session.params.filmStock)?.name,
                    exif: session.exif, intent: intent, history: steps, feedback: feedback,
                    round: round, of: Self.maxRounds, faces: faces, noFilm: session.noFilm,
                    reference: reference?.metrics, print: shot.metrics,
                    distance: best?.distance, retracted: retraction, scanned: session.params.scanFilm)
                retraction = nil
                // Each round is a request of its own, so the reference goes
                // with every one, labelled, ahead of the print.
                let parts: [AIRequest.Part] = reference.map {
                    [.text("Reference:"), .jpeg($0.jpeg), .text("Current print:"), .jpeg(jpeg), .text(user)]
                } ?? [.jpeg(jpeg), .text(user)]
                let answer = try await client.complete(AIRequest(
                    system: AIPrompts.refinerSystem, parts: parts, schema: AIPrompts.refinerSchema))
                try Task.checkCancellation()
                guard session.selection == url else { return }
                // An answer that cannot be read is a round that was not
                // applied, said back to the model — not the end of the run.
                let move: AIPrompts.Move
                do {
                    move = try AIPrompts.readMove(answer)
                } catch let e as AIError {
                    steps.append(Step(round: round, rationale: answer["rationale"]?.string ?? "", changed: [],
                                      refused: e.description))
                    feedback = AIPrompts.unreadableFeedback(e.description)
                    continue
                }
                var changed: [String] = []
                // Apart, because they are applied apart: a refused placement
                // leaves the patch in force, and the model must hear which.
                var patchRefused: String?, placementRefused: String?
                if let patch = move.patch {
                    do {
                        try AIPrompts.checkScope(patch)
                        changed += try await ws.edit(patch)
                    } catch let e as AgentError {
                        patchRefused = e.description
                    }
                }
                if let place = move.placement {
                    do {
                        // The pull-backs are totals: the same numbers again move
                        // nothing, and the round must not say they did.
                        let was = session.params.sceneLatitude
                        _ = try await ws.place(highlight: place.highlight, shadow: place.shadow)
                        if session.params.sceneLatitude != was { changed.append("params.sceneLatitude") }
                    } catch let e as AgentError {
                        placementRefused = e.description
                    }
                }
                try await ws.settle()
                let refusals = [patchRefused, placementRefused].compactMap { $0 }
                let why = refusals.isEmpty ? nil : refusals.joined(separator: " ")
                steps.append(Step(round: round, rationale: move.rationale, changed: changed, refused: why))
                feedback = AIPrompts.roundFeedback(patchRefused: patchRefused, placementRefused: placementRefused, applied: changed)
                if move.done && why == nil { break }
            }
            // The last round is measured too, and kept only if it came closer.
            guard session.selection == url else { return }
            if reference != nil { _ = try await keepOrRetract(try await shoot()) }
        }
    }

    /// Read off the main actor; a file that is not an image is said under the
    /// buttons and leaves any reference already chosen in place.
    func chooseReference(_ url: URL) {
        error = nil
        Task { [weak self] in
            do {
                let r = try await Task.detached(priority: .userInitiated) { try ReferenceImage.load(url) }.value
                self?.reference = r
            } catch let e as ReferenceImage.Failure {
                self?.error = e.localized
            } catch {
                self?.error = "\(error)"
            }
        }
    }

    func undoAI() {
        guard !busy, let before, before.url == session.selection else { return }
        session.restoreSidecar(before.sidecar)
        steps = []
    }

    // MARK: plumbing

    /// The edit before the first AI change on this frame.
    private func remember() {
        guard let url = session.selection else { return }
        if before?.url != url { before = (url, session.sidecar) }
    }

    private func start(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        guard !session.batchExporting else {
            error = L("A batch export is running. Try again when it finishes.", zh: "正在批量导出，请等它结束后再试。")
            return
        }
        error = nil
        task = Task { [weak self] in
            do {
                try await work()
            } catch is CancellationError {
            } catch let e as AIError {
                self?.error = e.localized
            } catch {
                self?.error = "\(error)"
            }
            self?.phase = .idle
            self?.task = nil
        }
    }

    /// The print as sent, measured the way the reference is.
    nonisolated static func metrics(_ jpeg: Data) -> ImageMetrics? {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return ImageMetrics(image)
    }

    static func jpeg(_ image: CGImage) -> Data? {
        let url = FileManager.default.temporaryDirectory.appending(path: "spektralab-ai-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? ProofSheet.writeJPEG(image, to: url)) != nil else { return nil }
        return try? Data(contentsOf: url)
    }
}
