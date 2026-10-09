import SwiftUI

/// Guide controls shown when the island expands for a walkthrough: one question or instruction,
/// the primary action first, and progress/sharing details on demand.
struct IslandGuideControls: View {
    @ObservedObject var controller: VisualGuideController
    let onCollapse: (() -> Void)?
    /// False when an IslandStepCard above already shows the instruction and status.
    var showsHeadline = true
    @State private var detailsShown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(controller.demo == nil ? "Clicky guide" : "Guide demo · no AI")
                    .font(.system(size: 11)).foregroundStyle(DS.Colors.textTertiary)
                Spacer()
                Button(detailsShown ? "Less" : "Details") { detailsShown.toggle() }.islandButton(.quiet)
                if let onCollapse { Button("Hide", action: onCollapse).islandButton(.quiet) }
            }
            if showsHeadline {
                Text(headline)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if showsHeadline && !uncertain {
                HStack(spacing: 6) {
                    if controller.isBusy { SpinnerRing(size: 8) }
                    Text(controller.status).font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                }
            }
            if let error = controller.error {
                Text(error).font(.system(size: 11)).foregroundStyle(DS.Colors.warningText).lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actions
            if detailsShown { details }
        }
    }

    private var uncertain: Bool { controller.task?.phase == .uncertain }

    private var headline: String {
        if uncertain { return controller.task?.step?.outcome?.description.isEmpty == false
            ? "Did this happen: \(controller.task?.step?.outcome?.description ?? "")?" : controller.status }
        return controller.demo?.instruction ?? controller.task?.step?.text ?? controller.task?.goal ?? ""
    }

    private var available: GuideControlAvailability {
        GuideControlAvailability(phase: controller.task?.phase, isBusy: controller.isBusy,
                                 hasStep: controller.task?.step != nil, demo: controller.demo != nil)
    }

    /// Only conflicting turn-starting actions disable while busy; End and Pause stay operable in every phase.
    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if controller.proposal != nil {
                Button("Start new task") { controller.acceptProposal() }.islandButton(.primary).disabled(controller.isBusy)
                Button("Keep current task") { controller.keepTask() }.islandButton(.secondary)
            } else if controller.task?.phase == .completed || controller.demo?.completed == true {
                Text("Finished").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            } else if controller.task?.phase == .paused || controller.demo?.paused == true {
                Button("Resume") { controller.resume() }.islandButton(.primary).disabled(!available.resume && controller.demo == nil)
            } else if uncertain {
                // The only state that asks: Next is the default so one keystroke unblocks.
                Button("Next ⌥⇧→") { controller.nextManually() }.islandButton(.warning).accessibilityLabel("Next")
                    .disabled(!available.next)
                Button("Re-check") { controller.checkNow() }.islandButton(.secondary).disabled(!available.recheck)
                Button("Retry") { controller.retry() }.islandButton(.secondary).disabled(!available.retry)
            } else {
                Button("Next") { controller.nextManually() }.islandButton(.secondary).disabled(!available.next)
                Button("Retry") { controller.retry() }.islandButton(.secondary).disabled(!available.retry)
                Button("Pause") { controller.pause() }.islandButton(.secondary).disabled(!available.pause && controller.demo == nil)
            }
            Spacer(minLength: 0)
            Button("End") { controller.endTask() }.islandButton(.quiet)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let demo = controller.demo {
                Text("Deterministic fixture. No capture, provider request, or outcome verification.")
                ForEach(Array(GuidePreviewFixture.instructions.enumerated()), id: \.offset) { index, instruction in
                    Text((index < demo.index ? "○ " : "· ") + instruction)
                }
            } else {
                Text(controller.currentTarget.map { "Sharing: " + $0.applicationName + " window" } ?? "No window shared")
                ForEach(controller.task?.milestones ?? []) { milestone in
                    Text((milestone.completion == .verified ? "✓ " : "○ ") + milestone.instruction)
                }
                Text("○ means you moved on with Next; it was not verified.").foregroundStyle(DS.Colors.textTertiary)
                HStack(spacing: 6) {
                    Button("Change window") { controller.chooseTarget() }.islandButton(.secondary)
                    Button("Finished manually") { controller.finishManually() }.islandButton(.secondary)
                }
                .disabled(controller.isBusy)
            }
        }
        .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
    }
}
