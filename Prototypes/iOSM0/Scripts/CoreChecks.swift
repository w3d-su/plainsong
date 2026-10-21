import Foundation

@main
enum CoreChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else {
                fputs("FAIL \(name)\n", stderr)
                exit(1)
            }
            count += 1
            print("PASS \(name)")
        }
        var ledger = SaveLedger(documentID: UUID(), source: "baseline")
        ledger.observe(source: "N 中文", revision: 1)
        let capture = ledger.begin()!
        check(ledger.begin() == nil, "oneWriter")
        ledger.observe(source: "N+1 👩🏽‍💻", revision: 2)
        check(ledger.complete(capture, success: true), "capturedAcknowledgement")
        check(ledger.source == "N+1 👩🏽‍💻" && ledger.savedSource == "N 中文" && ledger.dirty,
              "oldSaveLeavesNewRevisionDirty")
        let next = ledger.begin()!
        check(!ledger.complete(capture, success: true) && ledger.active == next, "staleAcknowledgementRefused")
        check(ledger.complete(next, success: false) && ledger.savedSource == "N 中文" && ledger.dirty,
              "failedSavePreservesBaseline")
        ledger.conflict = true
        check(ledger.begin() == nil, "conflictRefusesSave")
        ledger.conflict = false
        ledger.available = false
        check(ledger.begin() == nil, "unavailableRefusesSave")
        var unicode = SaveLedger(documentID: UUID(), source: "é")
        unicode.observe(source: "é", revision: 1)
        check(unicode.dirty && !sameSource(unicode.source, unicode.savedSource), "unicodeBytesDefineDirty")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecoveryStore(directory: directory)
        let snapshot = RecoveryEnvelope(documentID: UUID(), revision: 7, source: "中文\n👩🏽‍💻 é",
                                        reason: "background", time: Date(timeIntervalSince1970: 100))
        try store.persist(snapshot)
        let recovered = try store.readAll()
        check(recovered == [snapshot], "recoveryExactReadback")
        let blocker = directory.appendingPathComponent("file")
        try Data().write(to: blocker)
        do {
            try RecoveryStore(directory: blocker).persist(snapshot)
            check(false, "recoveryFailureReported")
        } catch { check(true, "recoveryFailureReported") }
        print("\(count) checks passed (host Foundation only; no UIKit/device claim)")
    }
}
