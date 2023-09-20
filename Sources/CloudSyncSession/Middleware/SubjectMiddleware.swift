import Foundation

struct SubjectMiddleware: Middleware {
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        DispatchQueue.main.async {
            switch event {
            case let .workSuccess(work, result):
                switch result {
                case let .fetchLatestChanges(response):
                    if case let .fetchLatestChanges(operation) = work {
                        session.fetchLatestChangesWorkCompletedSubject.send(.success((operation, response)))
                    }
                case let .fetchRecords(response):
                    if case let .fetchRecords(operation) = work {
                        session.fetchRecordsWorkCompletedSubject.send(.success((operation, response)))
                    }
                case let .modify(response):
                    if case let .modify(operation) = work {
                        session.modifyWorkCompletedSubject.send(.success((operation, response)))
                    }
                default:
                    break
                }
            case let .workFailure(work, error):
                switch work {
                case .modify:
                    session.modifyWorkCompletedSubject.send(.failure(error))
                case .fetchLatestChanges:
                    session.fetchLatestChangesWorkCompletedSubject.send(.failure(error))
                case .fetchRecords:
                    session.fetchRecordsWorkCompletedSubject.send(.failure(error))
                default:
                    break
                }
            case let .halt(error):
                session.haltedSubject.send(error)
            case let .accountStatusChanged(status):
                session.accountStatusSubject.send(status)
            case .start:
                session.haltedSubject.send(nil)
            default:
                break
            }
        }

        return next(event)
    }
}
