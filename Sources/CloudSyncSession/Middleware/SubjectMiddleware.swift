import Foundation
import CloudKit

struct SubjectMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        logMessage("🔥 4")

        DispatchQueue.main.async {
            switch event {
            case let .workSuccess(work, result):
                logMessage("🔥 4.1")

                switch result {
                case let .fetchLatestChanges(response):
                    logMessage("🔥 4.2")

                    if case let .fetchLatestChanges(operation) = work {
                        logMessage("🔥 4.3")

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
                logMessage("🔥 4.4 \(error)")

                switch work {
                case .modify:
                    if case let .modify(operation) = work {
                        session.modifyWorkCompletedSubject.send((operation, .failure(error)))
                    }
                case .fetchLatestChanges:
                    logMessage("🔥 4.5 \(error)")

                    if case let .fetchLatestChanges(operation) = work {
                        logMessage("🔥 4.6 \(error)")

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
                logMessage("🔥 4.7 \(error)")

                switch work {
                case .modify:
                    if case let .modify(operation) = work {
                        session.modifyWorkCompletedSubject.send((operation, .failure(error)))
                    }
                case .fetchLatestChanges:
                    logMessage("🔥 4.8 \(error)")

                    if case let .fetchLatestChanges(operation) = work {
                        logMessage("🔥 4.9 \(error)")

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
                logMessage("🔥 4.10")

                session.accountStatusSubject.send(status)
            case .start:
                logMessage("🔥 4.11")

                session.haltedSubject.send(nil)
            case let .resolveConflict(work, _, _):
                logMessage("🔥 4.12")

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
