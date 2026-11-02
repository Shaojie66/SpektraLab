import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// ARCHITECTURE §7.14: the AI assistant. The first group is pure — metrics,
/// the two wire formats, the ranking and the refinement's scope — and needs no
/// engine or network. The session group prints proofs of a synthetic frame on
/// a real engine, so it needs no fixture checkout and does not skip.
@MainActor
final class AIUnitTests: XCTestCase {

    // MARK: metrics

    private func metrics(_ pixels: [(UInt8, UInt8, UInt8)]) -> ImageMetrics {
        let bytes: [UInt8] = pixels.flatMap { p -> [UInt8] in [p.0, p.1, p.2, 255] }
        return bytes.withUnsafeBufferPointer { ImageMetrics(rgba: $0) }
    }

    func testMetricsOnKnownPixels() {
        let white = metrics(Array(repeating: (255, 255, 255), count: 4))
        XCTAssertEqual(white.highlightClip, 1)
        XCTAssertEqual(white.shadowClip, 0)
        XCTAssertEqual(white.meanLuma, 1, accuracy: 1e-9)

        let black = metrics(Array(repeating: (0, 0, 0), count: 4))
        XCTAssertEqual(black.shadowClip, 1)
        XCTAssertEqual(black.highlightClip, 0)

        // A dark red is not a crushed shadow: one channel is well above the floor.
        let darkRed = metrics([(120, 2, 2)])
        XCTAssertEqual(darkRed.shadowClip, 0)

        let grey = metrics(Array(repeating: (128, 128, 128), count: 9))
        XCTAssertEqual(grey.contrast, 0, accuracy: 1e-9)
        XCTAssertEqual(grey.colorfulness, 0, accuracy: 1e-9)
        XCTAssertEqual(grey.castRG, 0, accuracy: 1e-9)

        let half = metrics([(0, 0, 0), (255, 255, 255)])
        XCTAssertEqual(half.contrast, 0.5, accuracy: 1e-9)

        let warm = metrics(Array(repeating: (200, 150, 80), count: 4))
        XCTAssertGreaterThan(warm.castYB, 0, "orange leans warm")
        XCTAssertGreaterThan(warm.castRG, 0)
        // A flat patch has no spread, so only the mean term is left:
        // 0.3·√(rg² + yb²) with rg = 50, yb = 175 − 80 = 95.
        XCTAssertEqual(warm.colorfulness, 0.3 * (50.0 * 50 + 95 * 95).squareRoot(), accuracy: 1e-9)
    }

    // MARK: the Anthropic wire

    private struct Recorder: AITransport, @unchecked Sendable {
        final class Box: @unchecked Sendable { var url: URL?; var headers: [String: String] = [:]; var body: JSONValue? }
        let box = Box()
        let reply: AIHTTPResponse
        func post(_ url: URL, headers: [String: String], body: Data) async throws -> AIHTTPResponse {
            box.url = url; box.headers = headers
            box.body = try JSONValue.parse(String(decoding: body, as: UTF8.self))
            return reply
        }
    }

    private func reply(_ status: Int, _ json: JSONValue) -> AIHTTPResponse {
        AIHTTPResponse(status: status, body: Data(json.text().utf8))
    }

    private let schema: JSONValue = ["type": "object", "additionalProperties": false, "required": ["ok"],
                                     "properties": ["ok": ["type": "boolean"]]]

    func testTheAnthropicRequestCarriesTheImageTheSchemaAndTheFallback() async throws {
        let rec = Recorder(reply: reply(200, ["stop_reason": "end_turn", "content": [
            ["type": "thinking", "thinking": ""],
            ["type": "text", "text": "{\"ok\": true}"],
        ]]))
        let client = AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "sk-test", transport: rec)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let out = try await client.complete(AIRequest(system: "sys", parts: [.jpeg(jpeg), .text("hi")], schema: schema))
        XCTAssertEqual(out["ok"]?.bool, true, "the thinking block is not the answer")

        XCTAssertEqual(rec.box.url, AIClient.anthropicEndpoint)
        XCTAssertEqual(rec.box.headers["x-api-key"], "sk-test")
        XCTAssertEqual(rec.box.headers["anthropic-version"], "2023-06-01")
        XCTAssertEqual(rec.box.headers["anthropic-beta"], "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(rec.box.body)
        XCTAssertEqual(body["model"]?.string, "claude-opus-5-5")
        XCTAssertEqual(body["system"]?.string, "sys")
        XCTAssertEqual(body["fallbacks"]?.string, "default")
        XCTAssertEqual(body["output_config"]?["format"]?["type"]?.string, "json_schema")
        XCTAssertEqual(body["output_config"]?["format"]?["schema"], schema)
        XCTAssertNil(body["thinking"], "Opus 5.5 rejects a disabled thinking setting; none is sent")
        guard case .array(let msgs)? = body["messages"], case .array(let content)? = msgs.first?["content"] else {
            return XCTFail("no user content")
        }
        XCTAssertEqual(content.first?["type"]?.string, "image")
        XCTAssertEqual(content.first?["source"]?["media_type"]?.string, "image/jpeg")
        XCTAssertEqual(content.first?["source"]?["data"]?.string, jpeg.base64EncodedString())
        XCTAssertEqual(content.last?["text"]?.string, "hi")
    }

    func testOnlyTheModelsThatTakeItAskForTheFallback() {
        let haiku = AIClient(kind: .anthropic, model: "claude-haiku-5-5", baseURL: "", apiKey: "k")
        XCTAssertNil(haiku.anthropicHeaders()["anthropic-beta"])
        XCTAssertNil(haiku.anthropicBody(AIRequest(system: "", parts: [], schema: schema))["fallbacks"])
    }

    func testAnthropicFailuresAreNamed() {
        XCTAssertThrowsError(try AIClient.readAnthropic(reply(200, ["stop_reason": "refusal", "content": [],
                                                                    "stop_details": ["category": "cyber"]]))) {
            XCTAssertEqual($0 as? AIError, .refused("cyber"))
        }
        XCTAssertThrowsError(try AIClient.readAnthropic(reply(200, ["stop_reason": "max_tokens", "content": []]))) {
            XCTAssertEqual($0 as? AIError, .truncated)
        }
        XCTAssertThrowsError(try AIClient.readAnthropic(reply(401, ["error": ["message": "invalid x-api-key"]]))) {
            XCTAssertEqual($0 as? AIError, .http(401, "invalid x-api-key"))
        }
        XCTAssertThrowsError(try AIClient.readAnthropic(reply(200, ["stop_reason": "end_turn",
                                                                    "content": [["type": "text", "text": "no json here"]]])))
    }

