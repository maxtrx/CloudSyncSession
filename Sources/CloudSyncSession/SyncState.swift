import Foundation

/// The state of a session.
public struct SyncState {
    /// The various modes that the session can be operating in.
    public enum OperationMode {
        case modify
        case fetchChanges
        case fetchRecords
        case createZone
        case createSubscription
    }

    /// The queue of modification requests to be handled.
    internal var modifyQueue = [ModifyOperation]()

    /// The queue of fetch requests to be handled.
    internal var fetchLatestChangesQueue = [FetchLatestChangesOperation]()
    
    /// The queue of fetch requests to be handled.
    internal var fetchRecordsQueue = [FetchRecordsOperation]()

    /// The queue of create zone requests to be handled.
    internal var createZoneQueue = [CreateZoneOperation]()

    /// The queue of create subscription requests to be handled.
    internal var createSubscriptionQueue = [CreateSubscriptionOperation]()

    /// Indicates whether the CloudKit status is available. The value is nil if the account status is yet to be deteremined.
    public var hasGoodAccountStatus: Bool? = nil

    /// Indicates whether the zone has been created. The value is nil if the session has yet to create the zone.
    public var hasCreatedZone: Bool? = nil

    /// Indicates whether the subscription has been created. The value is nil if the session has yet to create the subscription.
    public var hasCreatedSubscription: Bool? = nil

    /// Indicates whether the sync session has halted.
    public var isHalted: Bool = false {
        didSet {
            lastHaltedDate = isHalted ? Date() : nil

            updateOperationMode()
        }
    }

    /// The time at which the sync session was last halted.
    public var lastHaltedDate: Date?

    /// How many times the current work has been retried.
    public var retryCount: Int = 0

    /// The error that caused the last retry.
    public var lastRetryError: Error?

    /// Indicates whether the session is currently modyifing, fetching, creating a zone, or creating a subscription.
    public var operationMode: OperationMode?

    /// Indicates whether or not there's any work to be done.
    public var hasWorkQueued: Bool {
        !modifyQueue.isEmpty || !fetchLatestChangesQueue.isEmpty || !fetchRecordsQueue.isEmpty || !createZoneQueue.isEmpty || !createSubscriptionQueue.isEmpty
    }

    /// Indicates whether the session is currently fetching.
    public var isFetching: Bool {
        operationMode == .fetchChanges || operationMode == .fetchRecords
    }

    /// Indicates whether the session is currently modifying.
    public var isModifying: Bool {
        operationMode == .modify
    }

    /// Indicates what kind of work is allowed at this time.
    internal var allowedOperationModes: Set<OperationMode?> {
        var allowedModes: Set<OperationMode?> = [nil]

        if isHalted {
            // Halted means no work allowed
            return allowedModes
        }

        if !(hasGoodAccountStatus ?? false) {
            // Bad or unknown account status means no work allowed
            return allowedModes
        }

        allowedModes.formUnion([.createZone, .createSubscription])

        if hasCreatedZone ?? false, hasCreatedSubscription ?? false {
            allowedModes.formUnion([.fetchChanges, .fetchRecords, .modify])
        }

        return allowedModes
    }

    /// An ordered list of the the kind of work that is allowed at this time.
    internal var preferredOperationModes: [OperationMode?] {
        [.createZone, .createSubscription, .modify, .fetchChanges, .fetchRecords, nil]
            .filter { allowedOperationModes.contains($0) }
            .filter { mode in
                switch mode {
                case .createZone:
                    return !createZoneQueue.isEmpty
                case .fetchChanges:
                    return !fetchLatestChangesQueue.isEmpty
                case .fetchRecords:
                    return !fetchRecordsQueue.isEmpty
                case .modify:
                    return !modifyQueue.isEmpty
                case .createSubscription:
                    return !createSubscriptionQueue.isEmpty
                case nil:
                    return true
                }
            }
    }

    /// Indicates whether the session is ready to perform fetches and modifications.
    public var isRunning: Bool {
        allowedOperationModes.contains(.fetchChanges)
            && allowedOperationModes.contains(.fetchRecords)
            && allowedOperationModes.contains(.modify)
            && !isHalted
    }

    /// Indicates whether the prerequisites have been met to fetch and/or modify records.
    public var hasStarted: Bool {
        hasCreatedZone != nil && hasCreatedSubscription != nil && hasGoodAccountStatus != nil
    }

    /// Indicates whether we are starting up, but not ready to fetch and/or modify records.
    public var isStarting: Bool {
        !hasStarted && !isHalted
    }

