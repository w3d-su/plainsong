import Foundation

final class TransientMutationOperationStore: WorkspaceMutationOperationRecoveryPersisting {
    private var records: [UUID: WorkspaceMutationOperationRecoveryRecord] = [:]

    func load() -> [WorkspaceMutationOperationRecoveryRecord] {
        records.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.id.uuidString.utf8.lexicographicallyPrecedes(rhs.id.uuidString.utf8)
        }
    }

    func upsert(_ record: WorkspaceMutationOperationRecoveryRecord) {
        records[record.id] = record
    }

    func remove(id: UUID) {
        records.removeValue(forKey: id)
    }

    func quarantineAfterLoadFailure() {
        records.removeAll()
    }
}

final class TransientMutationTextStore: WorkspaceMutationTextRecoveryPersisting {
    private var records: [UUID: WorkspaceMutationTextRecoveryRecord] = [:]
    private var quarantinedRecords: [UUID: WorkspaceMutationTextRecoveryRecord] = [:]

    func load() -> [WorkspaceMutationTextRecoveryRecord] {
        records.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.id.uuidString.utf8.lexicographicallyPrecedes(rhs.id.uuidString.utf8)
        }
    }

    func upsert(_ record: WorkspaceMutationTextRecoveryRecord) {
        records[record.id] = record
    }

    func remove(id: UUID) {
        records.removeValue(forKey: id)
    }

    func quarantine(id: UUID) {
        quarantinedRecords[id] = records.removeValue(forKey: id)
    }

    func quarantineAfterLoadFailure() {
        records.removeAll()
    }
}