    func testNoKeyIsRefusedBeforeAnythingIsSent() async {
        let rec = Recorder(reply: reply(200, [:]))
        let client = AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "", transport: rec)
        do {
            _ = try await client.complete(AIRequest(system: "", parts: [], schema: schema))
            XCTFail("sent without a key")
        } catch {
            guard case .notConfigured? = error as? AIError else { return XCTFail("\(error)") }
        }
        XCTAssertNil(rec.box.url)
    }

    // MARK: the OpenAI-compatible wire

    func testTheOpenAIRequestAndAFencedAnswer() async throws {
        let rec = Recorder(reply: reply(200, ["choices": [["finish_reason": "stop",
                                                           "message": ["content": "```json\n{\"ok\": true}\n```"]]]]))
        let client = AIClient(kind: .openAICompatible, model: "vision-model", baseURL: "http://localhost:11434/v1/",
                              apiKey: "", transport: rec)
        let out = try await client.complete(AIRequest(system: "sys", parts: [.jpeg(Data([1, 2, 3]))], schema: schema))
        XCTAssertEqual(out["ok"]?.bool, true)
        XCTAssertEqual(rec.box.url?.absoluteString, "http://localhost:11434/v1/chat/completions")
        XCTAssertNil(rec.box.headers["authorization"], "a local server with no key gets no header")
        let body = try XCTUnwrap(rec.box.body)
        XCTAssertEqual(body["response_format"]?["type"]?.string, "json_object")
        guard case .array(let msgs)? = body["messages"], case .array(let content)? = msgs.last?["content"] else {
            return XCTFail("no user content")
        }
        XCTAssertEqual(msgs.first?["role"]?.string, "system")
        XCTAssertEqual(content.first?["image_url"]?["url"]?.string, "data:image/jpeg;base64,AQID")
        XCTAssertTrue(content.last?["text"]?.string?.contains("\"additionalProperties\"") == true,
                      "the schema travels in the prompt")
    }

    func testAKeyIsABearerToken() async throws {
        let rec = Recorder(reply: reply(200, ["choices": [["message": ["content": "{\"ok\": false}"]]]]))
        let client = AIClient(kind: .openAICompatible, model: "m", baseURL: "https://api.openai.com/v1",
                              apiKey: "sk-x", transport: rec)
        _ = try await client.complete(AIRequest(system: "", parts: [], schema: schema))
        XCTAssertEqual(rec.box.headers["authorization"], "Bearer sk-x")
        XCTAssertThrowsError(try AIClient.readOpenAI(reply(200, ["choices": [["finish_reason": "length",
                                                                               "message": ["content": "{"]]]]))) {
            XCTAssertEqual($0 as? AIError, .truncated)
        }
    }

    // MARK: reading answers

    func testARankingKeepsTilesThatExistEachOnce() throws {
        let answer: JSONValue = ["summary": "s", "ranking": [
            ["index": 3, "score": 91, "reason": "a"], ["index": 3, "score": 80, "reason": "dup"],
            ["index": 0, "score": 70, "reason": "none"], ["index": 9, "score": 70, "reason": "past the end"],
            ["index": 1, "score": 140, "reason": "b"],
        ]]
        let (summary, ranked) = try AIPrompts.readRanking(answer, count: 4)
        XCTAssertEqual(summary, "s")
        XCTAssertEqual(ranked, [.init(index: 3, score: 91, reason: "a"), .init(index: 1, score: 100, reason: "b")])
        XCTAssertThrowsError(try AIPrompts.readRanking(["ranking": [["index": 7, "score": 1, "reason": ""]]], count: 4))
    }

    func testARefinementMayOnlyTouchItsOwnFields() throws {
        XCTAssertNoThrow(try AIPrompts.checkScope(["params": ["yFilterShift": 0.04, "printBrightnessStops": 0.2],
                                                   "adjustments": ["contrast": 6, "colorBalance": ["shadows": ["hue": 200, "saturation": 0.1]]]]))
        XCTAssertThrowsError(try AIPrompts.checkScope(["params": ["filmStock": "kodak_portra_160"]]),
                             "the film is the chooser's")
        XCTAssertThrowsError(try AIPrompts.checkScope(["geometry": ["angle": 2]]))
        XCTAssertThrowsError(try AIPrompts.checkScope(["decode": ["temperature": 5000]]))
        XCTAssertThrowsError(try AIPrompts.checkScope(["params": ["yFilterShift": 5]]), "the interface's range holds")
    }

    func testAMoveIsReadStrictly() throws {
        let none = try AIPrompts.readMove(["rationale": "fine", "patch_json": "{}", "placement": .null, "done": true])
        XCTAssertNil(none.patch)
        XCTAssertNil(none.placement)
        XCTAssertTrue(none.done)

        let move = try AIPrompts.readMove(["rationale": "r", "patch_json": "{\"adjustments\":{\"exposure\":0.2}}",
                                           "placement": ["highlight": 9, "shadow": 0], "done": false])
        XCTAssertEqual(move.patch, ["adjustments": ["exposure": 0.2]])
        XCTAssertEqual(move.placement?.highlight, 6, "clamped to the Fit's range")
        XCTAssertEqual(move.placement?.shadow, 0)

        let zero = try AIPrompts.readMove(["rationale": "", "patch_json": "", "placement": ["highlight": 0, "shadow": 0], "done": false])
        XCTAssertNil(zero.placement, "both sides 0 is no placement, not a reset")

        XCTAssertThrowsError(try AIPrompts.readMove(["rationale": "", "patch_json": "[1]", "placement": .null, "done": false]))

        // A compatible model that hands the patch over as an object.
        let object = try AIPrompts.readMove(["rationale": "", "patch_json": ["adjustments": ["contrast": 4]],
                                             "placement": .null, "done": false])
        XCTAssertEqual(object.patch, ["adjustments": ["contrast": 4]])

        // A placement written into the patch is lifted out and run through the Fit.
        let inPatch = try AIPrompts.readMove(["rationale": "", "placement": .null, "done": false,
                                              "patch_json": "{\"params\":{\"yFilterShift\":0.03},\"placement\":{\"highlight\":0.5,\"shadow\":0}}"])
        XCTAssertEqual(inPatch.patch, ["params": ["yFilterShift": 0.03]])
        XCTAssertEqual(inPatch.placement?.highlight, 0.5)
        XCTAssertEqual(inPatch.placement?.shadow, 0)
        let viaParams = try AIPrompts.readMove(["rationale": "", "placement": .null, "done": false,
                                                "patch_json": ["params": ["sceneLatitude": ["shadowPullBack": 1.25]]]])
        XCTAssertNil(viaParams.patch, "nothing else was asked for")
        XCTAssertEqual(viaParams.placement?.shadow, 1.25)
        let both = try AIPrompts.readMove(["rationale": "", "done": false, "placement": ["highlight": 1, "shadow": 0],
                                           "patch_json": "{\"placement\":{\"highlight\":3,\"shadow\":0}}"])
        XCTAssertEqual(both.placement?.highlight, 1, "the placement field wins")
        XCTAssertNil(both.patch)
    }

    func testRefiningMaySmoothSkinAndIsToldAboutFaces() throws {
        XCTAssertNoThrow(try AIPrompts.checkScope(["params": ["retouch": ["skinSmoothing": 0.3]]]))
        XCTAssertThrowsError(try AIPrompts.checkScope(["params": ["retouch": ["skinSmoothing": 1.5]]]), "the range holds")
        XCTAssertTrue(AIPrompts.refinerSystem.contains("params.retouch.skinSmoothing"))
        func told(_ mask: SkinMask) -> String {
            AIPrompts.refinerUser(document: ["params": [:], "adjustments": [:]], latitude: nil, film: nil, exif: nil,
                                  intent: "", history: [], feedback: nil, round: 1, of: 3, faces: mask)
        }
        XCTAssertTrue(told(.none).contains("No faces were found"))
        let big = SkinTests.face(0.2, 0.3, 0.2, 0.25)
        let two = told(SkinMask(faces: [big, big]))
        XCTAssertTrue(two.contains("2 face(s) found"))
        XCTAssertFalse(two.contains("unevenly"))
        XCTAssertFalse(two.contains("barely shows"))
        let crowd = told(SkinMask(faces: [SkinTests.face(0.2, 0.3, 0.03, 0.04)], missed: 4, aspect: 4.0 / 3))
        XCTAssertTrue(crowd.contains("4 more were too small or turned"), crowd)
        XCTAssertTrue(crowd.contains("All are small (the largest is 3% of the long edge)"), crowd)
    }

    /// The Portrait section says who is left alone, and when every face is
    /// too small for the smoothing to show.
    func testThePortraitNoteSaysWhoIsLeftAloneAndWhenFacesAreSmall() {
        let big = SkinTests.face(0.2, 0.3, 0.2, 0.25), small = SkinTests.face(0.2, 0.3, 0.03, 0.04)
        XCTAssertEqual(SkinMask(faces: [big]).largestFace, 0.2, accuracy: 1e-9)
        XCTAssertEqual(SkinMask(faces: [big], aspect: 0.75).largestFace, 0.15, accuracy: 1e-9,
                       "a portrait-format picture: a share of its long edge, the height")
        XCTAssertFalse(SkinMask(faces: [big, small]).facesAreSmall, "one large face is enough")
        XCTAssertTrue(SkinMask(faces: [small, small]).facesAreSmall)
        XCTAssertFalse(SkinMask.none.facesAreSmall)

        let plain = PortraitSection.note(SkinMask(faces: [big, big]))
        let group = PortraitSection.note(SkinMask(faces: [small, small], missed: 3))
        let lost = PortraitSection.note(SkinMask(faces: [], missed: 2))
        XCTAssertTrue(plain.contains("2"))
        XCTAssertFalse(plain.contains("3"))
        XCTAssertTrue(group.contains("2") && group.contains("3"), group)
        XCTAssertNotEqual(group, PortraitSection.note(SkinMask(faces: [big, small], missed: 3)), "small faces say so")
        XCTAssertTrue(lost.contains("2"), lost)
        XCTAssertNotEqual(lost, PortraitSection.note(.none))
    }

    func testAMeterIsReadStrictlyAndRefiningMayChangeIt() throws {
        XCTAssertEqual(try AIPrompts.readMeter(["meter": "protect_highlights", "reason": "night"]).meter, .protectHighlights)
        XCTAssertThrowsError(try AIPrompts.readMeter(["meter": "spot", "reason": ""]))
        XCTAssertThrowsError(try AIPrompts.readMeter(["reason": "no meter"]))
        XCTAssertNoThrow(try AIPrompts.checkScope(["params": ["autoExposure": true, "autoExposureMethod": "protect_highlights"]]))
        XCTAssertThrowsError(try AIPrompts.checkScope(["params": ["autoExposureMethod": "spot"]]), "only the four meters")
        XCTAssertTrue(AIPrompts.refinerSystem.contains("Exposure first, and on the negative"))
        XCTAssertTrue(AIPrompts.exposureSystem.contains("protect_highlights"))
        XCTAssertEqual(AIPrompts.exposureSchema["properties"]?["meter"]?["enum"],
                       .array(ExposureMethod.allCases.map { .string($0.rawValue) }))
    }

    func testTheRefinerIsToldToKeepWhatLiesOutsideTheIntent() {
        let text = AIPrompts.refinerSystem
        XCTAssertTrue(text.contains("outside the intent"))
        XCTAssertTrue(text.contains("sky"), "a global warm-up must not cost the sky")
        XCTAssertTrue(text.contains("colour balance by tonal zone"))
        XCTAssertTrue(text.contains("total pull-backs, not additions"))
        let user = AIPrompts.refinerUser(document: ["params": [:], "adjustments": [:]],
                                         latitude: ["fit": ["highlight": ["minimumPullBack": 0.8]], "placement": ["highlightPullBack": 0.6]],
                                         film: "Gold 200", exif: nil, intent: "", history: [], feedback: nil, round: 2, of: 3)
        XCTAssertTrue(user.contains("minimumPullBack"), "the minimum the prompt names is in what the model reads")
        XCTAssertTrue(user.contains("highlightPullBack"), "and so is the current total")
    }

    // MARK: which films

    func testTheDefaultCandidatesAreFairAndPrintable() {
        let catalog = StockCatalog.shared
        var current = FilmParams()
        current.filmStock = "kodak_portra_800_push1"
        current.printStock = "kodak_supra_endura"
        current.scanFilm = false
        let c = ProofSheet.defaultCandidates(catalog: catalog, current: current)
        XCTAssertEqual(c.first, ProofCandidate(film: "kodak_portra_800_push1", paper: "kodak_supra_endura"),
                       "what the frame has now is always one of the answers, first")
        XCTAssertEqual(Set(c.map(\.film)).count, c.count, "one proof per film")
        XCTAssertFalse(c.dropFirst().contains { $0.film.contains("_push") }, "push processes are the same emulsion")
        XCTAssertFalse(c.contains { catalog.stock($0.film)?.isMonochrome == true }, "black and white only when asked")
        for x in c {
            let film = catalog.stock(x.film)
            if film?.isPositive == true {
                XCTAssertNil(x.paper, "\(x.film) is scanned")
            } else {
                let paper = try? XCTUnwrap(x.paper)
                XCTAssertTrue(paper.map { catalog.canPrint(film: x.film, on: $0) } ?? false, "\(x.film)")
            }
        }
        let mono = ProofSheet.defaultCandidates(catalog: catalog, current: current, includeMonochrome: true)
        XCTAssertTrue(mono.contains { $0.film == "kodak_tri_x_400" && $0.paper == "ilford_multigrade_iv_rc" })
        XCTAssertThrowsError(try ProofSheet.candidates(films: ["kodak_portra_400", "no_such_film"], catalog: catalog))
    }

    func testAProofIsANeutralPrint() {
        var p = FilmParams()
        p.exposureCompensationEV = 1.5
        p.yFilterShift = 0.2
        p.grainActive = true
        p.glareActive = true
        p.filmEdge.active = true
        p.sceneLatitude.active = true
        p.autoExposureMethod = "protect_highlights"
        let q = ProofSheet.proofParams(from: p)
        XCTAssertEqual(q.exposureCompensationEV, 1.5, "the frame's own exposure is kept: it is the scene's, not the film's")
        XCTAssertEqual(q.autoExposureMethod, "protect_highlights")
        XCTAssertEqual(q.yFilterShift, 0)
        XCTAssertFalse(q.grainActive, "grain at proof size is aliasing")
        XCTAssertFalse(q.glareActive, "glare is the one unseeded stage (AGENTS.md trap 1)")
        XCTAssertFalse(q.filmEdge.active)
        XCTAssertEqual(q.sceneLatitude, SceneLatitudeSettings())
    }

    func testTheToolTableListsCompare() throws {
        let tool = try XCTUnwrap(AgentTools.named("compare_stocks"))
        XCTAssertEqual(tool.command, "compare")
        let (name, args, preview) = try AgentCLI.parse(["compare", "/tmp/x.tif", "--films", "kodak_portra_400, kodak_gold_200",
                                                        "--mono", "--long-edge", "512", "--preview", "/tmp/s.jpg"])
        XCTAssertEqual(name, "compare_stocks")
        XCTAssertEqual(args["films"], ["kodak_portra_400", "kodak_gold_200"])
        XCTAssertEqual(args["include_monochrome"], true)
        XCTAssertEqual(args["long_edge"], 512)
        XCTAssertEqual(preview?.path, "/tmp/s.jpg")
    }
}

