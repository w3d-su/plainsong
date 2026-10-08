import Foundation

func sameSource(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.elementsEqual(rhs.utf8)
}

struct SaveCapture: Equatable {
    let operationID: UUID
    let documentID: UUID
    let revision: Int
    let source: String

    static func == (lhs: SaveCapture, rhs: SaveCapture) -> Bool {
        lhs.operationID == rhs.operationID && lhs.documentID == rhs.documentID &&
            lhs.revision == rhs.revision && sameSource(lhs.source, rhs.source)
    }
}

struct SaveLedger {
    let documentID: UUID
    private(set) var source: String
    private(set) var savedSource: String
    private(set) var revision = 0
    private(set) var active: SaveCapture?
    var conflict = false
    var available = true
    var dirty: Bool {
        !sameSource(source, savedSource)
    }

    init(documentID: UUID, source: String) {
        self.documentID = documentID
        self.source = source
        savedSource = source
    }

    mutating func observe(source: String, revision: Int) {
        self.source = source
        self.revision = revision
    }

    mutating func begin() -> SaveCapture? {
        guard active == nil, available, !conflict else { return nil }
        let capture = SaveCapture(operationID: UUID(), documentID: documentID, revision: revision, source: source)
        active = capture
        return capture
    }

    @discardableResult
    mutating func complete(_ capture: SaveCapture, success: Bool) -> Bool {
        guard active == capture, capture.documentID == documentID else { return false }
        active = nil
        if success {
            savedSource = capture.source
        }
        // Never assign captured source to live source; N+1 stays dirty.
        return true
    }
}

struct RecoveryEnvelope: Codable, Equatable {
    let documentID: UUID
    let revision: Int
    let source: String
    let reason: String
    let time: Date
}

struct RecoveryStore {
    let directory: URL

    static func applicationStore() throws -> RecoveryStore {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        return RecoveryStore(directory: base.appendingPathComponent("M0Recovery", isDirectory: true))
    }

    /// The spike uses small public fixtures. This synchronous atomic write/readback
    /// prioritizes crash evidence; it is NOT a production latency implementation.
    func persist(_ snapshot: RecoveryEnvelope) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(snapshot.documentID).json")
        try JSONEncoder().encode(snapshot).write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        let decoded = try JSONDecoder().decode(RecoveryEnvelope.self, from: Data(contentsOf: url))
        guard decoded == snapshot, sameSource(decoded.source, snapshot.source) else {
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    func readAll() throws -> [RecoveryEnvelope] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(RecoveryEnvelope.self, from: Data(contentsOf: $0)) }
            .sorted { $0.time > $1.time }
    }
}
