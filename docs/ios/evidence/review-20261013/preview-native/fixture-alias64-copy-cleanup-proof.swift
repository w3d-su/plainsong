import Foundation
let lexicalRoot = URL(fileURLWithPath: "/tmp/plainsong-preview-ios-native-c1-20261013", isDirectory: true).appendingPathComponent("App/Resources/preview", isDirectory: true)
let destination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("PlainsongAliasProof-" + UUID().uuidString, isDirectory: true)
defer { try? FileManager.default.removeItem(at: destination) }
try FileManager.default.copyItem(at: lexicalRoot, to: destination)
let actualIndexExists = FileManager.default.fileExists(atPath: destination.appendingPathComponent("index.html").path)
let enumerator = FileManager.default.enumerator(at: lexicalRoot, includingPropertiesForKeys: [.isRegularFileKey])!
var count = 0, legacyMissing = 0, correctedEqual = 0
var examples: [[String: String]] = []
for case let file as URL in enumerator {
    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
    count += 1
    let legacyRelative = String(file.path.dropFirst(lexicalRoot.path.count + 1))
    if !FileManager.default.fileExists(atPath: destination.appendingPathComponent(legacyRelative).path) { legacyMissing += 1 }
    let rootComponents = lexicalRoot.resolvingSymlinksInPath().pathComponents
    let fileComponents = file.resolvingSymlinksInPath().pathComponents
    guard fileComponents.starts(with: rootComponents), fileComponents.count > rootComponents.count else { throw CocoaError(.fileReadInvalidFileName) }
    let relative = fileComponents.dropFirst(rootComponents.count).joined(separator: "/")
    let copied = destination.appendingPathComponent(relative)
    if try Data(contentsOf: file) == Data(contentsOf: copied) { correctedEqual += 1 }
    if examples.count < 3 { examples.append(["sourceRoot": lexicalRoot.path, "enumeratedPath": file.path, "legacyRelative": legacyRelative, "correctedRelative": relative]) }
}
let failureDestination = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent("PlainsongAliasFailureProof-" + UUID().uuidString, isDirectory: true)
var caughtMissing = false
func verifyFailureCleanup() throws {
    var verifiedCopy = false
    defer { if !verifiedCopy { try? FileManager.default.removeItem(at: failureDestination) } }
    try FileManager.default.copyItem(at: lexicalRoot.resolvingSymlinksInPath(), to: failureDestination)
    // Controlled fixture failure, after a real copy; the source tree is read-only.
    try FileManager.default.removeItem(at: failureDestination.appendingPathComponent("index.html"))
    _ = try Data(contentsOf: failureDestination.appendingPathComponent("index.html"))
    verifiedCopy = true
}
do { try verifyFailureCleanup() } catch { caughtMissing = true }
let removedAfterFailure = !FileManager.default.fileExists(atPath: failureDestination.path)
precondition(count > 3 && actualIndexExists && legacyMissing == count && correctedEqual == count && caughtMissing && removedAfterFailure)
let result: [String: Any] = ["files": count, "actualCopiedIndexExists": actualIndexExists, "legacyMissing": legacyMissing, "correctedBytesEqual": correctedEqual, "caughtMissingResource": caughtMissing, "failureDestinationRemoved": removedAfterFailure, "examples": examples, "scope": "Native macOS Foundation fixture-path logic and failure cleanup proof; no WKWebView/DOM/provider/runtime acceptance"]
let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: bytes, as: UTF8.self))
