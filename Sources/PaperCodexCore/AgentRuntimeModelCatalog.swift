import Foundation

public enum AgentRuntimeModelCatalog {
    public static func modelIDs(
        profile: AgentRuntimeProfile,
        stdout: String,
        stderr: String = ""
    ) -> [String] {
        switch profile.backend {
        case .openClawKimi:
            return openClawModelIDs(from: stdout)
        case .pi:
            return plainTextModelIDs(from: stdout)
        default:
            return []
        }
    }

    private static func openClawModelIDs(from text: String) -> [String] {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        var candidates: [String] = []
        appendString(root["defaultModel"], to: &candidates)
        appendStrings(root["allowed"], to: &candidates)
        if let aliases = root["aliases"] as? [String: Any] {
            for key in aliases.keys.sorted() {
                appendString(aliases[key], to: &candidates)
            }
        }
        return orderedUniqueModelIDs(candidates)
    }

    private static func plainTextModelIDs(from text: String) -> [String] {
        let candidates = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        return orderedUniqueModelIDs(candidates)
    }

    private static func appendString(_ value: Any?, to candidates: inout [String]) {
        guard let value = value as? String else {
            return
        }
        candidates.append(value)
    }

    private static func appendStrings(_ value: Any?, to candidates: inout [String]) {
        guard let values = value as? [String] else {
            return
        }
        candidates.append(contentsOf: values)
    }

    private static func orderedUniqueModelIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isSelectableModelID(trimmed), !seen.contains(trimmed) else {
                continue
            }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private static func isSelectableModelID(_ value: String) -> Bool {
        guard !value.isEmpty else {
            return false
        }
        let allowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/:")
        return value.unicodeScalars.allSatisfy { allowedScalars.contains($0) }
    }
}
