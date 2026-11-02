//  PipelinePhotoTests.swift — every photograph in a folder through the app's
//  whole path: open, Process, a full-size print, an export.
//
//  **Opt-in** (`SPK_PIPELINE_DIR`, and `SPK_PIPELINE_OUT` for the prints and
//  the timings): the camera fixtures are not in this checkout (AGENTS.md,
//  trap 26), and this is what stands in for them on a machine that has none —
//  real files, the decode, the develop, the meter and the writer, timed by
//  stage. It asserts only that each one gets through; what the prints look
//  like is for a person to judge from the files it writes. The export is the
//  first recipe in the machine's own store (read, never written): its format
//  is whatever that recipe says, into a scratch folder.
//
//      TEST_RUNNER_SPK_PIPELINE_DIR=~/photos TEST_RUNNER_SPK_PIPELINE_OUT=/tmp/out \
//      xcodebuild … test-without-building -only-testing:SpektrafilmTests/PipelinePhotoTests

import Foundation
import XCTest

@MainActor
final class PipelinePhotoTests: XCTestCase {
    func testEveryPhotoInAFolderDevelopsAndExports() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["SPK_PIPELINE_DIR"] else { throw XCTSkip("SPK_PIPELINE_DIR is not set") }
        let out = URL(fileURLWithPath: env["SPK_PIPELINE_OUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let files = try FileManager.default
            .contentsOfDirectory(at: URL(fileURLWithPath: (source as NSString).expandingTildeInPath),
                                 includingPropertiesForKeys: nil)
            .filter { !Library.frames(from: [$0]).isEmpty }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(files.isEmpty, "no image SpektraLab opens in \(source)")

        // Copies, so a develop's sidecar names a scratch file and not the photograph.
        let scratch = FileManager.default.temporaryDirectory.appending(path: "spk-pipeline-\(UUID().uuidString)")
        let exports = scratch.appending(path: "export")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }

        let ws = AgentWorkspace()
        ws.timeout = 300
        var lines = ["name\tpixels\topen_s\tprocess_s\tprint_s\texport_s\tfaces\tsolved_ev\texport"]
        for file in files {
            let copy = scratch.appending(path: file.lastPathComponent)
            try FileManager.default.copyItem(at: file, to: copy)
            let name = file.deletingPathExtension().lastPathComponent
            let clock = ContinuousClock()
            var stage = clock.now
            func lap() -> String {
                let d = clock.now - stage
                stage = clock.now
                return String(format: "%.2f", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
            }
            do {
                try await ws.open(copy.path)
                let open = lap()
                try await ws.process()
                let process = lap()
                let s = ws.session
                let edge = min(4096, Int(s.sourceLongEdge))
                _ = try await ws.preview(to: out.appending(path: "\(name).jpg"), longEdge: edge)
                let printed = lap()
                let written = try await ws.export(recipe: nil, to: exports.path)
                let export = lap()
                let faces = await s.refreshSkinMask()?.faces.count ?? -1
                let size = s.decoded.map { "\(Int($0.pixelSize.width))x\(Int($0.pixelSize.height))" } ?? "?"
                let ev = s.sidecar.solvedEV.map { String(format: "%+.2f", $0) } ?? "-"
                let written1 = written.first.map { u in
                    let bytes = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return "\(u.pathExtension) \(bytes / 1024) KB"
                } ?? "none"
                XCTAssertFalse(written.isEmpty, "\(name): the export wrote nothing")
                lines.append([name, size, open, process, printed, export, "\(faces)", ev, written1].joined(separator: "\t"))
                print("PIPE", lines.last!)
            } catch {
                XCTFail("\(name): \(error)")
                lines.append("\(name)\tFAILED: \(error)")
                print("PIPE", lines.last!)
            }
        }
        try lines.joined(separator: "\n").write(to: out.appending(path: "timings.tsv"), atomically: true, encoding: .utf8)
    }
}
