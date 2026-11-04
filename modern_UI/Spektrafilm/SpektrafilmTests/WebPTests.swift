//  WebPTests.swift — a WebP opens like any other flat image.
//
//  ImageIO reads WebP and cannot write it, so the picture is carried here:
//  8 × 6, lossless, the left half red (220, 30, 30) and the right half blue
//  (30, 30, 220), made with Pillow. A photo sent from a phone as WebP was
//  refused by name until `ImageDecoder.flatExtensions` listed it.

import CoreGraphics
import ImageIO
import XCTest

@MainActor
final class WebPTests: XCTestCase {
    private static let fixture = "UklGRiYAAABXRUJQVlA4TBoAAAAvB0ABAA8wHvfwvRD3/EcLAIJI8N9rIqL/IQ=="

    private func webp(_ name: String = "frame.webp") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "spk-webp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: name)
        try XCTUnwrap(Data(base64Encoded: Self.fixture)).write(to: url)
        addTeardownBlock { Sidecar.remove(for: url) }
        return url
    }

    func testAWebPIsListedAndOffered() throws {
        XCTAssertTrue(ImageDecoder.openable.contains("webp"))
        XCTAssertFalse(ImageDecoder.rawExtensions.contains("webp"), "a flat image, decoded by Core Image")
        let url = try webp("Frame.WEBP")
        XCTAssertEqual(Library.frames(at: url).map(\.id), [url], "a file, whatever the case of its extension")
        try Data("not a picture".utf8).write(to: url.deletingLastPathComponent().appending(path: "notes.txt"))
        // By name: a listed folder comes back under /private/var.
        XCTAssertEqual(Library.frames(at: url.deletingLastPathComponent()).map(\.id.lastPathComponent), ["Frame.WEBP"],
                       "and in a folder, beside a file that is not a picture")
    }

    func testAWebPDecodesAtItsOwnSize() throws {
        let d = try ImageDecoder.decode(try webp(), settings: DecodeSettings())
        XCTAssertEqual(d.pixelSize, CGSize(width: 8, height: 6))
        XCTAssertFalse(d.isRAW)
    }

    /// Opened, processed and exported through the app's own path: the red
    /// half stays red and the blue half blue, the right way round.
    func testAWebPPrints() async throws {
        let ws = AgentWorkspace()
        try await ws.open(try webp().path)
        try await ws.process()
        let file = try await ws.preview(longEdge: 64)
        defer { try? FileManager.default.removeItem(at: file) }
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertEqual(image.width, 8, "an export never enlarges")
        XCTAssertEqual(image.height, 6)
        // The outer three columns of each half, clear of the seam.
        let left = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 3, height: 6)).flatMap(ImageMetrics.init))
        let right = try XCTUnwrap(image.cropping(to: CGRect(x: 5, y: 0, width: 3, height: 6)).flatMap(ImageMetrics.init))
        XCTAssertGreaterThan(left.castRG, 0.1, "the red half")
        XCTAssertLessThan(right.castYB, -0.1, "the blue half")
    }
}
