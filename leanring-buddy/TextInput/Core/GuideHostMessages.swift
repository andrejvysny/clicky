import Foundation

/// The host's fixed provider messages, shared by the app coordinator and the offline replay harness so a replay
/// measures exactly what the app sends.
nonisolated public enum GuideHostMessages {
    public static func userGoal(_ text: String) -> String { "User goal; choose presentation.\n" + text }

    /// Task goal, completed milestones and the current step, as the provider's recovery context.
    public static func context(_ task: GuideTaskState) -> String {
        var message = "Task: " + task.goal
        if !task.milestones.isEmpty {
            message += "\nCompleted milestones: " + task.milestones.map { $0.instruction + " (" + $0.completion.rawValue + ")" }.joined(separator: "; ")
        }
        // Naming a step only when one exists keeps pointing questions from being read as walkthroughs.
        if let step = task.step { message += "\nCurrent step: " + step.text }
        return message
    }

    public static func requestedContext(_ task: GuideTaskState) -> String { "Requested approved context. " + context(task) }

    /// The instruction gives the verdict its context: the visible result of that action, not a literal match
    /// of the outcome wording. unknown is only for an outcome area that cannot be seen.
    public static func verification(instruction: String, outcome: String) -> String {
        "The user was asked: " + instruction
            + "\nVerify this intended outcome only: " + outcome
            + "\nThe intended outcome is the guide's prediction. Judge whether the current capture shows the result of "
            + "that action: if it shows a different but clearly direct result of this action that moves toward the task "
            + "(new content attributable to it), report confirmed and describe what appeared. Hover or focus highlight, "
            + "unchanged content or an unrelated change are never confirmation; visible loading is pending. Use unknown "
            + "only when the relevant area is not visible; if it is visible but shows no such result, use contradicted."
    }

    /// One look at the current state after the intended outcome was not confirmed. Replay showed that asking the
    /// provider to change the gesture from a no-response screenshot flips correct gestures, so it is not asked to;
    /// a repeated step and gesture is shown uncertain by the host instead.
    public static func recovery(_ task: GuideTaskState, evidence: String) -> String {
        context(task) + "\nThe intended outcome was not confirmed: " + evidence
            + "\nInspect the current state. If the user took another route or is ahead, present the step that continues "
            + "toward the goal from here; if the goal checks already hold, return task_completed. Never claim unseen actions."
    }

    public static func next(_ task: GuideTaskState, note: String) -> String {
        context(task) + "\n" + note + " Locate the next useful step or return task_completed if every goal check holds."
    }

    public static func wrongPurpose(_ wrong: GuideWrongPurpose) -> String {
        "Your previous reply was \(wrong.kind.rawValue), which this \(wrong.purpose.rawValue) turn does not allow. "
            + "Answer the same request again for the same capture, using only allowedKinds: "
            + GuideContract.allowedKinds(for: wrong.purpose).map(\.rawValue).joined(separator: ", ") + "."
    }

    public static func goalCheck(_ checks: [String]) -> String {
        "Final verification. Every stored goal check must hold now in this capture:\n- "
            + checks.joined(separator: "\n- ")
            + "\nA check about an action already taken (something created, opened or clicked) is established by the "
            + "matching host-verified milestone in the task context; every check about a final value, state or result "
            + "must be visible in this capture. matches=true only if all hold."
    }
}