    /// The current work that is, or is to be, worked on.
    internal var currentWork: SyncWork? {
        guard allowedOperationModes.contains(operationMode) else {
            return nil
        }

        switch operationMode {
        case nil:
            return nil
        case .modify:
            if let operation = modifyQueue.first {
                return SyncWork.modify(operation)
            }
        case .fetchChanges:
            if let operation = fetchLatestChangesQueue.first {
                return SyncWork.fetchLatestChanges(operation)
            }
        case .fetchRecords:
            if let operation = fetchRecordsQueue.first {
                return SyncWork.fetchRecords(operation)
            }
        case .createZone:
            if let operation = createZoneQueue.first {
                return SyncWork.createZone(operation)
            }
        case .createSubscription:
            if let operation = createSubscriptionQueue.first {
                return SyncWork.createSubscription(operation)
            }
        }

        return nil
    }

    /// Transition to a new operation mode (i.e. fetching, modifying creating a zone or subscription)
    internal mutating func updateOperationMode() {
        if isHalted {
            operationMode = nil
        }

        if operationMode == nil || !preferredOperationModes.contains(operationMode) {
            operationMode = preferredOperationModes.first ?? nil
        }
    }

    /// Add work to the end of the appropriate queue
    internal mutating func pushWork(_ work: SyncWork) {
        switch work {
        case let .fetchLatestChanges(operation):
            fetchLatestChangesQueue.append(operation)
        case let .fetchRecords(operation):
            fetchRecordsQueue.append(operation)
        case let .modify(operation):
            modifyQueue.append(operation)
        case let .createZone(operation):
            createZoneQueue.append(operation)
        case let .createSubscription(operation):
            createSubscriptionQueue.append(operation)
        }
    }

    /// Add work to the beginning of the appropriate queue.
    internal mutating func prioritizeWork(_ work: SyncWork) {
        switch work {
        case let .fetchLatestChanges(operation):
            fetchLatestChangesQueue = [operation] + fetchLatestChangesQueue
        case let .fetchRecords(operation):
            fetchRecordsQueue = [operation] + fetchRecordsQueue
        case let .modify(operation):
            modifyQueue = [operation] + modifyQueue
        case let .createZone(operation):
            createZoneQueue = [operation] + createZoneQueue
        case let .createSubscription(operation):
            createSubscriptionQueue = [operation] + createSubscriptionQueue
        }
    }

    /// Remove work from the corresponding queue.
    internal mutating func popWork(work: SyncWork) {
        switch work {
        case let .fetchLatestChanges(operation):
            fetchLatestChangesQueue = fetchLatestChangesQueue.filter { $0.id != operation.id }
        case let .fetchRecords(operation):
            fetchRecordsQueue = fetchRecordsQueue.filter { $0.id != operation.id }
        case let .modify(operation):
            modifyQueue = modifyQueue.filter { $0.id != operation.id }
        case let .createZone(operation):
            createZoneQueue = createZoneQueue.filter { $0.id != operation.id }
        case let .createSubscription(operation):
            createSubscriptionQueue = createSubscriptionQueue.filter { $0.id != operation.id }
        }
    }

    /// Update based on a sync event.
    internal func reduce(event: SyncEvent) -> SyncState {
        var state = self

        switch event {
        case let .accountStatusChanged(accountStatus):
            switch accountStatus {
            case .available:
                state.hasGoodAccountStatus = true
            default:
                state.hasGoodAccountStatus = false
            }
            state.updateOperationMode()
        case let .retryWork(work):
            state.popWork(work: work)
            state.pushWork(work.retried)
            state.updateOperationMode()
        case let .doWork(work):
            state.pushWork(work)
            state.updateOperationMode()
        case let .split(work, _):
            state.popWork(work: work)

            switch work {
            case let .modify(operation):
                for splitOperation in operation.splitInHalf.reversed() {
                    state.prioritizeWork(.modify(splitOperation))
                }
            default:
                state.isHalted = true
            }

            state.updateOperationMode()
        case let .workFailure(work, _):
            state.popWork(work: work)
            state.updateOperationMode()
        case let .workSuccess(work, result):
            state.retryCount = 0
            state.lastRetryError = nil

            state.popWork(work: work)

            switch result {
            case let .fetchLatestChanges(response):
                if response.hasMore {
                    state.prioritizeWork(.fetchLatestChanges(FetchLatestChangesOperation(changeToken: response.changeToken)))
                }
            case let .createZone(didCreateZone):
                state.hasCreatedZone = didCreateZone
            case let .createSubscription(didCreateSubscription):
                state.hasCreatedSubscription = didCreateSubscription
            default:
                break
            }

            state.updateOperationMode()
        case let .resolveConflict(work, records, recordIDsToDelete):
            if case let .modify(failedOperation) = work {
                let operation = ModifyOperation(records: records, recordIDsToDelete: recordIDsToDelete, checkpointID: work.checkpointID, userInfo: failedOperation.userInfo)

                state.popWork(work: work)
                state.pushWork(.modify(operation))
            }
        case .halt:
            state.isHalted = true
        case .start:
            state.isHalted = false
        case let .retry(_, error, _):
            state.retryCount += 1
            state.lastRetryError = error
        case .noop:
            break
        }

        return state
    }
}
