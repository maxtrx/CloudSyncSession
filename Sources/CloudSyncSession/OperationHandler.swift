public protocol OperationHandler {
    func handle(fetchOperation: FetchLatestChangesOperation, completion: @escaping (Result<FetchLatestChangesOperation.Response, Error>) -> Void)
    func handle(fetchOperation: FetchRecordsOperation, completion: @escaping (Result<FetchRecordsOperation.Response, Error>) -> Void)
    func handle(modifyOperation: ModifyOperation, completion: @escaping (Result<ModifyOperation.Response, Error>) -> Void)
    func handle(createZoneOperation: CreateZoneOperation, completion: @escaping (Result<Bool, Error>) -> Void)
    func handle(createSubscriptionOperation: CreateSubscriptionOperation, completion: @escaping (Result<Bool, Error>) -> Void)
}
