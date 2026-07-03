import Combine
import Foundation
import PaperCodexCore

private let selectedChatRuntimeDefaultsKey = "PaperCodexSelectedChatRuntimeID"
private let selectedEnrichmentRuntimeDefaultsKey = "PaperCodexSelectedEnrichmentRuntimeID"
private let enabledRuntimeIDsDefaultsKey = "PaperCodexEnabledAgentRuntimeIDs"
private let runtimeModelOverridesDefaultsKey = "PaperCodexAgentRuntimeModelOverrides"
private let runtimeProviderOverridesDefaultsKey = "PaperCodexAgentRuntimeProviderOverrides"
private let runtimeMCPModesDefaultsKey = "PaperCodexAgentRuntimeMCPModes"

enum AgentRuntimeDiagnosticState: String, Codable, Equatable, Sendable {
    case checking
    case ready
    case warning
    case blocked

    init(_ codexSeverity: CodexDiagnosticSeverity) {
        switch codexSeverity {
        case .ready:
            self = .ready
        case .warning:
            self = .warning
        case .blocked:
            self = .blocked
        }
    }
}

struct AgentRuntimeDiagnostic: Equatable, Sendable {
    var runtimeID: String
    var state: AgentRuntimeDiagnosticState
    var title: String
    var detail: String
    var executablePath: String?
    var version: String?
}

@MainActor
final class AgentRuntimeStore: ObservableObject {
    @Published private(set) var profiles: [AgentRuntimeProfile]
    @Published private(set) var selectedChatRuntimeID: String
    @Published private(set) var selectedEnrichmentRuntimeID: String
    @Published private(set) var enabledRuntimeIDs: Set<String>
    @Published private(set) var modelOverridesByRuntimeID: [String: String]
    @Published private(set) var providerOverridesByRuntimeID: [String: String]
    @Published private(set) var mcpModesByRuntimeID: [String: AgentRuntimeMCPMode]
    @Published private(set) var diagnosticsByRuntimeID: [String: AgentRuntimeDiagnostic] = [:]
    @Published private(set) var authSummariesByRuntimeID: [String: String] = [:]
    @Published private(set) var availableModelIDsByRuntimeID: [String: [String]] = [:]
    @Published private(set) var isRefreshingDiagnostics = false
    let profileConfigURL: URL?
    let profileLoadWarning: String?

    private let userDefaults: UserDefaults

    init(
        profiles: [AgentRuntimeProfile] = AgentRuntimeProfile.defaultProfiles,
        profileConfigURL: URL? = nil,
        profileLoadWarning: String? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.profiles = profiles
        self.profileConfigURL = profileConfigURL
        self.profileLoadWarning = profileLoadWarning
        self.userDefaults = userDefaults
        let validIDs = Set(profiles.map(\.id))
        selectedChatRuntimeID = Self.validRuntimeID(
            userDefaults.string(forKey: selectedChatRuntimeDefaultsKey),
            validIDs: validIDs,
            fallback: "codex"
        )
        selectedEnrichmentRuntimeID = Self.validRuntimeID(
            userDefaults.string(forKey: selectedEnrichmentRuntimeDefaultsKey),
            validIDs: validIDs,
            fallback: "codex"
        )
        let storedEnabled = Set(userDefaults.stringArray(forKey: enabledRuntimeIDsDefaultsKey) ?? [])
        enabledRuntimeIDs = storedEnabled.isEmpty ? ["codex"] : storedEnabled.intersection(validIDs).union(["codex"])
        modelOverridesByRuntimeID = Self.loadStringDictionary(from: userDefaults, key: runtimeModelOverridesDefaultsKey, validIDs: validIDs)
        providerOverridesByRuntimeID = Self.loadStringDictionary(from: userDefaults, key: runtimeProviderOverridesDefaultsKey, validIDs: validIDs)
        mcpModesByRuntimeID = Self.loadMCPModes(from: userDefaults, profiles: profiles)
    }

    var selectedChatRuntime: AgentRuntimeProfile {
        profile(id: selectedChatRuntimeID) ?? profiles[0]
    }

    var selectedEnrichmentRuntime: AgentRuntimeProfile {
        profile(id: selectedEnrichmentRuntimeID) ?? profiles[0]
    }

    func profile(id: String) -> AgentRuntimeProfile? {
        profiles.first { $0.id == id }
    }

    func isRuntimeEnabled(_ runtimeID: String) -> Bool {
        enabledRuntimeIDs.contains(runtimeID)
    }

    func modelOverride(for runtimeID: String) -> String {
        modelOverridesByRuntimeID[runtimeID] ?? ""
    }

    func availableModelIDs(for runtimeID: String) -> [String] {
        availableModelIDsByRuntimeID[runtimeID] ?? []
    }

    func providerOverride(for runtimeID: String) -> String {
        providerOverridesByRuntimeID[runtimeID] ?? ""
    }