/// Skin smoothing: the band-stop's arithmetic, measured on known pixels in the
/// Core Image context the engine's frame is rendered with.
@MainActor
final class SkinTests: XCTestCase {
    static let side = 512
    static let period = 40.0      // between the band's edges: should go
    static let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// 0.3 grey + a mid-scale blotch (sine, period 40 px) + a fine 2 px checker.
    static func frame() -> CIImage {
        let n = side
        var px = [Float](repeating: 0, count: n * n * 4)
        for y in 0..<n {
            for x in 0..<n {
                let blotch = 0.05 * sin(2 * .pi * Double(x) / period)
                let checker = ((x + y) % 2 == 0 ? 0.02 : -0.02)
                let v = Float(0.3 + blotch + checker)
                let i = (y * n + x) * 4
                px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 1
            }
        }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: n * 16, size: CGSize(width: n, height: n),
                       format: .RGBAf, colorSpace: space)
    }

    static func pixels(_ image: CIImage) -> [Float] {
        let n = side
        var out = [Float](repeating: 0, count: n * n * 4)
        out.withUnsafeMutableBytes { buf in
            ImageDecoder.context.render(image, toBitmap: buf.baseAddress!, rowBytes: n * 16,
                                        bounds: CGRect(x: 0, y: 0, width: n, height: n),
                                        format: .RGBAf, colorSpace: space)
        }
        return out
    }

    /// The mean, and the amplitudes of the blotch and of the checker, over
    /// rows 200–311 between `x0` and `x1`, by projection on the mean-removed
    /// values. The range must hold whole periods: a first version did not,
    /// and the offset of a broken smoothing leaked into the projection and
    /// read as a smaller blotch.
    static func amplitudes(_ px: [Float], x0: Int, x1: Int) -> (mean: Double, blotch: Double, checker: Double) {
        precondition(Double(x1 - x0).truncatingRemainder(dividingBy: period) == 0, "whole periods")
        var total = 0.0, count = 0
        for y in 200..<312 { for x in x0..<x1 { total += Double(px[(y * side + x) * 4]); count += 1 } }
        let mean = total / Double(count)
        var sinSum = 0.0, cosSum = 0.0, chk = 0.0
        for y in 200..<312 {
            for x in x0..<x1 {
                let v = Double(px[(y * side + x) * 4]) - mean
                sinSum += v * sin(2 * .pi * Double(x) / period)
                cosSum += v * cos(2 * .pi * Double(x) / period)
                chk += v * ((x + y) % 2 == 0 ? 1 : -1)
            }
        }
        let n = Double(count)
        return (mean, 2 * (sinSum * sinSum + cosSum * cosSum).squareRoot() / n, chk / n)
    }

    /// One "face" over the left half of the frame, nothing cut out of it.
    static let leftHalf = SkinMask(faces: [SkinMask.Face(
        box: CGRect(x: 0, y: 0, width: 0.5, height: 1),
        outline: [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 1)],
        features: [])])

    func testTheBandStopTakesTheBlotchAndKeepsTheTexture() {
        let input = Self.frame()
        let before = Self.pixels(input)
        let a0 = Self.amplitudes(before, x0: 40, x1: 200)
        XCTAssertEqual(a0.blotch, 0.05, accuracy: 0.005, "the premise: a 0.05 blotch")
        XCTAssertEqual(a0.checker, 0.02, accuracy: 0.002, "and a 0.02 checker")

        let out = Self.pixels(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 1))
        let a = Self.amplitudes(out, x0: 40, x1: 200)
        XCTAssertEqual(a.mean, a0.mean, accuracy: 0.005, "the skin's overall tone is kept")
        XCTAssertLessThan(a.blotch, a0.blotch * 0.35, "the mid-scale blotch is mostly gone (\(a.blotch))")
        XCTAssertGreaterThan(a.checker, a0.checker * 0.8, "the fine texture is kept (\(a.checker))")

        // Outside the mask, the pixels are the input's.
        var worst: Float = 0
        for y in 0..<Self.side { for x in 360..<Self.side {
            let i = (y * Self.side + x) * 4
            worst = max(worst, abs(out[i] - before[i]))
        } }
        XCTAssertLessThan(worst, 2e-3, "nothing changes outside the skin (half-float working format)")
        XCTAssertEqual(out[3], 1, accuracy: 1e-3, "alpha stays 1")
    }

    /// The blotch's amplitude over `rows` and `xs` (whole periods), mean removed.
    static func blotch(_ px: [Float], rows: Range<Int>, xs: Range<Int>) -> Double {
        var total = 0.0, n = 0.0
        for y in rows { for x in xs { total += Double(px[(y * side + x) * 4]); n += 1 } }
        let mean = total / n
        var sn = 0.0, cs = 0.0
        for y in rows { for x in xs {
            let v = Double(px[(y * side + x) * 4]) - mean
            sn += v * sin(2 * .pi * Double(x) / period); cs += v * cos(2 * .pi * Double(x) / period)
        } }
        return 2 * (sn * sn + cs * cs).squareRoot() / n
    }

    static func face(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> SkinMask.Face {
        SkinMask.Face(box: CGRect(x: x, y: y, width: w, height: h),
                      outline: [CGPoint(x: x, y: y), CGPoint(x: x + w, y: y), CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)],
                      features: [])
    }

    /// The same 40 px pattern is a blotch on a big face and the face's own
    /// shape on a small one: each face is smoothed at its own scale.
    func testEachFaceIsSmoothedAtItsOwnScale() {
        let big = Self.face(0, 0.2, 0.5, 0.6), small = Self.face(0.78, 0.3, 0.16, 0.4)
        let input = Self.frame()
        let before = Self.pixels(input)
        let out = Self.pixels(SkinSmoothing.apply(input, mask: SkinMask(faces: [big, small]), strength: 1))
        let bigBefore = Self.blotch(before, rows: 230..<282, xs: 40..<200), bigAfter = Self.blotch(out, rows: 230..<282, xs: 40..<200)
        let smallBefore = Self.blotch(before, rows: 230..<282, xs: 420..<460), smallAfter = Self.blotch(out, rows: 230..<282, xs: 420..<460)
        XCTAssertLessThan(bigAfter, bigBefore * 0.4, "a blotch on the big face goes")
        XCTAssertGreaterThan(smallAfter, smallBefore * 0.7, "the same size on a small face is its shape, and stays")
    }

    /// A thin dark line through the skin — a glasses frame — keeps its contrast.
    func testASharpEdgeIsHeldOffTheSmoothing() {
        let n = Self.side
        var px = [Float](repeating: 0, count: n * n * 4)
        for y in 0..<n { for x in 0..<n {
            let blotch = 0.05 * sin(2 * .pi * Double(x) / Self.period)
            let line: Double = (x == 120 || x == 121) ? -0.15 : 0
            let v = Float(0.3 + blotch + line)
            let i = (y * n + x) * 4
            px[i] = v; px[i + 1] = v; px[i + 2] = v; px[i + 3] = 1
        } }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        let input = CIImage(bitmapData: data, bytesPerRow: n * 16, size: CGSize(width: n, height: n),
                            format: .RGBAf, colorSpace: Self.space)
        let before = Self.pixels(input)
        let out = Self.pixels(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 1))
        func contrast(_ p: [Float]) -> Double {
            var c = 0.0
            for y in 230..<282 {
                let line = Double(p[(y * n + 120) * 4] + p[(y * n + 121) * 4]) / 2
                let around = Double(p[(y * n + 115) * 4] + p[(y * n + 126) * 4]) / 2
                c += around - line
            }
            return c / 52
        }
        XCTAssertGreaterThan(contrast(out), contrast(before) * 0.8, "the frame stays as sharp")
    }

    /// Full strength takes out nearly all of a blotch on a large face; a
    /// middling one, about what it always did.
    func testFullStrengthTakesNearlyAllOfTheBlotch() {
        let input = Self.frame()
        let before = Self.blotch(Self.pixels(input), rows: 200..<312, xs: 40..<200)
        let full = Self.blotch(Self.pixels(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 1)), rows: 200..<312, xs: 40..<200)
        XCTAssertLessThan(full, before * 0.12, "nearly all of it at 100 (\(full))")
    }

    /// Soft skin softens the fine texture as well; without it the texture stays.
    func testSoftSkinSoftensTheFineTextureToo() {
        let input = Self.frame()
        let before = Self.amplitudes(Self.pixels(input), x0: 40, x1: 200)
        let plain = Self.amplitudes(Self.pixels(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 1)), x0: 40, x1: 200)
        let soft = Self.amplitudes(Self.pixels(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 1, soft: 1)), x0: 40, x1: 200)
        XCTAssertGreaterThan(plain.checker, before.checker * 0.8, "without it, the texture stays")
        XCTAssertLessThan(soft.checker, before.checker * 0.55, "with it, the texture is softened (\(soft.checker))")
        XCTAssertLessThan(soft.blotch, before.blotch * 0.12, "and the blotch still goes")
        XCTAssertEqual(soft.mean, before.mean, accuracy: 0.005, "the tone is kept")
        var p = FilmParams()
        p.retouch = RetouchSettings(skinSmoothing: 0.5)
        let plainKey = p.engineFramingKey
        p.retouch.soft = true
        XCTAssertNotEqual(p.engineFramingKey, plainKey, "soft skin is another frame for the engine")
    }

    /// Soft skin takes off fine texture the film's grain would put back; on
    /// fine grain, or none, nothing puts it back and the skin goes waxy. So
    /// its share follows how coarse the grain lands, 35 mm at the film's own
    /// grain being the whole of it.
    func testSoftSkinIsHeldBackOnFineGrain() {
        XCTAssertEqual(RetouchSettings.softShare(grain: 0), RetouchSettings.softFloor, "no grain: the floor")
        XCTAssertEqual(RetouchSettings.softShare(grain: 1), 1, "35 mm: all of it")
        XCTAssertEqual(RetouchSettings.softShare(grain: 1.7), 1, "coarser: still all of it, never more")
        XCTAssertEqual(RetouchSettings.softShare(grain: 0.48), 0.7, accuracy: 1e-9, "120: in steps of a tenth")

        var p = FilmParams()
        XCTAssertEqual(p.grainCoarseness, 1, accuracy: 1e-9, "35 mm at the film's own grain")
        p.grainActive = false
        XCTAssertEqual(p.grainCoarseness, 0)
        p.grainActive = true
        p.filmStock = "kodak_tri_x_400"
        XCTAssertEqual(p.grainCoarseness, 1.7, accuracy: 1e-9, "a film's own grain counts")
        p.filmStock = FilmParams().filmStock
        p.filmFormatMM = 72
        XCTAssertEqual(p.grainCoarseness, 0.5, accuracy: 1e-9, "a frame twice as long: grain half the size")

        var q = FilmParams()
        q.retouch = RetouchSettings(skinSmoothing: 0.5, soft: true)
        XCTAssertEqual(q.softSkinShare, 1)
        let coarse = q.engineFramingKey
        q.grainActive = false
        XCTAssertEqual(q.softSkinShare, RetouchSettings.softFloor)
        XCTAssertNotEqual(q.engineFramingKey, coarse, "soft skin on bare film is another frame")
        XCTAssertNotEqual(Session.printStamp(q), { var c = q; c.grainActive = true; return Session.printStamp(c) }())
        q.retouch.soft = false
        XCTAssertEqual(q.softSkinShare, 0)
        let plain = q.engineFramingKey
        q.grainActive = true
        XCTAssertEqual(q.engineFramingKey, plain, "without soft skin the grain moves no frame")
        q.retouch.soft = true
        q.effects.grain = 1.05
        XCTAssertEqual(q.engineFramingKey, coarse, "a nudge of the grain inside a step moves no frame")

        let input = Self.frame()
        let full = Self.amplitudes(Self.pixels(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 1, soft: 1)), x0: 40, x1: 200)
        let held = Self.amplitudes(Self.pixels(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 1,
                                                                    soft: RetouchSettings.softFloor)), x0: 40, x1: 200)
        let none = Self.amplitudes(Self.pixels(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 1)), x0: 40, x1: 200)
        XCTAssertGreaterThan(held.checker, full.checker * 1.3, "held back, more texture is kept (\(held.checker) vs \(full.checker))")
        XCTAssertLessThan(held.checker, none.checker * 0.95, "but some is still softened")
    }

    /// The features stay out of the mask whatever the feather: an eye is
    /// about a twentieth of a face tall, and the edge's feather (3 % of a
    /// face's width) blurred over the hole filled it back to half, so a
    /// strong setting greyed the irises and took the lash line.
    func testTheEyesStayOutOfTheMask() {
        let n = Double(Self.side)
        // A face 40 % of the frame wide; an eye 8 % of it wide, 4 % tall.
        let eye = CGRect(x: 0.45, y: 0.492, width: 0.032, height: 0.016)   // centred in y: the bitmap may be flipped
        let mask = SkinMask(faces: [SkinMask.Face(
            box: CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5),
            outline: [CGPoint(x: 0.3, y: 0.25), CGPoint(x: 0.7, y: 0.25), CGPoint(x: 0.7, y: 0.75), CGPoint(x: 0.3, y: 0.75)],
            features: [[CGPoint(x: eye.minX, y: eye.minY), CGPoint(x: eye.maxX, y: eye.minY),
                        CGPoint(x: eye.maxX, y: eye.maxY), CGPoint(x: eye.minX, y: eye.maxY)]])])
        let image = try! XCTUnwrap(mask.ciImage(over: CGRect(x: 0, y: 0, width: n, height: n)))
        let px = Self.pixels(image)
        func at(_ x: Double, _ y: Double) -> Float { px[(Int(y * n) * Self.side + Int(x * n)) * 4] }
        XCTAssertLessThan(at(eye.midX, eye.midY), 0.1, "the eye is out (\(at(eye.midX, eye.midY)))")
        XCTAssertGreaterThan(at(0.4, 0.35), 0.95, "the cheek is in")
        XCTAssertLessThan(at(0.5, 0.2), 0.05, "outside the face is out")
    }

    /// A group's small faces are looked for on overlapping tiles: the tiles
    /// cover the picture with room for a face across each seam, and a face
    /// seen on several tiles — or cut in half by one — is one face.
    func testFacesAreLookedForOnOverlappingTilesAndMerged() {
        let size = CGSize(width: 2048, height: 1536)
        let tiles = SkinMask.tileRects(size, n: 3)
        XCTAssertEqual(tiles.count, 10, "the whole picture and nine tiles")
        XCTAssertEqual(tiles[0], CGRect(origin: .zero, size: size))
        let union = tiles.dropFirst().reduce(CGRect.null) { $0.union($1) }
        XCTAssertEqual(union, CGRect(origin: .zero, size: size), "the tiles cover it")
        let a = tiles[1], b = tiles[2]                                  // one above the other
        XCTAssertGreaterThan(a.intersection(b).height, 150, "a 150 px face across the seam is whole on one tile")
        XCTAssertEqual(SkinMask.tileRects(size, n: 1), [CGRect(origin: .zero, size: size)])

        let face = CGRect(x: 100, y: 100, width: 40, height: 40)
        let again = face.offsetBy(dx: 2, dy: 1)                         // the same face on the next tile
        let half = CGRect(x: 100, y: 100, width: 40, height: 18)       // the half a seam left
        let neighbour = CGRect(x: 150, y: 100, width: 40, height: 40)  // touching, another face
        let kept = SkinMask.merged([half, face, neighbour, again])
        XCTAssertEqual(kept.count, 2, "\(kept)")
        XCTAssertTrue(kept.contains(neighbour))
    }

    func testNothingIsDoneAtZeroOrWithoutAFace() {
        let input = Self.frame()
        XCTAssertTrue(SkinSmoothing.apply(input, mask: Self.leftHalf, strength: 0) === input)
        XCTAssertTrue(SkinSmoothing.apply(input, mask: .none, strength: 1) === input)
    }

    func testTheRetouchKeysTheEngineFrameAndThePrint() {
        var p = FilmParams()
        XCTAssertNil(p.engineFramingKey, "off: the whole decode, as before")
        let stampOff = Session.printStamp(p)
        p.retouch.skinSmoothing = 0.3
        XCTAssertEqual(p.engineFramingKey, "skin=0.300", "a retouched decode is another frame for the engine")
        XCTAssertNotEqual(Session.printStamp(p), stampOff, "and another print for the cache")
        XCTAssertTrue(p.delta(from: FilmParams()).delta.isEmpty, "and nothing on the wire")
    }
}

