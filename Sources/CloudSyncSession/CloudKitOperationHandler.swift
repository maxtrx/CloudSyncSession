//
// Copyright (c) 2020 Jay Hickey
// Copyright (c) 2020-present Ryan Ashcraft
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import CloudKit
import os.log

/// An object that handles all of the key operations (fetch, modify, create zone, and create subscription) using the standard CloudKit APIs.
public class CloudKitOperationHandler: OperationHandler {
    static let minThrottleDuration: TimeInterval = 0
    static let maxThrottleDuration: TimeInterval = 60 * 10

    let database: CKDatabase
    let zoneID: CKRecordZone.ID
    let subscriptionID: String
    let log: OSLog
    let savePolicy: CKModifyRecordsOperation.RecordSavePolicy = .ifServerRecordUnchanged
    let qos: QualityOfService = .userInitiated

    private let operationQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1

        return queue
    }()

    var throttleDuration: TimeInterval {
        didSet {
            if throttleDuration > oldValue {
                os_log(
                    "Increasing throttle duration from %{public}.0f seconds to %{public}.0f seconds",
                    log: log,
                    type: .default,
                    oldValue,
                    throttleDuration
                )
            } else if throttleDuration < oldValue {
                os_log(
                    "Decreasing throttle duration from %{public}.0f seconds to %{public}.0f seconds",
                    log: log,
                    type: .default,
                    oldValue,
                    throttleDuration
                )
            }
        }
    }

    var lastOperationTime: DispatchTime?

    public init(database: CKDatabase, zoneID: CKRecordZone.ID, subscriptionID: String, log: OSLog) {
        self.database = database
        self.zoneID = zoneID
        self.subscriptionID = subscriptionID
        self.log = log
        throttleDuration = Self.minThrottleDuration
    }

    private func queueOperation(_ operation: Operation) {
        let deadline: DispatchTime = (lastOperationTime ?? DispatchTime.now()) + throttleDuration

        DispatchQueue.main.asyncAfter(deadline: deadline) {
            self.operationQueue.addOperation(operation)
            self.operationQueue.addOperation {
                self.lastOperationTime = DispatchTime.now()
            }
        }
    }

    public func handle(
        modifyOperation: ModifyOperation,
        completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void
    ) {
        let recordsToSave = modifyOperation.records
        let recordIDsToDelete = modifyOperation.recordIDsToDelete

        guard !recordIDsToDelete.isEmpty || !recordsToSave.isEmpty else {
            completion(.success(ModifyOperation.Response(savedRecords: [], deletedRecordIDs: [])))

            return
        }

        let operation = CKModifyRecordsOperation(
            recordsToSave: recordsToSave,
            recordIDsToDelete: recordIDsToDelete
        )

        operation.modifyRecordsCompletionBlock = { serverRecords, deletedRecordIDs, error in
            if let error = error {
                if let ckError = error as? CKError {
                    // Use the suggested retry delay, or exponentially increase throttle duration if not provided
                    self.throttleDuration = min(Self.maxThrottleDuration, ckError.retryAfterSeconds ?? (self.throttleDuration * 2))
                }

                completion(.failure(error))
            } else {
                // On success, back off of the throttle duration by 66%. Backing off too quickly can result in thrashing.
                self.throttleDuration = max(Self.minThrottleDuration, self.throttleDuration * 2 / 3)

                completion(.success(ModifyOperation.Response(savedRecords: serverRecords ?? [], deletedRecordIDs: deletedRecordIDs ?? [])))
            }
        }

        operation.savePolicy = savePolicy
        operation.qualityOfService = qos
        operation.database = database

        queueOperation(operation)
    }

    public func handle(fetchOperation: FetchLatestChangesOperation, completion: @escaping (Result<FetchLatestChangesOperation.Response, Error>) -> Void) {
        var hasMore = false
        var token: CKServerChangeToken? = fetchOperation.changeToken
        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []

        let operation = CKFetchRecordZoneChangesOperation()

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration(
            previousServerChangeToken: token,
            resultsLimit: nil,
            desiredKeys: nil
        )

        operation.configurationsByRecordZoneID = [zoneID: config]

        operation.recordZoneIDs = [zoneID]
        operation.fetchAllChanges = true
        
        os_log("Fetching latest changes", log: self.log, type: .debug)

        operation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, newToken, _ in
            guard let self = self else {
                return
            }

            guard let newToken = newToken else {
                return
            }

            os_log("1 Received new change token", log: self.log, type: .debug)

            token = newToken
        }

        operation.recordChangedBlock = { record in
            changedRecords.append(record)
        }

        operation.recordWithIDWasDeletedBlock = { recordID, _ in
            deletedRecordIDs.append(recordID)
        }

        operation.recordZoneFetchCompletionBlock = { [weak self] _, newToken, _, newHasMore, _ in
            guard let self = self else {
                return
            }

            hasMore = newHasMore

            if let newToken = newToken {
                os_log("2 Received new change token", log: self.log, type: .debug)

                token = newToken
            } else {
                os_log("Confusingly received nil token", log: self.log, type: .debug)

                token = nil
            }
        }

        operation.fetchRecordZoneChangesCompletionBlock = { [weak self] error in
            guard let self = self else {
                return
            }

            if let error = error {
                os_log(
                    "Failed to fetch record zone changes: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                if let ckError = error as? CKError {
                    // Use the suggested retry delay, or exponentially increase throttle duration if not provided
                    self.throttleDuration = min(Self.maxThrottleDuration, ckError.retryAfterSeconds ?? (self.throttleDuration * 2))
                }

                completion(.failure(error))
            } else {
                os_log("Finished fetching record zone changes", log: self.log, type: .info)

                // On success, back off of the throttle duration by 66%. Backing off too quickly can result in thrashing.
                self.throttleDuration = max(Self.minThrottleDuration, self.throttleDuration * 2 / 3)

                completion(
                    .success(
                        FetchLatestChangesOperation.Response(
                            changeToken: token,
                            changedRecords: changedRecords,
                            deletedRecordIDs: deletedRecordIDs,
                            hasMore: hasMore
                        )
                    )
                )
            }
        }

        operation.qualityOfService = qos
        operation.database = database

        queueOperation(operation)
    }
    
    public func handle(fetchOperation: FetchRecordsOperation, completion: @escaping (Result<FetchRecordsOperation.Response, Error>) -> Void) {
        let operation = CKQueryOperation(query: fetchOperation.query)
        if let resultLimit = fetchOperation.resultLimit {
            operation.resultsLimit = resultLimit
        }
        operation.zoneID = zoneID
        
        var records = [CKRecord]()
        
        operation.recordFetchedBlock = { record in
            records.append(record)
        }
                
        operation.queryCompletionBlock = { [weak self] (cursor, error) in
            guard let self = self else {
                return
            }

            if let error = error {
                os_log(
                    "Failed to fetch record zone changes: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                if let ckError = error as? CKError {
                    // Use the suggested retry delay, or exponentially increase throttle duration if not provided
                    self.throttleDuration = min(Self.maxThrottleDuration, ckError.retryAfterSeconds ?? (self.throttleDuration * 2))
                }

                completion(.failure(error))
            } else {
                os_log("Finished fetching record zone changes", log: self.log, type: .info)

                // On success, back off of the throttle duration by 66%. Backing off too quickly can result in thrashing.
                self.throttleDuration = max(Self.minThrottleDuration, self.throttleDuration * 2 / 3)

                completion(
                    .success(
                        FetchRecordsOperation.Response(records: records)
                    )
                )
            }
        }
        
        operation.qualityOfService = qos
        operation.database = database

        queueOperation(operation)
    }

    public func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        checkCustomZone(zoneID: createZoneOperation.zoneID) { result in
            switch result {
            case let .failure(error):
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .partialFailure,
                         .zoneNotFound,
                         .userDeletedZone:
                        self.createCustomZone(zoneID: self.zoneID) { result in
                            switch result {
                            case let .failure(error):
                                completion(.failure(error))
                            case let .success(didCreateZone):
                                completion(.success(didCreateZone))
                            }
                        }

                        return
                    default:
                        break
                    }
                }

                completion(.failure(error))
            case let .success(isZoneAlreadyCreated):
                if isZoneAlreadyCreated {
                    completion(.success(true))

                    return
                }

                self.createCustomZone(zoneID: self.zoneID) { result in
                    switch result {
                    case let .failure(error):
                        completion(.failure(error))
                    case let .success(didCreateZone):
                        completion(.success(didCreateZone))
                    }
                }
            }
        }
    }

    public func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion: @escaping (Result<Bool, Error>) -> Void) {
        checkSubscription(zoneID: zoneID) { result in
            switch result {
            case let .failure(error):
                if let ckError = error as? CKError {
                    switch ckError.code {
                    case .partialFailure,
                         .zoneNotFound,
                         .userDeletedZone:
                        self.createSubscription(zoneID: self.zoneID, subscriptionID: self.subscriptionID) { result in
                            switch result {
                            case let .failure(error):
                                completion(.failure(error))
                            case let .success(didCreateSubscription):
                                completion(.success(didCreateSubscription))
                            }
                        }

                        return
                    default:
                        break
                    }
                }

                completion(.failure(error))
            case let .success(isSubscriptionAlreadyCreated):
                if isSubscriptionAlreadyCreated {
                    completion(.success(true))

                    return
                }

                self.createSubscription(zoneID: self.zoneID, subscriptionID: self.subscriptionID) { result in
                    switch result {
                    case let .failure(error):
                        completion(.failure(error))
                    case let .success(didCreateZone):
                        completion(.success(didCreateZone))
                    }
                }
            }
        }
    }
}

