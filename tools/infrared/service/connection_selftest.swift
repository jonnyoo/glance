// Run against an explicitly enabled local lab helper. Does not open the camera.
// An ad-hoc client must fail; a client signed as the app must receive "ready".
import Foundation

@main
struct ConnectionSelfTest {
    static func main() {
        guard CommandLine.arguments.count == 3,
              ["allow", "deny"].contains(CommandLine.arguments[1]) else {
            print("Usage: connection-selftest allow|deny TEAM_ID"); exit(2)
        }
        let allow = CommandLine.arguments[1] == "allow"
        let team = CommandLine.arguments[2]
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { exit(2) }
        let name = "local.glance.ir-lab.camera-helper"
        let connection = NSXPCConnection(machServiceName: name, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: InfraredServiceProtocol.self)
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"\(name)\" and certificate leaf[subject.OU] = \"\(team)\"")
        let lock = NSLock()
        var finished = false
        func finish(_ accepted: Bool) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            lock.unlock()
            let passed = accepted == allow
            print(passed ? "XPC connection authorization passed (\(allow ? "trusted" : "untrusted") client)." : "XPC connection authorization FAILED.")
            exit(passed ? 0 : 1)
        }
        connection.invalidationHandler = { finish(false) }
        connection.interruptionHandler = { finish(false) }
        connection.resume()
        let remote = connection.remoteObjectProxyWithErrorHandler { _ in finish(false) } as? InfraredServiceProtocol
        remote?.ping { finish($0 == "ready") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            print("XPC authorization test timed out; result is inconclusive."); exit(2)
        }
        RunLoop.current.run()
    }
}
