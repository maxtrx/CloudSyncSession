import CloudKit
@testable import CloudSyncSession
import Combine
import XCTest

class SuccessfulMockOperationHandler: OperationHandler {
    private var operationCount = 0

    func handle(fetchOperation: FetchRecordsOperation, completion: @escaping (Result<FetchRecordsOperation.Response, Error>) -> Void) {}
    func handle(createZoneOperation _: CreateZoneOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}
    func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}

    func handle(fetchOperation _: FetchLatestChangesOperation, completion: @escaping (Result<FetchLatestChangesOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            self.operationCount += 1

            completion(
                .success(
                    FetchLatestChangesOperation.Response(
                        changeToken: nil,
                        changedRecords: (0 ..< 400).map { _ in makeTestRecord() },
                        deletedRecordIDs: [],
                        hasMore: self.operationCount == 1
                    )
                )
            )
        }
    }

    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            completion(.success(ModifyOperation.Response(savedRecords: modifyOperation.records, deletedRecordIDs: [])))
        }
    }
}

class FailingMockOperationHandler: OperationHandler {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func handle(fetchOperation: FetchRecordsOperation, completion: @escaping (Result<FetchRecordsOperation.Response, Error>) -> Void) {}
    func handle(createZoneOperation _: CreateZoneOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}
    func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}
    func handle(fetchOperation _: FetchLatestChangesOperation, completion _: @escaping (Result<FetchLatestChangesOperation.Response, Error>) -> Void) {}

    func handle(modifyOperation _: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            completion(.failure(self.error))
        }
    }
}

class FailOnceMockOperationHandler: OperationHandler {
    let error: Error

    private var operationCount = 0

    init(error: Error) {
        self.error = error
    }

    func handle(fetchOperation: FetchRecordsOperation, completion: @escaping (Result<FetchRecordsOperation.Response, Error>) -> Void) {}
    func handle(createZoneOperation _: CreateZoneOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}
    func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}
    func handle(fetchOperation _: FetchLatestChangesOperation, completion _: @escaping (Result<FetchLatestChangesOperation.Response, Error>) -> Void) {}

    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            self.operationCount += 1

            if self.operationCount > 1 {
                completion(.success(ModifyOperation.Response(savedRecords: modifyOperation.records, deletedRecordIDs: [])))
            } else {
                completion(.failure(self.error))
            }
        }
    }
}

class PartialFailureMockOperationHandler: OperationHandler {
    func handle(fetchOperation: FetchRecordsOperation, completion: @escaping (Result<FetchRecordsOperation.Response, Error>) -> Void) {}
    func handle(createZoneOperation _: CreateZoneOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}
    func handle(fetchOperation _: FetchLatestChangesOperation, completion _: @escaping (Result<FetchLatestChangesOperation.Response, Error>) -> Void) {}
    func handle(createSubscriptionOperation _: CreateSubscriptionOperation, completion _: @escaping (Result<Bool, Error>) -> Void) {}

    func handle(modifyOperation _: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            completion(.failure(CKError(.partialFailure)))
        }
    }
}

private var testIdentifier = "8B14FD76-EA56-49B0-A184-6C01828BA20A"

private var testZoneID = CKRecordZone.ID(
    zoneName: "test",
    ownerName: CKCurrentUserDefaultName
)

func makeTestRecord() -> CKRecord {
    return CKRecord(
        recordType: "Test",
        recordID: CKRecord.ID(recordName: UUID().uuidString)
    )
}