/// Composition: the measurements and the rules that build crops from them.
@MainActor
final class CompositionTests: XCTestCase {

    /// Sky over ground, the boundary through the centre tilted `degrees`
    /// clockwise (y down: descending to the right).
    static func horizon(tilted degrees: Double, size: CGSize = CGSize(width: 1200, height: 800)) -> CGImage {
        let w = Int(size.width), h = Int(size.height)
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Core Graphics is y up: draw the ground as the polygon under the line.
        ctx.setFillColor(CGColor(srgbRed: 0.55, green: 0.75, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let t = tan(degrees * .pi / 180)
        let cx = Double(w) / 2, cy = Double(h) / 2
        func yUp(_ x: Double) -> Double { Double(h) - (cy + (x - cx) * t) }   // y-down line, flipped
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.35, blue: 0.15, alpha: 1))
        ctx.beginPath()
        ctx.move(to: CGPoint(x: 0, y: 0))
        ctx.addLine(to: CGPoint(x: 0, y: yUp(0)))
        ctx.addLine(to: CGPoint(x: Double(w), y: yUp(Double(w))))
        ctx.addLine(to: CGPoint(x: Double(w), y: 0))
        ctx.closePath()
        ctx.fillPath()
        return ctx.makeImage()!
    }

    /// The sign that matters: a horizon descending to the right is levelled by
    /// a positive (clockwise) `Geometry.angle` of the same size, and the
    /// crop's own x axis is then parallel to it.
    func testATiltedHorizonIsLevelledTheRightWay() throws {
        for tilt in [4.0, -3.0] {
            let a = try CompositionAnalysis.analyse(Self.horizon(tilted: tilt))
            let measured = try XCTUnwrap(a.horizonTilt, "a horizon at \(tilt)° was found")
            XCTAssertEqual(measured, tilt, accuracy: 1, "\(tilt)°: measured \(measured)°")
            XCTAssertEqual(a.straighten, measured, "beyond the tolerance, it is levelled")
        }
        let flat = try CompositionAnalysis.analyse(Self.horizon(tilted: 0.2))
        XCTAssertEqual(flat.straighten, 0, "within the tolerance a horizon is left alone")
    }

