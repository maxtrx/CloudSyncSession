import os.log

struct LoggerMiddleware: Middleware {
    var session: CloudSyncSession

    var log = OSLog(
        subsystem: "com.ryanashcraft.CloudSyncSession",
        category: "Sync Event"
    )

    func run(next: (SyncEvent) -> SyncEvent, event: SyncEvent) -> SyncEvent {
        os_log("%{public}@", log: log, type: .debug, event.logDescription)
        logMessage("🔥 3")

        return next(event)
    }
}
