import Foundation
import CloudKit

struct SubjectMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        DispatchQueue.main.async {
            switch event {
            case let .workSuccess(work, result):
                switch result {
                case let .fetchLatestChanges(response):
                    logMessage("🔥 fetch changes success")

                    if case let .fetchLatestChanges(operation) = work {
                        logMessage("🔥 fetch changes success 2")

                        session.fetchLatestChangesWorkCompletedSubject.send((operation, .success(response)))
                    }
                case let .fetchRecords(response):
                    if case let .fetchRecords(operation) = work {
                        session.fetchRecordsWorkCompletedSubject.send((operation, .success(response)))
                    }
                case let .modify(response):
                    if case let .modify(operation) = work {
                        session.modifyWorkCompletedSubject.send((operation, .success(response)))
                    }
                default:
                    break
                }
            case let .workFailure(work, error):
                logMessage("🔥 SubjectMiddleware \(error)")

                switch work {
                case .modify:
                    if case let .modify(operation) = work {
                        session.modifyWorkCompletedSubject.send((operation, .failure(error)))
                    }
                case .fetchLatestChanges:
                    logMessage("🔥 SubjectMiddleware changes \(error)")

                    if case let .fetchLatestChanges(operation) = work {
                        logMessage("🔥 SubjectMiddleware changes \(error)")

                        session.fetchLatestChangesWorkCompletedSubject.send((operation, .failure(error)))
                    }
                case .fetchRecords:
                    if case let .fetchRecords(operation) = work {
                        session.fetchRecordsWorkCompletedSubject.send((operation, .failure(error)))
                    }
                default:
                    break
                }
            case let .halt(work, error):
                logMessage("🔥 SubjectMiddleware halt \(error)")

                switch work {
                case .modify:
                    if case let .modify(operation) = work {
                        session.modifyWorkCompletedSubject.send((operation, .failure(error)))
                    }
                case .fetchLatestChanges:
                    logMessage("🔥 SubjectMiddleware halt 2 \(error)")

                    if case let .fetchLatestChanges(operation) = work {
                        logMessage("🔥 SubjectMiddleware halt 3 \(error)")

                        session.fetchLatestChangesWorkCompletedSubject.send((operation, .failure(error)))
                    }
                case .fetchRecords:
                    if case let .fetchRecords(operation) = work {
                        session.fetchRecordsWorkCompletedSubject.send((operation, .failure(error)))
                    }
                default:
                    break
                }
                
                session.haltedSubject.send(error)
            case let .accountStatusChanged(status):
                logMessage("🔥 accountStatusChanged")

                session.accountStatusSubject.send(status)
            case .start:
                logMessage("🔥 start")

                session.haltedSubject.send(nil)
            case let .resolveConflict(work, _, _):
                logMessage("🔥 resolveConflict")

                if case let .modify(failedOperation) = work {
                    session.modifyWorkCompletedSubject.send((failedOperation, .failure(CKError(.partialFailure))))
                }
            default:
                break
            }
        }

        return next(event)
    }
}