    private let landscape = CGSize(width: 1200, height: 800)

    private func ratio(_ g: Geometry, _ size: CGSize) -> Double {
        Double(g.crop.width * size.width) / Double(g.crop.height * size.height)
    }

    func testEveryCandidateFitsHasItsRatioAndKeepsTheSubject() {
        let subject = CGRect(x: 0.62, y: 0.3, width: 0.1, height: 0.2)
        let a = CompositionAnalysis(straighten: 0, horizonTilt: nil, salient: [subject], faces: [])
        let c = CompositionCandidates.make(current: .default, analysis: a, imageSize: landscape)
        XCTAssertEqual(c.first?.kind, .current, "the framing it has now is one of the answers, first")
        XCTAssertGreaterThan(c.count, 4)
        XCTAssertLessThanOrEqual(c.count, 12)
        for x in c.dropFirst() {
            let g = x.geometry
            XCTAssertTrue(g.fits(in: landscape), "\(x.label) \(x.kind) fits")
            XCTAssertGreaterThanOrEqual(g.crop.width * g.crop.height, CompositionCandidates.minimumArea - 1e-9)
            if let want = g.aspect.ratio(sourceAspect: 1.5) {
                // `snappedToFrame` trims a side by up to 1e-5 to sit on the frame's edge.
                XCTAssertEqual(ratio(g, landscape), want, accuracy: 1e-4, "\(x.label) is its ratio")
            }
            XCTAssertTrue(CompositionCandidates.contains(g, CGRect(x: subject.midX, y: subject.midY, width: 0, height: 0),
                                                         in: landscape), "the subject stays in \(x.label)")
            XCTAssertNoThrow(try AgentDocument.validate(["geometry": [
                "crop": ["x": .number(Double(g.crop.x)), "y": .number(Double(g.crop.y)),
                         "width": .number(Double(g.crop.width)), "height": .number(Double(g.crop.height))],
                "angle": .number(g.angle), "aspect": .string(g.aspect.rawValue)]]), "the edit document takes it")
        }
        for (i, x) in c.enumerated() {
            for y in c[(i + 1)...] { XCTAssertFalse(CompositionCandidates.alike(x.geometry, y.geometry)) }
        }
        XCTAssertTrue(c.contains { $0.kind == .thirds }, "a subject off centre is put on a third")
        XCTAssertTrue(Set(c.map(\.label)).isSuperset(of: ["5:4", "1:1"]), "several ratios are offered")
        XCTAssertFalse(c.contains { $0.geometry.aspect == .r3x2 && $0.kind == .ratio },
                       "on a 3:2 frame, 3:2 is the original ratio and is not offered twice")
    }

    /// What draws the eye is kept almost whole, not only its centre: a tight
    /// crop once cut the top off a firework.
    func testTheSubjectIsKeptAlmostWhole() {
        // From the top of the frame most of the way down, as a firework is:
        // a tight crop that only keeps its centre takes its top off.
        let burst = CGRect(x: 0.3, y: 0.0, width: 0.4, height: 0.8)
        let a = CompositionAnalysis(straighten: 0, horizonTilt: nil, salient: [burst], faces: [])
        let c = CompositionCandidates.make(current: .default, analysis: a, imageSize: landscape)
        XCTAssertGreaterThan(c.count, 1)
        for x in c.dropFirst() {
            XCTAssertGreaterThanOrEqual(CompositionCandidates.coverage(x.geometry, burst, in: landscape),
                                        CompositionCandidates.subjectKept, "\(x.label) \(x.kind) keeps the burst")
        }
    }

    /// A landscape's salient region is the scene, not a subject: the river
    /// frame's was the whole width and 75 % of the frame, and keeping 90 % of
    /// it left only three crops. A scene is kept at 60 %, and the crops are
    /// placed by how much sky and how much foreground they keep.
    func testASceneGetsCropsPlacedForSkyAndForeground() {
        let scene = CGRect(x: 0, y: 0.19, width: 1, height: 0.75)
        let a = CompositionAnalysis(straighten: 0, horizonTilt: nil, salient: [scene], faces: [])
        let size = CGSize(width: 1568, height: 1176)
        let c = CompositionCandidates.make(current: .default, analysis: a, imageSize: size)
        XCTAssertGreaterThanOrEqual(c.count, 6, "a landscape has crops to choose among (\(c.count))")
        let crops = c.dropFirst().map(\.geometry.crop)
        XCTAssertTrue(crops.contains { $0.y < 0.01 && $0.height < 0.95 }, "one keeps the sky and trims the foreground")
        XCTAssertTrue(crops.contains { $0.y + $0.height > 0.99 && $0.y > 0.05 }, "one keeps the foreground and trims the sky")
        XCTAssertTrue(c.contains { $0.label == "1:1" }, "a square is among them")
        for x in c.dropFirst() {
            XCTAssertGreaterThanOrEqual(CompositionCandidates.coverage(x.geometry, scene, in: size),
                                        CompositionCandidates.sceneKept, "\(x.label) keeps most of the scene")
        }
    }

    func testAFaceIsNeverCut() {
        let face = CGRect(x: 0.03, y: 0.2, width: 0.12, height: 0.18)
        let a = CompositionAnalysis(straighten: 0, horizonTilt: nil, salient: [], faces: [face])
        let c = CompositionCandidates.make(current: .default, analysis: a, imageSize: landscape)
        XCTAssertGreaterThan(c.count, 1)
        for x in c { XCTAssertTrue(CompositionCandidates.contains(x.geometry, face, in: landscape), "\(x.label) keeps the face") }
    }

    func testATiltIsLevelledOnlyWhenMeasured() {
        let tilted = CompositionAnalysis(straighten: 3, horizonTilt: 3, salient: [], faces: [])
        let c = CompositionCandidates.make(current: .default, analysis: tilted, imageSize: landscape)
        XCTAssertTrue(c.contains { $0.kind == .level }, "the whole frame, levelled")
        XCTAssertTrue(c.dropFirst().allSatisfy { $0.geometry.angle == 3 })
        XCTAssertEqual(c.first?.geometry.angle, 0, "the current framing is the unlevelled control")
        let level = CompositionAnalysis(straighten: 0, horizonTilt: 0.2, salient: [], faces: [])
        XCTAssertTrue(CompositionCandidates.make(current: .default, analysis: level, imageSize: landscape)
            .allSatisfy { $0.geometry.angle == 0 })
    }

    func testTheRatiosFollowThePicturesOrientation() {
        let a = CompositionAnalysis(straighten: 0, horizonTilt: nil, salient: [], faces: [])
        // A phone's 9:16, far enough from 2:3 and 4:5 that neither is the
        // original crop again (crops within `duplicateIoU` are one crop).
        let portrait = CGSize(width: 1080, height: 1920)
        let c = CompositionCandidates.make(current: .default, analysis: a, imageSize: portrait)
        XCTAssertTrue(c.contains { $0.geometry.aspect == .r4x5 && $0.label == "4:5" }, "a portrait is offered 4:5 upright, and says so")
        XCTAssertTrue(c.contains { $0.label == "2:3" }, "not \"3:2\" for an upright crop")
        XCTAssertFalse(c.contains { $0.geometry.aspect == .r16x9 }, "and no landscape ratio")
        // A landscape source turned a quarter is seen upright: the crop's
        // ratio, which is before the turn, is the transposed one.
        var turned = Geometry.default
        turned.quarterTurns = 1
        let t = CompositionCandidates.make(current: turned, analysis: a, imageSize: landscape)
        let fourFive = t.first { $0.label == "4:5" && $0.kind != .current }
        XCTAssertEqual(fourFive?.geometry.aspect, .r5x4, "seen 4:5 after the turn, cut 5:4 before it")
        XCTAssertTrue(t.dropFirst().allSatisfy { $0.geometry.quarterTurns == 1 }, "the person's turn is kept")
    }

    func testATileIsTheCropApplyWillMake() throws {
        let proof = Self.horizon(tilted: 0)
        var g = Geometry.default
        g.crop = CropRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        let tile = try XCTUnwrap(CompositionCandidates.render(g, from: proof, longEdge: 400))
        XCTAssertEqual(Double(tile.width) / Double(tile.height), 1.5, accuracy: 0.02, "a half-size crop of a 3:2 frame")
        let whole = try XCTUnwrap(CompositionCandidates.render(.default, from: proof, longEdge: 400))
        XCTAssertEqual(max(whole.width, whole.height), 400)
    }
}

/// Proofs on a real engine, of a frame drawn here — so nothing is skipped.
@MainActor
final class AISessionTests: XCTestCase {

    /// A 1200×800 PNG: a grey ramp across, a band of saturated patches, and a
    /// dark corner, so every film renders something to tell apart.
    private func syntheticFrame() throws -> URL {
        let w = 1200, h = 800
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        for x in 0..<w {
            let v = CGFloat(x) / CGFloat(w - 1)
            ctx.setFillColor(CGColor(srgbRed: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: h))
        }
        let patches: [(CGFloat, CGFloat, CGFloat)] = [(0.8, 0.2, 0.2), (0.2, 0.7, 0.3), (0.2, 0.3, 0.8),
                                                      (0.9, 0.75, 0.6), (0.9, 0.8, 0.2), (0.4, 0.6, 0.5)]
        for (i, c) in patches.enumerated() {
            ctx.setFillColor(CGColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1))
            ctx.fill(CGRect(x: 60 + i * 180, y: 300, width: 150, height: 200))
        }
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-ai-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "synthetic.png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, try XCTUnwrap(ctx.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// **The isolation promise.** Printing proofs runs on an engine of its
    /// own: the frame's edit, its undo history and the canvas's engine
    /// session are exactly as they were.
    func testProofsLeaveTheSessionAlone() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        try await ws.develop()
        let s = ws.session
        let sidecar = s.sidecar
        let canUndo = s.canUndo
        let engineSession = s.serviceSessionIDForExport

        let candidates = try ProofSheet.candidates(films: ["kodak_portra_400", "fujifilm_velvia_100", "kodak_vision3_500t"])
        var ticks: [Int] = []
        let proofs = try await ProofSheet.render(session: s, candidates: candidates, longEdge: 384) { done, _ in ticks.append(done) }

