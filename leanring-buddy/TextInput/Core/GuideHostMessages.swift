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
            + "\nJudge whether the current capture shows the result of that action. Use unknown only when "
            + "the relevant area is not visible; if it is visible but different, use contradicted."
    }

    public static func next(_ task: GuideTaskState, note: String) -> String {
        context(task) + "\n" + note + " Locate the next useful step or return task_completed if every goal check holds."
    }

    public static func goalCheck(_ checks: [String]) -> String {
        "Final verification. Every stored goal check must hold now in this capture:\n- "
            + checks.joined(separator: "\n- ") + "\nmatches=true only if all hold."
    }
}
