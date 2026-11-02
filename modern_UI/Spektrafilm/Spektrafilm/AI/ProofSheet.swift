//  ProofSheet.swift — the open frame printed on several films at once, small,
//  on an engine of its own (AI assistant, ARCHITECTURE §7.14).
//
//  **Not the canvas's engine.** `EngineClient` holds one session and `open`
//  replaces it, so proofing on the session's own client would swap the frame
//  the person is editing out from under them (`Session.pairExposure` can use
//  the shared client only because it runs before the frame's own open). A
//  proof run makes a second client on the same device, hands it the frame
//  shrunk to `longEdge`, prints every candidate on it and stops it. The
//  session's sidecar, parameters, undo stack and canvas are never touched;
//  `AITests.testProofsLeaveTheSessionAlone` holds that.
//
//  **The same print for every film.** Each candidate is opened from the
//  frame's own parameters with the things that would make the comparison
//  unfair taken out: the filter shifts and print brightness at zero (Solve
//  sets the neutral pack per pair), no
//  Scene Placement (its curve is solved for one medium), no film edge or
//  date, and no grain or glare — grain at 768 px is aliasing rather than
//  grain, and glare is the pipeline's one unseeded stage (AGENTS.md trap 1),
//  so with both off a proof reproduces bit for bit. No Layer 2: a proof
//  compares films, not grades. The crop and straighten *are* applied, so
//  the proof is the composition the person sees. The exposure is the
//  frame's own, the same for every film: it is a decision about the scene
//  (a night sky metered to mid-grey is nobody's film), so it is settled
//  first, on an exposure sheet of one film under the four meters
//  (`ProofCandidate.meter`, `AIAssistant.chooseExposure`).

import CoreGraphics
import CoreImage
import CoreText
import Foundation
import Metal

struct ProofCandidate: Hashable, Sendable {
    let film: String
    /// Nil: the film is scanned (a slide film).
    let paper: String?
    /// A meter (`ExposureMethod` raw value) to expose this proof with, in
    /// place of the frame's own exposure. Set for the exposure sheet, where
    /// the film is fixed and the meter is what varies; nil everywhere else.
    var meter: String? = nil

    func name(in catalog: StockCatalog) -> String {
        let f = catalog.stock(film)?.name ?? film
        guard let paper else { return f }
        return "\(f) / \(catalog.stock(paper)?.name ?? paper)"
    }

    var json: JSONValue {
        var o: [String: JSONValue] = ["film": .string(film), "paper": paper.map(JSONValue.string) ?? "scan"]
        if let meter { o["meter"] = .string(meter) }
        return .object(o)
    }
}

enum ProofSheet {
    /// The default proof long edge: enough to judge colour and tone, small
    /// enough that a run of twenty films takes seconds.
    static let defaultLongEdge = 768

    struct Proof: Sendable {
        let index: Int
        let candidate: ProofCandidate
        let image: CGImage
        let metrics: ImageMetrics
        /// Fractions of the frame below, within and above the medium's
        /// latitude, from the engine; nil when it could not measure.
        let latitude: (below: Double, within: Double, above: Double)?
        /// The Film Exposure the proof was printed at, stops: what the meter
        /// chose, or the frame's own Exp. Comp. with the meter off.
        var exposureEV: Double? = nil

        func json(in catalog: StockCatalog) -> JSONValue {
            var o: [String: JSONValue] = ["index": .number(Double(index)), "name": .string(candidate.name(in: catalog)),
                                          "metrics": metrics.json]
            for (k, v) in candidate.json.object ?? [:] { o[k] = v }
            if let ev = exposureEV { o["exposureEV"] = .number((ev * 100).rounded() / 100) }
            if let l = latitude {
                func r(_ v: Double) -> JSONValue { .number((v * 1000).rounded() / 1000) }
                o["latitude"] = ["below": r(l.below), "within": r(l.within), "above": r(l.above)]
            }
            return .object(o)
        }
    }

    // MARK: which films

    /// Every colour film on the paper it was made for, and every slide film
    /// scanned. Push processes are left out (they are the same emulsion), and
    /// black and white is in only when asked for. The frame's current pair is
    /// always in, first, so "keep what I have" is one of the answers.
    static func defaultCandidates(catalog: StockCatalog = .shared, current: FilmParams,
                                  includeMonochrome: Bool = false) -> [ProofCandidate] {
        var out: [ProofCandidate] = []
        if let now = candidate(film: current.filmStock, paper: current.scanFilm ? nil : current.printStock,
                               catalog: catalog) {
            out.append(now)
        }
        for film in catalog.filmsForPicker {
            if film.id.contains("_push") { continue }
            if film.isMonochrome, !includeMonochrome { continue }
            guard let c = candidate(film: film.id, paper: nil, catalog: catalog, declared: true),
                  !out.contains(where: { $0.film == c.film }) else { continue }
            out.append(c)
        }
        return out
    }

