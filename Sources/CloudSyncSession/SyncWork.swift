import CloudKit

public let maxRecommendedRecordsPerOperation = 400

public enum SyncWork: Identifiable {
    public enum Result {
        case modify(ModifyOperation.Response)
        case fetchLatestChanges(FetchLatestChangesOperation.Response)
        case fetchRecords(FetchRecordsOperation.Response)
        case createZone(Bool)
        case createSubscription(Bool)
    }

    case modify(ModifyOperation)
    case fetchLatestChanges(FetchLatestChangesOperation)
    case fetchRecords(FetchRecordsOperation)
    case createZone(CreateZoneOperation)
    case createSubscription(CreateSubscriptionOperation)

    public var id: UUID {
        switch self {
        case let .modify(operation):
            return operation.id
        case let .fetchLatestChanges(operation):
            return operation.id
        case let .fetchRecords(operation):
            return operation.id
        case let .createZone(operation):
            return operation.id
        case let .createSubscription(operation):
            return operation.id
        }
    }

    var retryCount: Int {
        switch self {
        case let .modify(operation):
            return operation.retryCount
        case let .fetchLatestChanges(operation):
            return operation.retryCount
        case let .fetchRecords(operation):
            return operation.retryCount
        case let .createZone(operation):
            return operation.retryCount
        case let .createSubscription(operation):
            return operation.retryCount
        }
    }

    var retried: SyncWork {
        switch self {
        case var .modify(operation):
            operation.retryCount += 1

            return .modify(operation)
        case var .fetchLatestChanges(operation):
            operation.retryCount += 1

            return .fetchLatestChanges(operation)
        case var .fetchRecords(operation):
            operation.retryCount += 1

            return .fetchRecords(operation)
        case var .createZone(operation):
            operation.retryCount += 1

            return .createZone(operation)
        case var .createSubscription(operation):
            operation.retryCount += 1

            return .createSubscription(operation)
        }
    }

    var checkpointID: UUID? {
        switch self {
        case let .modify(operation):
            return operation.checkpointID
        default:
            return nil
        }
    }

    var debugDescription: String {
        switch self {
        case let .modify(operation):
            return "Modify with \(operation.records.count) records to save and \(operation.recordIDsToDelete.count) to delete"
        case .fetchLatestChanges:
            return "Fetch Latest Changes"
        case .fetchRecords:
            return "Fetch Records"
        case .createZone:
            return "Create zone"
        case .createSubscription:
            return "Create subscription"
        }
    }
}

protocol SyncOperation {
    var retryCount: Int { get set }
}

public struct FetchRecordsOperation: Identifiable, SyncOperation {
    public struct Response {
        public let records: [CKRecord]
    }

    public let id = UUID()
    public let resultLimit: Int
    public let query: CKQuery
    /// The work item that dispatched the operation. If the operation is not part of a chained work, it is `nil`.
    public let parent: (any SyncChainWork<Response>)?

    var retryCount: Int = 0

    public init(resultLimit: Int, query: CKQuery, parent: (any SyncChainWork<Response>)? = nil) {
        self.resultLimit = resultLimit
        self.query = query
        self.parent = parent
    }
}

public struct FetchLatestChangesOperation: Identifiable, SyncOperation {
    public struct Response {
        public let changeToken: CKServerChangeToken?
        public let changedRecords: [CKRecord]
        public let deletedRecordIDs: [CKRecord.ID]
        public let hasMore: Bool
    }

    public let id = UUID()
    /// The work item that dispatched the operation. If the operation is not part of a chained work, it is `nil`.
    public let parent: (any SyncChainWork<Response>)?

    var changeToken: CKServerChangeToken?
    var retryCount: Int = 0

    public init(changeToken: CKServerChangeToken?, parent: (any SyncChainWork<Response>)? = nil) {
        self.changeToken = changeToken
        self.parent = parent
    }
}

public struct ModifyOperation: Identifiable, SyncOperation {
    public struct Response {
        public let savedRecords: [CKRecord]
        public let deletedRecordIDs: [CKRecord.ID]
    }

    public let id = UUID()
    public let checkpointID: UUID?
    public let userInfo: [String: Any]?
    /// The work item that dispatched the operation. If the operation is not part of a chained work, it is `nil`.
    public let parent: (any SyncChainWork<Response>)?

    var records: [CKRecord]
    var recordIDsToDelete: [CKRecord.ID]
    var retryCount: Int = 0

    public init(records: [CKRecord], recordIDsToDelete: [CKRecord.ID], checkpointID: UUID?, userInfo: [String: Any]?, parent: (any SyncChainWork<Response>)? = nil) {
        self.records = records
        self.recordIDsToDelete = recordIDsToDelete
        self.checkpointID = checkpointID
        self.userInfo = userInfo
        self.parent = parent
    }

    var shouldSplit: Bool {
        return records.count + recordIDsToDelete.count > maxRecommendedRecordsPerOperation
    }

    var split: [ModifyOperation] {
        let splitRecords: [[CKRecord]] = records.chunked(into: maxRecommendedRecordsPerOperation)
        let splitRecordIDsToDelete: [[CKRecord.ID]] = recordIDsToDelete.chunked(into: maxRecommendedRecordsPerOperation)

        return splitRecords.map { ModifyOperation(records: $0, recordIDsToDelete: [], checkpointID: nil, userInfo: userInfo) } +
            splitRecordIDsToDelete.enumerated().map { ModifyOperation(records: [], recordIDsToDelete: $0.element, checkpointID: $0.offset == splitRecordIDsToDelete.count - 1 ? checkpointID : nil, userInfo: userInfo) }
    }

    var splitInHalf: [ModifyOperation] {
        let firstHalfRecords = Array(records[0 ..< records.count / 2])
        let secondHalfRecords = Array(records[records.count / 2 ..< records.count])

        let firstHalfRecordIDsToDelete = Array(recordIDsToDelete[0 ..< recordIDsToDelete.count / 2])
        let secondHalfRecordIDsToDelete = Array(recordIDsToDelete[recordIDsToDelete.count / 2 ..< recordIDsToDelete.count])

        return [
            ModifyOperation(records: firstHalfRecords, recordIDsToDelete: firstHalfRecordIDsToDelete, checkpointID: nil, userInfo: userInfo),
            ModifyOperation(records: secondHalfRecords, recordIDsToDelete: secondHalfRecordIDsToDelete, checkpointID: checkpointID, userInfo: userInfo),
        ]
    }
}

public struct CreateZoneOperation: Identifiable, SyncOperation {
    var zoneID: CKRecordZone.ID
    var retryCount: Int = 0

    public let id = UUID()

    public init(zoneID: CKRecordZone.ID) {
        self.zoneID = zoneID
    }
}

public struct CreateSubscriptionOperation: Identifiable, SyncOperation {
    var zoneID: CKRecordZone.ID
    var retryCount: Int = 0

    public let id = UUID()

    public init(zoneID: CKRecordZone.ID) {
        self.zoneID = zoneID
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}
