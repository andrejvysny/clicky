import SwiftUI

/// Guide controls shown when the island expands for a walkthrough: one question or instruction,
/// the primary action first, and progress/sharing details on demand.
struct IslandGuideControls: View {
    @ObservedObject var controller: VisualGuideController
    let onCollapse: (() -> Void)?
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
            Text(headline)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if !uncertain {
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

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            if controller.needsSharingApproval, let target = controller.currentTarget {
                Button("Share \(target.applicationName) window") { controller.authorizeWindow(target) }.islandButton(.warning)
            } else if controller.needsSharingApproval {
                Button("Choose window") { controller.chooseTarget() }.islandButton(.warning)
            } else if controller.proposal != nil {
                Button("Start new task") { controller.acceptProposal() }.islandButton(.primary)
                Button("Keep current task") { controller.keepTask() }.islandButton(.secondary)
            } else if controller.task?.phase == .completed || controller.demo?.completed == true {
                Text("Finished").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            } else if controller.task?.phase == .paused || controller.demo?.paused == true {
                Button("Resume") { controller.resume() }.islandButton(.primary)
            } else if uncertain {
                // The only state that asks: Next is the default so one keystroke unblocks.
                Button("Next ⌥⇧→") { controller.nextManually() }.islandButton(.warning).accessibilityLabel("Next")
                Button("Re-check") { controller.checkNow() }.islandButton(.secondary)
                Button("Retry") { controller.retry() }.islandButton(.secondary)
            } else {
                Button("Next") { controller.nextManually() }.islandButton(.secondary)
                    .disabled(controller.isBusy || (controller.task?.step == nil && controller.demo == nil))
                Button("Retry") { controller.retry() }.islandButton(.secondary)
                    .disabled(controller.isBusy || controller.demo != nil)
                Button("Pause") { controller.pause() }.islandButton(.secondary)
            }
            Spacer(minLength: 0)
            Button("End") { controller.endTask() }.islandButton(.quiet)
        }
        .disabled(controller.isBusy && !uncertain && controller.proposal == nil && !controller.needsSharingApproval)
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
