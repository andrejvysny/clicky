import ClickyCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct ClickyTextCLI {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.contains("--help") {
                print("clicky-text [--provider preview|claude|codex] [--executable PATH] [--directory PATH] [--prompt-file PATH] [--image-file PNG] [--session-file PATH]\nPrompt is read from stdin unless --prompt-file is supplied. An optional PNG (up to 3 MiB) is attached to this turn only. Preview is offline and makes no AI request.")
                return
            }
            var options: [String: String] = [:]
            var index = 0
            let allowed = Set(["--provider", "--executable", "--directory", "--prompt-file", "--image-file", "--session-file"])
            while index < arguments.count {
                guard allowed.contains(arguments[index]), index + 1 < arguments.count else { throw AskError.protocolFailure("Unknown option or missing value. Run clicky-text --help.") }
                options[arguments[index]] = arguments[index + 1]
                index += 2
            }
            guard let provider = AgentProvider(rawValue: options["--provider"] ?? "preview") else { throw AskError.protocolFailure("Unknown provider.") }
            let directory = options["--directory"] ?? FileManager.default.currentDirectoryPath
            let promptData: Data
            if let path = options["--prompt-file"] { promptData = try Data(contentsOf: URL(fileURLWithPath: path)) }
            else { promptData = FileHandle.standardInput.readDataToEndOfFile() }
            guard let text = String(data: promptData, encoding: .utf8) else { throw AskError.protocolFailure("Prompt must be UTF-8.") }
            var session: AgentSession?
            let sessionURL = options["--session-file"].map { URL(fileURLWithPath: $0) }
            if let sessionURL, FileManager.default.fileExists(atPath: sessionURL.path) {
                let data = try Data(contentsOf: sessionURL)
                guard data.count <= 8192 else { throw AskError.protocolFailure("Session metadata is too large.") }
                session = try JSONDecoder().decode(AgentSession.self, from: data)
                guard session?.provider == provider, session?.workingDirectory == directory else { throw AskError.protocolFailure("Saved session belongs to a different provider or project folder.") }
            }
            var image: PNGImageAttachment?
            if let path = options["--image-file"] {
                let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                defer { try? handle.close() }
                let data = try handle.read(upToCount: PNGImageAttachment.maximumBytes + 1) ?? Data()
                image = try PNGImageAttachment(data: data)
            }
            let request = AskRequest(text: text, workingDirectory: directory, session: session, image: image)
            var state = AskInputState()
            _ = try state.begin(text: text, identifier: request.identifier)
            let executable = options["--executable"].map { URL(fileURLWithPath: $0) }
            let runner = ManagedAgentRunner()
            for try await event in runner.stream(provider: provider, executable: executable, request: request) {
                switch event {
                case .textDelta(let delta): FileHandle.standardOutput.write(Data(delta.utf8))
                case .status(let status): FileHandle.standardError.write(Data((status + "\n").utf8))
                case .session(let value):
                    if let sessionURL { try JSONEncoder().encode(value).write(to: sessionURL, options: .atomic) }
                case .completed: FileHandle.standardOutput.write(Data([10]))
                }
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
