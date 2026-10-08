import Foundation

nonisolated public enum GuideLoginEvent: Sendable { case authorizationURL(URL), completed }
nonisolated public enum GuideCodexLogin {
    public static func signIn(executable: URL, profile: GuideAgentProfile) -> AsyncThrowingStream<GuideLoginEvent, Error> {
        AsyncThrowingStream { continuation in
            let cancellation = AgentProcessCancellation()
            let task = Task.detached {
                var process: AgentProcess?
                do {
                    try profile.validate(executable: executable)
                    let child = try AgentProcess(executable: executable, arguments: profile.arguments,
                                                 workingDirectory: profile.workingDirectory.path, environment: profile.environment,
                                                 onExit: { profile.removeTaskFiles() })
                    cancellation.install(child)
                    defer { child.stop() }
                    let stream = try child.start()
                    process = child
                    try child.send(AgentProtocol.rpc(identifier: 1, method: "initialize", params: .object([
                        "clientInfo": .object(["name": .string("clicky"), "version": .string("0.2.0")])
                    ])))
                    for try await message in stream {
                        try Task.checkCancellation()
                        if message["error"] != .null { throw AskError.authenticationRequired }
                        if message["id"].integer == 1 {
                            try child.send(.object(["method": .string("initialized")]))
                            try child.send(AgentProtocol.rpc(identifier: 2, method: "account/login/start", params: .object(["type": .string("chatgpt")])))
                        } else if message["id"].integer == 2 {
                            guard let text = message["result"]["authUrl"].string, let url = URL(string: text),
                                  url.scheme == "https", url.host == "auth.openai.com" else { throw AskError.authenticationRequired }
                            continuation.yield(.authorizationURL(url))
                        } else if message["method"].string == "account/login/completed" {
                            guard message["params"]["success"].bool else { throw AskError.authenticationRequired }
                            continuation.yield(.completed); continuation.finish(); return
                        }
                    }
                    throw AskError.incompleteTurn
                } catch {
                    if let process { process.stop() } else { profile.removeTaskFiles() }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel(); cancellation.cancel() }
        }
    }
}
