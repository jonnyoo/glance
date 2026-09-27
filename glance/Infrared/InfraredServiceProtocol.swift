import Foundation

/// Fixed camera operations only. Never accepts paths, commands or credentials.
@objc nonisolated protocol InfraredServiceProtocol {
    func capture(_ requestID: String, withReply reply: @escaping (Data?, String?) -> Void)
    func cancel(_ requestID: String)
    func ping(withReply reply: @escaping (String) -> Void)
}
