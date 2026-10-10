import Combine
import AppKit
import SwiftUI

/// State shared by the Lab tabs. Everything lives in memory; closing the Clicky window cancels recording and running jobs.
@MainActor
final class LocalAILabModel: ObservableObject {
    let runtime: LocalAIRuntime
    let results = LabResults()
    lazy var text = LabTextModel(runtime: runtime, results: results)
    lazy var vision = LabVisionModel(runtime: runtime, results: results)
    lazy var speech = LabSpeechModel(runtime: runtime, results: results)

    init(runtime: LocalAIRuntime) { self.runtime = runtime }

    func windowClosed() {
        speech.cancelRecording()
        text.cancel(); vision.cancel(); speech.cancelProcessing()
    }
}
