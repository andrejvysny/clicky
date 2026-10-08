import ClickyCore
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@main
struct ClickyGuideCLI {
    static func main() async {
        do {
            let options = Array(CommandLine.arguments.dropFirst())
            guard options.count == 3, let provider = AgentProvider(rawValue: options[0]), provider != .preview else {
                throw AskError.protocolFailure("Usage: clicky-guide claude|codex EXECUTABLE CLICKY_PROFILE_ROOT. UTF-8 newline-separated test requests on stdin. Prints presentation kinds only; never saves content.")
            }
            let lines = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                .split(separator: "\n").map(String.init)
            guard !lines.isEmpty, lines.allSatisfy({ $0.utf8.count <= 65_536 }) else { throw AskError.emptyPrompt }
            let profile = try GuideAgentProfile(provider: provider, root: URL(fileURLWithPath: options[2]), taskID: UUID())
            let session = GuideAgentSession(profile: profile, executable: URL(fileURLWithPath: options[1]))
            do {
                for line in lines {
                    let result = try await session.turn(GuideAgentTurn(message: line))
                    print("Validated presentation: " + result.kind.rawValue)
                }
                await session.close()
            } catch { await session.close(); throw error }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
