import AppKit
import Darwin
import Foundation
import MarkdownCore
@testable import Plainsong
import PreviewKit
import WorkspaceKit
import XCTest

/// Opt-in E9 probes. Ordinary correctness runs never publish contention-dependent numbers.
/// Run Scripts/run-export-html-e9.sh after the machine is idle, in Debug and Release.
@MainActor
final class ExportHTMLPerformanceTests: XCTestCase {
    func testProductionOffscreenExportTimeAndHostMemory() async throws {
        try requireOptIn()
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        // Twenty-four distinct bounded PNGs, not repeated references to one resource.
        let images = try (0 ..< 24).map { index -> String in
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16,
                                                        pixelsHigh: 16, bitsPerSample: 8, samplesPerPixel: 4,
                                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                        bytesPerRow: 0, bitsPerPixel: 0))
            let color = NSColor(srgbRed: Double(index) / 24, green: 0.5, blue: 0.8, alpha: 1)
            for y in 0 ..< 16 {
                for x in 0 ..< 16 {
                    bitmap.setColor(color, atX: x, y: y)
                }
            }
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: assets.appendingPathComponent("pixel-\(index).png"))
            if index == 0 { try png.write(to: assets.appendingPathComponent("pixel.png")) }
            return "![asset \(index)](assets/pixel-\(index).png)"
        }.joined(separator: "\n\n")
        for path in ["large-1mb.md", "export-f-heavy.md"] {
            let resource = try XCTUnwrap(Bundle(for: Self.self).url(
                forResource: path,
                withExtension: nil,
                subdirectory: "Fixtures"
            ))
            let source = try String(contentsOf: resource, encoding: .utf8) + "\n\n" + images
            var times: [Double] = []
            var peakHostRSS = Self.hostRSS()
            for sample in 0 ..< (isSmoke ? 1 : 3) {
                let document = root.appendingPathComponent("source.md")
                try source.write(to: document, atomically: true, encoding: .utf8)
                let app = try makeApp(document: document, root: root, source: source)
                let destination = root.appendingPathComponent("\(path)-\(sample).html")
                app.exportHTMLOperations.destinationChooser = { _ in destination }
                let start = DispatchTime.now().uptimeNanoseconds
                let task = try XCTUnwrap(app.exportCurrentDocumentAsHTML())
                while app.exportHTMLOperations.activeOperationID != nil {
                    peakHostRSS = max(peakHostRSS, Self.hostRSS())
                    try await Task.sleep(nanoseconds: 5_000_000)
                }
                await task.value
                times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            }
            if isSmoke { print("EXPORT E9 SMOKE \(path) production body committed; no timing evidence") }
            else {
                print("EXPORT E9 \(path) production milliseconds \(times); peak sampled host RSS MiB \(peakHostRSS)")
            }
        }
    }

    func testSixtyFourMiBWriterMainActorTime() throws {
        try requireOptIn()
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("source.md")
        try Data("# Writer timing".utf8).write(to: document)
        let app = try makeApp(document: document, root: root, source: "# Writer timing")
        let bytes = Data(repeating: 65, count: 64 * 1_048_576)
        var samples: [Double] = []
        for index in 0 ..< (isSmoke ? 1 : 3) {
            let request = ExportArtifactWriteRequest(destinationURL: root.appendingPathComponent("cap-\(index).html"),
                                                     kind: .html, disposition: .createNew, bytes: bytes)
            let start = DispatchTime.now().uptimeNanoseconds
            let outcome = app.writeExportArtifact(request, exportSource: app.currentDocument)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            guard case .committed = outcome else { return XCTFail("Writer probe must commit: \(outcome)") }
            samples.append(elapsed)
        }
        if isSmoke { print("EXPORT E9 SMOKE 64 MiB writer body committed; no timing evidence") }
        else {
            print("EXPORT E9 64 MiB synchronous main-actor writer milliseconds \(samples). " +
                "Review any visible UI stall with the owner before changing the E2 contract.")
        }
    }

    private var isSmoke: Bool {
        ProcessInfo.processInfo.environment["PLAINSONG_EXPORT_E9_SMOKE"] == "1"
    }

    private func makeApp(document: URL, root: URL, source: String) throws -> AppState {
        let authority = try WorkspaceFileSystemRootAuthority(rootURL: root)
        let location = try authority.location(relativePath: document.lastPathComponent)
        let read = try MarkdownFileStore().loadResult(at: location)
        let session = DocumentSession(text: source, url: document)
        let app = AppState(currentDocument: session, shouldRestoreLastOpenedFile: false)
        app.workspaceRootURL = authority.canonicalRootURL
        app.anchoredSessionFileBindings[ObjectIdentifier(session)] = AnchoredWorkspaceSessionFileBinding(
            location: location, identity: read.metadata.identity, sha256Digest: read.sha256Digest
        )
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 800, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        app.exportHTMLOperations.panelWindowProvider = { window }
        return app
    }

    private func requireOptIn() throws {
        guard ProcessInfo.processInfo.environment["PLAINSONG_RUN_EXPORT_E9"] == "1" else {
            throw XCTSkip("pending idle-machine run: Scripts/run-export-html-e9.sh Debug|Release")
        }
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExportE9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.resolvingSymlinksInPath()
    }

    private static func hostRSS() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }
}