    /// Named films, each on its declared paper. Unknown ids are refused by
    /// name rather than skipped: a caller who asked for a film should hear it
    /// was not there.
    static func candidates(films: [String], catalog: StockCatalog = .shared) throws -> [ProofCandidate] {
        guard !films.isEmpty else { throw AgentError.refused("films is empty.") }
        var out: [ProofCandidate] = []
        for id in films {
            guard let c = candidate(film: id, paper: nil, catalog: catalog, declared: true) else {
                throw AgentError.refused("No film with id \(id) — list_stocks lists them.")
            }
            if !out.contains(c) { out.append(c) }
        }
        return out
    }

    /// One film and its paper, by the film list's rule: a slide film is
    /// scanned, a negative is printed on `paper` or, with `declared`, on its
    /// own target. Nil for an id that is not a film, or a pair the catalogue
    /// says cannot print.
    static func candidate(film id: String, paper: String?, catalog: StockCatalog,
                          declared: Bool = false) -> ProofCandidate? {
        guard let film = catalog.stock(id), film.isFilm else { return nil }
        if film.isPositive { return ProofCandidate(film: id, paper: nil) }
        let p = declared ? (film.targetPrint ?? paper) : (paper ?? film.targetPrint)
        guard let p, catalog.stock(p)?.isPaper == true, catalog.canPrint(film: id, on: p) else { return nil }
        return ProofCandidate(film: id, paper: p)
    }

    // MARK: printing

    /// The parameters every proof starts from (see the file comment). The
    /// frame's own exposure — its meter, or Custom and its Exp. Comp. — is
    /// kept: how a photograph is exposed is decided for the scene, not per
    /// film, and a night frame metered to mid-grey is no film's look
    /// (`AIAssistant.chooseExposure` settles it before the films are proofed).
    static func proofParams(from p: FilmParams) -> FilmParams {
        var q = p
        q.yFilterShift = 0
        q.mFilterShift = 0
        q.printBrightnessStops = 0
        q.sceneLatitude = SceneLatitudeSettings()
        q.digitalIntermediate = false
        q.filmEdge.active = false
        q.dateBack.active = false
        q.grainActive = false
        q.glareActive = false
        return q
    }

    enum Failure: Error, CustomStringConvertible {
        case nothingOpen, pair, noPixels(String)
        var description: String {
            switch self {
            case .nothingOpen: "No frame is open."
            case .pair: "Film proofs are not available on a half-frame pair yet; open one frame."
            case .noPixels(let film): "The proof of \(film) came back empty."
            }
        }
    }

    /// Print `candidates` on the open frame. `progress` is called on the main
    /// actor after each proof with (done, total).
    @MainActor
    /// `wholeFrame` prints the photograph uncropped and unturned — the frame
    /// composition is worked out on, in the coordinates `Geometry` uses.
    static func render(session: Session, candidates: [ProofCandidate], longEdge: Int = defaultLongEdge,
                       wholeFrame: Bool = false,
                       progress: ((Int, Int) -> Void)? = nil) async throws -> [Proof] {
        guard session.selection != nil, let decoded = await session.ensureDecoded() else { throw Failure.nothingOpen }
        guard session.pair == nil else { throw Failure.pair }
        let device = session.renderer.device
        let geometry = wholeFrame ? Geometry.default : session.geometry
        let frame = try await Task.detached(priority: .userInitiated) {
            var image = Session.engineImage(decoded.linear, size: decoded.pixelSize,
                                            cut: geometry.isIdentity ? nil : geometry)
            let long = max(image.extent.width, image.extent.height)
            if long > CGFloat(longEdge) {
                image = image.applyingFilter("CILanczosScaleTransform",
                                             parameters: [kCIInputScaleKey: CGFloat(longEdge) / long,
                                                          kCIInputAspectRatioKey: 1])
            }
            return try ImageDecoder.engineFrame(from: image, device: device)
        }.value

        let client = EngineClient(device: device, log: session.log)
        defer { Task { await client.stop() } }
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.noPixels("sRGB") }
        var base = session.sidecar
        base.params = proofParams(from: base.params)