        XCTAssertEqual(proofs.map(\.candidate), candidates)
        XCTAssertEqual(ticks, [1, 2, 3])
        for p in proofs {
            XCTAssertEqual(max(p.image.width, p.image.height), 384, "\(p.candidate.film) at the asked size")
            XCTAssertNotNil(p.latitude, "\(p.candidate.film): the engine measured the scene")
        }
        XCTAssertNotEqual(proofs[0].metrics, proofs[1].metrics, "two films print differently")

        XCTAssertEqual(s.sidecar, sidecar, "the edit is untouched")
        XCTAssertEqual(s.canUndo, canUndo, "no undo step was taken")
        XCTAssertEqual(s.serviceSessionIDForExport, engineSession)
        // The engine behind the canvas still holds this frame, at its own size:
        // a proof run on the shared client would have replaced it with a proof.
        let sid = try XCTUnwrap(engineSession)
        let again = try await s.client.render(.reprint, RenderRequest(sessionID: sid))
        XCTAssertEqual(again.texture.map { max($0.width, $0.height) }, 1200,
                       "the canvas's engine session was not replaced")

        let sheet = try XCTUnwrap(ProofSheet.contactSheet(proofs))
        XCTAssertGreaterThan(sheet.width, sheet.height / 2)
    }

    /// Proofs are a neutral print with the stochastic stages off, so the same
    /// film twice is the same picture (AGENTS.md trap 1).
    func testAProofReproduces() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let c = try ProofSheet.candidates(films: ["kodak_gold_200"])
        let a = try await ProofSheet.render(session: ws.session, candidates: c, longEdge: 256)
        let b = try await ProofSheet.render(session: ws.session, candidates: c, longEdge: 256)
        XCTAssertEqual(a[0].metrics, b[0].metrics)
    }

    /// A model's answers in order, one per request, and what it was sent.
    private final class Script: AITransport, @unchecked Sendable {
        var replies: [JSONValue]
        var sent: [JSONValue] = []
        init(_ replies: [JSONValue]) { self.replies = replies }
        func post(_ url: URL, headers: [String: String], body: Data) async throws -> AIHTTPResponse {
            sent.append(try JSONValue.parse(String(decoding: body, as: UTF8.self)))
            let next = replies.isEmpty ? ["rationale": "", "patch_json": "{}", "placement": .null, "done": true] : replies.removeFirst()
            let wire: JSONValue = ["stop_reason": "end_turn", "content": [["type": "text", "text": .string(next.text())]]]
            return AIHTTPResponse(status: 200, body: Data(wire.text().utf8))
        }
    }

    /// An unreadable round, an out-of-scope round and a good round: the first
    /// two are reported and fed back, the run goes on, the third is applied,
    /// and Undo AI changes puts every writable field back.
    func testARefinementSurvivesABadRoundAndUndoes() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        let script = Script([
            ["rationale": "garbled", "patch_json": "{not json", "placement": .null, "done": false],
            ["rationale": "film", "patch_json": "{\"params\":{\"filmStock\":\"kodak_gold_200\"}}", "placement": .null, "done": false],
            ["rationale": "warmer", "patch_json": "{\"params\":{\"yFilterShift\":0.05},\"adjustments\":{\"contrast\":7}}",
             "placement": .null, "done": true],
        ])
        let assistant = AIAssistant(session: s)
        assistant.makeClient = { AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "k", transport: script) }
        let film = s.params.filmStock
        let before = try s.agentDocument.json

        assistant.refine()
        try await Task.sleep(for: .milliseconds(50))
        while assistant.busy { try await Task.sleep(for: .milliseconds(100)) }

        XCTAssertNil(assistant.error, assistant.error ?? "")
        XCTAssertEqual(assistant.steps.count, 3)
        XCTAssertNotNil(assistant.steps[0].refused, "the unreadable round is reported")
        XCTAssertNotNil(assistant.steps[1].refused, "the film is not the refiner's")
        XCTAssertNil(assistant.steps[2].refused)
        XCTAssertEqual(Set(assistant.steps[2].changed), ["params.yFilterShift", "adjustments.contrast"])
        XCTAssertEqual(s.params.filmStock, film)
        XCTAssertEqual(s.params.yFilterShift, 0.05, accuracy: 1e-9)
        XCTAssertEqual(s.adjustments.contrast, 7)
        // Each refusal was said back in the next request.
        XCTAssertEqual(script.sent.count, 3)
        let third = script.sent[2].text()
        XCTAssertTrue(third.contains("was refused"), "the second refusal travels with the third request")

        assistant.undoAI()
        let after = try s.agentDocument.json
        for field in AgentSchema.fields where field.readOnly == nil {
            let path = field.path.split(separator: ".").map(String.init)
            XCTAssertEqual(path.reduce(Optional(after)) { $0?[$1] }, path.reduce(Optional(before)) { $0?[$1] }, field.path)
        }
    }

    /// Applying a negative from a slide film prints it: the film list leaves
    /// `scanFilm` on, and the paper the slide kept may already be the one.
    func testApplyingANegativeAfterASlidePrintsIt() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        s.selectFilmStock("kodak_portra_400")
        s.selectPrintStock("kodak_portra_endura")
        s.selectFilmStock("fujifilm_velvia_100")
        XCTAssertTrue(s.params.scanFilm)
        XCTAssertEqual(s.params.printStock, "kodak_portra_endura", "the slide keeps the paper it does not use")

        let tile = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage())
        let pick = AIAssistant.Pick(index: 1, candidate: ProofCandidate(film: "kodak_portra_400", paper: "kodak_portra_endura"),
                                    score: 90, reason: "", thumbnail: tile)
        AIAssistant(session: s).apply(pick)
        XCTAssertEqual(s.params.filmStock, "kodak_portra_400")
        XCTAssertFalse(s.params.scanFilm, "printed on the paper, not scanned")
        try await ws.settle()
    }

    /// The sidecar watcher must recognise the window's own last write. A
    /// field whose codec is not an identity (a nil date-back camera reads back
    /// as 135) made the file look written elsewhere, and the watcher adopted
    /// it over every edit made since — which is how a Scene Placement placed
    /// through the agent layer vanished on the next settle.
    func testTheWatcherDoesNotTakeBackAnEditOverTheWindowsOwnWrite() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        try await ws.develop()
        let s = ws.session
        s.sidecar.params.dateBack.camera = nil
        s.flushSave()
        var a = s.adjustments
        a.contrast = 23
        s.adjustments = a                 // an edit not yet written
        s.sidecarStoreChanged()           // the watcher's burst for the write above
        XCTAssertEqual(s.adjustments.contrast, 23, "the window's own file is not someone else's edit")
    }

    /// The exposure sheet: one film under each meter, each proof printed at
    /// the Film Exposure its meter chose.
    func testTheExposureSheetVariesOnlyTheMeter() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let candidates = ExposureMethod.allCases.map {
            ProofCandidate(film: "kodak_portra_400", paper: "kodak_portra_endura", meter: $0.rawValue)
        }
        let proofs = try await ProofSheet.render(session: ws.session, candidates: candidates, longEdge: 256)
        XCTAssertEqual(proofs.count, 4)
        XCTAssertTrue(proofs.allSatisfy { $0.exposureEV != nil }, "each proof says what it was exposed at")
        XCTAssertGreaterThan(Set(proofs.compactMap { $0.exposureEV.map { ($0 * 100).rounded() } }).count, 1,
                             "the meters disagree on this frame, so the sheet shows a choice")
        XCTAssertNotNil(ProofSheet.contactSheet(proofs, columns: 2))
    }

    /// Recommend on an untouched frame: the exposure is chosen first and set on
    /// the frame, the films are proofed at it, and Undo AI changes takes the
    /// meter back with everything else.
    func testRecommendChoosesTheExposureBeforeTheFilms() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        XCTAssertEqual(s.params.autoExposureMethod, "balanced")
        let script = Script([
            ["meter": "protect_highlights", "reason": "a bright source against dark"],
            ["summary": "s", "ranking": [["index": 1, "score": 90, "reason": "r"]]],
        ])
        let assistant = AIAssistant(session: s)
        assistant.makeClient = { AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "k", transport: script) }
        assistant.recommendFilm()
        try await Task.sleep(for: .milliseconds(50))
        while assistant.busy { try await Task.sleep(for: .milliseconds(100)) }

        XCTAssertNil(assistant.error, assistant.error ?? "")
        XCTAssertEqual(script.sent.count, 2, "one call for the exposure, one for the films")
        XCTAssertTrue(script.sent[0]["system"]?.string?.contains("four meters") == true
                      || script.sent[0]["system"]?.string?.contains("each of the camera's meters") == true)
        XCTAssertEqual(s.params.autoExposureMethod, "protect_highlights", "the chosen meter is on the frame")
        XCTAssertTrue(s.params.autoExposure)
        XCTAssertEqual(assistant.exposureChoice?.byAI, true)
        XCTAssertNotNil(assistant.recommendation)
        XCTAssertTrue(assistant.canUndo)
        assistant.undoAI()
        XCTAssertEqual(s.params.autoExposureMethod, "balanced", "Undo AI changes takes the meter back")
    }

    /// An exposure the person set is theirs: no exposure call, nothing changed.
    func testRecommendKeepsAnExposureThePersonSet() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        _ = try await ws.edit(["params": ["autoExposureMethod": "center"]])
        let script = Script([["summary": "s", "ranking": [["index": 1, "score": 90, "reason": "r"]]]])
        let assistant = AIAssistant(session: s)
        assistant.makeClient = { AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "k", transport: script) }
        assistant.recommendFilm()
        try await Task.sleep(for: .milliseconds(50))
        while assistant.busy { try await Task.sleep(for: .milliseconds(100)) }

        XCTAssertNil(assistant.error, assistant.error ?? "")
        XCTAssertEqual(script.sent.count, 1, "no exposure call")
        XCTAssertEqual(s.params.autoExposureMethod, "center")
        XCTAssertEqual(assistant.exposureChoice?.byAI, false)
    }

    /// Recommend crops, Apply one, and Undo AI changes puts the framing back.
    func testRecommendingAndApplyingACrop() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        let before = s.geometry
        let script = Script([["summary": "s", "ranking": [["index": 2, "score": 90, "reason": "r"],
                                                          ["index": 1, "score": 60, "reason": "keep"]]]])
        let assistant = AIAssistant(session: s)
        assistant.makeClient = { AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "k", transport: script) }
        assistant.recommendComposition()
        try await Task.sleep(for: .milliseconds(50))
        while assistant.busy { try await Task.sleep(for: .milliseconds(100)) }

        XCTAssertNil(assistant.error, assistant.error ?? "")
        let rec = try XCTUnwrap(assistant.composition)
        XCTAssertEqual(rec.picks.map(\.index), [2, 1])
        XCTAssertTrue(script.sent[0]["system"]?.string?.contains("crop") == true)
        XCTAssertEqual(s.geometry, before, "recommending changes nothing")
        XCTAssertTrue(assistant.isCurrent(rec.picks[1]), "tile 1 is the framing it has now")

        let pick = rec.picks[0]
        assistant.applyComposition(pick)
        XCTAssertNil(assistant.error, assistant.error ?? "")
        XCTAssertTrue(assistant.isCurrent(pick), "the frame is cropped as the tile shows")
        XCTAssertEqual(s.geometry.aspect, pick.candidate.geometry.aspect)
        XCTAssertTrue(s.geometry.fits(in: s.sourceImageSize))

        assistant.undoAI()
        XCTAssertEqual(s.geometry.crop, before.crop, "Undo AI changes puts the framing back")
        XCTAssertEqual(s.geometry.angle, before.angle)
    }

    func testCompositionIsRefusedUnderAFilmEdge() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        _ = try await ws.edit(["params": ["filmEdge": ["active": true]]])
        let script = Script([])
        let assistant = AIAssistant(session: ws.session)
        assistant.makeClient = { AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "k", transport: script) }
        assistant.recommendComposition()
        try await Task.sleep(for: .milliseconds(50))
        while assistant.busy { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNotNil(assistant.error)
        XCTAssertEqual(script.sent.count, 0, "nothing is sent")
    }

    /// A crop through the agent layer settles. A crop re-resolves fields the
    /// engine carries (`dateBack.framing`, `filmEdge.framing`) without asking
    /// for a print — in the window it is a draw — so the engine's parameters
    /// never caught up with the sidecar and `settle` waited out its timeout:
    /// `spektralab edit … --patch '{"geometry":…}'` and Apply on a crop both hung.
    func testAGeometryEditSettles() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        ws.timeout = 10
        try await ws.open(url.path)
        try await ws.develop()
        let written = try await ws.edit(["geometry": ["crop": ["x": 0.1, "y": 0.1, "width": 0.7, "height": 0.7],
                                                      "aspect": "free"]])
        XCTAssertTrue(written.contains("geometry.crop.width"))
        try await ws.settle()
        XCTAssertTrue(ws.session.params.delta(from: ws.session.scheduler.sent).delta.isEmpty,
                      "the engine has everything the sidecar tells it")
        XCTAssertFalse(ws.session.scheduler.pending)
    }

    /// Skin smoothing is an open, not a delta: the strength keys the engine's
    /// frame, so setting it re-develops (and `settle` sees it through), and
    /// Undo re-develops back. No face here, so this is the plumbing only —
    /// the pixels are `SkinTests`' and the opt-in `SkinPhotoTests`'.
    func testSkinSmoothingReDevelopsTheFrameAndUndoes() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        ws.timeout = 30
        try await ws.open(url.path)
        try await ws.develop()
        let s = ws.session
        XCTAssertNil(s.engineFraming)
        _ = try await ws.edit(["params": ["retouch": ["skinSmoothing": 0.3]]])
        try await ws.settle()
        XCTAssertEqual(s.engineFraming, "skin=0.300", "the engine holds the retouched frame")
        XCTAssertTrue(s.printStamp.contains("skin=0.300"), "and the print is stamped with it")
        s.undo()
        try await ws.settle()
        XCTAssertEqual(s.params.retouch.skinSmoothing, 0)
        XCTAssertNil(s.engineFraming, "Undo re-develops the untouched frame")
    }

    /// A run is busy from the moment it is started: the work before its first
    /// phase (finding faces, a Process) once left it looking finished, so the
    /// end-to-end run went on to Undo under a refinement still going.
    func testARunIsBusyFromTheMomentItStarts() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let script = Script([["rationale": "", "patch_json": "{}", "placement": .null, "done": true]])
        let assistant = AIAssistant(session: ws.session)
        assistant.makeClient = { AIClient(kind: .anthropic, model: "claude-opus-5-5", baseURL: "", apiKey: "k", transport: script) }
        assistant.refine()
        XCTAssertTrue(assistant.busy, "busy before its first phase is set")
        while assistant.busy { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(script.sent.count, 1, "and it did run")
    }

    /// Restoring an earlier edit is one step, and Undo takes it back.
    func testRestoringAnEditIsOneUndoableStep() async throws {
        let url = try syntheticFrame()
        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        let before = s.sidecar
        _ = try await ws.edit(["adjustments": ["contrast": 20, "exposure": 0.5], "params": ["yFilterShift": 0.1]])
        try await Task.sleep(for: .milliseconds(600))
        _ = try await ws.edit(["adjustments": ["saturation": 15]])
        let edited = s.sidecar
        XCTAssertNotEqual(edited, before)

        s.restoreSidecar(before)
        XCTAssertEqual(s.sidecar.params, before.params)
        XCTAssertEqual(s.sidecar.adjustments, before.adjustments)
        s.undo()
        XCTAssertEqual(s.sidecar.adjustments, edited.adjustments, "Undo takes the restore back in one step")
    }
}

