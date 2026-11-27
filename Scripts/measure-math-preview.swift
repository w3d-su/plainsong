import AppKit
import WebKit

@MainActor
private final class MathPreviewProbe: NSObject, WKScriptMessageHandler {
    let messages: AsyncStream<[String: Any]>
    private let continuation: AsyncStream<[String: Any]>.Continuation

    override init() {
        (messages, continuation) = AsyncStream.makeStream()
    }

    func userContentController(_: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] {
            continuation.yield(body)
        }
    }

    func measure(kind: String, page: URL, source: String) async throws {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "bridge")
        defer { config.userContentController.removeScriptMessageHandler(forName: "bridge") }
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 900, height: 750), configuration: config)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -3000, y: -3000))
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        view.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        var events = messages.makeAsyncIterator()
        while await events.next()?["name"] as? String != "ready" {}

        let middle = source.index(source.startIndex, offsetBy: source.count / 2)
        guard let edit = source.range(of: #"\$E = mc\^[^$\n]+\$"#, options: .regularExpression,
                                      range: middle ..< source.endIndex)
        else {
            throw ProbeError("Fixture is missing the middle inline equation")
        }
        let section = source[..<edit.lowerBound].components(separatedBy: "## Section\n").count - 2
        let original = String(source[edit].dropFirst().dropLast())
        var samples: [Double] = []
        for version in 0 ... 8 {
            let equation = version == 0 ? original : "E = mc^{\(version + 2)}"
            let text = source.replacingCharacters(in: edit, with: "$\(equation)$")
            let payload: [String: Any] = [
                "renderID": version, "version": version, "fileKind": kind, "text": text,
                "baseDir": NSNull(), "assetRootID": "", "theme": "light", "allowRemoteImages": false,
            ]
            let start = ProcessInfo.processInfo.systemUptime
            _ = try await view.callAsyncJavaScript(
                "window.PlainsongBridge.receive({name:'render', payload})",
                arguments: ["payload": payload], in: nil, contentWorld: .page
            )
            while let message = await events.next() {
                let result = message["payload"] as? [String: Any]
                if message["name"] as? String == "renderComplete", result?["renderID"] as? Int == version { break }
            }
            let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            try await verify(equation: equation, ordinal: section * 6, in: view)
            if version > 3 { samples.append(milliseconds) }
            print(String(
                format: "%@ %@ %d %.1f ms",
                kind,
                version == 0 ? "prime" : version <= 3 ? "settle" : "edit",
                version,
                milliseconds
            ))
        }
        print(String(format: "%@ settled median %.1f ms", kind, samples.sorted()[samples.count / 2]))
    }

    private func verify(equation: String, ordinal: Int, in view: WKWebView) async throws {
        let valid = try await view.callAsyncJavaScript(
            """
            await document.fonts.ready
            document.body.getBoundingClientRect()
            const math = document.querySelectorAll('#preview-root annotation[encoding="application/x-tex"]')
            return math.length === 1752 && math[ordinal]?.textContent === equation
            """,
            arguments: ["equation": equation, "ordinal": ordinal], in: nil, contentWorld: .page
        )
        guard valid as? Bool == true else { throw ProbeError("Expected formula \(ordinal) to contain \(equation)") }
    }
}

private struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}

let application = NSApplication.shared
let page = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "App/Resources/preview/index.html")
    .standardizedFileURL
let fixture = URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? "Fixtures/math-dense-100kb.md")
Task { @MainActor in
    do {
        let source = try String(contentsOf: fixture, encoding: .utf8)
        for kind in ["md", "mdx"] {
            try await MathPreviewProbe().measure(kind: kind, page: page, source: source)
        }
        exit(0)
    } catch {
        print("Math preview probe failed: \(error)")
        exit(1)
    }
}

Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { _ in
    print("Timed out waiting for the WebKit preview")
    exit(2)
}

application.run()
