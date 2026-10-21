import Foundation
let lexicalRoot = URL(fileURLWithPath: "/tmp/plainsong-preview-ios-native-c1-20261013", isDirectory: true).appendingPathComponent("App/Resources/preview", isDirectory: true)
let canonicalRoot = lexicalRoot.resolvingSymlinksInPath()
var records: [[String: String]] = []
let enumerator = FileManager.default.enumerator(at: lexicalRoot, includingPropertiesForKeys: [.isRegularFileKey])!
for case let file as URL in enumerator {
    if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile != true { continue }
    let rawRelative = String(file.path.dropFirst(lexicalRoot.path.count + 1))
    let canonicalFile = file.resolvingSymlinksInPath()
    let canonicalRelative = String(canonicalFile.path.dropFirst(canonicalRoot.path.count + 1))
    records.append(["lexicalRoot": lexicalRoot.path, "canonicalRoot": canonicalRoot.path, "enumeratedPath": file.path, "rawRelative": rawRelative, "canonicalRelative": canonicalRelative])
    if records.count == 3 { break }
}
let bytes = try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: bytes, as: UTF8.self))