/// The whole loop against a real model: proofs, a ranking, three rounds of
/// refinement and the undo. **Opt-in** — it needs a model and costs whatever
/// that model costs — so it skips unless `SPK_AI_E2E` names an
/// OpenAI-compatible base URL and `SPK_AI_MODEL` a vision model, e.g. a local
/// Ollama:
///
///     TEST_RUNNER_SPK_AI_E2E=http://localhost:11434/v1 TEST_RUNNER_SPK_AI_MODEL=gemma4:e4b \
///     TEST_RUNNER_SPK_AI_IMAGE=/path/to/photo.jpg xcodebuild … test \
///         -only-testing:SpektrafilmTests/AIEndToEndTests
@MainActor
final class AIEndToEndTests: XCTestCase {
    private struct Tracing: AITransport {
        let inner: AITransport
        func post(_ url: URL, headers: [String: String], body: Data) async throws -> AIHTTPResponse {
            let r = try await inner.post(url, headers: headers, body: body)
            let json = try? JSONValue.parse(String(decoding: r.body, as: UTF8.self))
            var text = ""
            if case .array(let blocks)? = json?["content"] {
                text = blocks.filter { $0["type"]?.string == "text" }.compactMap { $0["text"]?.string }.joined()
            } else if case .array(let choices)? = json?["choices"] {
                text = choices.first?["message"]?["content"]?.string ?? ""
            }
            print("E2E raw:", text.replacingOccurrences(of: "\n", with: " "))
            return r
        }
    }

    func testChooseRefineAndUndo() async throws {
        let env = ProcessInfo.processInfo.environment
        // `SPK_AI_E2E=anthropic` uses Claude with the key saved in Settings ▸ AI
        // (the Keychain); anything else is an OpenAI-compatible base URL.
        guard let base = env["SPK_AI_E2E"], let model = env["SPK_AI_MODEL"] else {
            throw XCTSkip("SPK_AI_E2E and SPK_AI_MODEL are not set")
        }
        let anthropic = base == "anthropic"
        let source = try XCTUnwrap(env["SPK_AI_IMAGE"].map(URL.init(fileURLWithPath:)), "SPK_AI_IMAGE")
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-ai-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)

        let saved = (AISettings.enabled, AISettings.provider, AISettings.openAIBaseURL, AISettings.openAIModel,
                     AISettings.anthropicModel)
        addTeardownBlock { @MainActor in
            (AISettings.enabled, AISettings.provider, AISettings.openAIBaseURL, AISettings.openAIModel,
             AISettings.anthropicModel) = saved
        }
        AISettings.enabled = true
        if anthropic {
            try XCTSkipUnless(AIKeychain.has(.anthropic), "no Anthropic key in Settings ▸ AI")
            AISettings.provider = .anthropic
            AISettings.anthropicModel = model
        } else {
            AISettings.provider = .openAICompatible
            AISettings.openAIBaseURL = base
            AISettings.openAIModel = model
        }

        let ws = AgentWorkspace()
        try await ws.open(url.path)
        let s = ws.session
        let assistant = AIAssistant(session: s)
        // Every answer, as the model wrote it, so a run can be read afterwards.
        assistant.makeClient = {
            var c = try AISettings.client()
            c.transport = Tracing(inner: c.transport)
            return c
        }
        assistant.intent = env["SPK_AI_INTENT"] ?? "warm and cinematic"
        let before = s.sidecar

        func finish() async throws {
            let deadline = Date().addingTimeInterval(900)
            try await Task.sleep(for: .milliseconds(50))
            while assistant.busy {
                XCTAssertLessThan(Date(), deadline, "the assistant did not finish")
                try await Task.sleep(for: .milliseconds(200))
            }
        }

        assistant.recommendFilm()
        try await finish()
        XCTAssertNil(assistant.error, assistant.error ?? "")
        let rec = try XCTUnwrap(assistant.recommendation)
        print("E2E summary:", rec.summary)
        print("E2E applied first pick; proofs compared:", rec.compared)
        for p in rec.picks { print("E2E pick \(p.index) \(p.candidate.film) \(p.score): \(p.reason)") }
        XCTAssertFalse(rec.picks.isEmpty)
        // Recommending changes nothing a person can write but the meter it
        // chose for the scene (fields the app resolves itself are re-derived).
        let afterDoc = try s.agentDocument.json, beforeDoc = try AgentDocument(before).json
        for field in AgentSchema.fields where field.readOnly == nil
            && !["params.autoExposure", "params.autoExposureMethod"].contains(field.path) {
            let path = field.path.split(separator: ".").map(String.init)
            XCTAssertEqual(path.reduce(Optional(afterDoc)) { $0?[$1] }, path.reduce(Optional(beforeDoc)) { $0?[$1] },
                           "recommending changed \(field.path)")
        }
        print("E2E exposure:", assistant.exposureChoice.map { "\($0.meter.title) byAI=\($0.byAI) \($0.reason)" } ?? "none")

