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

    /// Actual scope: the exact window or the session-approved display, never implied wider sharing.
    private var sharingScope: String {
        guard let target = controller.currentTarget else { return "Nothing shared" }
        let paused = controller.task?.grant?.paused == true ? " · paused" : ""
        if let display = target.displayIdentifier { return "Sharing: display \(display) for this session" + paused }
        return "Sharing: " + target.applicationName + " window only" + paused
    }

    private static func symbol(_ completion: GuideCompletion) -> String {
        switch completion { case .verified: return "✓ "; case .manuallyAcknowledged: return "○ "; case .satisfied: return "◇ " }
    }

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
            if let index = controller.task?.historyIndex {
                Button("Return to current") { controller.returnToCurrent() }.islandButton(.primary).disabled(controller.isBusy)
                Button("Back") { controller.back() }.islandButton(.secondary).disabled(index == 0 || controller.isBusy)
                Button("Forward") { controller.forward() }.islandButton(.secondary).disabled(controller.isBusy)
            } else if controller.proposal != nil {
                Button("Start new task") { controller.acceptProposal() }.islandButton(.primary).disabled(controller.isBusy)
                Button("Keep current task") { controller.keepTask() }.islandButton(.secondary)
            } else if controller.task?.phase == .completed || controller.demo?.completed == true {
                Text("Finished").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
            } else if controller.task?.phase == .paused, controller.task?.interruptions.allSatisfy(\.isTemporary) == true {
                // Temporary holds continue by themselves after fresh validation; Resume stays as a manual option.
                Text("Continues automatically").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                Button("Resume") { controller.resume() }.islandButton(.secondary).disabled(!available.resume)
            } else if controller.task?.phase == .paused || controller.demo?.paused == true {
                Button("Resume") { controller.resume() }.islandButton(.primary).disabled(!available.resume && controller.demo == nil)
            } else if controller.correcting {
                Text("Click the control Clicky should use · Esc cancels").font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
                Button("Cancel") { controller.cancelCorrection() }.islandButton(.secondary)
            } else if uncertain {
                // Re-check is the primary recovery; manual acknowledgement is explicit and stays unverified.
                Button("Re-check") { controller.checkNow() }.islandButton(.primary).disabled(!available.recheck)
                Button("Mark done") { controller.nextManually() }.islandButton(.secondary).disabled(!available.next)
                    .accessibilityLabel("Mark done manually, not verified")
                Button("Find again") { controller.retry() }.islandButton(.secondary).disabled(!available.retry)
                    .accessibilityLabel("Locate the control again")
                Button("Wrong target") { controller.beginCorrection() }.islandButton(.secondary).disabled(!available.recheck)
            } else {
                // The normal interaction is with the application; no routine Next here.
                Button("Pause") { controller.pause() }.islandButton(.secondary).disabled(!available.pause && controller.demo == nil)
                if controller.demo != nil {
                    Button("Next") { controller.nextManually() }.islandButton(.secondary)
                } else {
                    Button("Wrong target") { controller.beginCorrection() }.islandButton(.secondary)
                        .disabled(controller.isBusy || controller.task?.phase != .waiting)
                    Button("Back") { controller.back() }.islandButton(.secondary)
                        .disabled(controller.isBusy || controller.task?.milestones.isEmpty != false)
                }
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
                Text(sharingScope)
                if let sent = controller.lastSent {
                    Text("Last sent to \(controller.provider.displayName): " + sent.formatted(date: .omitted, time: .standard))
                }
                ForEach(controller.task?.milestones ?? []) { milestone in
                    Text(Self.symbol(milestone.completion) + milestone.instruction)
                }
                ForEach(controller.task?.plan.items.filter { $0.status == .current || $0.status == .upcoming } ?? []) { item in
                    Text((item.status == .current ? "▸ " : "· ") + item.intent).foregroundStyle(DS.Colors.textTertiary)
                }
                Text("✓ verified · ○ marked done, not verified · ◇ already satisfied. Upcoming steps are an approximate route.")
                    .foregroundStyle(DS.Colors.textTertiary)
                HStack(spacing: 6) {
                    // Revocation stays available while busy; it pauses the grant and invalidates pending work.
                    Button("Stop sharing") { controller.stopSharing() }.islandButton(.secondary)
                        .disabled(controller.task?.grant == nil || controller.task?.grant?.paused == true)
                    Button("Change window") { controller.chooseTarget() }.islandButton(.secondary).disabled(controller.isBusy)
                    Button("Finished manually") { controller.finishManually() }.islandButton(.secondary).disabled(controller.isBusy)
                }
            }
        }
        .font(.system(size: 11)).foregroundStyle(DS.Colors.textSecondary)
    }
}