    func mcpMode(for runtimeID: String) -> AgentRuntimeMCPMode {
        if let mode = mcpModesByRuntimeID[runtimeID] {
            return mode
        }
        return profile(id: runtimeID)?.mcpMode ?? .workspaceOnly
    }

    func setSelectedChatRuntimeID(_ runtimeID: String) {
        guard profile(id: runtimeID) != nil else {
            return
        }
        selectedChatRuntimeID = runtimeID
        enabledRuntimeIDs.insert(runtimeID)
        userDefaults.set(runtimeID, forKey: selectedChatRuntimeDefaultsKey)
        saveEnabledRuntimeIDs()
    }

    func setSelectedEnrichmentRuntimeID(_ runtimeID: String) {
        guard profile(id: runtimeID) != nil else {
            return
        }
        selectedEnrichmentRuntimeID = runtimeID
        enabledRuntimeIDs.insert(runtimeID)
        userDefaults.set(runtimeID, forKey: selectedEnrichmentRuntimeDefaultsKey)
        saveEnabledRuntimeIDs()
    }

    func setRuntimeEnabled(_ runtimeID: String, enabled: Bool) {
        guard profile(id: runtimeID) != nil else {
            return
        }
        if enabled {
            enabledRuntimeIDs.insert(runtimeID)
        } else if runtimeID != "codex" {
            enabledRuntimeIDs.remove(runtimeID)
        }
        if !enabledRuntimeIDs.contains(selectedChatRuntimeID) {
            setSelectedChatRuntimeID("codex")
        }
        if !enabledRuntimeIDs.contains(selectedEnrichmentRuntimeID) {
            setSelectedEnrichmentRuntimeID("codex")
        }
        saveEnabledRuntimeIDs()
    }

    func setModelOverride(_ model: String, for runtimeID: String) {
        setTrimmedString(model, runtimeID: runtimeID, values: &modelOverridesByRuntimeID, key: runtimeModelOverridesDefaultsKey)
    }

    func setProviderOverride(_ provider: String, for runtimeID: String) {
        setTrimmedString(provider, runtimeID: runtimeID, values: &providerOverridesByRuntimeID, key: runtimeProviderOverridesDefaultsKey)
    }

    func setMCPMode(_ mode: AgentRuntimeMCPMode, for runtimeID: String) {
        guard profile(id: runtimeID) != nil else {
            return
        }
        mcpModesByRuntimeID[runtimeID] = mode
        let encoded = mcpModesByRuntimeID.mapValues(\.rawValue)
        userDefaults.set(encoded, forKey: runtimeMCPModesDefaultsKey)
    }

    func refreshDiagnostics() async {
        guard !isRefreshingDiagnostics else {
            return
        }
        isRefreshingDiagnostics = true
        let profilesSnapshot = profiles
        let results = await Task.detached(priority: .utility) {
            profilesSnapshot.map { profile in
                diagnose(profile)
            }
        }.value
        diagnosticsByRuntimeID = Dictionary(uniqueKeysWithValues: results.map { ($0.profileID, $0.diagnostic) })
        authSummariesByRuntimeID = Dictionary(uniqueKeysWithValues: results.map { ($0.profileID, $0.authSummary) })
        availableModelIDsByRuntimeID = Dictionary(uniqueKeysWithValues: results.map { ($0.profileID, $0.modelIDs) })
        isRefreshingDiagnostics = false
    }

    private func setTrimmedString(_ value: String, runtimeID: String, values: inout [String: String], key: String) {
        guard profile(id: runtimeID) != nil else {
            return
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            values.removeValue(forKey: runtimeID)
        } else {
            values[runtimeID] = trimmed
        }
        userDefaults.set(values, forKey: key)
    }

    private func saveEnabledRuntimeIDs() {
        userDefaults.set(Array(enabledRuntimeIDs).sorted(), forKey: enabledRuntimeIDsDefaultsKey)
    }

    private static func validRuntimeID(_ storedID: String?, validIDs: Set<String>, fallback: String) -> String {
        guard let storedID, validIDs.contains(storedID) else {
            return fallback
        }
        return storedID
    }

