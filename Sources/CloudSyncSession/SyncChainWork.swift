//
//  SyncChainWork.swift
//  
//
//  Created by maxtrx on 24.05.23.
//

import Foundation

/// A work item that is part of a larger task that involves multiple requests made to CloudKit.
public protocol SyncChainWork<OperationResponse> {
    associatedtype OperationResponse
    
    /// The next request to be dispatched after this request completed. If the parent work has been completed, it is `nil`.
    var successor: (any SyncChainWork)? { get }
    
    /// The response that is returned from the session for this particular work item.
    var response: OperationResponse? { get set }
    
    /// Creates a `SyncOperation` and dispatches it to the session.
    func dispatch(to session: CloudSyncSession) throws
    
    /// Dispatches the next request in the work chain to the session.
    func dispatchSuccessor(to session: CloudSyncSession) throws
}
