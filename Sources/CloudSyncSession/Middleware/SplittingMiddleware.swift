import os.log

struct SplittingMiddleware: Middleware {
    private let myLog = OSLog(
        subsystem: "com.ryanashcraft.CloudSyncSession",
        category: "Subject Middleware"
    )
    
    var session: CloudSyncSession

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        os_log(
            "🦊 Work",
            log: myLog,
            type: .info
        )
        
        switch event {
        case let .doWork(work):
            switch work {
            case let .modify(operation):
                if operation.shouldSplit {
                    for splitOperation in operation.split {
                        os_log(
                            "🦊 Work dispatch",
                            log: myLog,
                            type: .info
                        )
                        session.dispatch(event: .doWork(.modify(splitOperation)))
                    }

                    return next(.noop)
                }
            default:
                break
            }
        default:
            break
        }

        return next(event)
    }
}
