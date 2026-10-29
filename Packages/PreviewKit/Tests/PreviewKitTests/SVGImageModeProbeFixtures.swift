import Foundation
import XCTest

/// Hostile samples and the probe page for `SVGImageModeProbeTests`.
enum SVGProbeFixtures {
    static let controlHost = "plainsong-svg-control.invalid"
    private static let probeHost = "https://plainsong-svg-probe.invalid"
    private static let bridgePost =
        "try{webkit.messageHandlers.bridge.postMessage({name:'svgProbe',payload:{}})}catch(e){}"

    /// Valid for WebKit, rejected only by `SVGImageValidator` (event handler).
    static let rejectedButPaintableSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10" onload="\(bridgePost)">\
    <rect width="10" height="10" fill="#c00"/></svg>
    """

    /// One attack per image. Each is well-formed XML with a painted 32×32 rect.
    static let hostileSamples: [String: String] = {
        let attacks = [
            "script": """
            <script><![CDATA[\(bridgePost); try { fetch('\(probeHost)/script'); } catch (e) {}]]></script>
            """,
            "onload": #"<g onload="\#(bridgePost)"><rect width="1" height="1"/></g>"#,
            "foreign-object": """
            <foreignObject width="32" height="32"><body xmlns="http://www.w3.org/1999/xhtml">\
            <img src="\(probeHost)/foreign-object" alt=""/>\
            <iframe src="\(probeHost)/foreign-frame"></iframe></body></foreignObject>
            """,
            "image-href": #"<image href="\#(probeHost)/image-href" width="8" height="8"/>"#,
            "use-href": #"<use href="\#(probeHost)/use-href#x"/>"#,
            "style-import": #"<style>@import url("\#(probeHost)/import.css");</style>"#,
            "style-url": "<style>rect.p { stroke: url(\(probeHost)/style-url); }</style>",
            "style-escape": #"<style>rect.p { stroke: u\72l(\#(probeHost)/style-escape); }</style>"#,
            "image-set": #"<style>rect.p { fill: image-set("\#(probeHost)/image-set.png" 1x); }</style>"#,
            "font-face": #"<style>@font-face { font-family: p; src: url("\#(probeHost)/font.woff"); } "# +
                #"text { font-family: p; }</style><text y="8">x</text>"#,
            "fe-image": #"<filter id="f"><feImage href="\#(probeHost)/fe-image"/></filter>"# +
                #"<rect width="4" height="4" filter="url(#f)"/>"#,
            "fill-url": #"<rect width="4" height="4" fill="url(\#(probeHost)/fill-url)"/>"#,
            "smil-values": #"<rect width="4" height="4"><animate attributeName="fill" dur="1s" "# +
                #"values="url(\#(probeHost)/smil-values);red"/></rect>"#,
        ]
        return attacks.mapValues { attack in
            """
            <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
            width="32" height="32" viewBox="0 0 32 32">\
            <rect class="p" width="32" height="32" fill="#c00"/>\(attack)</svg>
            """
        }
    }()

    static func writeProbePage(names: [String]) throws -> URL {
        let html = try String(contentsOf: PreviewBundleFixture.indexURL(), encoding: .utf8)
        guard let marker = html.range(of: "content=\""),
              let end = html[marker.upperBound...].firstIndex(of: "\"")
        else {
            throw ProbeFailure.missingCSP
        }
        let csp = String(html[marker.upperBound ..< end])
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("plainsong-svg-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let page = directory.appendingPathComponent("probe.html")
        let images = names.map { #"<img class="sample" id="\#($0)" src="asset://\#($0).svg" alt="">"# }
        let document = """
        <!doctype html>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <script src="control.js"></script>
        <img src="https://\(controlHost)/control.png" alt="">
        \(images.joined(separator: "\n"))
        """
        try Data(document.utf8).write(to: page)
        try Data("webkit.messageHandlers.bridge.postMessage({name:'probeControl',payload:{}});".utf8)
            .write(to: directory.appendingPathComponent("control.js"))
        return page.resolvingSymlinksInPath()
    }
}

enum ProbeFailure: Error { case missingCSP }