        let pick = rec.picks[0]
        assistant.apply(pick)
        try await ws.settle()
        XCTAssertEqual(s.params.filmStock, pick.candidate.film)

        assistant.refine()
        try await finish()
        XCTAssertNil(assistant.error, assistant.error ?? "")
        for step in assistant.steps {
            print("E2E round \(step.round): \(step.rationale) | changed \(step.changed) | refused \(step.refused ?? "-")")
        }
        XCTAssertFalse(assistant.steps.isEmpty)
        s.flushSave()
        let out = env["SPK_AI_OUT"] ?? "/tmp/spk-test/e2e-refined.jpg"
        let preview = try await ws.preview(to: URL(fileURLWithPath: out), longEdge: 1024)
        print("E2E preview:", preview.path)
        // Composition, when asked for: the three crops, and the best applied.
        if env["SPK_AI_COMPOSE"] != nil {
            assistant.recommendComposition()
            try await finish()
            XCTAssertNil(assistant.error, assistant.error ?? "")
            let comp = try XCTUnwrap(assistant.composition)
            print("E2E composition summary:", comp.summary, "compared:", comp.compared)
            for (n, p) in comp.picks.enumerated() {
                print("E2E crop \(p.index) \(p.candidate.kind.rawValue) \(p.candidate.label) angle \(p.candidate.geometry.angle) score \(p.score): \(p.reason)")
                if let dir = env["SPK_AI_OUT"].map({ URL(fileURLWithPath: $0).deletingLastPathComponent() }) {
                    try? ProofSheet.writeJPEG(p.thumbnail, to: dir.appending(path: "crop-\(n + 1).jpg"))
                }
            }
            if let best = comp.picks.first {
                assistant.applyComposition(best)
                try await ws.settle()
                XCTAssertTrue(assistant.isCurrent(best))
            }
        }
        // The finished print at the photograph's own size, before Undo below
        // takes the edit back: what Export would write, as a JPEG.
        if let full = env["SPK_AI_FULL"] {
            let edge = min(4096, max(64, Int(s.sourceLongEdge)))
            let file = try await ws.preview(to: URL(fileURLWithPath: full), longEdge: edge)
            print("E2E full:", file.path, edge)
        }

        XCTAssertTrue(assistant.canUndo)
        assistant.undoAI()
        // Every field a person (or an agent) can write is back. The fields the
        // app resolves for itself (`readOnly`, e.g. the date back's camera) are
        // re-derived after a render and are not part of the edit.
        let now = try s.agentDocument.json, then = try AgentDocument(before).json
        for field in AgentSchema.fields where field.readOnly == nil {
            let path = field.path.split(separator: ".").map(String.init)
            let a = path.reduce(Optional(now)) { $0?[$1] }, b = path.reduce(Optional(then)) { $0?[$1] }
            XCTAssertEqual(a, b, "Undo AI changes puts \(field.path) back")
        }
    }
}


/// Skin smoothing on a real portrait: faces found, the frame re-developed,
/// before and after written out. **Opt-in** (`SPK_SKIN_IMAGE`, and
/// `SPK_SKIN_OUT` for a directory): there is no portrait fixture in this
/// checkout, and Vision does not find faces in drawn ones.
@MainActor
final class SkinPhotoTests: XCTestCase {
    func testSmoothingARealPortrait() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["SPK_SKIN_IMAGE"] else { throw XCTSkip("SPK_SKIN_IMAGE is not set") }
        let out = URL(fileURLWithPath: env["SPK_SKIN_OUT"] ?? NSTemporaryDirectory())
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-skin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: URL(fileURLWithPath: source).lastPathComponent)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: url)

        let ws = AgentWorkspace()
        ws.timeout = 120
        try await ws.open(url.path)
        try await ws.process()
        let s = ws.session
        let found = await s.refreshSkinMask()
        let mask = try XCTUnwrap(found)
        print("SKIN faces:", mask.faces.count, "median width:", mask.faceWidth)
        print("SKIN missed:", mask.missed, "largest:", mask.largestFace, "note:", PortraitSection.note(mask))
        XCTAssertFalse(mask.isEmpty, "a portrait has a face Vision finds")
        if let d = s.decoded, let m = mask.render(width: Int(d.pixelSize.width / 4), height: Int(d.pixelSize.height / 4)) {
            try? ProofSheet.writeJPEG(m, to: out.appending(path: "skin-mask.jpg"))
        }
        // The rest of the look, e.g. `{"params":{"grainActive":false}}`, and
        // a tag for the file names, to compare one portrait under several.
        if let patch = env["SPK_SKIN_PATCH"] {
            _ = try await ws.edit(try JSONValue.parse(patch))
            try await ws.settle()
        }
        let tag = env["SPK_SKIN_TAG"].map { "-" + $0 } ?? ""
        let edge = min(4096, Int(s.sourceLongEdge))
        _ = try await ws.preview(to: out.appending(path: "skin-0\(tag).jpg"), longEdge: edge)
        let strength = Double(env["SPK_SKIN_STRENGTH"] ?? "0.6") ?? 0.6
        let soft = env["SPK_SKIN_SOFT"] != nil
        _ = try await ws.edit(["params": ["retouch": ["skinSmoothing": .number(strength), "soft": .bool(soft)]]])
        try await ws.settle()
        XCTAssertNotNil(s.engineFraming)
        _ = try await ws.preview(to: out.appending(path: "skin-\(Int((strength * 100).rounded()))\(soft ? "-soft" : "")\(tag).jpg"),
                                 longEdge: edge)
        print("SKIN grain:", s.params.grainCoarseness, "soft share:", s.params.softSkinShare,
              "format:", s.params.wireFilmFormatMM)
        print("SKIN wrote", out.path)
    }
}

/// Composition alone on a real photograph, against a real model: what Vision
/// measured, the whole sheet of crops, the model's three, and the best one
/// applied at full size. **Opt-in** (`SPK_AI_E2E`, `SPK_AI_MODEL`,
/// `SPK_AI_IMAGE`, `SPK_COMPOSE_OUT`), like `AIEndToEndTests`.
@MainActor
final class CompositionPhotoTests: XCTestCase {
    func testComposingARealPhoto() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SPK_AI_E2E"], let model = env["SPK_AI_MODEL"], let source = env["SPK_AI_IMAGE"] else {
            throw XCTSkip("SPK_AI_E2E, SPK_AI_MODEL and SPK_AI_IMAGE are not set")
        }
        let out = URL(fileURLWithPath: env["SPK_COMPOSE_OUT"] ?? NSTemporaryDirectory())
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-compose-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: URL(fileURLWithPath: source).lastPathComponent)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: url)
        let saved = (AISettings.enabled, AISettings.provider, AISettings.openAIBaseURL, AISettings.openAIModel)
        addTeardownBlock { @MainActor in
            (AISettings.enabled, AISettings.provider, AISettings.openAIBaseURL, AISettings.openAIModel) = saved
        }
        AISettings.enabled = true
        AISettings.provider = .openAICompatible
        AISettings.openAIBaseURL = base
        AISettings.openAIModel = model

        let ws = AgentWorkspace()
        ws.timeout = 120
        try await ws.open(url.path)
        try await ws.process()
        let s = ws.session

        // What the assistant measures and offers, drawn here so the sheet can be kept.
        let p = s.params
        let film = try XCTUnwrap(ProofSheet.candidate(film: p.filmStock, paper: p.scanFilm ? nil : p.printStock, catalog: s.catalog))
        let proof = try await ProofSheet.render(session: s, candidates: [film], longEdge: AIAssistant.compositionLongEdge,
                                                wholeFrame: true)[0].image
        let analysis = try CompositionAnalysis.analyse(proof)
        print("COMPOSE horizon tilt:", analysis.horizonTilt.map { String(format: "%+.2f°", $0) } ?? "none",
              "straighten:", analysis.straighten, "salient:", analysis.salient.count, "faces:", analysis.faces.count)
        for r in analysis.salient {
            print(String(format: "COMPOSE salient x %.2f–%.2f y %.2f–%.2f (area %.0f%%)", r.minX, r.maxX, r.minY, r.maxY, r.width * r.height * 100))
        }
        let candidates = CompositionCandidates.make(current: s.geometry, analysis: analysis,
                                                    imageSize: CGSize(width: proof.width, height: proof.height))
        let tiles = candidates.enumerated().compactMap { i, c -> ProofSheet.Tile? in
            CompositionCandidates.render(c.geometry, from: proof, longEdge: 400).map {
                ProofSheet.Tile(image: $0, title: "\(i + 1)  \(c.kind == .current ? "current" : c.label)",
                                subtitle: c.straightened ? String(format: "levelled %+.1f°", c.geometry.angle)
                                    : "\(Int((c.geometry.crop.width * c.geometry.crop.height * 100).rounded()))% of frame")
            }
        }
        if let sheet = ProofSheet.sheet(tiles) { try ProofSheet.writeJPEG(sheet, to: out.appending(path: "candidates.jpg")) }

        let assistant = AIAssistant(session: s)
        assistant.intent = env["SPK_AI_INTENT"] ?? ""
        assistant.recommendComposition()
        try await Task.sleep(for: .milliseconds(50))
        while assistant.busy { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertNil(assistant.error, assistant.error ?? "")
        let rec = try XCTUnwrap(assistant.composition)
        print("COMPOSE summary:", rec.summary, "compared:", rec.compared)
        for p in rec.picks {
            print("COMPOSE pick \(p.index) \(p.candidate.kind.rawValue) \(p.candidate.label) angle \(p.candidate.geometry.angle) score \(p.score): \(p.reason)")
        }
        let best = try XCTUnwrap(rec.picks.first)
        assistant.applyComposition(best)
        try await ws.settle()
        XCTAssertTrue(assistant.isCurrent(best))
        let edge = min(4096, Int(s.sourceLongEdge))
        _ = try await ws.preview(to: out.appending(path: "best-full.jpg"), longEdge: edge)
    }
}