private extension CloudKitOperationHandler {
    func checkCustomZone(zoneID: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let operation = CKFetchRecordZonesOperation(recordZoneIDs: [zoneID])

        operation.fetchRecordZonesCompletionBlock = { ids, error in
            if let error = error {
                os_log(
                    "Failed to check for custom zone existence: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                completion(.failure(error))

                return
            } else if (ids ?? [:]).isEmpty {
                os_log(
                    "Custom zone reported as existing, but it doesn't exist",
                    log: self.log,
                    type: .error
                )

                completion(.success(false))

                return
            }

            os_log(
                "Custom zone exists",
                log: self.log,
                type: .error
            )

            completion(.success(true))
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }

    func createCustomZone(zoneID: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let zone = CKRecordZone(zoneID: zoneID)
        let operation = CKModifyRecordZonesOperation(
            recordZonesToSave: [zone],
            recordZoneIDsToDelete: nil
        )

        operation.modifyRecordZonesCompletionBlock = { _, _, error in
            if let error = error {
                os_log(
                    "Failed to create custom zone: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                completion(.failure(error))

                return
            }

            os_log("Created custom zone", log: self.log, type: .debug)

            completion(.success(true))
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }

    func checkSubscription(zoneID _: CKRecordZone.ID, completion: @escaping (Result<Bool, Error>) -> Void) {
        let operation = CKFetchSubscriptionsOperation(subscriptionIDs: [subscriptionID])

        operation.fetchSubscriptionCompletionBlock = { ids, error in
            if let error = error {
                os_log(
                    "Failed to check for subscription existence: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                completion(.failure(error))

                return
            } else if (ids ?? [:]).isEmpty {
                os_log(
                    "Subscription reported as existing, but it doesn't exist",
                    log: self.log,
                    type: .error
                )

                completion(.success(false))

                return
            }

            os_log("Subscription exists", log: self.log, type: .debug)

            completion(.success(true))
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }

    func createSubscription(zoneID: CKRecordZone.ID, subscriptionID: String, completion: @escaping (Result<Bool, Error>) -> Void) {
        let subscription = CKRecordZoneSubscription(
            zoneID: zoneID,
            subscriptionID: subscriptionID
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true

        subscription.notificationInfo = notificationInfo

        let operation = CKModifySubscriptionsOperation(
            subscriptionsToSave: [subscription],
            subscriptionIDsToDelete: nil
        )

        operation.modifySubscriptionsCompletionBlock = { _, _, error in
            if let error = error {
                os_log(
                    "Failed to create subscription: %{public}@",
                    log: self.log,
                    type: .error,
                    String(describing: error)
                )

                completion(.failure(error))

                return
            }

            os_log("Created subscription", log: self.log, type: .debug)

            completion(.success(true))
        }

        operation.qualityOfService = .userInitiated
        operation.database = database

        queueOperation(operation)
    }
}
