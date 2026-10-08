import Foundation

nonisolated public enum GuideClaudePolicy {
    public static func control(_ subtype: String, identifier: String) -> JSONValue {
        .object(["type": .string("control_request"), "request_id": .string(identifier),
                 "request": .object(["subtype": .string(subtype)])])
    }

    public static func audit(_ result: JSONValue) throws {
        let effective = result["effective"]
        guard case .object = effective, case .array(let sources) = result["sources"],
              effective["autoMemoryEnabled"] == .bool(false), effective["disableAllHooks"] == .bool(true),
              effective["claudeMdExcludes"] == .array([.string("**")]),
              result["errors"] == .null || result["errors"] == .array([]) else { throw incompatible }
        for source in sources {
            guard ["flagSettings", "policySettings", "managedSettings"].contains(source["source"].string ?? "") else { throw incompatible }
            try auditManaged(source["settings"])
        }
    }

    public static func auditManaged(_ settings: JSONValue) throws {
        guard case .object = settings else { throw incompatible }
        for key in ["hooks", "env", "enabledPlugins", "agents", "policyHelper", "apiKeyHelper", "statusLine", "otelHeadersHelper",
                    "systemPrompt", "appendSystemPrompt", "outputStyle", "agent"] {
            let value = settings[key]
            guard value == .null || value == .object([:]) || value == .array([]) || value == .string("") else { throw incompatible }
        }
    }

    private static var incompatible: AskError {
        .protocolFailure("Claude settings or managed policy are incompatible with Clicky's clean guide. Remove custom hooks/instructions from the managed profile, or select another backend.")
    }
}
