import CloudKit
import Foundation

let maxRetryCount = 5

private func getRetryTimeInterval(retryCount: Int) -> TimeInterval {
    return TimeInterval(pow(Double(retryCount), 2.0))
}

struct RetryMiddleware: Middleware {
    var session: CloudSyncSession

    private let dispatchQueue = DispatchQueue(label: "ErrorMiddleware.Dispatch", qos: .userInitiated)

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        logMessage("🔥 6")

        switch event {
        case let .retry(work, error, suggestedInterval):
            logMessage("🔥 6.1")

            let currentRetryCount = work.retryCount

            if currentRetryCount + 1 > maxRetryCount {
                session.dispatch(event: .halt(work, error))
            } else {
                let retryInterval: TimeInterval

                if let suggestedInterval = suggestedInterval {
                    retryInterval = suggestedInterval
                } else {
                    retryInterval = getRetryTimeInterval(retryCount: work.retryCount)
                }

                dispatchQueue.asyncAfter(deadline: .now() + retryInterval) {
                    session.dispatch(event: .retryWork(work))
                }
            }

            return next(event)
        default:
            logMessage("🔥 6.2")

            return next(event)
        }
    }
}
