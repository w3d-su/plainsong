import CryptoKit
import UIKit

struct ProbeEvent: Codable {
    let time: Date
    let event: String
    let documentID: UUID
    let revision: Int
    let sourceSHA256: String
    let utf16Count: Int
    let selection: [Int]
    let marked: [Int]?
    let canUndo: Bool
    let canRedo: Bool
    let dirty: Bool
    let saving: Bool
    let conflict: Bool
}

func digest(_ source: String) -> String {
    SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
}

@MainActor
final class Probe {
    // No URLs, bookmarks, device IDs or user source. Exact source may be inspected
    // on screen; exported hashes are paired with the public fixture by the owner.
    private(set) var events: [ProbeEvent] = []
    func record(_ event: String, editor: SourceEditor, dirty: Bool, saving: Bool, conflict: Bool) {
        let view = editor.textView
        let marked = view.markedTextRange.map {
            [view.offset(from: view.beginningOfDocument, to: $0.start),
             view.offset(from: $0.start, to: $0.end)]
        }
        events.append(ProbeEvent(time: Date(), event: event, documentID: editor.documentID,
                                 revision: editor.revision, sourceSHA256: digest(view.text),
                                 utf16Count: view.text.utf16.count,
                                 selection: [view.selectedRange.location, view.selectedRange.length],
                                 marked: marked, canUndo: view.undoManager?.canUndo ?? false,
                                 canRedo: view.undoManager?.canRedo ?? false,
                                 dirty: dirty, saving: saving, conflict: conflict))
        if events.count > 2000 {
            events.removeFirst()
        }
    }

    func export() throws -> URL {
        let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = directory.appendingPathComponent("m0-events-\(UUID()).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(events).write(to: url, options: .atomic)
        return url
    }
}
