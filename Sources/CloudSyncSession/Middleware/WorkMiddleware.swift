import Combine
import Foundation

private let workDelay = DispatchTimeInterval.milliseconds(60)

struct WorkMiddleware: Middleware {
    var session: CloudSyncSession

    private let dispatchQueue = DispatchQueue(label: "WorkMiddleware.Dispatch", qos: .userInitiated)

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        let prevState = session.state
        let event = next(event)
        let newState = session.state

        if let work = newState.currentWork {
            let prevWork = prevState.currentWork

            if prevWork?.id != work.id || prevWork?.retryCount != work.retryCount {
                dispatchQueue.asyncAfter(deadline: .now() + workDelay) {
                    self.doWork(work)
                }
            }
        }

        return event
    }

    private func doWork(_ work: SyncWork) {
        logMessage("🔥 5")

        switch work {
        case let .fetchLatestChanges(operation):
            logMessage("🔥 5.1")

            session.operationHandler.handle(fetchOperation: operation) { result in
                logMessage("🔥 5.6")

                switch result {
                case let .failure(error):
                    logMessage("🔥 5.7")

                    session.dispatch(event: .workFailure(work, error))
                case let .success(response):
                    logMessage("🔥 5.8")

                    session.dispatch(event: .workSuccess(work, .fetchLatestChanges(response)))
                }
            }
        case let .fetchRecords(operation):
            logMessage("🔥 5.2")

            session.operationHandler.handle(fetchOperation: operation) { result in
                switch result {
                case let .failure(error):
                    session.dispatch(event: .workFailure(work, error))
                case let .success(response):
                    session.dispatch(event: .workSuccess(work, .fetchRecords(response)))
                }
            }
        case let .modify(operation):
            logMessage("🔥 5.3")

            session.operationHandler.handle(modifyOperation: operation) { result in
                switch result {
                case let .failure(error):
                    session.dispatch(event: .workFailure(work, error))
                case let .success(response):
                    session.dispatch(event: .workSuccess(work, .modify(response)))
                }
            }
        case let .createZone(operation):
            logMessage("🔥 5.4")

            session.operationHandler.handle(createZoneOperation: operation) { result in
                switch result {
                case let .failure(error):
                    session.dispatch(event: .workFailure(work, error))
                case let .success(hasCreatedZone):
                    session.dispatch(event: .workSuccess(work, .createZone(hasCreatedZone)))
                }
            }
        case let .createSubscription(operation):
            logMessage("🔥 5.5")

            session.operationHandler.handle(createSubscriptionOperation: operation) { result in
                switch result {
                case let .failure(error):
                    session.dispatch(event: .workFailure(work, error))
                case let .success(hasCreatedSubscription):
                    session.dispatch(event: .workSuccess(work, .createSubscription(hasCreatedSubscription)))
                }
            }
        }
    }
}