    private static func loadStringDictionary(from userDefaults: UserDefaults, key: String, validIDs: Set<String>) -> [String: String] {
        let raw = userDefaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return raw.filter { validIDs.contains($0.key) && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func loadMCPModes(from userDefaults: UserDefaults, profiles: [AgentRuntimeProfile]) -> [String: AgentRuntimeMCPMode] {
        let raw = userDefaults.dictionary(forKey: runtimeMCPModesDefaultsKey) as? [String: String] ?? [:]
        let profilesByID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        var modes: [String: AgentRuntimeMCPMode] = [:]
        for profile in profiles {
            modes[profile.id] = raw[profile.id].flatMap(AgentRuntimeMCPMode.init(rawValue:)) ?? profile.mcpMode
        }
        return modes.filter { profilesByID[$0.key] != nil }
    }
}

private struct AgentRuntimeCommandOutput: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

private func diagnose(_ profile: AgentRuntimeProfile) -> (profileID: String, diagnostic: AgentRuntimeDiagnostic, authSummary: String, modelIDs: [String]) {
    do {
        let executablePath = try findExecutable(for: profile)
        let versionOutput = runSafeCommand(executablePath: executablePath, arguments: versionArguments(for: profile))
        let version = firstNonEmptyLine(versionOutput.stdout) ?? firstNonEmptyLine(versionOutput.stderr)
        let authOutput = runSafeCommand(executablePath: executablePath, arguments: safeAuthStatusArguments(for: profile))
        let authSummary = authSummaryText(profile: profile, output: authOutput)
        let modelIDs = AgentRuntimeModelCatalog.modelIDs(
            profile: profile,
            stdout: authOutput.stdout,
            stderr: authOutput.stderr
        )
        let diagnostic = AgentRuntimeDiagnostic(
            runtimeID: profile.id,
            state: versionOutput.status == 0 ? .ready : .warning,
            title: versionOutput.status == 0 ? "\(profile.displayName) ready" : "\(profile.displayName) found",
            detail: executablePath,
            executablePath: executablePath,
            version: version
        )
        return (profile.id, diagnostic, authSummary, modelIDs)
    } catch {
        let diagnostic = AgentRuntimeDiagnostic(
            runtimeID: profile.id,
            state: .blocked,
            title: "\(profile.displayName) unavailable",
            detail: String(describing: error),
            executablePath: nil,
            version: nil
        )
        return (profile.id, diagnostic, "Auth not checked", [])
    }
}

private func findExecutable(for profile: AgentRuntimeProfile) throws -> String {
    switch profile.backend {
    case .codex:
        return try CodexRuntimeAdapter.findExecutable()
    case .claudeCode:
        return try ClaudeCodeRuntimeAdapter.findExecutable()
    case .acp:
        return try ACPAgentRuntimeAdapter.findExecutable(for: profile)
    case .hermes:
        return try HermesRuntimeAdapter.findExecutable()
    case .kimiCLI:
        return try KimiRuntimeAdapter.findExecutable()
    case .openClawKimi:
        return try OpenClawRuntimeAdapter.findExecutable()
    case .pi:
        return try PiRuntimeAdapter.findExecutable()
    }
}

private func versionArguments(for profile: AgentRuntimeProfile) -> [String] {
    switch profile.backend {
    case .kimiCLI:
        return ["--version"]
    case .acp:
        return ["--version"]
    case .openClawKimi:
        return ["--version"]
    default:
        return ["--version"]
    }
}

private func safeAuthStatusArguments(for profile: AgentRuntimeProfile) -> [String] {
    switch profile.backend {
    case .codex:
        return ["mcp", "list"]
    case .claudeCode:
        return ["auth", "status"]
    case .acp:
        return profile.id == "kimi-acp" ? ["doctor"] : ["--version"]
    case .hermes:
        return ["status"]
    case .kimiCLI:
        return ["doctor"]
    case .openClawKimi:
        return ["models", "status", "--json"]
    case .pi:
        return ["--list-models"]
    }
}

private func runSafeCommand(executablePath: String, arguments: [String], timeoutSeconds: Double = 4) -> AgentRuntimeCommandOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.environment = AgentRuntimeEnvironment.sanitizedProcessEnvironment(
        workingDirectoryURL: FileManager.default.temporaryDirectory,
        executablePath: executablePath
    )

    let output = Pipe()
    let error = Pipe()
    process.standardOutput = output
    process.standardError = error
    let semaphore = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in
        semaphore.signal()
    }

    do {
        try process.run()
    } catch {
        return AgentRuntimeCommandOutput(status: -1, stdout: "", stderr: String(describing: error))
    }

    let timeout = DispatchTimeInterval.milliseconds(Int(timeoutSeconds * 1_000))
    let timedOut = semaphore.wait(timeout: .now() + timeout) == .timedOut
    if timedOut {
        process.terminate()
        process.waitUntilExit()
    }

    let stderr = String(decoding: error.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return AgentRuntimeCommandOutput(
        status: timedOut ? -2 : process.terminationStatus,
        stdout: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
        stderr: timedOut ? "\(stderr)\nCommand timed out." : stderr
    )
}

private func authSummaryText(profile: AgentRuntimeProfile, output: AgentRuntimeCommandOutput) -> String {
    let line = firstNonEmptyLine(output.stdout) ?? firstNonEmptyLine(output.stderr)
    guard let line else {
        return output.status == 0 ? "Auth command completed" : "Auth command returned \(output.status)"
    }
    return output.status == 0 ? line : "\(profile.displayName): \(line)"
}

private func firstNonEmptyLine(_ text: String) -> String? {
    text.split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}