final class CloudSyncSessionTests: XCTestCase {
    func testRunsAfterAccountAvailableAndZoneCreated() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")
        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneID: testZoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )

        session.dispatch(event: .accountStatusChanged(.available))
        let createZoneWork = SyncWork.createZone(CreateZoneOperation(zoneID: testZoneID))
        session.dispatch(event: .workSuccess(createZoneWork, .createZone(true)))
        let createSubscriptionWork = SyncWork.createSubscription(CreateSubscriptionOperation(zoneID: testZoneID))
        session.dispatch(event: .workSuccess(createSubscriptionWork, .createSubscription(true)))

        session.$state
            .sink { newState in
                if newState.isRunning {
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        wait(for: [expectation], timeout: 1)
    }

    func testModifyFailure() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = FailingMockOperationHandler(error: CKError(.notAuthenticated))
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneID: testZoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )
        session.state = SyncState(
            hasGoodAccountStatus: true,
            hasCreatedZone: true,
            hasCreatedSubscription: true
        )

        session.$state
            .sink { newState in
                if !newState.isRunning {
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        let operation = ModifyOperation(records: [makeTestRecord()], recordIDsToDelete: [], checkpointID: nil, userInfo: nil)
        session.modify(operation)

        wait(for: [expectation], timeout: 1)
    }

    func testHaltedIgnoresModifyEvents() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")
        expectation.isInverted = true

        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneID: testZoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )
        session.state = SyncState(
            hasGoodAccountStatus: true,
            hasCreatedZone: true,
            hasCreatedSubscription: true,
            isHalted: true
        )

        session.modifyWorkCompletedSubject
            .sink { _ in
                expectation.fulfill()
            }
            .store(in: &tasks)

        let operation = ModifyOperation(records: [makeTestRecord()], recordIDsToDelete: [], checkpointID: nil, userInfo: nil)
        session.modify(operation)

        wait(for: [expectation], timeout: 1)
    }

    func testDoesNotUnhaltAfterFailure() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")
        expectation.assertForOverFulfill = false

        let mockOperationHandler = FailingMockOperationHandler(error: CKError(.notAuthenticated))
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneID: testZoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )
        session.state = SyncState(
            hasGoodAccountStatus: true,
            hasCreatedZone: true,
            hasCreatedSubscription: true
        )

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { newState in
                if newState.isHalted {
                    session.dispatch(event: .accountStatusChanged(.available))
                    XCTAssertFalse(session.state.isRunning)
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        let operation = ModifyOperation(records: [makeTestRecord()], recordIDsToDelete: [], checkpointID: nil, userInfo: nil)
        session.modify(operation)

        wait(for: [expectation], timeout: 1)
    }

    func testHaltAfterPartialFailureWithoutRecovery() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = PartialFailureMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneID: testZoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )
        session.state = SyncState(
            hasGoodAccountStatus: true,
            hasCreatedZone: true,
            hasCreatedSubscription: true
        )

        // Won't recover because no conflict handler set up

        session.$state
            .receive(on: DispatchQueue.main)
            .sink { newState in
                if newState.isHalted {
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        let operation = ModifyOperation(records: [makeTestRecord()], recordIDsToDelete: [], checkpointID: nil, userInfo: nil)
        session.modify(operation)

        wait(for: [expectation], timeout: 1)
    }

    func testLoadsMore() {
        var tasks = Set<AnyCancellable>()
        let expectation = self.expectation(description: "work")

        let mockOperationHandler = SuccessfulMockOperationHandler()
        let session = CloudSyncSession(
            operationHandler: mockOperationHandler,
            zoneID: testZoneID,
            resolveConflict: { _, _ in nil },
            resolveExpiredChangeToken: { nil }
        )
        session.state = SyncState(
            hasGoodAccountStatus: true,
            hasCreatedZone: true,
            hasCreatedSubscription: true
        )

        var timesCalled = 0

        session.fetchLatestChangesWorkCompletedSubject
            .sink { _ in
                timesCalled += 1

                if timesCalled >= 2 {
                    expectation.fulfill()
                }
            }
            .store(in: &tasks)

        let operation = FetchLatestChangesOperation(changeToken: nil)
        session.dispatch(event: .doWork(.fetchLatestChanges(operation)))

        wait(for: [expectation], timeout: 1)
    }

    // MARK: - CKRecord Extensions
    @available(iOS 15, watchOS 8, *)
    func testCKRecordRemoveAllFields() {
        let record = makeTestRecord()
        record["hello"] = "world"
        record.encryptedValues["secrets"] = "👻"

        record.removeAllFields()

        XCTAssertEqual(record["hello"] as! String?, nil)
        XCTAssertEqual(record["secrets"] as! String?, nil)
    }

    @available(iOS 15, watchOS 8, *)
    func testCKRecordCopyFields() {
        let recordA = makeTestRecord()
        recordA["hello"] = "world"
        recordA.encryptedValues["secrets"] = "👻"

        let recordB = makeTestRecord()
        recordB["hello"] = "🌎"
        recordA.encryptedValues["secrets"] = "💀"

        recordA.copyFields(from: recordB)

        XCTAssertEqual(recordA["hello"] as! String?, "🌎")
        XCTAssertEqual(recordA.encryptedValues["secrets"] as! String?, "💀")
    }
}
