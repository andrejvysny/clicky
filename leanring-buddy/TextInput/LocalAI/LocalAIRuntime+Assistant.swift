import Foundation
#if canImport(ClickyCore)
import ClickyCore
#endif

extension LocalAIRuntime {
    /// How long an assistant turn waits for a running Lab or assistant job before reporting busy.
    static let assistantSlotWait: TimeInterval = 5

    /// The on-device backend for Quick Ask, walkthroughs and writing: the selected vision model on the inference
    /// worker. It honours the vision group's load policy (Manual asks the user to load it first) and never falls
    /// back to another provider.
    nonisolated static let assistantClient: LocalInferenceClient = { request in
        try await LocalAIRuntime.runAssistant(request)
    }

    static func runAssistant(_ request: LocalInferenceRequest) async throws -> String {
        guard let runtime = shared else { throw LocalAIError.workerMissing }
        guard runtime.installedModel(.vision) != nil else { throw LocalAIError.notInstalled(runtime.displayName(.vision)) }
        try await runtime.ensureReady(.vision, explicitRun: false)
        var final: String?
        for try await event in runtime.generate(group: .vision, messages: request.messages, imagePNG: request.image,
                                                parameters: request.parameters, slotWait: assistantSlotWait) {
            if case .completed(_, _, let text, _) = event { final = text }
        }
        try Task.checkCancellation()
        guard let final else { throw LocalWorkerError(.internalError, "The local worker ended the request without a result.") }
        return final
    }
}