        var setup: OutputTransformSetup?
        var proofs: [Proof] = []
        for (i, c) in candidates.enumerated() {
            try Task.checkCancellation()
            var sc = base
            sc.params.filmStock = c.film
            if let paper = c.paper {
                sc.params.printStock = paper
                sc.params.scanFilm = false
            } else {
                sc.params.scanFilm = true
            }
            if let meter = c.meter {
                sc.params.autoExposure = true
                sc.params.autoExposureMethod = meter
                sc.params.exposureCompensationEV = 0
            }
            // The engine's live tier renders at min(preview edge, picture), and
            // will not take a preview edge under 800: the frame's own size is
            // what bounds the proof.
            let delta = Session.openDelta(sidecar: sc, previewLongEdge: max(800, longEdge))
            let opened = try await client.open(frame, paramsDelta: delta)
            let solved = try await client.call(.solve, SolveRequest(sessionID: opened.sessionID, target: "both"),
                                               as: SolveResponse.self)
            let exposureEV = sc.params.autoExposure ? solved.solvedParams["exposure_compensation_ev"]
                                                    : sc.params.exposureCompensationEV
            let rendered = try await client.render(.reprint, RenderRequest(sessionID: opened.sessionID))
            guard let texture = rendered.texture else { throw Failure.noPixels(c.film) }
            if setup == nil {
                let (made, problem) = await ColourManagement.setup(client: client, source: session.workingSpaceName,
                                                                   target: srgb, device: device)
                guard let made else { throw Failure.noPixels(problem ?? "sRGB transform") }
                setup = made
            }
            guard let setup,
                  let converted = session.renderer.applyOutputTransform(to: texture, setup: setup),
                  let image = converted.texture.makeCGImage(space: srgb),
                  let metrics = ImageMetrics(image)
            else { throw Failure.noPixels(c.film) }
            let latitude = try? await client.sceneLatitude(SceneLatitudeRequest(highlightPullBack: 0, shadowPullBack: 0))
            let readout = latitude.map(LatitudeReadout.init)
            proofs.append(Proof(index: i + 1, candidate: c, image: image, metrics: metrics,
                                latitude: readout.map { ($0.below, $0.within, $0.above) },
                                exposureEV: exposureEV))
            progress?(i + 1, candidates.count)
        }
        return proofs
    }

    // MARK: the sheet

    /// The proofs on one sRGB image, numbered and named, `columns` across,
    /// each fitted in a `tile`-pixel square. What a model is shown, so the
    /// numbers are big and the names are the catalogue's.
    static func contactSheet(_ proofs: [Proof], catalog: StockCatalog = .shared,
                             tile: Int = 300, columns: Int? = nil) -> CGImage? {
        sheet(proofs.map { proof in
            let title = proof.candidate.meter.flatMap(ExposureMethod.init(rawValue:))?.title
                ?? catalog.stock(proof.candidate.film)?.name ?? proof.candidate.film
            var second = proof.candidate.paper.map { catalog.stock($0)?.name ?? $0 } ?? "scanned"
            if proof.candidate.meter != nil, let ev = proof.exposureEV {
                second = String(format: "metered %+.1f EV", ev)
            }
            return Tile(image: proof.image, title: "\(proof.index)  \(title)", subtitle: second)
        }, tile: tile, columns: columns)
    }

    /// One labelled picture on a sheet.
    struct Tile {
        let image: CGImage
        let title: String
        let subtitle: String
    }

    /// Pictures on one sRGB image, `columns` across, each fitted in a
    /// `tile`-pixel square with its two lines of label — what a model is shown,
    /// so the numbers are big. The film sheet, the exposure sheet and the
    /// composition sheet are all this.
    static func sheet(_ tiles: [Tile], tile: Int = 300, columns: Int? = nil) -> CGImage? {
        guard !tiles.isEmpty, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        let cols = columns ?? min(5, Int(Double(tiles.count).squareRoot().rounded(.up)) + 1)
        let rows = (tiles.count + cols - 1) / cols
        let pad = 8, label = 34
        let cellW = tile + pad, cellH = tile + label + pad
        let width = cols * cellW + pad, height = rows * cellH + pad
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        for (n, t) in tiles.enumerated() {
            let col = n % cols, row = n / cols
            // Core Graphics is y-up; rows are laid top-down.
            let x = pad + col * cellW
            let top = height - pad - row * cellH
            let iw = CGFloat(t.image.width), ih = CGFloat(t.image.height)
            let s = CGFloat(tile) / max(iw, ih)
            let dw = iw * s, dh = ih * s
            let rect = CGRect(x: CGFloat(x) + (CGFloat(tile) - dw) / 2,
                              y: CGFloat(top - tile) + (CGFloat(tile) - dh) / 2, width: dw, height: dh)
            ctx.draw(t.image, in: rect)
            draw(t.title, at: CGPoint(x: x, y: top - tile - 18), size: 15, bold: true, in: ctx)
            draw(t.subtitle, at: CGPoint(x: x, y: top - tile - 33), size: 12, bold: false, in: ctx)
        }
        return ctx.makeImage()
    }

    private static func draw(_ text: String, at p: CGPoint, size: CGFloat, bold: Bool, in ctx: CGContext) {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: bold ? 0.95 : 0.7, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = p
        CTLineDraw(line, ctx)
    }

    /// `image` as a JPEG at `url`.
    @MainActor
    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) throws {
        try Exporter.write(image, to: url, format: .jpeg, quality: quality)
    }
}
