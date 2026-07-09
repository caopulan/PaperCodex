import AppKit
import Combine
import Foundation
import PaperCodexCore
import SwiftUI

enum AppRoute: Hashable {
    case library
    case discover
    case search
    case settings
    case reader
}

private extension AppRoute {
    var mcpName: String {
        switch self {
        case .library:
            "library"
        case .discover:
            "discover"
        case .search:
            "search"
        case .settings:
            "settings"
        case .reader:
            "reader"
        }
    }
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var route: AppRoute = .library
}

enum LibrarySurface: Equatable {
    case recentConversations
    case papers
}

typealias LibraryCategoryDropPlacement = CategoryMovePlacement

enum ArxivSaveOrganization: String, CaseIterable, Identifiable {
    case primaryCategory = "primary-category"
    case firstTag = "first-tag"
    case date = "date"
    case flat = "flat"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .primaryCategory:
            "Primary category"
        case .firstTag:
            "First tag"
        case .date:
            "Feed date"
        case .flat:
            "Flat library"
        }
    }
}

enum DiscoverProcessAction: String, CaseIterable, Identifiable {
    case embedding
    case translate
    case summarize
    case cachePDFThumbnails = "cache-pdf-thumbnails"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .embedding:
            "Embeddings"
        case .translate:
            "Translate"
        case .summarize:
            "Summarize"
        case .cachePDFThumbnails:
            "Download & Thumbnails"
        }
    }

    var detail: String {
        switch self {
        case .embedding:
            "Generate and cache vectors for the visible results"
        case .translate:
            "Chinese title translation for each result"
        case .summarize:
            "Chinese summary, contribution, tags, and useful links"
        case .cachePDFThumbnails:
            "Cache the PDF and render preview thumbnails"
        }
    }

    var systemImage: String {
        switch self {
        case .embedding:
            "point.3.connected.trianglepath.dotted"
        case .translate:
            "character.book.closed"
        case .summarize:
            "text.alignleft"
        case .cachePDFThumbnails:
            "doc.richtext"
        }
    }
}

struct PDFSelectionInfo: Equatable {
    var text: String
    var page: Int
    var bboxList: [BoundingBox]
}

struct PDFJumpTarget: Equatable {
    var id: String
    var paperID: String
    var page: Int
    var bboxList: [BoundingBox]
    var label: String
}

struct ActiveCodexRun: Identifiable, Equatable {
    var id: String
    var sessionID: String
    var title: String
    var startedAt: Date
    var events: [CodexRunEvent]
}

struct AgentTerminalState: Identifiable, Equatable {
    var id: String
    var sessionID: String
    var runtimeID: String
    var runtimeName: String
    var workspacePath: String
    var logPath: String
    var output: String
    var isRunning: Bool
    var startedAt: Date
    var columns: Int
    var rows: Int
}

struct ArxivCacheProgress: Equatable, Sendable {
    var date: String
    var title: String
    var detail: String
    var completed: Int
    var total: Int

    var fraction: Double? {
        guard total > 0 else {
            return nil
        }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

enum LibraryArxivImportOutcomeState: Equatable {
    case imported
    case alreadyInLibrary
    case failed
}

struct LibraryArxivImportOutcome: Equatable {
    var requestedID: String
    var canonicalID: String
    var title: String
    var state: LibraryArxivImportOutcomeState
    var message: String
    var isRateLimited = false
}

private enum DiscoverPaperProcessingState: Sendable {
    case processed
    case cached
    case failed
    case cancelled
}

private enum EmbeddingProgressDestination {
    case arxivCache
    case discoverProcessing
}

private struct DiscoverPaperProcessingResult: Sendable {
    var paperID: String
    var state: DiscoverPaperProcessingState
    var tokenUsage: CodexTokenUsage? = nil
}

private struct CachedDiscoverSearchHit: Equatable, Sendable {
    var feed: ArxivFeedResponse
    var progressTitle: String
    var cacheRangeFeed: Bool
    var cacheQueryResult: Bool
}

private enum CachedDiscoverSearchLoadResult: Equatable, Sendable {
    case none
    case complete(CachedDiscoverSearchHit)
    case partial(CachedDiscoverSearchHit)

    var didLoad: Bool {
        self != .none
    }

    var isComplete: Bool {
        if case .complete = self {
            return true
        }
        return false
    }

    var hit: CachedDiscoverSearchHit? {
        switch self {
        case .none:
            nil
        case .complete(let hit), .partial(let hit):
            hit
        }
    }
}

private func filteredDiscoverFeed(_ feed: ArxivFeedResponse, keyword: String) -> ArxivFeedResponse {
    let deduplicatedFeed = feed.deduplicatedByCanonicalID(preservingCount: feed.date == "search")
    let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
        return deduplicatedFeed
    }
    let terms = query.lowercased().split(separator: " ").map(String.init)
    let papers = deduplicatedFeed.papers.filter { paper in
        let haystack = [
            paper.id,
            paper.title.en,
            paper.title.zh,
            paper.abstract.en,
            paper.abstract.zh,
            paper.summary.en,
            paper.summary.zh,
            paper.authors.joined(separator: " "),
            paper.categories.joined(separator: " "),
            paper.listCategories.joined(separator: " "),
            paper.tags.joined(separator: " ")
        ]
            .joined(separator: " ")
            .lowercased()
        return terms.allSatisfy { haystack.contains($0) }
    }
    return ArxivFeedResponse(
        date: deduplicatedFeed.date,
        count: papers.count,
        papers: papers,
        groups: deduplicatedFeed.groups,
        tagOptions: deduplicatedFeed.tagOptions,
        sourceCategories: deduplicatedFeed.sourceCategories
    )
    .deduplicatedByCanonicalID()
}

private func loadCachedDiscoverSearchSnapshot(
    query: DiscoverQuery,
    supportRoot: URL,
    allowPartialFragments: Bool = false
) throws -> CachedDiscoverSearchLoadResult {
    let localDiscoverCache = LocalDiscoverCache(root: supportRoot.appendingPathComponent("discover-cache", isDirectory: true))
    let arxivCache = ArxivFeedCache(root: supportRoot.appendingPathComponent("arxiv-cache", isDirectory: true))

    if let queryResult = try localDiscoverCache.loadQueryResult(cacheKey: query.cacheKey),
       let cachedFeed = queryResult.feed,
       !cachedFeed.papers.isEmpty {
        try localDiscoverCache.saveLastQueryResult(queryResult)
        return .complete(CachedDiscoverSearchHit(
            feed: cachedFeed,
            progressTitle: "Cached search",
            cacheRangeFeed: false,
            cacheQueryResult: false
        ))
    }

    if let cachedFeed = try arxivCache.loadFeed(containing: query.dateRange),
       cachedFeed.coversSourceCategories(query.categories) {
        let scopedFeed = cachedFeed.scoped(to: query)
        let filteredFeed = filteredDiscoverFeed(scopedFeed, keyword: query.keyword)
        guard !filteredFeed.papers.isEmpty else {
            return .none
        }
        return .complete(CachedDiscoverSearchHit(
            feed: filteredFeed,
            progressTitle: "Cached search",
            cacheRangeFeed: false,
            cacheQueryResult: true
        ))
    }

    let cachedFragments = try localDiscoverCache.loadQueryResults(containedIn: query)
    guard !cachedFragments.isEmpty else {
        return .none
    }
    let coveredDates = Set(cachedFragments.flatMap { $0.query.dateRange.dates })
    let hasCompleteCoverage = Set(query.dateRange.dates).isSubset(of: coveredDates)
    guard allowPartialFragments || hasCompleteCoverage else {
        return .none
    }
    let fragmentFeed = mergedCachedDiscoverFeed(from: cachedFragments, query: query)
    let filteredFeed = filteredDiscoverFeed(fragmentFeed.scoped(to: query), keyword: query.keyword)
    guard !filteredFeed.papers.isEmpty else {
        return .none
    }
    let hit = CachedDiscoverSearchHit(
        feed: filteredFeed,
        progressTitle: hasCompleteCoverage ? "Cached search" : "Partial cached search",
        cacheRangeFeed: false,
        cacheQueryResult: hasCompleteCoverage
    )
    return hasCompleteCoverage ? .complete(hit) : .partial(hit)
}

private func mergedCachedDiscoverFeed(
    from cachedFragments: [DiscoverQueryResult],
    query: DiscoverQuery
) -> ArxivFeedResponse {
    var papers: [ArxivFeedPaper] = []
    var seenIDs: Set<String> = []
    for result in cachedFragments {
        guard let feed = result.feed else {
            continue
        }
        let fragmentFeed = feed.scoped(to: result.query.normalized)
        for paper in fragmentFeed.papers where !seenIDs.contains(paper.id) {
            seenIDs.insert(paper.id)
            papers.append(paper)
        }
    }
    return ArxivFeedResponse(
        date: query.dateRange.cacheLabel,
        count: papers.count,
        papers: papers,
        sourceCategories: query.categories
    )
    .deduplicatedByCanonicalID()
}

private struct DiscoverSimilarityCategorySource {
    var categoryID: String
    var papers: [Paper]
}

private struct SessionPaperContext {
    var papers: [Paper]
    var pagesByPaperID: [String: [PageIndex]]
    var spansByPaperID: [String: [Span]]
    var anchorsByPaperID: [String: [PaperCodexCore.Anchor]]

    var spans: [Span] {
        papers.flatMap { spansByPaperID[$0.id] ?? [] }
    }
}

private let codexModelOverrideDefaultsKey = "PaperCodexCodexModelOverride"
private let codexReasoningEffortDefaultsKey = "PaperCodexCodexReasoningEffort"
private let codexSystemPromptDefaultsKey = "PaperCodexCodexSystemPrompt"
private let inAppCodexMCPEnabledDefaultsKey = "PaperCodexInAppCodexMCPEnabled"
private let globalLanguageModeDefaultsKey = "PaperCodexGlobalLanguageMode"
private let discoverCodexModelOverrideDefaultsKey = "PaperCodexDiscoverCodexModelOverride"
private let discoverCodexReasoningEffortDefaultsKey = "PaperCodexDiscoverCodexReasoningEffort"
private let discoverCodexConcurrencyDefaultsKey = "PaperCodexDiscoverCodexConcurrency"
private let localDiscoverPreferencesDefaultsKey = "PaperCodexLocalDiscoverPreferences"
private let arxivSaveOrganizationDefaultsKey = "PaperCodexArxivSaveOrganization"
private let quickPromptsDefaultsKey = "PaperCodexQuickPrompts"
private let librarySidebarWidthDefaultsKey = "PaperCodexLibrarySidebarWidth"
private let chatMessageFontSizeDefaultsKey = "PaperCodexChatMessageFontSize"
private let chatComposerFontSizeDefaultsKey = "PaperCodexChatComposerFontSize"
private let chatFontFamilyDefaultsKey = "PaperCodexChatFontFamily"
private let readerTabContentLoadDelayNanoseconds: UInt64 = 60_000_000
private let readerPositionSaveDelayNanoseconds: UInt64 = 750_000_000
private let discoverScrollPositionPaperIDDefaultsKey = "PaperCodexDiscoverScrollPositionPaperID"
private let arxivSearchRequiredCategoriesDefaultsKey = "PaperCodexArxivSearchRequiredCategories"
private let arxivSearchFromYearDefaultsKey = "PaperCodexArxivSearchFromYear"
private let arxivSearchThroughYearDefaultsKey = "PaperCodexArxivSearchThroughYear"
private let defaultDiscoverCodexConcurrency = 10
private let arxivLibraryImportRetryDelaysNanoseconds: [UInt64] = [
    30_000_000_000,
    120_000_000_000,
    300_000_000_000
]

private struct LocalEmbeddingProviderCredentialStore {
    private let apiKeyDefaultsKey = "PaperCodexEmbeddingProviderAPIKey"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = UserDefaults.standard) {
        self.userDefaults = userDefaults
    }

    func loadAPIKey() -> String {
        userDefaults.string(forKey: apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    func saveAPIKey(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            userDefaults.removeObject(forKey: apiKeyDefaultsKey)
        } else {
            userDefaults.set(trimmed, forKey: apiKeyDefaultsKey)
        }
    }
}

private func loadDiscoverCodexConcurrencyFromDefaults() -> Int {
    let stored = UserDefaults.standard.integer(forKey: discoverCodexConcurrencyDefaultsKey)
    return stored == 0 ? defaultDiscoverCodexConcurrency : min(max(stored, 1), 20)
}

private func loadChatMessageFontSizeFromDefaults() -> Double {
    let stored = UserDefaults.standard.double(forKey: chatMessageFontSizeDefaultsKey)
    return stored == 0
        ? ChatAppearanceDefaults.defaultMessageFontSize
        : ChatAppearanceDefaults.clampedMessageFontSize(stored)
}

private func loadChatComposerFontSizeFromDefaults() -> Double {
    let stored = UserDefaults.standard.double(forKey: chatComposerFontSizeDefaultsKey)
    return stored == 0
        ? ChatAppearanceDefaults.defaultComposerFontSize
        : ChatAppearanceDefaults.clampedComposerFontSize(stored)
}

private func loadChatFontFamilyFromDefaults() -> ChatFontFamily {
    let stored = UserDefaults.standard.string(forKey: chatFontFamilyDefaultsKey)
    return stored.flatMap(ChatFontFamily.init(rawValue:)) ?? .system
}

private func loadCodexReasoningEffortFromDefaults(key: String) -> CodexReasoningEffort {
    let stored = UserDefaults.standard.string(forKey: key)
    return stored.flatMap(CodexReasoningEffort.init(rawValue:)) ?? .default
}

private func loadInAppCodexMCPEnabledFromDefaults() -> Bool {
    guard UserDefaults.standard.object(forKey: inAppCodexMCPEnabledDefaultsKey) != nil else {
        return true
    }
    return UserDefaults.standard.bool(forKey: inAppCodexMCPEnabledDefaultsKey)
}

private func loadQuickPromptsFromDefaults() -> [QuickPrompt] {
    guard let data = UserDefaults.standard.data(forKey: quickPromptsDefaultsKey),
          let prompts = try? JSONDecoder().decode([QuickPrompt].self, from: data),
          !prompts.isEmpty else {
        return [
            QuickPrompt(id: "summary", title: "Summary", content: "Summarize the paper's main contribution, method, and evidence."),
            QuickPrompt(id: "limitations", title: "Limitations", content: "Identify the most important limitations, hidden assumptions, and missing experiments."),
            QuickPrompt(id: "related", title: "Related Work", content: "Compare this paper with closely related work and explain what is genuinely new.")
        ]
    }
    return prompts
}

private func saveQuickPromptsToDefaults(_ prompts: [QuickPrompt]) {
    if let data = try? JSONEncoder().encode(prompts) {
        UserDefaults.standard.set(data, forKey: quickPromptsDefaultsKey)
    }
}

private func loadDiscoverScrollPositionPaperIDFromDefaults() -> String? {
    let value = UserDefaults.standard.string(forKey: discoverScrollPositionPaperIDDefaultsKey)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
}

private func loadArxivSearchRequiredCategoriesFromDefaults() -> [String] {
    let stored = UserDefaults.standard.stringArray(forKey: arxivSearchRequiredCategoriesDefaultsKey) ?? []
    let categories = LocalArxivClient.normalizedSearchCategories(stored)
    return categories.isEmpty ? ["cs.CV"] : categories
}

private func loadTrimmedSearchTextFromDefaults(_ key: String) -> String {
    UserDefaults.standard.string(forKey: key)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

private func saveTrimmedSearchTextToDefaults(_ value: String, key: String) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
        UserDefaults.standard.removeObject(forKey: key)
    } else {
        UserDefaults.standard.set(trimmed, forKey: key)
    }
}

private func loadCodexSystemPromptFromDefaults(languageMode: PaperCodexLanguageMode) -> String {
    guard let stored = UserDefaults.standard.string(forKey: codexSystemPromptDefaultsKey),
          !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return PromptBuilder.defaultSystemPrompt(for: languageMode)
    }
    if PromptBuilder.isBuiltInSystemPrompt(stored) {
        UserDefaults.standard.removeObject(forKey: codexSystemPromptDefaultsKey)
        return PromptBuilder.defaultSystemPrompt(for: languageMode)
    }
    return stored
}

private func loadGlobalLanguageModeFromDefaults() -> PaperCodexLanguageMode {
    guard let stored = UserDefaults.standard.string(forKey: globalLanguageModeDefaultsKey),
          let mode = PaperCodexLanguageMode(rawValue: stored) else {
        return .automatic
    }
    return mode
}

private func loadLocalDiscoverPreferencesFromDefaults() -> LocalDiscoverPreferences {
    guard let data = UserDefaults.standard.data(forKey: localDiscoverPreferencesDefaultsKey),
          let preferences = try? JSONDecoder().decode(LocalDiscoverPreferences.self, from: data) else {
        return LocalDiscoverPreferences()
    }
    return preferences.normalized
}

private func saveLocalDiscoverPreferencesToDefaults(_ preferences: LocalDiscoverPreferences) {
    if let data = try? JSONEncoder().encode(preferences.normalized) {
        UserDefaults.standard.set(data, forKey: localDiscoverPreferencesDefaultsKey)
    }
}

private func isCancellationError(_ error: any Error) -> Bool {
    if error is CancellationError {
        return true
    }
    if let urlError = error as? URLError, urlError.code == .cancelled {
        return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

@MainActor
final class AppModel: ObservableObject {
    let navigation = AppNavigation()
    @Published var searchFocusRequestID = UUID()
    @Published var chatComposerFocusRequestID = UUID()

    var route: AppRoute {
        get { navigation.route }
        set { navigation.route = newValue }
    }

    var papers: [Paper] {
        get { libraryStore.papers }
        set { libraryStore.papers = newValue }
    }

    var categories: [PaperCodexCore.Category] {
        get { libraryStore.categories }
        set { libraryStore.categories = newValue }
    }

    var tags: [PaperTag] {
        get { libraryStore.tags }
        set { libraryStore.tags = newValue }
    }

    var watchedFolders: [WatchedFolder] {
        get { libraryStore.watchedFolders }
        set { libraryStore.watchedFolders = newValue }
    }

    var paperCategoryIDsByID: [String: [String]] {
        get { libraryStore.paperCategoryIDsByID }
        set { libraryStore.paperCategoryIDsByID = newValue }
    }

    var paperTagsByID: [String: [PaperTag]] {
        get { libraryStore.paperTagsByID }
        set { libraryStore.paperTagsByID = newValue }
    }

    var libraryDerivedState: PaperLibraryDerivedState {
        get { libraryStore.libraryDerivedState }
        set { libraryStore.libraryDerivedState = newValue }
    }

    var selectedLibraryPaper: Paper? {
        get { libraryStore.selectedLibraryPaper }
        set { libraryStore.selectedLibraryPaper = newValue }
    }

    var selectedLibrarySurface: LibrarySurface {
        get { libraryStore.selectedLibrarySurface }
        set { libraryStore.selectedLibrarySurface = newValue }
    }

    var librarySearchText: String {
        get { libraryStore.librarySearchText }
        set { libraryStore.librarySearchText = newValue }
    }

    var librarySelectedCategoryID: String? {
        get { libraryStore.librarySelectedCategoryID }
        set { libraryStore.librarySelectedCategoryID = newValue }
    }

    var librarySelectedTagID: String? {
        get { libraryStore.librarySelectedTagID }
        set { libraryStore.librarySelectedTagID = newValue }
    }

    func setLibrarySelection(surface: LibrarySurface, categoryID: String?, tagID: String?) {
        libraryStore.setSelection(surface: surface, categoryID: categoryID, tagID: tagID)
    }

    var readerReturnRoute: AppRoute {
        get { readerStore.readerReturnRoute }
        set { readerStore.readerReturnRoute = newValue }
    }

    var selectedPaper: Paper? {
        get { readerStore.selectedPaper }
        set { readerStore.selectedPaper = newValue }
    }

    var readerTabState: ReaderTabState {
        get { readerStore.readerTabState }
        set { readerStore.readerTabState = newValue }
    }

    var isReaderTabContentLoading: Bool {
        guard route == .reader,
              let activePaperID = readerTabState.activePaperID else {
            return false
        }
        return selectedPaper?.id != activePaperID
    }

    var activeReaderTabTitle: String {
        guard let activePaperID = readerTabState.activePaperID else {
            return "Paper"
        }
        if let tab = readerTabState.tabs.first(where: { $0.paperID == activePaperID }) {
            return tab.title
        }
        return selectedPaper?.title ?? "Paper"
    }

    var selectedSession: PaperSession? {
        get { readerStore.selectedSession }
        set { readerStore.selectedSession = newValue }
    }

    var sessions: [PaperSession] {
        get { readerStore.sessions }
        set { readerStore.sessions = newValue }
    }

    var recentSessions: [PaperSession] {
        get { readerStore.recentSessions }
        set { readerStore.recentSessions = newValue }
    }

    var recentSessionPapersByID: [String: [Paper]] {
        get { readerStore.recentSessionPapersByID }
        set { readerStore.recentSessionPapersByID = newValue }
    }

    var selectedSessionPanelTab: SessionPanelTab {
        get { readerStore.selectedSessionPanelTab }
        set { readerStore.selectedSessionPanelTab = newValue }
    }

    var messages: [ChatMessage] {
        get { readerStore.messages }
        set { readerStore.messages = newValue }
    }

    var currentSelection: PDFSelectionInfo? {
        get { readerStore.currentSelection }
        set { readerStore.currentSelection = newValue }
    }

    var pdfJumpTarget: PDFJumpTarget? {
        get { readerStore.pdfJumpTarget }
        set { readerStore.pdfJumpTarget = newValue }
    }

    var readerPosition: PaperReaderPosition? {
        get { readerStore.readerPosition }
        set { readerStore.readerPosition = newValue }
    }
    @Published var codexDiagnostic: CodexDiagnostic?
    @Published var codexModelOverride: String = UserDefaults.standard.string(forKey: codexModelOverrideDefaultsKey) ?? ""
    @Published var codexReasoningEffort: CodexReasoningEffort = loadCodexReasoningEffortFromDefaults(key: codexReasoningEffortDefaultsKey)
    @Published var codexSystemPrompt: String = PromptBuilder.defaultSystemPrompt
    @Published var inAppCodexMCPEnabled: Bool = loadInAppCodexMCPEnabledFromDefaults()
    @Published var codexPluginInstallationStatus: CodexPluginInstallationStatus?
    @Published var isInstallingCodexPlugin = false
    @Published var globalLanguageMode: PaperCodexLanguageMode = .automatic
    @Published var activeCodexRunsBySessionID: [String: ActiveCodexRun] = [:]
    @Published var agentTerminalState: AgentTerminalState?
    @Published var errorMessage: String?
    @Published var notices: [InteractionNotice] = []
    @Published var discoverCodexModelOverride: String = UserDefaults.standard.string(forKey: discoverCodexModelOverrideDefaultsKey) ?? ""
    @Published var discoverCodexReasoningEffort: CodexReasoningEffort = loadCodexReasoningEffortFromDefaults(key: discoverCodexReasoningEffortDefaultsKey)
    @Published var discoverCodexConcurrency: Int = loadDiscoverCodexConcurrencyFromDefaults()
    @Published var availableCodexModelIDs: [String] = CodexCLI.fallbackAvailableModelIDs(
        configuredModelID: CodexCLI.configuredDefaultModelID()
    )
    @Published var codexDefaultModelID: String = CodexCLI.configuredDefaultModelID() ?? ""
    @Published var isRefreshingCodexModels = false
    @Published var isScanningWatchedFolders = false
    @Published var localDiscoverPreferences: LocalDiscoverPreferences = loadLocalDiscoverPreferencesFromDefaults()
    @Published var arxivSaveOrganization: ArxivSaveOrganization = {
        let stored = UserDefaults.standard.string(forKey: arxivSaveOrganizationDefaultsKey)
        return stored.flatMap(ArxivSaveOrganization.init(rawValue:)) ?? .primaryCategory
    }()
    @Published var quickPrompts: [QuickPrompt] = loadQuickPromptsFromDefaults()
    var arxivDates: [String] {
        get { discoverStore.arxivDates }
        set { discoverStore.arxivDates = newValue }
    }

    var selectedArxivDate: String? {
        get { discoverStore.selectedArxivDate }
        set { discoverStore.selectedArxivDate = newValue }
    }

    var arxivFeed: ArxivFeedResponse? {
        get { discoverStore.arxivFeed }
        set { discoverStore.arxivFeed = newValue }
    }

    var selectedArxivPaper: ArxivFeedPaper? {
        get { discoverStore.selectedArxivPaper }
        set { discoverStore.selectedArxivPaper = newValue }
    }

    var discoverKeyword: String {
        get { discoverStore.discoverKeyword }
        set { discoverStore.discoverKeyword = newValue }
    }

    var arxivSearchQuery: String {
        get { discoverStore.arxivSearchQuery }
        set { discoverStore.arxivSearchQuery = newValue }
    }

    var arxivSearchFeed: ArxivFeedResponse? {
        get { discoverStore.arxivSearchFeed }
        set { discoverStore.arxivSearchFeed = newValue }
    }

    var arxivSearchSortRawValue: String {
        get { discoverStore.arxivSearchSortRawValue }
        set { discoverStore.arxivSearchSortRawValue = newValue }
    }

    var arxivSearchSortOrderRawValue: String {
        get { discoverStore.arxivSearchSortOrderRawValue }
        set { discoverStore.arxivSearchSortOrderRawValue = newValue }
    }

    var arxivSearchRequiredCategories: [String] {
        get { discoverStore.arxivSearchRequiredCategories }
        set {
            let normalized = LocalArxivClient.normalizedSearchCategories(newValue)
            discoverStore.arxivSearchRequiredCategories = normalized
            UserDefaults.standard.set(normalized, forKey: arxivSearchRequiredCategoriesDefaultsKey)
        }
    }

    var arxivSearchFromYear: String {
        get { discoverStore.arxivSearchFromYear }
        set {
            discoverStore.arxivSearchFromYear = newValue
            saveTrimmedSearchTextToDefaults(newValue, key: arxivSearchFromYearDefaultsKey)
        }
    }

    var arxivSearchThroughYear: String {
        get { discoverStore.arxivSearchThroughYear }
        set {
            discoverStore.arxivSearchThroughYear = newValue
            saveTrimmedSearchTextToDefaults(newValue, key: arxivSearchThroughYearDefaultsKey)
        }
    }

    var discoverStartDate: String {
        get { discoverStore.discoverStartDate }
        set {
            discoverStore.discoverStartDate = newValue
            selectedArxivDate = nil
        }
    }

    var discoverEndDate: String {
        get { discoverStore.discoverEndDate }
        set {
            discoverStore.discoverEndDate = newValue
            selectedArxivDate = nil
        }
    }

    var discoverSelectedCategories: [String] {
        get { discoverStore.discoverSelectedCategories }
        set { discoverStore.discoverSelectedCategories = newValue }
    }

    var discoverSelectedSimilaritySourceIDs: [String] {
        get { discoverStore.discoverSelectedSimilaritySourceIDs }
        set { discoverStore.discoverSelectedSimilaritySourceIDs = newValue }
    }

    var discoverResultIDs: [String] {
        get { discoverStore.discoverResultIDs }
        set { discoverStore.discoverResultIDs = newValue }
    }

    var discoverEnrichmentsByID: [String: DiscoverPaperEnrichment] {
        get { discoverStore.discoverEnrichmentsByID }
        set { discoverStore.discoverEnrichmentsByID = newValue }
    }

    var isSearchingDiscover: Bool {
        get { discoverStore.isSearchingDiscover }
        set { discoverStore.isSearchingDiscover = newValue }
    }

    var isCancellingDiscoverSearch: Bool {
        get { discoverStore.isCancellingDiscoverSearch }
        set { discoverStore.isCancellingDiscoverSearch = newValue }
    }

    var isSearchingArxivSearch: Bool {
        get { discoverStore.isSearchingArxivSearch }
        set { discoverStore.isSearchingArxivSearch = newValue }
    }

    var isCancellingArxivSearch: Bool {
        get { discoverStore.isCancellingArxivSearch }
        set { discoverStore.isCancellingArxivSearch = newValue }
    }

    var isProcessingDiscoverResults: Bool {
        get { discoverStore.isProcessingDiscoverResults }
        set { discoverStore.isProcessingDiscoverResults = newValue }
    }

    var discoverProcessingProgress: ArxivCacheProgress? {
        get { discoverStore.discoverProcessingProgress }
        set { discoverStore.discoverProcessingProgress = newValue }
    }

    var isCachingDiscoverPDFs: Bool {
        get { discoverStore.isCachingDiscoverPDFs }
        set { discoverStore.isCachingDiscoverPDFs = newValue }
    }

    var discoverPDFCacheProgress: ArxivCacheProgress? {
        get { discoverStore.discoverPDFCacheProgress }
        set { discoverStore.discoverPDFCacheProgress = newValue }
    }

    var arxivAssetURLs: [String: URL] {
        get { discoverStore.arxivAssetURLs }
        set { discoverStore.arxivAssetURLs = newValue }
    }

    var arxivPDFThumbnailURLsByID: [String: [URL]] {
        get { discoverStore.arxivPDFThumbnailURLsByID }
        set { discoverStore.arxivPDFThumbnailURLsByID = newValue }
    }

    var discoverPaperInteractionStateByID: [String: DiscoverPaperInteractionState] {
        get { discoverStore.discoverPaperInteractionStateByID }
        set { discoverStore.discoverPaperInteractionStateByID = newValue }
    }

    var discoverScrollPositionPaperID: String? {
        get { discoverStore.discoverScrollPositionPaperID }
        set { discoverStore.discoverScrollPositionPaperID = newValue }
    }

    var isLoadingArxivFeed: Bool {
        get { discoverStore.isLoadingArxivFeed }
        set { discoverStore.isLoadingArxivFeed = newValue }
    }

    var isRefreshingArxivDates: Bool {
        get { discoverStore.isRefreshingArxivDates }
        set { discoverStore.isRefreshingArxivDates = newValue }
    }

    var isPreloadingArxivAssets: Bool {
        get { discoverStore.isPreloadingArxivAssets }
        set { discoverStore.isPreloadingArxivAssets = newValue }
    }

    var isAddingArxivPaper: Bool {
        get { discoverStore.isAddingArxivPaper }
        set { discoverStore.isAddingArxivPaper = newValue }
    }

    var arxivDownloadingPaperIDs: Set<String> {
        get { discoverStore.arxivDownloadingPaperIDs }
        set { discoverStore.arxivDownloadingPaperIDs = newValue }
    }

    var arxivDownloadProgressByID: [String: Double] {
        get { discoverStore.arxivDownloadProgressByID }
        set { discoverStore.arxivDownloadProgressByID = newValue }
    }

    var arxivCacheProgress: ArxivCacheProgress? {
        get { discoverStore.arxivCacheProgress }
        set { discoverStore.arxivCacheProgress = newValue }
    }
    var paperThumbnailURLsByID: [String: [URL]] {
        get { libraryStore.paperThumbnailURLsByID }
        set { libraryStore.paperThumbnailURLsByID = newValue }
    }
    @Published var cacheStorageSummary = CacheStorageSummary()
    var paperNotesByID: [String: [PaperNote]] {
        get { libraryStore.paperNotesByID }
        set { libraryStore.paperNotesByID = newValue }
    }
    var citationReturnPoint: CitationReturnPoint? {
        get { readerStore.citationReturnPoint }
        set { readerStore.citationReturnPoint = newValue }
    }

    var pdfKitCommand: PDFKitCommand? {
        get { readerStore.pdfKitCommand }
        set { readerStore.pdfKitCommand = newValue }
    }

    var pdfDocumentStatus: PDFDocumentStatus? {
        get { readerStore.pdfDocumentStatus }
        set { readerStore.pdfDocumentStatus = newValue }
    }
    var pendingArxivLibraryImportIDs: Set<String> {
        get { discoverStore.pendingArxivLibraryImportIDs }
        set { discoverStore.pendingArxivLibraryImportIDs = newValue }
    }

    var failedArxivLibraryImportMessagesByID: [String: String] {
        get { discoverStore.failedArxivLibraryImportMessagesByID }
        set { discoverStore.failedArxivLibraryImportMessagesByID = newValue }
    }
    @Published var embeddingProviderTestStatus: String?
    @Published var isTestingEmbeddingProvider = false
    @Published var librarySidebarWidth: CGFloat = {
        let stored = UserDefaults.standard.double(forKey: librarySidebarWidthDefaultsKey)
        return stored > 0 ? CGFloat(stored) : 280
    }()
    @Published var chatMessageFontSize = loadChatMessageFontSizeFromDefaults()
    @Published var chatComposerFontSize = loadChatComposerFontSizeFromDefaults()
    @Published var chatFontFamily = loadChatFontFamilyFromDefaults()

    private let libraryStore = LibraryFeatureStore()
    private let readerStore = ReaderFeatureStore()
    private let discoverStore: DiscoverFeatureStore
    private let agentRuntimeStore: AgentRuntimeStore
    private let agentRunCoordinator = AgentRunCoordinator()
    private var repository: PaperRepository?
    private let supportRoot: URL
    private let arxivCache: ArxivFeedCache
    private let localDiscoverCache: LocalDiscoverCache
    private let thumbnailCache: PDFThumbnailCache
    private let workspaceManager = SessionWorkspaceManager()
    private var watchedFolderAutoScanTask: Task<Void, Never>?
    private var watchedFolderScanTask: Task<Void, Never>?
    private var activeDiscoverSearchTask: Task<Void, Never>?
    private var activeArxivSearchTask: Task<Void, Never>?
    private var activeDiscoverPDFCacheTask: Task<Void, Never>?
    private var activeDiscoverSimilarityRerankTask: Task<Void, Never>?
    private var discoverCacheWarmupTask: Task<Void, Never>?
    private var cacheStorageSummaryTask: Task<Void, Never>?
    private var libraryThumbnailRefreshTask: Task<Void, Never>?
    private var routeDeferredWorkTask: Task<Void, Never>?
    private var readerTabSelectionTask: Task<Void, Never>?
    private var pendingReaderPositionSaveTask: Task<Void, Never>?
    private var pendingReaderPosition: PaperReaderPosition?
    private var paperNotesLoadTasks: [String: Task<Void, Never>] = [:]
    private var mcpService: PaperCodexMCPService?
    private var mcpServer: PaperCodexMCPServer?
    private var mcpEndpoint: PaperCodexMCPEndpoint?
    private var mcpCommandPollingTask: Task<Void, Never>?
    private var mcpCommandReadOffset: UInt64 = 0
    private var libraryStoreObservation: AnyCancellable?
    private var readerStoreObservation: AnyCancellable?
    private var discoverStoreObservation: AnyCancellable?
    private var agentRuntimeStoreObservation: AnyCancellable?
    private var cachedEmbeddingProviderAPIKey: String?
    private let embeddingProviderCredentialStore = LocalEmbeddingProviderCredentialStore()
    private var activeCodexRunHandlesBySessionID: [String: CodexRunHandle] = [:]
    private var activeDiscoverCodexRunHandles: [CodexRunHandle] = []
    private var activeAgentTerminalProcess: LocalPTYProcess?
    private var cancellingCodexRunSessionIDs: Set<String> = []
    private var loadedPaperNotesPaperIDs: Set<String> = []
    private var isCancellingDiscoverProcessing = false
    private var isCancellingDiscoverPDFCache = false

    var activeCodexRun: ActiveCodexRun? {
        activeCodexRun(for: selectedSession?.id)
    }

    func agentTerminalState(for sessionID: String?) -> AgentTerminalState? {
        guard let sessionID, agentTerminalState?.sessionID == sessionID else {
            return nil
        }
        return agentTerminalState
    }

    var isSending: Bool {
        !activeCodexRunsBySessionID.isEmpty
    }

    var isCancellingCodexRun: Bool {
        !cancellingCodexRunSessionIDs.isEmpty
    }

    var arxivDisposableCachePath: String {
        supportRoot.appendingPathComponent("cache", isDirectory: true).path
    }

    var paperLibraryRootPath: String {
        supportRoot.appendingPathComponent("papers", isDirectory: true).path
    }

    var inAppCodexMCPStatusText: String {
        guard inAppCodexMCPEnabled else {
            return "Disabled"
        }
        guard let endpoint = mcpEndpoint else {
            return "Enabled · Starting"
        }
        return "Enabled · \(endpoint.host):\(endpoint.port)"
    }

    var paperCodexMCPServerReady: Bool {
        mcpEndpoint != nil
    }

    private var arxivSearchQueryPreview: String {
        do {
            let fromYear = try LocalArxivClient.normalizedSearchYear(arxivSearchFromYear)
            let throughYear = try LocalArxivClient.normalizedSearchYear(arxivSearchThroughYear)
            return try LocalArxivClient.composedUserSearchQuery(
                arxivSearchQuery,
                requiredCategories: arxivSearchRequiredCategories,
                fromYear: fromYear,
                throughYear: throughYear
            )
        } catch {
            return String(describing: error)
        }
    }

    var globalOperationStatuses: [AppOperationStatus] {
        var statuses: [AppOperationStatus] = []

        if isSearchingDiscover {
            statuses.append(AppOperationStatus(
                id: "discover-search",
                title: isCancellingDiscoverSearch ? "Stopping Explore Search" : "Searching Explore",
                detail: arxivCacheProgress?.detail ?? "\(discoverStartDate)...\(discoverEndDate)",
                systemImage: "magnifyingglass",
                tint: .blue,
                fraction: arxivCacheProgress?.fraction
            ))
        }
        if isSearchingArxivSearch {
            statuses.append(AppOperationStatus(
                id: "arxiv-search",
                title: isCancellingArxivSearch ? "Stopping arXiv Search" : "Searching arXiv",
                detail: arxivCacheProgress?.detail ?? arxivSearchQueryPreview,
                systemImage: "magnifyingglass",
                tint: .blue,
                fraction: arxivCacheProgress?.fraction
            ))
        }
        if isProcessingDiscoverResults {
            statuses.append(AppOperationStatus(
                id: "discover-processing",
                title: isCancellingDiscoverProcessing ? "Stopping Explore Processing" : discoverProcessingProgress?.title ?? "Processing Explore Results",
                detail: discoverProcessingProgress?.detail ?? "\(discoverCodexConcurrency) workers",
                systemImage: "sparkles",
                tint: .indigo,
                fraction: discoverProcessingProgress?.fraction
            ))
        }
        if isPreloadingArxivAssets {
            statuses.append(AppOperationStatus(
                id: "arxiv-preview-cache",
                title: arxivCacheProgress?.title ?? "Caching Preview Images",
                detail: arxivCacheProgress?.detail ?? "Preparing previews",
                systemImage: "photo.on.rectangle.angled",
                tint: .blue,
                fraction: arxivCacheProgress?.fraction
            ))
        }
        if isCachingDiscoverPDFs {
            statuses.append(AppOperationStatus(
                id: "discover-pdf-cache",
                title: isCancellingDiscoverPDFCache ? "Stopping PDF Cache" : "Caching PDFs",
                detail: discoverPDFCacheProgress?.detail ?? "Downloading arXiv PDFs",
                systemImage: "tray.and.arrow.down",
                tint: .green,
                fraction: discoverPDFCacheProgress?.fraction
            ))
        }
        if isScanningWatchedFolders {
            statuses.append(AppOperationStatus(
                id: "watched-folder-scan",
                title: "Scanning Watched Folders",
                detail: "\(watchedFolders.count) folder\(watchedFolders.count == 1 ? "" : "s")",
                systemImage: "folder.badge.gearshape",
                tint: .orange
            ))
        }
        if isSending {
            let activeRuns = activeCodexRunsBySessionID.values.sorted { $0.startedAt < $1.startedAt }
            statuses.append(AppOperationStatus(
                id: "agent-runs",
                title: isCancellingCodexRun ? "Stopping Agent" : "Agent Running",
                detail: activeRuns.count == 1
                    ? (activeRuns.first?.title ?? "Current session")
                    : "\(activeRuns.count) sessions running",
                systemImage: "brain.head.profile",
                tint: .purple
            ))
        }
        return statuses
    }

    var globalOperationStatus: AppOperationStatus? {
        globalOperationStatuses.first
    }

    func activeCodexRun(for sessionID: String?) -> ActiveCodexRun? {
        guard let sessionID else {
            return nil
        }
        return activeCodexRunsBySessionID[sessionID]
    }

    var agentRuntimeProfiles: [AgentRuntimeProfile] {
        agentRuntimeStore.profiles
    }

    var agentRuntimeProfileConfigPath: String {
        agentRuntimeStore.profileConfigURL?.path ?? ""
    }

    var agentRuntimeProfileLoadWarning: String? {
        agentRuntimeStore.profileLoadWarning
    }

    var selectedChatRuntimeID: String {
        agentRuntimeStore.selectedChatRuntimeID
    }

    var selectedEnrichmentRuntimeID: String {
        agentRuntimeStore.selectedEnrichmentRuntimeID
    }

    var selectedChatRuntimeDisplayName: String {
        agentRuntimeStore.selectedChatRuntime.displayName
    }

    var selectedEnrichmentRuntimeDisplayName: String {
        agentRuntimeStore.selectedEnrichmentRuntime.displayName
    }

    var selectedChatRuntimeSupportsPTY: Bool {
        agentRuntimeStore.selectedChatRuntime.supportsPTY
    }

    var selectedChatRuntimeDiagnostic: AgentRuntimeDiagnostic? {
        agentRuntimeDiagnostic(for: selectedChatRuntimeID)
    }

    var selectedChatRuntimeAuthSummary: String {
        agentRuntimeAuthSummary(for: selectedChatRuntimeID)
    }

    var isRefreshingAgentRuntimeDiagnostics: Bool {
        agentRuntimeStore.isRefreshingDiagnostics
    }

    func isAgentRuntimeEnabled(_ runtimeID: String) -> Bool {
        agentRuntimeStore.isRuntimeEnabled(runtimeID)
    }

    func agentRuntimeDiagnostic(for runtimeID: String) -> AgentRuntimeDiagnostic? {
        if let diagnostic = agentRuntimeStore.diagnosticsByRuntimeID[runtimeID] {
            return diagnostic
        }
        if runtimeID == "codex", let codexDiagnostic {
            return AgentRuntimeDiagnostic(
                runtimeID: "codex",
                state: AgentRuntimeDiagnosticState(codexDiagnostic.severity),
                title: codexDiagnostic.title,
                detail: codexDiagnostic.detail,
                executablePath: codexDiagnostic.executablePath,
                version: codexDiagnostic.version
            )
        }
        return nil
    }

    func agentRuntimeAuthSummary(for runtimeID: String) -> String {
        agentRuntimeStore.authSummariesByRuntimeID[runtimeID] ?? "Auth not checked"
    }

    func agentRuntimeModelOverride(for runtimeID: String) -> String {
        runtimeID == "codex" ? codexModelOverride : agentRuntimeStore.modelOverride(for: runtimeID)
    }

    func availableAgentRuntimeModelIDs(for runtimeID: String) -> [String] {
        runtimeID == "codex" ? availableCodexModelIDs : agentRuntimeStore.availableModelIDs(for: runtimeID)
    }

    func agentRuntimeDefaultModelID(for runtimeID: String) -> String {
        if runtimeID == "codex" {
            return codexDefaultModelID
        }
        return agentRuntimeStore.profile(id: runtimeID)?.defaultModelID ?? ""
    }

    func agentRuntimeProviderOverride(for runtimeID: String) -> String {
        agentRuntimeStore.providerOverride(for: runtimeID)
    }

    func agentRuntimeMCPMode(for runtimeID: String) -> AgentRuntimeMCPMode {
        agentRuntimeStore.mcpMode(for: runtimeID)
    }

    func isSessionSending(_ sessionID: String?) -> Bool {
        activeCodexRun(for: sessionID) != nil
    }

    var readerPositionContextID: String? {
        guard let session = selectedSession, let paper = selectedPaper else {
            return nil
        }
        return "\(session.id)|\(paper.id)"
    }

    var currentSessionPapers: [Paper] {
        guard let session = selectedSession else {
            return selectedPaper.map { [$0] } ?? []
        }
        let linkedPapers = papersForSession(session)
        if linkedPapers.isEmpty, let selectedPaper {
            return [selectedPaper]
        }
        return linkedPapers
    }

    init() {
        let storedLanguageMode = loadGlobalLanguageModeFromDefaults()
        globalLanguageMode = storedLanguageMode
        codexSystemPrompt = loadCodexSystemPromptFromDefaults(languageMode: storedLanguageMode)
        let initialDiscoverDate = DiscoverDateRange.isoDate()
        discoverStore = DiscoverFeatureStore(
            startDate: initialDiscoverDate,
            endDate: initialDiscoverDate,
            scrollPositionPaperID: loadDiscoverScrollPositionPaperIDFromDefaults(),
            searchRequiredCategories: loadArxivSearchRequiredCategoriesFromDefaults(),
            searchFromYear: loadTrimmedSearchTextFromDefaults(arxivSearchFromYearDefaultsKey),
            searchThroughYear: loadTrimmedSearchTextFromDefaults(arxivSearchThroughYearDefaultsKey)
        )

        let root = PaperCodexPaths.supportRoot()
        let runtimeProfileLoad = AgentRuntimeProfile.loadProfiles(supportRoot: root)
        supportRoot = root
        agentRuntimeStore = AgentRuntimeStore(
            profiles: runtimeProfileLoad.profiles,
            profileConfigURL: runtimeProfileLoad.configURL,
            profileLoadWarning: runtimeProfileLoad.warning
        )
        arxivCache = ArxivFeedCache(root: root.appendingPathComponent("arxiv-cache", isDirectory: true))
        localDiscoverCache = LocalDiscoverCache(root: root.appendingPathComponent("discover-cache", isDirectory: true))
        thumbnailCache = PDFThumbnailCache(root: root.appendingPathComponent("thumbnails", isDirectory: true))
        libraryStoreObservation = libraryStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        readerStoreObservation = readerStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        discoverStoreObservation = discoverStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        agentRuntimeStoreObservation = agentRuntimeStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        discoverSelectedCategories = localDiscoverPreferences.categories.isEmpty ? ["cs.CV"] : [localDiscoverPreferences.categories[0]]
        do {
            try PaperCodexPaths.migrateLegacySupportRootIfNeeded(to: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try PaperRepository(databasePath: root.appendingPathComponent("store.sqlite").path)
            try store.migrate()
            _ = try store.repairPaperFilePaths(
                from: root.deletingLastPathComponent().appendingPathComponent(PaperCodexPaths.legacyAppSupportDirectoryName, isDirectory: true),
                to: root
            )
            repository = store
            try reloadLibrary()
            startDiscoverCacheWarmupIfNeeded()
            refreshCacheStorageSummary()
            startMCPServer(repository: store)
            refreshMCPActiveContextSnapshot()
            Task {
                await refreshCodexDiagnostic()
                await refreshAvailableCodexModels()
                await refreshAgentRuntimeDiagnostics()
            }
            startWatchedFolderAutoScan()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    deinit {
        watchedFolderAutoScanTask?.cancel()
        watchedFolderScanTask?.cancel()
        activeDiscoverSearchTask?.cancel()
        activeArxivSearchTask?.cancel()
        activeDiscoverPDFCacheTask?.cancel()
        activeDiscoverSimilarityRerankTask?.cancel()
        discoverCacheWarmupTask?.cancel()
        cacheStorageSummaryTask?.cancel()
        libraryThumbnailRefreshTask?.cancel()
        routeDeferredWorkTask?.cancel()
        readerTabSelectionTask?.cancel()
        pendingReaderPositionSaveTask?.cancel()
        paperNotesLoadTasks.values.forEach { $0.cancel() }
        mcpCommandPollingTask?.cancel()
        mcpServer?.stop()
    }

    private func startMCPServer(repository: PaperRepository) {
        do {
            let service = PaperCodexMCPService(repository: repository, supportRoot: supportRoot)
            let server = PaperCodexMCPServer(service: service, supportRoot: supportRoot)
            mcpEndpoint = try server.start()
            mcpService = service
            mcpServer = server
            refreshInstalledCodexPluginIfNeeded()
            startMCPCommandPolling()
        } catch {
            errorMessage = "Episteme MCP server failed to start: \(String(describing: error))"
        }
    }

    func refreshMCPActiveContextSnapshot() {
        do {
            let context = PaperCodexMCPActiveContext(
                route: route.mcpName,
                paperID: selectedPaper?.id,
                paperTitle: selectedPaper?.title,
                sessionID: selectedSession?.id,
                selectedText: currentSelection?.text,
                selectedPage: currentSelection?.page
            )
            try mcpService?.writeActiveContextSnapshot(context)
        } catch {
            errorMessage = "Episteme MCP context update failed: \(String(describing: error))"
        }
    }

    private func startMCPCommandPolling() {
        let commandLogURL = PaperCodexMCPAppCommand.commandLogURL(supportRoot: supportRoot)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: commandLogURL.path),
           let size = attributes[.size] as? NSNumber {
            mcpCommandReadOffset = size.uint64Value
        } else {
            mcpCommandReadOffset = 0
        }
        mcpCommandPollingTask?.cancel()
        mcpCommandPollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else {
                    return
                }
                self?.processPendingMCPCommands()
            }
        }
    }

    private func processPendingMCPCommands() {
        let commandLogURL = PaperCodexMCPAppCommand.commandLogURL(supportRoot: supportRoot)
        guard FileManager.default.fileExists(atPath: commandLogURL.path),
              let handle = try? FileHandle(forReadingFrom: commandLogURL) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: mcpCommandReadOffset)
            let data = handle.readDataToEndOfFile()
            mcpCommandReadOffset = try handle.offset()
            guard !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            for line in text.split(separator: "\n") {
                let lineData = Data(line.utf8)
                let command = try decoder.decode(PaperCodexMCPAppCommand.self, from: lineData)
                handleMCPCommand(command)
            }
        } catch {
            errorMessage = "Episteme MCP command handling failed: \(String(describing: error))"
        }
    }

    private func handleMCPCommand(_ command: PaperCodexMCPAppCommand) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            switch command.type {
            case "app.open_paper":
                let paper = try paperFromMCPCommand(command, repository: repository)
                openPaper(paper)
            case "app.reveal_paper":
                let paper = try paperFromMCPCommand(command, repository: repository)
                selectedLibraryPaper = paper
                setLibrarySelection(surface: .papers, categoryID: nil, tagID: nil)
                route = .library
            case "app.open_folder":
                let folderID = try mcpCommandArgument("folder_id", in: command)
                setLibrarySelection(surface: .papers, categoryID: folderID, tagID: nil)
                route = .library
            case "app.open_tag":
                let tagID = try mcpCommandArgument("tag_id", in: command)
                setLibrarySelection(surface: .papers, categoryID: nil, tagID: tagID)
                route = .library
            case "app.jump_to_page":
                let paper = try paperFromMCPCommand(command, repository: repository)
                openPaper(paper)
                let page = Int(command.arguments["page"] ?? "1") ?? 1
                readerPosition = PaperReaderPosition(
                    sessionID: selectedSession?.id ?? "mcp-navigation",
                    paperID: paper.id,
                    pageIndex: max(page - 1, 0),
                    pagePointX: 0,
                    pagePointY: 0,
                    scaleFactor: 1,
                    updatedAt: Date()
                )
            case "app.jump_to_anchor":
                jumpToCitation(try mcpCommandArgument("anchor_id", in: command))
            default:
                return
            }
            refreshMCPActiveContextSnapshot()
        } catch {
            errorMessage = "Episteme MCP command failed: \(String(describing: error))"
        }
    }

    private func paperFromMCPCommand(_ command: PaperCodexMCPAppCommand, repository: PaperRepository) throws -> Paper {
        let paperID = try mcpCommandArgument("paper_id", in: command)
        if let paper = papers.first(where: { $0.id == paperID }) {
            return paper
        }
        guard let paper = try repository.fetchPapers(ids: [paperID]).first else {
            throw AppModelError.paperNotFound(paperID)
        }
        return paper
    }

    private func mcpCommandArgument(_ name: String, in command: PaperCodexMCPAppCommand) throws -> String {
        guard let value = command.arguments[name],
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppModelError.missingMCPCommandArgument(name)
        }
        return value
    }

    func postNotice(
        kind: InteractionNoticeKind,
        title: String,
        message: String = "",
        autoDismissAfter: TimeInterval? = nil
    ) {
        let dismissAfter = autoDismissAfter ?? defaultNoticeDismissDuration(for: kind)
        let notice = InteractionNotice(
            kind: kind,
            title: title,
            message: message,
            autoDismissAfter: dismissAfter
        )
        notices.append(notice)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
            await MainActor.run {
                self?.dismissNotice(id: notice.id)
            }
        }
    }

    func dismissNotice(id: InteractionNotice.ID) {
        notices.removeAll { $0.id == id }
    }

    private func embeddingProviderAPIKeyValue() -> String {
        if let cachedEmbeddingProviderAPIKey {
            return cachedEmbeddingProviderAPIKey
        }
        let value = embeddingProviderCredentialStore.loadAPIKey()
        cachedEmbeddingProviderAPIKey = value
        return value
    }

    var defaultDiscoverProcessActions: Set<DiscoverProcessAction> {
        var actions = Set(DiscoverProcessAction.allCases)
        if !isEmbeddingProviderReadyForProcessing {
            actions.remove(.embedding)
        }
        return actions
    }

    private var isEmbeddingProviderReadyForProcessing: Bool {
        let embeddingSettings = localDiscoverPreferences.normalized.embedding
        let model = embeddingSettings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = embeddingProviderAPIKeyValue().trimmingCharacters(in: .whitespacesAndNewlines)
        return embeddingSettings.enabled
            && !embeddingSettings.baseURL.isEmpty
            && !model.isEmpty
            && !apiKey.isEmpty
    }

    func refreshCacheStorageSummary() {
        cacheStorageSummaryTask?.cancel()
        let supportRoot = supportRoot
        cacheStorageSummaryTask = Task { [weak self] in
            let summary = await Task.detached(priority: .utility) {
                CacheStorageSummaryLoader.load(supportRoot: supportRoot)
            }.value
            guard !Task.isCancelled else {
                return
            }
            self?.cacheStorageSummary = summary
            self?.cacheStorageSummaryTask = nil
        }
    }

    func revealPath(_ path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }

    private func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    func reloadLibrary() throws {
        guard let repository else {
            return
        }
        let fetchedPapers = try repository.fetchPapers()
        let fetchedCategories = try repository.fetchCategories()
        let fetchedTags = try repository.fetchTags()
        let fetchedWatchedFolders = try repository.fetchWatchedFolders()
        let categoryIDsByPaperID = try repository.fetchCategoryIDsByPaperID()
        let tagsByPaperID = try repository.fetchTagsByPaperID()
        libraryStore.applySnapshot(
            papers: fetchedPapers,
            categories: fetchedCategories,
            tags: fetchedTags,
            watchedFolders: fetchedWatchedFolders,
            categoryIDsByPaperID: categoryIDsByPaperID,
            tagsByPaperID: tagsByPaperID
        )
        try refreshRecentSessions(repository: repository)
        startLibraryThumbnailRefresh(for: fetchedPapers)
    }

    private func startLibraryThumbnailRefresh(for papers: [Paper]) {
        let visibleIDs = Set(papers.map(\.id))
        paperThumbnailURLsByID = paperThumbnailURLsByID.filter { visibleIDs.contains($0.key) }
        libraryThumbnailRefreshTask?.cancel()
        let supportRoot = supportRoot
        let existing = paperThumbnailURLsByID
        libraryThumbnailRefreshTask = Task { [weak self] in
            let urlsByID = await Task.detached(priority: .utility) {
                LibraryThumbnailLoader.load(
                    supportRoot: supportRoot,
                    papers: papers,
                    existing: existing
                )
            }.value
            guard let self, !Task.isCancelled else {
                return
            }
            self.paperThumbnailURLsByID = urlsByID
            self.libraryThumbnailRefreshTask = nil
        }
    }

    func refreshRecentSessions() {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            try refreshRecentSessions(repository: repository)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func refreshRecentSessions(repository: PaperRepository) throws {
        let sessions = try repository.fetchRecentSessions(limit: 8)
        recentSessions = sessions
        recentSessionPapersByID = try repository.fetchPapersBySessionID(for: sessions)
    }

    func papersForSession(_ session: PaperSession) -> [Paper] {
        let visiblePapers = recentSessionPapersByID[session.id, default: []]
        return session.paperIDs.compactMap { paperID in
            papers.first(where: { $0.id == paperID })
                ?? visiblePapers.first(where: { $0.id == paperID })
        }
    }

    func importPDF(from sourceURL: URL) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let result = try PaperLibraryImporter(repository: repository, supportRoot: supportRoot)
                .importPDF(from: sourceURL)
            try reloadLibrary()
            refreshCacheStorageSummary()
            postNotice(
                kind: result.didImport ? .success : .info,
                title: result.didImport ? "PDF Imported" : "Already in Library",
                message: result.paper.title
            )
            openPaper(result.paper)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func importPDFs(from sourceURLs: [URL]) {
        let pdfURLs = sourceURLs.filter { $0.pathExtension.compare("pdf", options: [.caseInsensitive]) == .orderedSame }
        guard !pdfURLs.isEmpty else {
            postNotice(kind: .warning, title: "No PDFs Found", message: "Drop or choose PDF files to import.")
            return
        }
        var imported = 0
        var existing = 0
        var lastPaper: Paper?
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let importer = PaperLibraryImporter(repository: repository, supportRoot: supportRoot)
            for sourceURL in pdfURLs {
                let accessed = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }
                let result = try importer.importPDF(from: sourceURL)
                if result.didImport {
                    imported += 1
                } else {
                    existing += 1
                }
                lastPaper = result.paper
            }
            try reloadLibrary()
            refreshCacheStorageSummary()
            if let lastPaper {
                selectedLibraryPaper = papers.first { $0.id == lastPaper.id } ?? lastPaper
            }
            postNotice(
                kind: imported > 0 ? .success : .info,
                title: "PDF Import Finished",
                message: "\(imported) imported · \(existing) already in Library"
            )
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func addWatchedFolder(from sourceURL: URL) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    sourceURL.stopAccessingSecurityScopedResource()
                }
            }

            let path = sourceURL.standardizedFileURL.path
            let folder = watchedFolders.first { $0.path == path } ?? WatchedFolder(
                id: makeManualID(prefix: "watch", name: sourceURL.lastPathComponent),
                path: path,
                createdAt: Date(),
                lastScannedAt: nil
            )
            try repository.upsertWatchedFolder(folder)
            try reloadLibrary()
            try scanWatchedFolder(folder)
            try reloadLibrary()
            postNotice(kind: .success, title: "Watched Folder Added", message: sourceURL.lastPathComponent)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func scanWatchedFolders() {
        guard !isScanningWatchedFolders else {
            return
        }
        guard !watchedFolders.isEmpty else {
            return
        }
        isScanningWatchedFolders = true
        watchedFolderScanTask?.cancel()
        let databasePath = supportRoot.appendingPathComponent("store.sqlite").path
        let supportRoot = supportRoot
        watchedFolderScanTask = Task { [weak self] in
            do {
                let results = try await Task.detached(priority: .utility) {
                    let repository = try PaperRepository(databasePath: databasePath)
                    return try WatchedFolderScanner(repository: repository, supportRoot: supportRoot)
                        .scanAllWatchedFolders()
                }.value
                guard let self, !Task.isCancelled else {
                    return
                }
                try self.reloadLibrary()
                let imported = results.flatMap(\.importedPapers).count
                let existing = results.flatMap(\.existingPapers).count
                self.postNotice(
                    kind: imported > 0 ? .success : .info,
                    title: "Folder Scan Finished",
                    message: "\(imported) imported · \(existing) already known"
                )
                self.isScanningWatchedFolders = false
                self.watchedFolderScanTask = nil
            } catch {
                guard let self, !Task.isCancelled else {
                    return
                }
                self.isScanningWatchedFolders = false
                self.watchedFolderScanTask = nil
                self.errorMessage = String(describing: error)
            }
        }
    }

    func removeWatchedFolder(_ folder: WatchedFolder) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            try repository.deleteWatchedFolder(id: folder.id)
            try reloadLibrary()
            postNotice(kind: .success, title: "Watched Folder Removed", message: URL(fileURLWithPath: folder.path).lastPathComponent)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func selectLibraryPaper(_ paper: Paper) {
        selectedLibraryPaper = paper
    }

    func showDiscover() {
        route = .discover
        scheduleDiscoverCacheWarmup()
    }

    func showSearch() {
        route = .search
    }

    func requestSearchFocus() {
        if route == .settings {
            route = .search
        } else if route == .reader {
            returnFromReader()
            if route == .reader || route == .settings {
                route = .search
            }
        }
        searchFocusRequestID = UUID()
    }

    func requestChatComposerFocus() {
        guard route == .reader, selectedPaper != nil else {
            return
        }
        selectedSessionPanelTab = .chat
        chatComposerFocusRequestID = UUID()
    }

    func showReaderSessionPanel(_ tab: SessionPanelTab) {
        guard route == .reader, selectedPaper != nil else {
            return
        }
        selectedSessionPanelTab = tab
    }

    private func startDiscoverCacheWarmupIfNeeded() {
        guard discoverCacheWarmupTask == nil else {
            return
        }
        let supportRoot = supportRoot
        let preferences = localDiscoverPreferences
        let selectedDate = selectedArxivDate
        if arxivFeed == nil {
            isLoadingArxivFeed = true
        }
        discoverCacheWarmupTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    return Result<DiscoverCachedState?, Error>.success(
                        try DiscoverCacheLoader.loadInitialState(
                            supportRoot: supportRoot,
                            preferences: preferences,
                            selectedDate: selectedDate
                        )
                    )
                } catch {
                    return Result<DiscoverCachedState?, Error>.failure(error)
                }
            }.value
            guard let self, !Task.isCancelled else {
                return
            }
            self.discoverCacheWarmupTask = nil
            self.isLoadingArxivFeed = false
            guard !self.isSearchingDiscover else {
                return
            }
            switch result {
            case .success(let state):
                if let state {
                    self.applyDiscoverCachedState(state)
                }
            case .failure(let error):
                self.errorMessage = String(describing: error)
            }
        }
    }

    private func cancelDiscoverCacheWarmup() {
        discoverCacheWarmupTask?.cancel()
        discoverCacheWarmupTask = nil
        if arxivFeed != nil {
            isLoadingArxivFeed = false
        }
    }

    private func applyDiscoverCachedState(_ state: DiscoverCachedState) {
        if let query = state.query {
            discoverKeyword = query.keyword
            discoverStartDate = query.dateRange.start
            discoverEndDate = query.dateRange.end
            discoverSelectedCategories = query.categories
            discoverSelectedSimilaritySourceIDs = query.similaritySourceIDs
        } else {
            syncDiscoverControlsFromCachedDateIfNeeded(state.selectedDate)
        }
        arxivDates = state.arxivDates
        selectedArxivDate = state.selectedDate
        arxivFeed = state.feed
        discoverResultIDs = state.feed.papers.map(\.id)
        if let selected = selectedArxivPaper,
           state.feed.papers.contains(where: { $0.id == selected.id }) {
            selectedArxivPaper = selected
        } else {
            selectedArxivPaper = state.feed.papers.first
        }
        discoverEnrichmentsByID = state.enrichmentsByID
        arxivAssetURLs = state.assetURLs
        arxivPDFThumbnailURLsByID = state.pdfThumbnailURLsByID
        arxivCacheProgress = ArxivCacheProgress(
            date: state.selectedDate,
            title: state.progressTitle,
            detail: "Preview images \(state.assetCacheSummary.cached)/\(state.assetCacheSummary.total)",
            completed: state.assetCacheSummary.cached,
            total: state.assetCacheSummary.total
        )
    }

    private func syncDiscoverControlsFromCachedDateIfNeeded(_ cachedDate: String) {
        do {
            let range = try DiscoverDateRange(cacheLabel: cachedDate)
            discoverStore.discoverStartDate = range.start
            discoverStore.discoverEndDate = range.end
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func showRecentConversations() {
        setLibrarySelection(surface: .recentConversations, categoryID: nil, tagID: nil)
        route = .library
        scheduleRecentSessionsRefresh()
    }

    func recordDiscoverScrollPosition(_ paperID: String?) {
        let trimmed = paperID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = trimmed.isEmpty ? nil : trimmed
        guard discoverScrollPositionPaperID != normalized else {
            return
        }
        discoverScrollPositionPaperID = normalized
        if let normalized {
            UserDefaults.standard.set(normalized, forKey: discoverScrollPositionPaperIDDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: discoverScrollPositionPaperIDDefaultsKey)
        }
    }

    func showSettings() {
        route = .settings
    }

    func setLocalArxivCategories(_ categories: [String]) {
        var preferences = localDiscoverPreferences
        preferences.categories = categories
        localDiscoverPreferences = preferences.normalized
        saveLocalDiscoverPreferencesToDefaults(localDiscoverPreferences)
        postNotice(kind: .success, title: "arXiv Categories Saved", message: localDiscoverPreferences.categories.joined(separator: ", "))
    }

    func setLocalTagFilters(whitelist: [String], blacklist: [String]) {
        var preferences = localDiscoverPreferences
        preferences.whitelistTags = whitelist
        preferences.blacklistTags = blacklist
        localDiscoverPreferences = preferences.normalized
        saveLocalDiscoverPreferencesToDefaults(localDiscoverPreferences)
        if let feed = arxivFeed {
            arxivFeed = applyLocalDiscoverPreferences(to: feed)
        }
        postNotice(kind: .success, title: "Ranking Filters Saved")
    }

    func similarityCategoryIDsForSettings() -> [String] {
        let configured = localDiscoverPreferences.normalized.similarityCategoryIDs ?? categories.map(\.id)
        return normalizedIdentifiers(configured).filter { categoryID in
            categories.contains { $0.id == categoryID }
        }
    }

    func setLocalSimilarityCategoryIDs(_ categoryIDs: [String]) {
        var preferences = localDiscoverPreferences
        preferences.similarityCategoryIDs = normalizedIdentifiers(categoryIDs)
        localDiscoverPreferences = preferences.normalized
        saveLocalDiscoverPreferencesToDefaults(localDiscoverPreferences)
        refreshDiscoverSimilarityRankingAfterPreferenceChange()
    }

    private func refreshDiscoverSimilarityRankingAfterPreferenceChange() {
        activeDiscoverSimilarityRerankTask?.cancel()
        activeDiscoverSimilarityRerankTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }
            defer {
                self.activeDiscoverSimilarityRerankTask = nil
            }
            do {
                let scoredCount = try await self.rerankCurrentDiscoverFeedsForSimilarityChange()
                guard !Task.isCancelled else {
                    return
                }
                if scoredCount > 0 {
                    self.postNotice(kind: .success, title: "Similarity Categories Saved", message: "\(scoredCount) papers scored")
                } else {
                    self.postNotice(kind: .success, title: "Similarity Categories Saved")
                }
            } catch {
                guard !Task.isCancelled, !isCancellationError(error) else {
                    return
                }
                let message = String(describing: error)
                self.errorMessage = message
                self.postNotice(kind: .error, title: "Similarity Ranking Failed", message: message, autoDismissAfter: nil)
            }
        }
    }

    private func includeCategoryInSimilarityDefaults(_ categoryID: String) {
        var preferences = localDiscoverPreferences
        guard var categoryIDs = preferences.similarityCategoryIDs else {
            return
        }
        if !categoryIDs.contains(categoryID) {
            categoryIDs.append(categoryID)
            preferences.similarityCategoryIDs = categoryIDs
            localDiscoverPreferences = preferences.normalized
            saveLocalDiscoverPreferencesToDefaults(localDiscoverPreferences)
        }
    }

    func setLocalEnrichmentPreferences(autoOpen: Bool, autoSave: Bool) {
        var preferences = localDiscoverPreferences
        preferences.enrichment = LocalEnrichmentPreferences(autoEnrichOnOpen: autoOpen, autoEnrichOnSave: autoSave)
        localDiscoverPreferences = preferences.normalized
        saveLocalDiscoverPreferencesToDefaults(localDiscoverPreferences)
        postNotice(kind: .success, title: "Enrichment Preferences Saved")
    }

    func setEmbeddingProviderSettings(enabled: Bool, baseURL: String, apiKey: String, model: String) {
        let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var preferences = localDiscoverPreferences
        preferences.embedding = EmbeddingProviderSettings(enabled: enabled, baseURL: baseURL, model: model)
        let normalizedPreferences = preferences.normalized
        localDiscoverPreferences = normalizedPreferences
        saveLocalDiscoverPreferencesToDefaults(normalizedPreferences)

        guard !trimmedAPIKey.isEmpty else {
            postNotice(kind: .success, title: "Embedding Provider Saved")
            return
        }
        embeddingProviderCredentialStore.saveAPIKey(trimmedAPIKey)
        cachedEmbeddingProviderAPIKey = trimmedAPIKey
        postNotice(kind: .success, title: "Embedding Provider Saved")
    }

    func testEmbeddingProvider(baseURL: String, apiKey: String, model: String) async {
        guard !isTestingEmbeddingProvider else {
            return
        }
        isTestingEmbeddingProvider = true
        embeddingProviderTestStatus = "Testing..."
        defer {
            isTestingEmbeddingProvider = false
        }
        do {
            let settings = EmbeddingProviderSettings(enabled: true, baseURL: baseURL, model: model)
            let trimmedAPIKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveAPIKey = trimmedAPIKey.isEmpty ? embeddingProviderAPIKeyValue() : trimmedAPIKey
            let client = try OpenAICompatibleEmbeddingClient(settings: settings, apiKey: effectiveAPIKey)
            let vectors = try await client.embed(texts: ["Episteme embedding connection test."])
            let dimensions = vectors.first?.count ?? 0
            embeddingProviderTestStatus = "Connected · \(dimensions) dimensions"
            postNotice(kind: .success, title: "Embedding Test Passed", message: "\(dimensions) dimensions")
        } catch {
            embeddingProviderTestStatus = "Failed: \(error)"
            postNotice(kind: .error, title: "Embedding Test Failed", message: String(describing: error), autoDismissAfter: nil)
        }
    }

    func setDiscoverCodexSettings(modelOverride: String, concurrency: Int, reasoningEffort: CodexReasoningEffort) {
        let trimmedModel = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        discoverCodexModelOverride = trimmedModel
        discoverCodexReasoningEffort = reasoningEffort
        discoverCodexConcurrency = min(max(concurrency, 1), 20)
        if trimmedModel.isEmpty {
            UserDefaults.standard.removeObject(forKey: discoverCodexModelOverrideDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmedModel, forKey: discoverCodexModelOverrideDefaultsKey)
        }
        if reasoningEffort == .default {
            UserDefaults.standard.removeObject(forKey: discoverCodexReasoningEffortDefaultsKey)
        } else {
            UserDefaults.standard.set(reasoningEffort.rawValue, forKey: discoverCodexReasoningEffortDefaultsKey)
        }
        UserDefaults.standard.set(discoverCodexConcurrency, forKey: discoverCodexConcurrencyDefaultsKey)
        mergeAvailableCodexModelIDs([trimmedModel])
        postNotice(kind: .success, title: "Explore Processing Saved", message: "\(discoverCodexConcurrency) workers · Think \(reasoningEffort.displayName)")
    }

    func setChatAppearance(
        messageFontSize: Double,
        composerFontSize: Double,
        fontFamily: ChatFontFamily
    ) {
        chatMessageFontSize = ChatAppearanceDefaults.clampedMessageFontSize(messageFontSize)
        chatComposerFontSize = ChatAppearanceDefaults.clampedComposerFontSize(composerFontSize)
        chatFontFamily = fontFamily
        UserDefaults.standard.set(chatMessageFontSize, forKey: chatMessageFontSizeDefaultsKey)
        UserDefaults.standard.set(chatComposerFontSize, forKey: chatComposerFontSizeDefaultsKey)
        UserDefaults.standard.set(fontFamily.rawValue, forKey: chatFontFamilyDefaultsKey)
        postNotice(
            kind: .success,
            title: "Chat Appearance Saved",
            message: "\(fontFamily.title) · Message \(Int(chatMessageFontSize)) pt · Composer \(Int(chatComposerFontSize)) pt"
        )
    }

    func resetChatAppearance() {
        setChatAppearance(
            messageFontSize: ChatAppearanceDefaults.defaultMessageFontSize,
            composerFontSize: ChatAppearanceDefaults.defaultComposerFontSize,
            fontFamily: .system
        )
    }

    func setCodexSystemPrompt(_ prompt: String) {
        let normalized = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || PromptBuilder.isBuiltInSystemPrompt(normalized) {
            resetCodexSystemPrompt()
            return
        }
        codexSystemPrompt = normalized
        UserDefaults.standard.set(normalized, forKey: codexSystemPromptDefaultsKey)
        postNotice(kind: .success, title: "System Prompt Saved")
    }

    func resetCodexSystemPrompt() {
        codexSystemPrompt = PromptBuilder.defaultSystemPrompt(for: globalLanguageMode)
        UserDefaults.standard.removeObject(forKey: codexSystemPromptDefaultsKey)
        postNotice(kind: .success, title: "System Prompt Reset")
    }

    func setGlobalLanguageMode(_ mode: PaperCodexLanguageMode) {
        let shouldSwitchSystemPrompt = PromptBuilder.isBuiltInSystemPrompt(codexSystemPrompt)
        globalLanguageMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: globalLanguageModeDefaultsKey)
        if shouldSwitchSystemPrompt {
            codexSystemPrompt = PromptBuilder.defaultSystemPrompt(for: mode)
            UserDefaults.standard.removeObject(forKey: codexSystemPromptDefaultsKey)
        }
        let promptMessage = shouldSwitchSystemPrompt ? "System prompt switched" : "Custom prompt preserved"
        postNotice(kind: .success, title: "Language Saved", message: "\(mode.title(appLanguage: mode)) · \(promptMessage)")
    }

    func setArxivSaveOrganization(_ organization: ArxivSaveOrganization) {
        arxivSaveOrganization = organization
        UserDefaults.standard.set(organization.rawValue, forKey: arxivSaveOrganizationDefaultsKey)
        postNotice(kind: .success, title: "Storage Rule Saved", message: organization.title)
    }

    func setLibrarySidebarWidth(_ width: CGFloat) {
        let clamped = min(max(width, 220), 420)
        librarySidebarWidth = clamped
        UserDefaults.standard.set(Double(clamped), forKey: librarySidebarWidthDefaultsKey)
    }

    func addQuickPrompt(title: String, content: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedContent.isEmpty else {
            errorMessage = AppModelError.emptyName.description
            return
        }
        quickPrompts.append(
            QuickPrompt(
                id: "prompt-\(makeSlug(from: trimmedTitle))-\(UUID().uuidString.prefix(8).lowercased())",
                title: trimmedTitle,
                content: trimmedContent
            )
        )
        saveQuickPromptsToDefaults(quickPrompts)
        postNotice(kind: .success, title: "Prompt Added", message: trimmedTitle)
    }

    func updateQuickPrompt(_ prompt: QuickPrompt, title: String, content: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty, !trimmedContent.isEmpty else {
            errorMessage = AppModelError.emptyName.description
            return
        }
        guard let index = quickPrompts.firstIndex(where: { $0.id == prompt.id }) else {
            return
        }
        quickPrompts[index] = QuickPrompt(id: prompt.id, title: trimmedTitle, content: trimmedContent)
        saveQuickPromptsToDefaults(quickPrompts)
        postNotice(kind: .success, title: "Prompt Updated", message: trimmedTitle)
    }

    func moveQuickPrompt(_ prompt: QuickPrompt, direction: Int) {
        guard let index = quickPrompts.firstIndex(where: { $0.id == prompt.id }) else {
            return
        }
        let target = index + direction
        guard quickPrompts.indices.contains(target) else {
            return
        }
        quickPrompts.swapAt(index, target)
        saveQuickPromptsToDefaults(quickPrompts)
        postNotice(kind: .success, title: "Prompt Reordered", message: prompt.title)
    }

    func deleteQuickPrompt(_ prompt: QuickPrompt) {
        quickPrompts.removeAll { $0.id == prompt.id }
        saveQuickPromptsToDefaults(quickPrompts)
        postNotice(kind: .success, title: "Prompt Deleted", message: prompt.title)
    }

    func sendQuickPrompt(_ prompt: QuickPrompt) {
        Task {
            await sendMessage(prompt.content)
        }
    }

    func applyDiscoverQuickRange(_ preset: DiscoverQuickRange) {
        do {
            let range = try preset.dateRange(containing: Date())
            discoverStartDate = range.start
            discoverEndDate = range.end
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func resetStaleDiscoverSearchTaskIfNeeded() {
        guard activeDiscoverSearchTask != nil, !isSearchingDiscover else {
            return
        }
        activeDiscoverSearchTask?.cancel()
        activeDiscoverSearchTask = nil
    }

    private func resetStaleArxivSearchTaskIfNeeded() {
        guard activeArxivSearchTask != nil, !isSearchingArxivSearch else {
            return
        }
        activeArxivSearchTask?.cancel()
        activeArxivSearchTask = nil
    }

    func startDiscoverSearch() {
        resetStaleDiscoverSearchTaskIfNeeded()
        guard activeDiscoverSearchTask == nil, !isSearchingDiscover else {
            return
        }
        cancelDiscoverCacheWarmup()
        isSearchingDiscover = true
        isCancellingDiscoverSearch = false
        arxivCacheProgress = ArxivCacheProgress(
            date: "\(discoverStartDate)...\(discoverEndDate)",
            title: "Preparing Explore Search",
            detail: "Checking cached results",
            completed: 0,
            total: 0
        )
        activeDiscoverSearchTask = Task { [weak self] in
            await Task.yield()
            await self?.searchDiscover()
            await MainActor.run {
                self?.activeDiscoverSearchTask = nil
            }
        }
    }

    func startArxivSearch() {
        resetStaleArxivSearchTaskIfNeeded()
        guard activeArxivSearchTask == nil, !isSearchingArxivSearch else {
            return
        }
        activeArxivSearchTask = Task { @MainActor [weak self] in
            defer {
                self?.activeArxivSearchTask = nil
            }
            await self?.searchArxiv()
        }
    }

    func cancelArxivSearch() {
        isCancellingArxivSearch = true
        activeArxivSearchTask?.cancel()
    }

    func cancelDiscoverSearch() {
        isCancellingDiscoverSearch = true
        activeDiscoverSearchTask?.cancel()
    }

    func rerankCurrentDiscoverResults() async {
        guard let currentFeed = arxivFeed,
              !isSearchingDiscover,
              !isProcessingDiscoverResults else {
            return
        }
        do {
            let range = try DiscoverDateRange(start: discoverStartDate, end: discoverEndDate)
            let categories = discoverSelectedCategories.isEmpty ? [localDiscoverPreferences.normalized.categories.first ?? "cs.CV"] : discoverSelectedCategories
            let similaritySourceIDs = effectiveDiscoverSimilaritySourceIDs()
            let query = DiscoverQuery(
                keyword: discoverKeyword,
                dateRange: range,
                categories: categories,
                similaritySourceIDs: similaritySourceIDs,
                rankingVersion: discoverRankingVersion()
            ).normalized
            let rankedFeed = try await applyDiscoverRanking(to: resetDiscoverRanking(in: currentFeed), query: query)
            let filteredFeed = filterDiscoverFeed(rankedFeed, keyword: query.keyword)
            try displayDiscoverFeed(
                filteredFeed,
                query: query,
                progressTitle: similaritySourceIDs.isEmpty ? "Similarity cleared" : "Similarity ranking ready",
                cacheRangeFeed: false
            )
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func searchDiscover() async {
        var cachedSearchResult: CachedDiscoverSearchLoadResult = .none
        var searchQuery: DiscoverQuery?
        do {
            if Task.isCancelled {
                isSearchingDiscover = false
                isCancellingDiscoverSearch = false
                arxivCacheProgress = nil
                return
            }
            if !isSearchingDiscover {
                isSearchingDiscover = true
            }
            isCancellingDiscoverSearch = false
            defer {
                isSearchingDiscover = false
                isCancellingDiscoverSearch = false
            }

            let range = try DiscoverDateRange(start: discoverStartDate, end: discoverEndDate)
            let categories = discoverSelectedCategories.isEmpty ? [localDiscoverPreferences.normalized.categories.first ?? "cs.CV"] : discoverSelectedCategories
            let similaritySourceIDs = effectiveDiscoverSimilaritySourceIDs()
            let query = DiscoverQuery(
                keyword: discoverKeyword,
                dateRange: range,
                categories: categories,
                similaritySourceIDs: similaritySourceIDs,
                rankingVersion: discoverRankingVersion()
            ).normalized
            searchQuery = query
            discoverStartDate = query.dateRange.start
            discoverEndDate = query.dateRange.end
            discoverSelectedCategories = query.categories
            discoverPaperInteractionStateByID = [:]

            cachedSearchResult = try await loadAndDisplayCachedDiscoverSearch(query: query, allowPartialFragments: true)
            try Task.checkCancellation()
            if cachedSearchResult.isComplete {
                return
            }

            arxivCacheProgress = ArxivCacheProgress(
                date: range.cacheLabel,
                title: "Searching arXiv",
                detail: categories.joined(separator: ", "),
                completed: 0,
                total: 0
            )

            let client = makeLocalArxivClient(categories: categories)
            let liveFeed = try await client.fetchFeed(range: range)
            let rankedFeed = try await applyDiscoverRanking(to: liveFeed, query: query)
            if !rankedFeed.papers.isEmpty {
                try arxivCache.saveFeed(rankedFeed)
                try mergeAndSaveArxivDate(rankedFeed.date)
            }
            let filteredFeed = filterDiscoverFeed(rankedFeed, keyword: query.keyword)
            try displayDiscoverFeed(filteredFeed, query: query, progressTitle: "Search results cached", cacheRangeFeed: false, cacheQueryResult: true)
        } catch {
            if isCancellationError(error) || isCancellingDiscoverSearch || Task.isCancelled {
                arxivCacheProgress = nil
            } else if cachedSearchResult.didLoad {
                errorMessage = "Using partial cached Explore results. Search failed: \(error)"
            } else if let query = searchQuery,
                      (try? await loadAndDisplayCachedDiscoverSearch(query: query, allowPartialFragments: true).didLoad) == true {
                errorMessage = "Using cached Explore results. Search failed: \(error)"
            } else {
                errorMessage = String(describing: error)
            }
        }
    }

    func searchArxiv() async {
        do {
            let fromYear = try LocalArxivClient.normalizedSearchYear(arxivSearchFromYear)
            let throughYear = try LocalArxivClient.normalizedSearchYear(arxivSearchThroughYear)
            let normalizedQuery = try LocalArxivClient.composedUserSearchQuery(
                arxivSearchQuery,
                requiredCategories: arxivSearchRequiredCategories,
                fromYear: fromYear,
                throughYear: throughYear
            )
            guard !normalizedQuery.isEmpty else {
                arxivSearchFeed = ArxivFeedResponse(date: "search", count: 0, papers: [])
                return
            }
            isSearchingArxivSearch = true
            isCancellingArxivSearch = false
            defer {
                isSearchingArxivSearch = false
                isCancellingArxivSearch = false
            }
            arxivCacheProgress = ArxivCacheProgress(
                date: "search",
                title: "Searching arXiv",
                detail: normalizedQuery,
                completed: 0,
                total: 0
            )
            let sortBy = ArxivAPISort(rawValue: arxivSearchSortRawValue) ?? .relevance
            let sortOrder = ArxivAPISortOrder(rawValue: arxivSearchSortOrderRawValue) ?? .descending
            let feed = try await makeLocalArxivClient().search(
                query: arxivSearchQuery,
                requiredCategories: arxivSearchRequiredCategories,
                fromYear: fromYear,
                throughYear: throughYear,
                maxResults: 100,
                sortBy: sortBy,
                sortOrder: sortOrder
            )
            arxivSearchFeed = feed
            mergeDiscoverEnrichments(for: feed.papers)
            arxivCacheProgress = ArxivCacheProgress(
                date: "search",
                title: "arXiv Search Ready",
                detail: "\(feed.papers.count)/\(feed.count) results",
                completed: feed.papers.count,
                total: max(feed.count, feed.papers.count)
            )
        } catch {
            if isCancellationError(error) || isCancellingArxivSearch || Task.isCancelled {
                arxivCacheProgress = nil
            } else {
                let message = String(describing: error)
                errorMessage = message
                postNotice(kind: .error, title: "arXiv Search Failed", message: message)
            }
        }
    }

    func processCurrentDiscoverResults(_ papers: [ArxivFeedPaper], actions: Set<DiscoverProcessAction> = Set(DiscoverProcessAction.allCases), modelOverride: String? = nil, reasoningEffort: CodexReasoningEffort? = nil) async {
        guard !isProcessingDiscoverResults else {
            return
        }
        let visiblePapers = uniqueArxivPapers(papers)
        guard !visiblePapers.isEmpty, !actions.isEmpty else {
            return
        }
        let enrichmentRuntimeProfile = agentRuntimeStore.selectedEnrichmentRuntime
        let selectedModelOverride = modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? effectiveDiscoverModelOverride(for: enrichmentRuntimeProfile)
        let selectedReasoningEffort = reasoningEffort ?? discoverCodexReasoningEffort
        isProcessingDiscoverResults = true
        isCancellingDiscoverProcessing = false
        defer {
            isProcessingDiscoverResults = false
            isCancellingDiscoverProcessing = false
            activeDiscoverCodexRunHandles.removeAll()
            discoverProcessingProgress = nil
        }

        for paper in visiblePapers {
            discoverPaperInteractionStateByID[paper.id] = .queued
        }

        if actions.contains(.embedding),
           !isCancellingDiscoverProcessing,
           !Task.isCancelled {
            await processDiscoverEmbeddings(visiblePapers)
        }

        if actions.contains(.translate) || actions.contains(.summarize) {
            let total = visiblePapers.count
            var completed = 0
            var cached = 0
            var failed = 0
            var aggregateTokenUsage = CodexTokenUsage()
            discoverProcessingProgress = ArxivCacheProgress(
                date: selectedArxivDate ?? "\(discoverStartDate)...\(discoverEndDate)",
                title: "Processing results",
                detail: "0/\(total) processed",
                completed: completed,
                total: total
            )

            let workerCount = min(max(discoverCodexConcurrency, 1), max(total, 1))
            var nextIndex = 0

            await withTaskGroup(of: DiscoverPaperProcessingResult.self) { group in
                for _ in 0..<workerCount {
                    guard nextIndex < visiblePapers.count else {
                        break
                    }
                    let paper = visiblePapers[nextIndex]
                    nextIndex += 1
                    group.addTask {
                        await self.processDiscoverPaperForEnrichment(
                            paper,
                            actions: actions,
                            runtimeProfile: enrichmentRuntimeProfile,
                            modelOverride: selectedModelOverride,
                            reasoningEffort: selectedReasoningEffort
                        )
                    }
                }

                while let result = await group.next() {
                    if result.state == .cancelled {
                        group.cancelAll()
                        break
                    }
                    completed += 1
                    switch result.state {
                    case .processed:
                        break
                    case .cached:
                        cached += 1
                    case .failed:
                        failed += 1
                    case .cancelled:
                        break
                    }
                    if let tokenUsage = result.tokenUsage {
                        aggregateTokenUsage.add(tokenUsage)
                    }
                    updateDiscoverProcessingProgress(
                        completed: completed,
                        cached: cached,
                        failed: failed,
                        total: total,
                        tokenUsage: aggregateTokenUsage.isEmpty ? nil : aggregateTokenUsage
                    )
                    if isCancellingDiscoverProcessing || Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if nextIndex < visiblePapers.count {
                        let paper = visiblePapers[nextIndex]
                        nextIndex += 1
                        group.addTask {
                            await self.processDiscoverPaperForEnrichment(
                                paper,
                                actions: actions,
                                runtimeProfile: enrichmentRuntimeProfile,
                                modelOverride: selectedModelOverride,
                                reasoningEffort: selectedReasoningEffort
                            )
                        }
                    }
                }
            }
            if !aggregateTokenUsage.isEmpty {
                postNotice(
                    kind: .info,
                    title: "Process Tokens",
                    message: aggregateTokenUsage.compactSummary,
                    autoDismissAfter: 8
                )
            }
        }

        if actions.contains(.cachePDFThumbnails),
           !isCancellingDiscoverProcessing,
           !Task.isCancelled {
            discoverProcessingProgress = nil
            await cacheDiscoverPDFs(visiblePapers)
        }
    }

    func cancelDiscoverProcessing() {
        isCancellingDiscoverProcessing = true
        for runHandle in activeDiscoverCodexRunHandles {
            runHandle.cancel()
        }
    }

    private func processDiscoverEmbeddings(_ papers: [ArxivFeedPaper]) async {
        let visiblePapers = uniqueArxivPapers(papers)
        guard !visiblePapers.isEmpty else {
            return
        }

        let embeddingSettings = localDiscoverPreferences.normalized.embedding
        let model = embeddingSettings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = embeddingProviderAPIKeyValue().trimmingCharacters(in: .whitespacesAndNewlines)
        guard embeddingSettings.enabled, !embeddingSettings.baseURL.isEmpty, !model.isEmpty, !apiKey.isEmpty else {
            let message = "Embedding provider is disabled or missing Base URL, API key, or model."
            errorMessage = message
            discoverProcessingProgress = ArxivCacheProgress(
                date: discoverProcessingDateLabel(for: visiblePapers),
                title: "Embedding unavailable",
                detail: message,
                completed: 0,
                total: visiblePapers.count
            )
            for paper in visiblePapers {
                discoverPaperInteractionStateByID[paper.id] = .failed
            }
            postNotice(kind: .error, title: "Embedding Unavailable", message: message)
            return
        }

        do {
            for paper in visiblePapers {
                discoverPaperInteractionStateByID[paper.id] = .processing
            }
            let client = try OpenAICompatibleEmbeddingClient(settings: embeddingSettings, apiKey: apiKey)
            let inputs = visiblePapers.map { paper in
                DiscoverEmbeddingInput(
                    sourceID: "arxiv:\(paper.id)",
                    text: trimmedEmbeddingText(DiscoverEmbeddingText.arxivPaperText(paper))
                )
            }
            let vectors = try await cachedEmbeddings(
                inputs: inputs,
                model: model,
                client: client,
                progressDate: discoverProcessingDateLabel(for: visiblePapers),
                progressTitle: "Embedding results",
                totalOffset: 0,
                progressDestination: .discoverProcessing
            )
            let vectorsByID = Dictionary(uniqueKeysWithValues: zip(inputs.map(\.sourceID), vectors))
            let embeddedPapers = visiblePapers.map { paper -> ArxivFeedPaper in
                var embeddedPaper = paper
                embeddedPaper.embedding = vectorsByID["arxiv:\(paper.id)"]
                return embeddedPaper
            }
            mergeDiscoverEmbeddings(from: embeddedPapers)
            let sortedCount = try await rerankDiscoverFeedsAfterEmbeddingProcess(
                visiblePapers: embeddedPapers,
                model: model,
                client: client
            )
            let embeddedCount = embeddedPapers.filter { $0.embedding != nil }.count
            for paper in embeddedPapers {
                discoverPaperInteractionStateByID[paper.id] = paper.embedding == nil ? .failed : .processed
            }
            discoverProcessingProgress = ArxivCacheProgress(
                date: discoverProcessingDateLabel(for: visiblePapers),
                title: "Embedding results sorted",
                detail: "\(embeddedCount)/\(visiblePapers.count) vectors ready · \(sortedCount) scored",
                completed: embeddedCount,
                total: visiblePapers.count
            )
            postNotice(kind: .success, title: "Embeddings Sorted", message: "\(embeddedCount)/\(visiblePapers.count) vectors · \(sortedCount) scored")
        } catch {
            if isCancellingDiscoverProcessing || Task.isCancelled || isCancellationError(error) {
                for paper in visiblePapers {
                    discoverPaperInteractionStateByID[paper.id] = .cancelled
                }
                return
            }
            let message = String(describing: error)
            errorMessage = message
            for paper in visiblePapers {
                discoverPaperInteractionStateByID[paper.id] = .failed
            }
            discoverProcessingProgress = ArxivCacheProgress(
                date: discoverProcessingDateLabel(for: visiblePapers),
                title: "Embedding failed",
                detail: message,
                completed: 0,
                total: visiblePapers.count
            )
            postNotice(kind: .error, title: "Embedding Failed", message: message)
        }
    }

    @discardableResult
    private func rerankDiscoverFeedsAfterEmbeddingProcess(
        visiblePapers: [ArxivFeedPaper],
        model: String,
        client: OpenAICompatibleEmbeddingClient
    ) async throws -> Int {
        let visibleIDs = Set(visiblePapers.map(\.id))
        var scoredIDs: Set<String> = []

        if let feed = arxivFeed,
           feed.papers.contains(where: { visibleIDs.contains($0.id) }) {
            let previousSelectionID = selectedArxivPaper?.id
            let rankedFeed = try await rerankEmbeddedDiscoverFeed(
                feed,
                model: model,
                client: client,
                progressDate: discoverProcessingDateLabel(for: visiblePapers),
                progressTitle: "Sorting Explore results"
            )
            arxivFeed = rankedFeed
            discoverResultIDs = rankedFeed.papers.map(\.id)
            selectedArxivPaper = rankedFeed.papers.first { $0.id == previousSelectionID } ?? rankedFeed.papers.first
            try loadDiscoverEnrichments(for: rankedFeed.papers)
            reloadCachedArxivAssets()
            scoredIDs.formUnion(rankedFeed.papers.compactMap { paper in
                paper.similarity == nil ? nil : paper.id
            })
        }

        if let feed = arxivSearchFeed,
           feed.papers.contains(where: { visibleIDs.contains($0.id) }) {
            let rankedFeed = try await rerankEmbeddedDiscoverFeed(
                feed,
                model: model,
                client: client,
                progressDate: discoverProcessingDateLabel(for: visiblePapers),
                progressTitle: "Sorting Search results"
            )
            arxivSearchFeed = rankedFeed
            mergeDiscoverEnrichments(for: rankedFeed.papers)
            scoredIDs.formUnion(rankedFeed.papers.compactMap { paper in
                paper.similarity == nil ? nil : paper.id
            })
        }

        return scoredIDs.count
    }

    @discardableResult
    private func rerankCurrentDiscoverFeedsForSimilarityChange() async throws -> Int {
        let preferences = localDiscoverPreferences.normalized
        let embeddingSettings = preferences.embedding
        let sourceIDs = effectiveDiscoverSimilaritySourceIDs()
        let model = embeddingSettings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = embeddingProviderAPIKeyValue().trimmingCharacters(in: .whitespacesAndNewlines)
        let client = embeddingSettings.enabled && !sourceIDs.isEmpty && !embeddingSettings.baseURL.isEmpty && !model.isEmpty && !apiKey.isEmpty
            ? try OpenAICompatibleEmbeddingClient(settings: embeddingSettings, apiKey: apiKey)
            : nil
        var scoredIDs: Set<String> = []

        if let feed = arxivFeed {
            let previousSelectionID = selectedArxivPaper?.id
            let resetFeed = resetDiscoverRanking(in: feed)
            let rankedFeed: ArxivFeedResponse
            if let client {
                rankedFeed = try await rerankEmbeddedDiscoverFeed(
                    resetFeed,
                    model: model,
                    client: client,
                    progressDate: selectedArxivDate ?? resetFeed.date,
                    progressTitle: "Sorting Explore results"
                )
            } else {
                rankedFeed = applyLocalDiscoverPreferences(to: resetFeed)
            }
            arxivFeed = rankedFeed
            discoverResultIDs = rankedFeed.papers.map(\.id)
            selectedArxivPaper = rankedFeed.papers.first { $0.id == previousSelectionID } ?? rankedFeed.papers.first
            try loadDiscoverEnrichments(for: rankedFeed.papers)
            reloadCachedArxivAssets()
            scoredIDs.formUnion(rankedFeed.papers.compactMap { paper in
                paper.similarity == nil ? nil : paper.id
            })
        }

        if let feed = arxivSearchFeed {
            let resetFeed = resetDiscoverRanking(in: feed)
            let rankedFeed: ArxivFeedResponse
            if let client {
                rankedFeed = try await rerankEmbeddedDiscoverFeed(
                    resetFeed,
                    model: model,
                    client: client,
                    progressDate: resetFeed.date,
                    progressTitle: "Sorting Search results"
                )
            } else {
                rankedFeed = applyLocalDiscoverPreferences(to: resetFeed)
            }
            arxivSearchFeed = rankedFeed
            mergeDiscoverEnrichments(for: rankedFeed.papers)
            scoredIDs.formUnion(rankedFeed.papers.compactMap { paper in
                paper.similarity == nil ? nil : paper.id
            })
        }

        return scoredIDs.count
    }

    private func cacheDiscoverPDFs(_ papers: [ArxivFeedPaper]) async {
        guard !papers.isEmpty else {
            return
        }
        isCachingDiscoverPDFs = true
        isCancellingDiscoverPDFCache = false
        defer {
            isCachingDiscoverPDFs = false
            isCancellingDiscoverPDFCache = false
            discoverPDFCacheProgress = nil
        }

        let client = makeLocalArxivClient()
        let total = papers.count
        var completed = 0
        var cached = 0
        var failed = 0
        updateDiscoverPDFCacheProgress(completed: completed, cached: cached, failed: failed, total: total)

        for paper in papers {
            if isCancellingDiscoverPDFCache || Task.isCancelled {
                break
            }
            arxivDownloadingPaperIDs.insert(paper.id)
            discoverPaperInteractionStateByID[paper.id] = .downloading
            arxivDownloadProgressByID[paper.id] = 0.08
            do {
                let wasCached = try cachedArxivPDFURL(for: paper) != nil
                let pdfURL = try await ensureArxivPDFCached(paper, client: client)
                arxivDownloadProgressByID[paper.id] = 0.84
                _ = try refreshDiscoverPDFThumbnails(for: paper, pdfURL: pdfURL)
                if wasCached {
                    cached += 1
                }
                arxivDownloadProgressByID[paper.id] = 1
                discoverPaperInteractionStateByID[paper.id] = .pdfCached
            } catch {
                arxivDownloadingPaperIDs.remove(paper.id)
                arxivDownloadProgressByID.removeValue(forKey: paper.id)
                if isCancellationError(error) || isCancellingDiscoverPDFCache || Task.isCancelled {
                    discoverPaperInteractionStateByID[paper.id] = .cancelled
                    break
                }
                discoverPaperInteractionStateByID[paper.id] = .failed
                failed += 1
            }
            completed += 1
            arxivDownloadingPaperIDs.remove(paper.id)
            arxivDownloadProgressByID.removeValue(forKey: paper.id)
            updateDiscoverPDFCacheProgress(completed: completed, cached: cached, failed: failed, total: total)
        }
    }

    private func processDiscoverPaperForEnrichment(
        _ paper: ArxivFeedPaper,
        actions: Set<DiscoverProcessAction>,
        runtimeProfile: AgentRuntimeProfile,
        modelOverride: String,
        reasoningEffort: CodexReasoningEffort
    ) async -> DiscoverPaperProcessingResult {
        if isCancellingDiscoverProcessing || Task.isCancelled {
            discoverPaperInteractionStateByID[paper.id] = .cancelled
            return DiscoverPaperProcessingResult(paperID: paper.id, state: .cancelled)
        }

        let existing = try? localDiscoverCache.loadEnrichment(arxivID: paper.id)
        if let existing,
           discoverEnrichment(existing, satisfies: actions) {
            discoverEnrichmentsByID[paper.id] = existing
            discoverPaperInteractionStateByID[paper.id] = .cached
            return DiscoverPaperProcessingResult(paperID: paper.id, state: .cached)
        }

        do {
            discoverPaperInteractionStateByID[paper.id] = .processing
            let runResult = try await runDiscoverAgentEnrichment(
                for: paper,
                actions: actions,
                runtimeProfile: runtimeProfile,
                existing: existing,
                modelOverride: modelOverride,
                reasoningEffort: reasoningEffort
            )
            try localDiscoverCache.saveEnrichment(runResult.enrichment)
            discoverEnrichmentsByID[paper.id] = runResult.enrichment
            discoverPaperInteractionStateByID[paper.id] = .processed
            return DiscoverPaperProcessingResult(paperID: paper.id, state: .processed, tokenUsage: runResult.tokenUsage)
        } catch {
            if isCancellingDiscoverProcessing || Task.isCancelled || isCancellationError(error) {
                discoverPaperInteractionStateByID[paper.id] = .cancelled
                return DiscoverPaperProcessingResult(paperID: paper.id, state: .cancelled)
            }
            let failedEnrichment = DiscoverPaperEnrichment(
                arxivID: paper.id,
                processorVersion: DiscoverPaperEnrichment.currentProcessorVersion,
                promptVersion: DiscoverPaperEnrichment.currentPromptVersion,
                modelIdentity: discoverModelIdentity(runtimeProfile: runtimeProfile, modelOverride: modelOverride, reasoningEffort: reasoningEffort),
                titleZH: "",
                summaryZH: "",
                contribution: "",
                tags: [],
                links: [:],
                generatedAt: Date(),
                error: String(describing: error)
            )
            try? localDiscoverCache.saveEnrichment(failedEnrichment)
            discoverEnrichmentsByID[paper.id] = failedEnrichment
            discoverPaperInteractionStateByID[paper.id] = .failed
            return DiscoverPaperProcessingResult(paperID: paper.id, state: .failed)
        }
    }

    private func discoverEnrichment(_ enrichment: DiscoverPaperEnrichment, satisfies actions: Set<DiscoverProcessAction>) -> Bool {
        guard enrichment.isCurrent, enrichment.error == nil else {
            return false
        }
        if actions.contains(.translate),
           enrichment.titleZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        if actions.contains(.summarize) {
            let hasSummary = !enrichment.summaryZH.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasContribution = !enrichment.contribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if !hasSummary || !hasContribution || enrichment.tags.isEmpty {
                return false
            }
        }
        return true
    }

    func discoverEnrichment(for paper: ArxivFeedPaper) -> DiscoverPaperEnrichment? {
        discoverEnrichmentsByID[paper.id]
    }

    func refreshArxivDatesAndFeed() async {
        do {
            isLoadingArxivFeed = true
            isRefreshingArxivDates = true
            defer {
                isLoadingArxivFeed = false
                isRefreshingArxivDates = false
            }
            let client = makeLocalArxivClient()
            let feed = try await client.fetchLatestFeed()
            try cacheAndDisplayArxivFeed(feed, title: "Metadata cached")
            try await preloadArxivAssets(includeLarge: false, feed: feed)
        } catch {
            if let date = selectedArxivDate,
               (try? loadCachedArxivFeed(date: date)) == true {
                errorMessage = "Using cached arXiv feed for \(date). Refresh failed: \(error)"
            } else {
                errorMessage = String(describing: error)
            }
        }
    }

    func refreshArxivDates() async {
        do {
            isRefreshingArxivDates = true
            defer {
                isRefreshingArxivDates = false
            }
            let client = makeLocalArxivClient()
            let feed = try await client.fetchLatestFeed()
            try cacheAndDisplayArxivFeed(feed, title: "Latest arXiv date cached")
            if selectedArxivDate == nil {
                selectedArxivDate = feed.date
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func loadArxivFeed(date: String) async {
        do {
            isLoadingArxivFeed = true
            defer {
                isLoadingArxivFeed = false
            }
            selectedArxivDate = date
            arxivFeed = nil
            arxivCacheProgress = ArxivCacheProgress(
                date: date,
                title: "Loading feed",
                detail: "Fetching metadata",
                completed: 0,
                total: 0
            )
            let latestCachedDate = arxivDates.sorted().last
            if latestCachedDate != date,
               (try? loadCachedArxivFeed(date: date)) == true {
                return
            }
            let client = makeLocalArxivClient()
            let feed = try await client.fetchFeed(date: date)
            try cacheAndDisplayArxivFeed(feed, title: "Metadata cached")
            try await preloadArxivAssets(includeLarge: false, feed: feed)
        } catch {
            if (try? loadCachedArxivFeed(date: date)) == true {
                errorMessage = "Using cached arXiv feed for \(date). Refresh failed: \(error)"
            } else {
                errorMessage = String(describing: error)
            }
        }
    }

    func preloadArxivAssets(includeLarge: Bool) async {
        do {
            guard let arxivFeed else {
                return
            }
            try await preloadArxivAssets(includeLarge: includeLarge, feed: arxivFeed)
        } catch {
            if isCancellationError(error) {
                return
            }
            errorMessage = String(describing: error)
        }
    }

    func ensureArxivAssetCached(_ asset: ArxivFeedAsset?) async {
        do {
            guard let asset else {
                return
            }
            if let url = try arxivCache.cachedAssetURL(path: asset.path) {
                arxivAssetURLs[asset.path] = url
                return
            }
            let data = try await fetchArxivAsset(asset)
            arxivAssetURLs[asset.path] = try arxivCache.saveAsset(data, path: asset.path)
        } catch {
            if isCancellationError(error) {
                return
            }
            errorMessage = String(describing: error)
        }
    }

    func cachedArxivAssetURL(for asset: ArxivFeedAsset?) -> URL? {
        guard let asset else {
            return nil
        }
        if let url = arxivAssetURLs[asset.path] {
            return url
        }
        return try? arxivCache.cachedAssetURL(path: asset.path)
    }

    func cachedArxivPDFThumbnailURLs(for paper: ArxivFeedPaper) -> [URL] {
        arxivPDFThumbnailURLsByID[paper.id, default: []]
    }

    func isDownloadingArxivPaper(_ paper: ArxivFeedPaper) -> Bool {
        arxivDownloadingPaperIDs.contains(paper.id)
    }

    func arxivDownloadProgress(for paper: ArxivFeedPaper) -> Double? {
        arxivDownloadProgressByID[paper.id]
    }

    func startCachingDiscoverPDFs(_ papers: [ArxivFeedPaper]) {
        let uniquePapers = uniqueArxivPapers(papers)
        guard !uniquePapers.isEmpty,
              activeDiscoverPDFCacheTask == nil,
              !isCachingDiscoverPDFs else {
            return
        }
        activeDiscoverPDFCacheTask = Task { [weak self] in
            await self?.cacheDiscoverPDFs(uniquePapers)
            await MainActor.run {
                self?.activeDiscoverPDFCacheTask = nil
            }
        }
    }

    func cancelDiscoverPDFCache() {
        isCancellingDiscoverPDFCache = true
        activeDiscoverPDFCacheTask?.cancel()
    }

    func libraryPaper(for arxivPaper: ArxivFeedPaper, includePlaceholders: Bool = true) -> Paper? {
        let absURL = arxivPaper.links.abs
        return papers.first { paper in
            if !includePlaceholders, paper.isArxivImportPlaceholder {
                return false
            }
            return paper.sourceURL == absURL || paper.sourceURL?.contains(arxivPaper.id) == true
        }
    }

    func libraryArxivMetadata(for paper: Paper) -> LibraryPaperArxivMetadata? {
        let canonicalID = paper.arxivImportPlaceholderCanonicalID
            ?? paper.sourceURL.flatMap(ArxivIDExtractor.firstCanonicalID(in:))
        guard let canonicalID else {
            return nil
        }
        let feedPaper = arxivFeed?.papers.first { $0.id == canonicalID }
            ?? arxivSearchFeed?.papers.first { $0.id == canonicalID }
        let enrichment = discoverEnrichmentsByID[canonicalID]
        guard feedPaper != nil || enrichment != nil else {
            return nil
        }
        let tags = uniqueDisplayTags((enrichment?.tags ?? []) + (feedPaper?.tags ?? []) + (feedPaper?.categories ?? []))
        return LibraryPaperArxivMetadata(
            arxivID: canonicalID,
            titleZH: nonEmpty(enrichment?.titleZH) ?? feedPaper?.title.zh ?? "",
            summaryZH: nonEmpty(enrichment?.summaryZH) ?? feedPaper?.summary.zh ?? "",
            contribution: nonEmpty(enrichment?.contribution) ?? "",
            abstractZH: feedPaper?.abstract.zh ?? "",
            abstractEN: feedPaper?.abstract.en ?? "",
            tags: tags
        )
    }

    private func nonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func uniqueDisplayTags(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    func arxivImportPlaceholderDetail(for paper: Paper) -> String {
        guard let canonicalID = paper.arxivImportPlaceholderCanonicalID else {
            return paper.authors.isEmpty ? "Authors not set" : paper.authors.joined(separator: ", ")
        }
        if let failure = failedArxivLibraryImportMessagesByID[canonicalID] {
            return globalLanguageMode == .chinese ? "导入失败 · \(failure)" : "Import failed · \(failure)"
        }
        if pendingArxivLibraryImportIDs.contains(canonicalID) {
            return globalLanguageMode == .chinese ? "正在缓存 arXiv 元数据和 PDF..." : "Caching arXiv metadata and PDF..."
        }
        return globalLanguageMode == .chinese ? "已加入 arXiv 导入队列" : "Queued for arXiv import"
    }

    func openArxivPaper(_ arxivPaper: ArxivFeedPaper) async {
        if let pendingPaper = paper(matchingArxivCanonicalID: arxivPaper.id, includePlaceholders: true),
           pendingPaper.isArxivImportPlaceholder,
           pendingArxivLibraryImportIDs.contains(arxivPaper.id) {
            route = .library
            selectedLibraryPaper = pendingPaper
            postNotice(kind: .info, title: "arXiv Import Running", message: arxivPaper.id)
            return
        }
        if let existing = libraryPaper(for: arxivPaper, includePlaceholders: false) {
            openPaper(existing)
            return
        }
        do {
            let paper = try await importArxivPaper(arxivPaper, isSaved: false)
            try reloadLibrary()
            openPaper(paper)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func suggestedCategoryIDsForDiscoverSave() -> [String] {
        normalizedSimilaritySourceIDs(discoverSelectedSimilaritySourceIDs).compactMap { sourceID in
            guard sourceID.hasPrefix("category:") else {
                return nil
            }
            let categoryID = String(sourceID.dropFirst("category:".count))
            return categories.contains(where: { $0.id == categoryID }) ? categoryID : nil
        }
    }

    func addArxivPaperToLibrary(
        _ arxivPaper: ArxivFeedPaper,
        selectedCategoryIDs: [String] = [],
        newCategoryNames: [String] = [],
        newCategories: [SaveToLibraryNewCategory] = []
    ) async {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            if let pendingPaper = paper(matchingArxivCanonicalID: arxivPaper.id, includePlaceholders: true),
               pendingPaper.isArxivImportPlaceholder,
               pendingArxivLibraryImportIDs.contains(arxivPaper.id) {
                selectedLibraryPaper = pendingPaper
                postNotice(kind: .info, title: "arXiv Import Already Queued", message: arxivPaper.id)
                return
            }
            if let existing = libraryPaper(for: arxivPaper, includePlaceholders: false) {
                try assignCategories(
                    categoryIDs: selectedCategoryIDs,
                    newCategoryNames: newCategoryNames,
                    newCategories: newCategories,
                    to: existing,
                    repository: repository
                )
                try reloadLibrary()
                openPaper(existing)
                return
            }
            let paper = try await importArxivPaper(arxivPaper, isSaved: true)
            try assignCategories(
                categoryIDs: selectedCategoryIDs,
                newCategoryNames: newCategoryNames,
                newCategories: newCategories,
                to: paper,
                repository: repository
            )
            try reloadLibrary()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func enqueueArxivIDsForLibrary(_ versionedIDs: [String], categoryID: String?) {
        let ids = uniqueVersionedArxivIDs(versionedIDs)
        guard !ids.isEmpty else {
            return
        }
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            var queuedIDs: [String] = []
            var placeholderPaperIDs: [String] = []
            var alreadyAvailableCount = 0
            for versionedID in ids {
                let canonicalID = ArxivIDExtractor.canonicalID(from: versionedID)
                if let existing = paper(matchingArxivCanonicalID: canonicalID, includePlaceholders: false) {
                    try transferAndDeleteArxivImportPlaceholder(canonicalID: canonicalID, toPaperID: existing.id, categoryID: categoryID, repository: repository)
                    alreadyAvailableCount += 1
                    continue
                }

                let placeholder = makeArxivImportPlaceholderPaper(canonicalID: canonicalID)
                try repository.upsertPaper(placeholder)
                if let categoryID {
                    try repository.assignPaper(placeholder.id, toCategory: categoryID)
                }
                placeholderPaperIDs.append(placeholder.id)
                failedArxivLibraryImportMessagesByID.removeValue(forKey: canonicalID)
                if !pendingArxivLibraryImportIDs.contains(canonicalID) {
                    pendingArxivLibraryImportIDs.insert(canonicalID)
                    queuedIDs.append(versionedID)
                }
            }

            try reloadLibrary()
            route = .library
            if let firstPlaceholderID = placeholderPaperIDs.first,
               let placeholder = papers.first(where: { $0.id == firstPlaceholderID }) {
                selectedLibraryPaper = placeholder
            }
            if !queuedIDs.isEmpty {
                postNotice(
                    kind: .info,
                    title: "arXiv Import Started",
                    message: "\(queuedIDs.count) queued\(alreadyAvailableCount > 0 ? " · \(alreadyAvailableCount) already ready" : "")"
                )
                Task { [weak self] in
                    await self?.completeQueuedArxivLibraryImports(queuedIDs, categoryID: categoryID)
                }
            } else if alreadyAvailableCount > 0 {
                postNotice(kind: .info, title: "Already in Library", message: "\(alreadyAvailableCount) paper\(alreadyAvailableCount == 1 ? "" : "s")")
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func addArxivIDToLibrary(_ versionedID: String, categoryID: String?) async -> LibraryArxivImportOutcome {
        let canonicalID = ArxivIDExtractor.canonicalID(from: versionedID)
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let arxivPaper = try await cachedArxivPaperForLibraryImport(versionedID: versionedID, canonicalID: canonicalID)

            if let existing = libraryPaper(for: arxivPaper, includePlaceholders: false) {
                try transferAndDeleteArxivImportPlaceholder(canonicalID: canonicalID, toPaperID: existing.id, categoryID: categoryID, repository: repository)
                try reloadLibrary()
                selectedLibraryPaper = papers.first { $0.id == existing.id } ?? existing
                return LibraryArxivImportOutcome(
                    requestedID: versionedID,
                    canonicalID: canonicalID,
                    title: existing.title,
                    state: .alreadyInLibrary,
                    message: categoryID == nil ? "Already in Library" : "Already in Library · folder updated"
                )
            }

            let importedPaper = try await importArxivPaper(arxivPaper, isSaved: true)
            try transferAndDeleteArxivImportPlaceholder(canonicalID: canonicalID, toPaperID: importedPaper.id, categoryID: categoryID, repository: repository)
            try reloadLibrary()
            selectedLibraryPaper = papers.first { $0.id == importedPaper.id } ?? importedPaper
            return LibraryArxivImportOutcome(
                requestedID: versionedID,
                canonicalID: canonicalID,
                title: importedPaper.title,
                state: .imported,
                message: categoryID == nil ? "Imported" : "Imported to folder"
            )
        } catch {
            let isRateLimited = isArxivRateLimitError(error)
            let message = String(describing: error)
            if !isRateLimited {
                errorMessage = message
            }
            return LibraryArxivImportOutcome(
                requestedID: versionedID,
                canonicalID: canonicalID,
                title: "",
                state: .failed,
                message: message,
                isRateLimited: isRateLimited
            )
        }
    }

    private func completeQueuedArxivLibraryImports(_ versionedIDs: [String], categoryID: String?, attempt: Int = 0) async {
        var readyCount = 0
        var retryIDs: [String] = []
        for versionedID in versionedIDs {
            let outcome = await addArxivIDToLibrary(versionedID, categoryID: categoryID)
            switch outcome.state {
            case .imported:
                pendingArxivLibraryImportIDs.remove(outcome.canonicalID)
                failedArxivLibraryImportMessagesByID.removeValue(forKey: outcome.canonicalID)
                readyCount += 1
            case .alreadyInLibrary:
                pendingArxivLibraryImportIDs.remove(outcome.canonicalID)
                failedArxivLibraryImportMessagesByID.removeValue(forKey: outcome.canonicalID)
            case .failed:
                if outcome.isRateLimited,
                   attempt < arxivLibraryImportRetryDelaysNanoseconds.count {
                    retryIDs.append(outcome.requestedID)
                    failedArxivLibraryImportMessagesByID.removeValue(forKey: outcome.canonicalID)
                } else {
                    pendingArxivLibraryImportIDs.remove(outcome.canonicalID)
                    failedArxivLibraryImportMessagesByID[outcome.canonicalID] = outcome.message
                    postNotice(kind: .error, title: "arXiv Import Failed", message: "\(outcome.canonicalID) · \(outcome.message)", autoDismissAfter: nil)
                }
            }
        }
        if readyCount > 0 {
            postNotice(kind: .success, title: "arXiv Import Finished", message: "\(readyCount) paper\(readyCount == 1 ? "" : "s") ready")
        }
        guard !retryIDs.isEmpty,
              attempt < arxivLibraryImportRetryDelaysNanoseconds.count else {
            return
        }
        let delay = arxivLibraryImportRetryDelaysNanoseconds[attempt]
        postNotice(
            kind: .info,
            title: "Retrying arXiv Import",
            message: "arXiv is rate limiting. \(retryIDs.count) queued paper\(retryIDs.count == 1 ? "" : "s") will retry in \(Int(delay / 1_000_000_000))s."
        )
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else {
                return
            }
            await self?.completeQueuedArxivLibraryImports(retryIDs, categoryID: categoryID, attempt: attempt + 1)
        }
    }

    private func cachedArxivPaperForLibraryImport(versionedID: String, canonicalID: String) async throws -> ArxivFeedPaper {
        if let paper = arxivFeed?.papers.first(where: { $0.id == canonicalID }) {
            return paper
        }
        if let paper = try arxivCache.loadPaper(arxivID: canonicalID) {
            return paper
        }

        let metadataPapers = try await makeLocalArxivClient().fetchPapers(ids: [versionedID])
        guard let arxivPaper = metadataPapers.first(where: { $0.id == canonicalID }) ?? metadataPapers.first else {
            throw AppModelError.arxivMetadataNotFound(versionedID)
        }
        return arxivPaper
    }

    private func isArxivRateLimitError(_ error: Error) -> Bool {
        if case LocalArxivClientError.badStatus(429, _) = error {
            return true
        }
        return String(describing: error).contains("HTTP 429")
    }

    private func uniqueVersionedArxivIDs(_ versionedIDs: [String]) -> [String] {
        var seenCanonicalIDs: Set<String> = []
        var result: [String] = []
        for versionedID in versionedIDs {
            let canonicalID = ArxivIDExtractor.canonicalID(from: versionedID)
            guard seenCanonicalIDs.insert(canonicalID).inserted else {
                continue
            }
            result.append(versionedID)
        }
        return result
    }

    private func makeArxivImportPlaceholderPaper(canonicalID: String) -> Paper {
        let now = Date()
        return Paper(
            id: Paper.makeArxivImportPlaceholderID(for: canonicalID),
            filePath: "",
            fileHash: Paper.arxivImportPlaceholderFileHash(canonicalID: canonicalID),
            title: canonicalID,
            authors: [],
            year: nil,
            sourceURL: "https://arxiv.org/abs/\(canonicalID)",
            isSaved: true,
            importedAt: now,
            updatedAt: now
        )
    }

    private func paper(matchingArxivCanonicalID canonicalID: String, includePlaceholders: Bool) -> Paper? {
        papers.first { paper in
            if !includePlaceholders, paper.isArxivImportPlaceholder {
                return false
            }
            return paper.arxivImportPlaceholderCanonicalID == canonicalID
                || paper.sourceURL == "https://arxiv.org/abs/\(canonicalID)"
                || paper.sourceURL?.contains(canonicalID) == true
        }
    }

    private func transferAndDeleteArxivImportPlaceholder(
        canonicalID: String,
        toPaperID paperID: String,
        categoryID: String?,
        repository: PaperRepository
    ) throws {
        let placeholderID = Paper.makeArxivImportPlaceholderID(for: canonicalID)
        if let categoryID {
            try repository.assignPaper(paperID, toCategory: categoryID)
        }
        guard placeholderID != paperID,
              try repository.fetchPapers(ids: [placeholderID]).first != nil else {
            return
        }
        let placeholderCategoryIDs = try repository.fetchCategoryIDs(forPaperID: placeholderID)
        let placeholderTags = try repository.fetchTags(forPaperID: placeholderID)
        for categoryID in placeholderCategoryIDs {
            try repository.assignPaper(paperID, toCategory: categoryID)
        }
        for tag in placeholderTags {
            try repository.assignPaper(paperID, toTag: tag.id)
        }
        try repository.deletePapers(ids: [placeholderID])
    }

    func saveCachedPaperToLibrary(
        _ paper: Paper,
        selectedCategoryIDs: [String] = [],
        newCategoryNames: [String] = [],
        newCategories: [SaveToLibraryNewCategory] = []
    ) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard !paper.isSaved else {
                return
            }
            let metadata = PaperImportMetadata(
                title: paper.title,
                authors: paper.authors,
                year: paper.year,
                sourceURL: paper.sourceURL
            )
            let result = try PaperLibraryImporter(repository: repository, supportRoot: supportRoot)
                .importPDF(
                    from: URL(fileURLWithPath: paper.filePath),
                    metadata: metadata,
                    isSaved: true,
                    storageSubpath: arxivStorageSubpath(forCachedPaper: paper)
                )
            try reloadLibrary()
            try assignCategories(
                categoryIDs: selectedCategoryIDs,
                newCategoryNames: newCategoryNames,
                newCategories: newCategories,
                to: result.paper,
                repository: repository
            )
            try reloadLibrary()
            let savedPaper = papers.first { $0.id == result.paper.id } ?? result.paper
            selectedLibraryPaper = savedPaper
            selectedPaper = savedPaper
            replaceReaderTab(oldPaperID: paper.id, with: savedPaper)
            if let session = selectedSession {
                let context = try loadSessionPaperContext(session: session, fallbackPaper: savedPaper, repository: repository)
                try workspaceManager.writeWorkspace(
                    session: session,
                    papers: context.papers,
                    pagesByPaperID: context.pagesByPaperID,
                    spansByPaperID: context.spansByPaperID,
                    anchorsByPaperID: context.anchorsByPaperID,
                    mcpEndpoint: mcpEndpoint
                )
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func clearArxivCaches() {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            try repository.deleteUnsavedPapers()
            try removeDirectoryIfExists(supportRoot.appendingPathComponent("cache", isDirectory: true))
            try removeDirectoryIfExists(supportRoot.appendingPathComponent("arxiv-cache", isDirectory: true))
            arxivFeed = nil
            selectedArxivPaper = nil
            arxivAssetURLs = [:]
            arxivPDFThumbnailURLsByID = [:]
            discoverPDFCacheProgress = nil
            try reloadLibrary()
            refreshCacheStorageSummary()
            postNotice(kind: .success, title: "arXiv Cache Cleared", message: "Temporary feeds, PDFs, and previews were removed.")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func createCategory(name: String, parentID: String?) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppModelError.emptyName
            }
            let nextSortOrder = (categories.map(\.sortOrder).max() ?? 0) + 1
            let category = PaperCodexCore.Category(
                id: makeManualID(prefix: "cat", name: trimmed),
                parentID: parentID,
                name: trimmed,
                sortOrder: nextSortOrder
            )
            try repository.upsertCategory(category)
            includeCategoryInSimilarityDefaults(category.id)
            try reloadLibrary()
            postNotice(kind: .success, title: "Category Created", message: trimmed)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func updateCategory(_ categoryID: String, name: String, parentID: String?) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard var category = categories.first(where: { $0.id == categoryID }) else {
                throw AppModelError.categoryNotFound(categoryID)
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppModelError.emptyName
            }
            if parentID == categoryID || categoryDescendantIDs(of: categoryID).contains(parentID ?? "") {
                throw AppModelError.invalidCategoryMove
            }
            category.name = trimmed
            category.parentID = parentID
            try repository.upsertCategory(category)
            try reloadLibrary()
            postNotice(kind: .success, title: "Category Updated", message: trimmed)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func moveCategory(_ categoryID: String, toParent parentID: String?) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard let category = categories.first(where: { $0.id == categoryID }) else {
                throw AppModelError.categoryNotFound(categoryID)
            }
            let updatedCategories = try CategoryMovePlanner.movedCategories(
                movingCategoryID: categoryID,
                toParent: parentID,
                in: categories
            )
            let changedCategories = categoryChanges(from: categories, to: updatedCategories)
            guard !changedCategories.isEmpty else {
                return
            }
            try saveCategoryChanges(changedCategories, repository: repository)
            libraryStore.applyCategories(updatedCategories)
            postNotice(kind: .success, title: "Category Moved", message: category.name)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func reorderCategory(
        _ categoryID: String,
        relativeTo targetCategoryID: String,
        placement: LibraryCategoryDropPlacement,
        postsNotice: Bool = true
    ) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard let category = categories.first(where: { $0.id == categoryID }) else {
                throw AppModelError.categoryNotFound(categoryID)
            }
            let updatedCategories = try CategoryMovePlanner.reorderedCategories(
                movingCategoryID: categoryID,
                relativeTo: targetCategoryID,
                placement: placement,
                in: categories
            )
            let changedCategories = categoryChanges(from: categories, to: updatedCategories)
            guard !changedCategories.isEmpty else {
                return
            }
            try saveCategoryChanges(changedCategories, repository: repository)
            libraryStore.applyCategories(updatedCategories)
            if postsNotice {
                postNotice(kind: .success, title: "Category Reordered", message: category.name)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setCategoryPinned(_ categoryID: String, pinned: Bool) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard var category = categories.first(where: { $0.id == categoryID }) else {
                throw AppModelError.categoryNotFound(categoryID)
            }
            guard category.isPinned != pinned else {
                return
            }
            category.isPinned = pinned
            var siblings = sortedCategorySiblings(parentID: category.parentID).filter { $0.id != categoryID }
            let insertionIndex: Int
            if pinned {
                insertionIndex = 0
            } else {
                insertionIndex = siblings.firstIndex { !$0.isPinned } ?? siblings.count
            }
            siblings.insert(category, at: insertionIndex)
            try saveNormalizedCategoryOrder(siblings, repository: repository)
            try reloadLibrary()
            postNotice(kind: .success, title: pinned ? "Folder Pinned" : "Folder Unpinned", message: category.name)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func deleteCategory(_ categoryID: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let name = categories.first { $0.id == categoryID }?.name ?? "Category"
            try repository.deleteCategory(id: categoryID)
            try reloadLibrary()
            postNotice(kind: .success, title: "Category Deleted", message: name)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func createTag(name: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppModelError.emptyName
            }
            if tags.contains(where: { $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
                postNotice(kind: .info, title: "Tag Already Exists", message: trimmed)
                return
            }
            try repository.upsertTag(PaperTag(id: makeManualID(prefix: "tag", name: trimmed), name: trimmed))
            try reloadLibrary()
            postNotice(kind: .success, title: "Tag Created", message: trimmed)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func updateTag(_ tagID: String, name: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppModelError.emptyName
            }
            try repository.upsertTag(PaperTag(id: tagID, name: trimmed))
            try reloadLibrary()
            postNotice(kind: .success, title: "Tag Updated", message: trimmed)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func deleteTag(_ tagID: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let name = tags.first { $0.id == tagID }?.name ?? "Tag"
            try repository.deleteTag(id: tagID)
            try reloadLibrary()
            postNotice(kind: .success, title: "Tag Deleted", message: name)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func categoryDescendantIDs(of categoryID: String) -> Set<String> {
        var descendants: Set<String> = []
        var didChange = true
        while didChange {
            didChange = false
            for category in categories where category.parentID.map({ $0 == categoryID || descendants.contains($0) }) == true && !descendants.contains(category.id) {
                descendants.insert(category.id)
                didChange = true
            }
        }
        return descendants
    }

    func categoryIsDescendant(_ categoryID: String, of ancestorID: String) -> Bool {
        categoryDescendantIDs(of: ancestorID).contains(categoryID)
    }

    func canMoveCategory(_ categoryID: String, toParent parentID: String?) -> Bool {
        CategoryMovePlanner.canMoveCategory(categoryID, toParent: parentID, in: categories)
    }

    func canDropCategory(_ categoryID: String, onto targetCategoryID: String, placement: LibraryCategoryDropPlacement) -> Bool {
        CategoryMovePlanner.canDropCategory(
            categoryID,
            ontoCategory: targetCategoryID,
            placement: placement,
            in: categories
        )
    }

    private func sortedCategorySiblings(parentID: String?) -> [PaperCodexCore.Category] {
        categories
            .filter { $0.parentID == parentID }
            .sorted(by: categorySortPrecedes)
    }

    private func categorySortPrecedes(_ left: PaperCodexCore.Category, _ right: PaperCodexCore.Category) -> Bool {
        if left.isPinned != right.isPinned {
            return left.isPinned
        }
        if left.sortOrder != right.sortOrder {
            return left.sortOrder < right.sortOrder
        }
        let nameComparison = left.name.localizedCaseInsensitiveCompare(right.name)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        return left.id < right.id
    }

    private func nextCategorySortOrder(parentID: String?) -> Int {
        (categories.filter { $0.parentID == parentID }.map(\.sortOrder).max() ?? 0) + 10
    }

    private func saveNormalizedCategoryOrder(_ siblings: [PaperCodexCore.Category], repository: PaperRepository) throws {
        for (index, sibling) in siblings.enumerated() {
            var updated = sibling
            updated.sortOrder = (index + 1) * 10
            try repository.upsertCategory(updated)
        }
    }

    private func categoryChanges(
        from currentCategories: [PaperCodexCore.Category],
        to updatedCategories: [PaperCodexCore.Category]
    ) -> [PaperCodexCore.Category] {
        let currentCategoriesByID = Dictionary(uniqueKeysWithValues: currentCategories.map { ($0.id, $0) })
        return updatedCategories.filter { currentCategoriesByID[$0.id] != $0 }
    }

    private func saveCategoryChanges(_ changedCategories: [PaperCodexCore.Category], repository: PaperRepository) throws {
        for category in changedCategories {
            try repository.upsertCategory(category)
        }
    }

    func setCategory(_ categoryID: String, assigned: Bool, for paper: Paper) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            if assigned {
                try repository.assignPaper(paper.id, toCategory: categoryID)
            } else {
                try repository.removePaper(paper.id, fromCategory: categoryID)
            }
            try reloadLibrary()
            postNotice(kind: .success, title: assigned ? "Category Assigned" : "Category Removed", message: paper.title)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func assignPapers(_ paperIDs: [String], toCategory categoryID: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard categories.contains(where: { $0.id == categoryID }) else {
                throw AppModelError.categoryNotFound(categoryID)
            }
            let validPaperIDs = Set(papers.map(\.id))
            var assignedPaperIDs = Set<String>()
            for paperID in paperIDs where validPaperIDs.contains(paperID) && !assignedPaperIDs.contains(paperID) {
                try repository.assignPaper(paperID, toCategory: categoryID)
                assignedPaperIDs.insert(paperID)
            }
            guard !assignedPaperIDs.isEmpty else {
                return
            }
            try reloadLibrary()
            postNotice(kind: .success, title: "Papers Assigned", message: "\(assignedPaperIDs.count) moved into category")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func copyPapers(_ paperIDs: [String], toCategory categoryID: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard categories.contains(where: { $0.id == categoryID }) else {
                throw AppModelError.categoryNotFound(categoryID)
            }
            let validPaperIDs = Set(papers.map(\.id))
            var copiedPaperIDs = Set<String>()
            for paperID in paperIDs where validPaperIDs.contains(paperID) && !copiedPaperIDs.contains(paperID) {
                try repository.assignPaper(paperID, toCategory: categoryID)
                copiedPaperIDs.insert(paperID)
            }
            guard !copiedPaperIDs.isEmpty else {
                return
            }
            try reloadLibrary()
            postNotice(kind: .success, title: "已复制", message: "\(copiedPaperIDs.count) 篇论文")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func movePapers(_ paperIDs: [String], toCategory categoryID: String?) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            if let categoryID, !categories.contains(where: { $0.id == categoryID }) {
                throw AppModelError.categoryNotFound(categoryID)
            }
            let validPaperIDs = Set(papers.map(\.id))
            var movedPaperIDs = Set<String>()
            for paperID in paperIDs where validPaperIDs.contains(paperID) && !movedPaperIDs.contains(paperID) {
                for existingCategoryID in paperCategoryIDsByID[paperID, default: []] {
                    try repository.removePaper(paperID, fromCategory: existingCategoryID)
                }
                if let categoryID {
                    try repository.assignPaper(paperID, toCategory: categoryID)
                }
                movedPaperIDs.insert(paperID)
            }
            guard !movedPaperIDs.isEmpty else {
                return
            }
            try reloadLibrary()
            postNotice(kind: .success, title: "已移动", message: "\(movedPaperIDs.count) 篇论文")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func assignPapers(_ paperIDs: [String], toTags tagIDs: [String]) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let validPaperIDs = Set(papers.map(\.id))
            let validTagIDs = Set(tags.map(\.id))
            let assignableTagIDs = Array(Set(tagIDs).intersection(validTagIDs)).sorted()
            guard !assignableTagIDs.isEmpty else {
                return
            }
            var assignedPaperIDs = Set<String>()
            for paperID in paperIDs where validPaperIDs.contains(paperID) && !assignedPaperIDs.contains(paperID) {
                for tagID in assignableTagIDs {
                    try repository.assignPaper(paperID, toTag: tagID)
                }
                assignedPaperIDs.insert(paperID)
            }
            guard !assignedPaperIDs.isEmpty else {
                return
            }
            try reloadLibrary()
            postNotice(kind: .success, title: "Tags Applied", message: "\(assignableTagIDs.count) tag\(assignableTagIDs.count == 1 ? "" : "s") · \(assignedPaperIDs.count) paper\(assignedPaperIDs.count == 1 ? "" : "s")")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func deletePapers(_ paperIDs: [String]) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let requestedIDs = Set(paperIDs)
            let papersToDelete = papers.filter { requestedIDs.contains($0.id) }
            guard !papersToDelete.isEmpty else {
                return
            }
            let deletedIDs = Set(papersToDelete.map(\.id))
            try repository.deletePapers(ids: Array(deletedIDs))
            for paper in papersToDelete {
                try removeManagedPaperStorage(for: paper)
            }
            for paperID in deletedIDs {
                paperNotesByID.removeValue(forKey: paperID)
                loadedPaperNotesPaperIDs.remove(paperID)
            }
            if let selectedLibraryPaper, deletedIDs.contains(selectedLibraryPaper.id) {
                self.selectedLibraryPaper = nil
            }
            if let selectedPaper, deletedIDs.contains(selectedPaper.id) {
                self.selectedPaper = nil
                selectedSession = nil
                sessions = []
                messages = []
                currentSelection = nil
                pdfJumpTarget = nil
                readerPosition = nil
                clearActiveCodexRunIfIdle()
                if route == .reader {
                    route = .library
                }
            }
            var tabState = readerTabState
            for paperID in deletedIDs {
                _ = tabState.close(paperID)
            }
            readerTabState = tabState
            try reloadLibrary()
            refreshCacheStorageSummary()
            postNotice(kind: .success, title: "Papers Deleted", message: "\(deletedIDs.count) removed")
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setTag(_ tagID: String, assigned: Bool, for paper: Paper) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            if assigned {
                try repository.assignPaper(paper.id, toTag: tagID)
            } else {
                try repository.removePaper(paper.id, fromTag: tagID)
            }
            try reloadLibrary()
            postNotice(kind: .success, title: assigned ? "Tag Assigned" : "Tag Removed", message: paper.title)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func togglePaperStar(_ paper: Paper) {
        setPaperStarred(!paper.isStarred, for: paper)
    }

    func setPaperStarred(_ isStarred: Bool, for paper: Paper) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            try repository.setPaperStarred(isStarred, paperID: paper.id)
            try reloadLibrary()
            if selectedPaper?.id == paper.id {
                selectedPaper = papers.first { $0.id == paper.id } ?? selectedPaper
            }
            postNotice(kind: .success, title: isStarred ? "Paper Starred" : "Paper Unstarred", message: paper.title)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func loadPaperNotes(for paper: Paper, force: Bool = false) {
        guard force || !loadedPaperNotesPaperIDs.contains(paper.id) else {
            return
        }
        if !force && paperNotesLoadTasks[paper.id] != nil {
            return
        }
        let paperID = paper.id
        let databasePath = supportRoot.appendingPathComponent("store.sqlite").path
        paperNotesLoadTasks[paperID]?.cancel()
        paperNotesLoadTasks[paperID] = Task { [weak self] in
            do {
                let notes = try await Task.detached(priority: .userInitiated) {
                    let repository = try PaperRepository(databasePath: databasePath)
                    return try repository.fetchNotes(paperID: paperID)
                }.value
                guard let self, !Task.isCancelled else {
                    return
                }
                self.paperNotesByID[paperID] = notes
                self.loadedPaperNotesPaperIDs.insert(paperID)
                self.paperNotesLoadTasks[paperID] = nil
            } catch {
                guard let self, !Task.isCancelled, !isCancellationError(error) else {
                    return
                }
                self.paperNotesLoadTasks[paperID] = nil
                self.errorMessage = String(describing: error)
            }
        }
    }

    func saveNote(paperID: String, noteID: String?, title: String, bodyMarkdown: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedBody = bodyMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else {
                throw AppModelError.emptyName
            }
            let existing = noteID.flatMap { id in paperNotesByID[paperID, default: []].first { $0.id == id } }
            let now = Date()
            let note = PaperNote(
                id: existing?.id ?? "note-\(UUID().uuidString.lowercased())",
                paperID: paperID,
                anchorID: existing?.anchorID,
                title: trimmedTitle.isEmpty ? "Untitled note" : trimmedTitle,
                bodyMarkdown: trimmedBody,
                createdAt: existing?.createdAt ?? now,
                updatedAt: now,
                deletedAt: nil,
                syncRevision: (existing?.syncRevision ?? 0) + 1
            )
            try repository.upsertNote(note)
            paperNotesByID[paperID] = try repository.fetchNotes(paperID: paperID)
            loadedPaperNotesPaperIDs.insert(paperID)
            postNotice(kind: .success, title: existing == nil ? "Note Added" : "Note Updated", message: note.title)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func deleteNote(_ note: PaperNote) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            try repository.deleteNote(id: note.id)
            paperNotesByID[note.paperID] = try repository.fetchNotes(paperID: note.paperID)
            loadedPaperNotesPaperIDs.insert(note.paperID)
            postNotice(kind: .success, title: "Note Deleted", message: note.title)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func openOrUpdateReaderTab(_ paper: Paper) {
        var tabState = readerTabState
        tabState.open(ReaderPaperTab(paper: paper))
        readerTabState = tabState
    }

    private func selectOrOpenReaderTab(_ paper: Paper) {
        var tabState = readerTabState
        if tabState.tabs.contains(where: { $0.paperID == paper.id }) {
            _ = tabState.select(paper.id)
        } else {
            tabState.open(ReaderPaperTab(paper: paper))
        }
        readerTabState = tabState
    }

    private func replaceReaderTab(oldPaperID: String, with paper: Paper) {
        var tabState = readerTabState
        tabState.replace(oldPaperID, with: ReaderPaperTab(paper: paper))
        readerTabState = tabState
    }

    private func loadReaderPositionForSelectedContext(repository: PaperRepository) throws {
        try flushPendingReaderPositionSave(repository: repository)
        guard let session = selectedSession, let paper = selectedPaper else {
            readerPosition = nil
            return
        }
        readerPosition = try repository.fetchReaderPosition(sessionID: session.id, paperID: paper.id)
    }

    func updateReaderPosition(_ viewportPosition: PDFViewportPosition) {
        do {
            guard repository != nil else {
                throw AppModelError.repositoryUnavailable
            }
            guard let session = selectedSession, let paper = selectedPaper else {
                readerPosition = nil
                return
            }
            guard viewportPosition.pageIndex >= 0,
                  viewportPosition.pagePointX.isFinite,
                  viewportPosition.pagePointY.isFinite,
                  viewportPosition.scaleFactor.isFinite,
                  viewportPosition.scaleFactor > 0 else {
                return
            }
            let position = PaperReaderPosition(
                sessionID: session.id,
                paperID: paper.id,
                pageIndex: viewportPosition.pageIndex,
                pagePointX: viewportPosition.pagePointX,
                pagePointY: viewportPosition.pagePointY,
                scaleFactor: viewportPosition.scaleFactor,
                updatedAt: Date()
            )
            scheduleReaderPositionSave(position)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func scheduleReaderPositionSave(_ position: PaperReaderPosition) {
        pendingReaderPosition = position
        pendingReaderPositionSaveTask?.cancel()
        let databasePath = supportRoot.appendingPathComponent("store.sqlite").path
        pendingReaderPositionSaveTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: readerPositionSaveDelayNanoseconds)
                try await Self.persistReaderPosition(position, databasePath: databasePath)
                guard let self, !Task.isCancelled else {
                    return
                }
                if self.pendingReaderPosition == position {
                    self.readerPosition = position
                    self.pendingReaderPosition = nil
                }
                self.pendingReaderPositionSaveTask = nil
            } catch {
                guard let self, !Task.isCancelled, !isCancellationError(error) else {
                    return
                }
                self.pendingReaderPositionSaveTask = nil
                self.errorMessage = String(describing: error)
            }
        }
    }

    private func flushPendingReaderPositionSave(repository: PaperRepository) throws {
        guard let position = pendingReaderPosition else {
            return
        }
        pendingReaderPositionSaveTask?.cancel()
        pendingReaderPositionSaveTask = nil
        try repository.upsertReaderPosition(position)
        readerPosition = position
        pendingReaderPosition = nil
    }

    private nonisolated static func persistReaderPosition(
        _ position: PaperReaderPosition,
        databasePath: String
    ) async throws {
        try await Task.detached(priority: .utility) {
            let repository = try PaperRepository(databasePath: databasePath)
            try repository.upsertReaderPosition(position)
        }.value
    }

    func updatePDFDocumentStatus(_ status: PDFDocumentStatus) {
        pdfDocumentStatus = status
    }

    func sendPDFKitCommand(_ kind: PDFKitCommandKind) {
        pdfKitCommand = PDFKitCommand(kind: kind)
    }

    private func paperForReaderTab(_ tab: ReaderPaperTab) throws -> Paper? {
        if selectedPaper?.id == tab.paperID {
            return selectedPaper
        }
        if let paper = papers.first(where: { $0.id == tab.paperID }) {
            return paper
        }
        guard let repository else {
            throw AppModelError.repositoryUnavailable
        }
        return try repository.fetchPapers(ids: [tab.paperID]).first
    }

    private func focusPaperForReader(_ paper: Paper, opensReaderTab: Bool) throws {
        try openPaperSet([paper.id], focusedPaperID: paper.id, opensReaderTabs: opensReaderTab, panelTab: selectedSessionPanelTab)
    }

    private func sessionsForPaperSet(paperIDs: [String], repository: PaperRepository) throws -> [PaperSession] {
        guard let firstPaperID = paperIDs.first else {
            return []
        }
        return try repository.fetchSessions(paperID: firstPaperID).filter { session in
            session.paperIDs.count == paperIDs.count && Set(session.paperIDs) == Set(paperIDs)
        }
    }

    private func reloadSessionsForVisibleContext(repository: PaperRepository) throws {
        let paperIDs = currentReaderPaperIDs()
        sessions = try sessionsForPaperSet(paperIDs: paperIDs, repository: repository)
    }

    private func currentReaderPaperIDs() -> [String] {
        if let selectedSession, !selectedSession.paperIDs.isEmpty {
            return uniqueIDs(selectedSession.paperIDs)
        }
        if let selectedPaper {
            return [selectedPaper.id]
        }
        return []
    }

    private func focusPaperInCurrentReaderSession(_ paper: Paper) throws {
        openOrUpdateReaderTab(paper)
        selectedLibraryPaper = paper
        selectedPaper = paper
        currentSelection = nil
        pdfJumpTarget = nil
        guard let repository else {
            throw AppModelError.repositoryUnavailable
        }
        if let selectedSession, selectedSession.paperIDs.contains(paper.id) {
            try reloadSessionsForVisibleContext(repository: repository)
            try loadReaderPositionForSelectedContext(repository: repository)
            return
        }
        try focusPaperForReader(paper, opensReaderTab: false)
    }

    private func openPaperSet(
        _ paperIDs: [String],
        focusedPaperID: String? = nil,
        opensReaderTabs: Bool,
        panelTab: SessionPanelTab
    ) throws {
        guard let repository else {
            throw AppModelError.repositoryUnavailable
        }
        let uniquePaperIDs = uniqueIDs(paperIDs)
        let paperSet = try repository.fetchPapers(ids: uniquePaperIDs).filter { !$0.isArxivImportPlaceholder }
        guard let firstPaper = paperSet.first else {
            throw AppModelError.noSelectedPaper
        }
        let focusID = focusedPaperID.flatMap { id in
            paperSet.first(where: { $0.id == id })?.id
        } ?? firstPaper.id
        let focusedPaper = paperSet.first(where: { $0.id == focusID }) ?? firstPaper

        selectedSessionPanelTab = panelTab
        selectedLibraryPaper = focusedPaper
        selectedPaper = focusedPaper
        currentSelection = nil
        pdfJumpTarget = nil
        citationReturnPoint = nil
        if opensReaderTabs {
            for paper in paperSet {
                openOrUpdateReaderTab(paper)
            }
        }
        selectOrOpenReaderTab(focusedPaper)

        sessions = try sessionsForPaperSet(paperIDs: paperSet.map(\.id), repository: repository)
        if let latestSession = sessions.last {
            selectedSession = latestSession
            messages = try repository.fetchMessages(sessionID: latestSession.id)
        } else {
            try createSession(paperIDs: paperSet.map(\.id))
        }
        try loadReaderPositionForSelectedContext(repository: repository)
        clearActiveCodexRunIfIdle()
        route = .reader
    }

    func openPaper(_ paper: Paper) {
        do {
            if route == .discover {
                readerReturnRoute = .discover
            } else if route == .search {
                readerReturnRoute = .search
            } else if route == .library {
                readerReturnRoute = .library
            }
            try openPaperSet([paper.id], focusedPaperID: paper.id, opensReaderTabs: true, panelTab: .chat)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func openPapersForReading(_ paperIDs: [String]) {
        do {
            readerReturnRoute = .library
            setLibrarySelection(surface: .papers, categoryID: librarySelectedCategoryID, tagID: librarySelectedTagID)
            try openPaperSet(paperIDs, opensReaderTabs: true, panelTab: .chat)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func openPapersForChat(_ paperIDs: [String]) {
        do {
            readerReturnRoute = .library
            setLibrarySelection(surface: .papers, categoryID: librarySelectedCategoryID, tagID: librarySelectedTagID)
            try openPaperSet(paperIDs, opensReaderTabs: true, panelTab: .chat)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    var canOpenSelectedLibraryPaper: Bool {
        selectedLibraryPaper?.isArxivImportPlaceholder == false
    }

    func openSelectedLibraryPaperForReading() {
        guard canOpenSelectedLibraryPaper,
              let paperID = selectedLibraryPaper?.id else {
            return
        }
        openPapersForReading([paperID])
    }

    func openSelectedLibraryPaperForChat() {
        guard canOpenSelectedLibraryPaper,
              let paperID = selectedLibraryPaper?.id else {
            return
        }
        openPapersForChat([paperID])
    }

    func openRecentSession(_ session: PaperSession) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard let storedSession = try repository.fetchSession(id: session.id) else {
                refreshRecentSessions()
                return
            }
            let paperSet = try repository.fetchPapers(ids: storedSession.paperIDs).filter { !$0.isArxivImportPlaceholder }
            guard let firstPaper = paperSet.first else {
                throw AppModelError.noSelectedPaper
            }
            readerReturnRoute = .library
            setLibrarySelection(surface: .recentConversations, categoryID: nil, tagID: nil)
            selectedSessionPanelTab = .chat
            for paper in paperSet {
                openOrUpdateReaderTab(paper)
            }
            selectOrOpenReaderTab(firstPaper)
            selectedLibraryPaper = firstPaper
            selectedPaper = firstPaper
            selectedSession = storedSession
            sessions = try sessionsForPaperSet(paperIDs: storedSession.paperIDs, repository: repository)
            messages = try repository.fetchMessages(sessionID: storedSession.id)
            currentSelection = nil
            pdfJumpTarget = nil
            citationReturnPoint = nil
            try loadReaderPositionForSelectedContext(repository: repository)
            route = .reader
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func selectReaderTab(_ tab: ReaderPaperTab) {
        let needsContentLoad = selectedPaper?.id != tab.paperID
        readerTabSelectionTask?.cancel()
        activateReaderTabImmediately(tab)
        guard needsContentLoad else {
            return
        }
        readerTabSelectionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: readerTabContentLoadDelayNanoseconds)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.readerTabState.activePaperID == tab.paperID else {
                return
            }
            self.finishSelectingReaderTab(tab)
            if self.readerTabState.activePaperID == tab.paperID {
                self.readerTabSelectionTask = nil
            }
        }
    }

    private func activateReaderTabImmediately(_ tab: ReaderPaperTab) {
        var tabState = readerTabState
        _ = tabState.select(tab.paperID)
        readerTabState = tabState
        currentSelection = nil
        pdfJumpTarget = nil
        citationReturnPoint = nil
        pdfDocumentStatus = nil
        readerPosition = nil
        route = .reader
    }

    private func finishSelectingReaderTab(_ tab: ReaderPaperTab) {
        do {
            guard readerTabState.activePaperID == tab.paperID else {
                return
            }
            guard let paper = try paperForReaderTab(tab) else {
                closeReaderTab(tab)
                return
            }
            guard readerTabState.activePaperID == tab.paperID else {
                return
            }
            if selectedSession?.paperIDs.contains(paper.id) == true {
                try focusPaperInCurrentReaderSession(paper)
            } else {
                try focusPaperForReader(paper, opensReaderTab: false)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func selectPreviousReaderTab() {
        selectAdjacentReaderTab(offset: -1)
    }

    func selectNextReaderTab() {
        selectAdjacentReaderTab(offset: 1)
    }

    private func selectAdjacentReaderTab(offset: Int) {
        guard route == .reader,
              readerTabState.tabs.count > 1,
              let paperID = readerTabState.adjacentPaperID(
                from: readerTabState.activePaperID ?? selectedPaper?.id,
                offset: offset
              ),
              let tab = readerTabState.tabs.first(where: { $0.paperID == paperID }) else {
            return
        }
        selectReaderTab(tab)
    }

    func closeReaderTab(_ tab: ReaderPaperTab) {
        do {
            let wasActive = readerTabState.activePaperID == tab.paperID
            var tabState = readerTabState
            let nextPaperID = tabState.close(tab.paperID)
            readerTabState = tabState

            guard wasActive else {
                return
            }
            guard let nextPaperID,
                  let nextTab = readerTabState.tabs.first(where: { $0.paperID == nextPaperID }),
                  let paper = try paperForReaderTab(nextTab) else {
                selectedPaper = nil
                selectedSession = nil
                sessions = []
                messages = []
                currentSelection = nil
                pdfJumpTarget = nil
                readerPosition = nil
                clearActiveCodexRunIfIdle()
                route = .library
                return
            }
            if selectedSession?.paperIDs.contains(paper.id) == true {
                try focusPaperInCurrentReaderSession(paper)
            } else {
                try focusPaperForReader(paper, opensReaderTab: false)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func createSession(paperIDs requestedPaperIDs: [String]? = nil) throws {
        guard let fallbackPaper = selectedPaper else {
            throw AppModelError.noSelectedPaper
        }
        guard let repository else {
            throw AppModelError.repositoryUnavailable
        }
        let sessionPaperIDs = uniqueIDs(requestedPaperIDs ?? [fallbackPaper.id])
        let sessionPapers = try repository.fetchPapers(ids: sessionPaperIDs)
        guard !sessionPapers.isEmpty else {
            throw AppModelError.noSelectedPaper
        }
        let now = Date()
        let sessionID = UUID().uuidString.lowercased()
        let workspacePath = supportRoot.appendingPathComponent("sessions/\(sessionID)", isDirectory: true).path
        let session = PaperSession(
            id: sessionID,
            title: sessionTitle(for: sessionPapers),
            paperIDs: sessionPaperIDs,
            codexSessionID: nil,
            workspacePath: workspacePath,
            createdAt: now,
            updatedAt: now
        )
        try repository.upsertSession(session)
        let context = try loadSessionPaperContext(session: session, fallbackPaper: fallbackPaper, repository: repository)
        try workspaceManager.writeWorkspace(
            session: session,
            papers: context.papers,
            pagesByPaperID: context.pagesByPaperID,
            spansByPaperID: context.spansByPaperID,
            anchorsByPaperID: context.anchorsByPaperID,
            mcpEndpoint: mcpEndpoint
        )
        sessions = try sessionsForPaperSet(paperIDs: sessionPaperIDs, repository: repository)
        selectedSession = session
        messages = []
        readerPosition = nil
        try refreshRecentSessions(repository: repository)
        clearActiveCodexRunIfIdle()
    }

    func newSessionButtonTapped() {
        do {
            try createSession(paperIDs: currentReaderPaperIDs())
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func renameSession(_ session: PaperSession, title: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw AppModelError.emptyName
            }
            var updated = session
            updated.title = trimmed
            updated.updatedAt = Date()
            try repository.upsertSession(updated)
            if selectedSession?.id == session.id {
                selectedSession = updated
            }
            try reloadSessionsForVisibleContext(repository: repository)
            try refreshRecentSessions(repository: repository)
            postNotice(kind: .success, title: "Session Renamed", message: trimmed)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func startFreshSessionFromCurrentPaperSet() {
        do {
            try createSession(paperIDs: currentReaderPaperIDs())
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func selectSession(_ sessionID: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard let session = sessions.first(where: { $0.id == sessionID }) else {
                return
            }
            selectedSession = session
            messages = try repository.fetchMessages(sessionID: session.id)
            if let selectedPaper, !session.paperIDs.contains(selectedPaper.id),
               let firstPaper = try repository.fetchPapers(ids: session.paperIDs).first {
                try focusPaperInCurrentReaderSession(firstPaper)
            }
            try loadReaderPositionForSelectedContext(repository: repository)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func selectReaderPaper(_ paper: Paper) {
        do {
            try focusPaperInCurrentReaderSession(paper)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setPaper(_ paper: Paper, includedInCurrentSession included: Bool) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            if included {
                try addPaperToCurrentSession(paper, repository: repository)
            } else if selectedPaper?.id == paper.id {
                try removePaperFromCurrentSession(paper.id, repository: repository)
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func addPaperToCurrentSession(_ paper: Paper) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            try addPaperToCurrentSession(paper, repository: repository)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func addPaperToCurrentSession(_ paper: Paper, repository: PaperRepository) throws {
        guard var session = selectedSession else {
            try openPaperSet([paper.id], focusedPaperID: paper.id, opensReaderTabs: true, panelTab: selectedSessionPanelTab)
            return
        }
        guard !paper.isArxivImportPlaceholder else {
            return
        }
        var paperIDs = uniqueIDs(session.paperIDs)
        guard !paperIDs.contains(paper.id) else {
            try focusPaperInCurrentReaderSession(paper)
            return
        }
        paperIDs.append(paper.id)
        session.paperIDs = paperIDs
        session.updatedAt = Date()
        try repository.upsertSession(session)
        let context = try loadSessionPaperContext(session: session, fallbackPaper: paper, repository: repository)
        try workspaceManager.writeWorkspace(
            session: session,
            papers: context.papers,
            pagesByPaperID: context.pagesByPaperID,
            spansByPaperID: context.spansByPaperID,
            anchorsByPaperID: context.anchorsByPaperID,
            mcpEndpoint: mcpEndpoint
        )
        openOrUpdateReaderTab(paper)
        selectedSession = session
        selectedPaper = paper
        selectedLibraryPaper = paper
        sessions = try sessionsForPaperSet(paperIDs: paperIDs, repository: repository)
        messages = try repository.fetchMessages(sessionID: session.id)
        try loadReaderPositionForSelectedContext(repository: repository)
        try refreshRecentSessions(repository: repository)
        postNotice(kind: .success, title: "Paper Added", message: paper.title)
    }

    func removePaperFromCurrentSession(_ paperID: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            try removePaperFromCurrentSession(paperID, repository: repository)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func removePaperFromCurrentSession(_ paperID: String, repository: PaperRepository) throws {
        guard var session = selectedSession else {
            return
        }
        let nextPaperIDs = session.paperIDs.filter { $0 != paperID }
        guard nextPaperIDs.count != session.paperIDs.count else {
            return
        }
        guard let fallbackPaper = selectedPaper else {
            throw AppModelError.noSelectedPaper
        }
        if nextPaperIDs.isEmpty {
            throw AppModelError.noSelectedPaper
        }
        session.paperIDs = nextPaperIDs
        session.updatedAt = Date()
        try repository.upsertSession(session)
        let nextPapers = try repository.fetchPapers(ids: nextPaperIDs)
        let nextFocusedPaper = selectedPaper?.id == paperID ? (nextPapers.first ?? fallbackPaper) : fallbackPaper
        let context = try loadSessionPaperContext(session: session, fallbackPaper: nextFocusedPaper, repository: repository)
        try workspaceManager.writeWorkspace(
            session: session,
            papers: context.papers,
            pagesByPaperID: context.pagesByPaperID,
            spansByPaperID: context.spansByPaperID,
            anchorsByPaperID: context.anchorsByPaperID,
            mcpEndpoint: mcpEndpoint
        )
        var tabState = readerTabState
        _ = tabState.close(paperID)
        readerTabState = tabState
        selectedSession = session
        sessions = try sessionsForPaperSet(paperIDs: nextPaperIDs, repository: repository)
        messages = try repository.fetchMessages(sessionID: session.id)
        try focusPaperInCurrentReaderSession(nextFocusedPaper)
        try refreshRecentSessions(repository: repository)
        postNotice(kind: .success, title: "Paper Removed", message: nextFocusedPaper.title)
    }

    private func sessionTitle(for papers: [Paper]) -> String {
        guard let firstPaper = papers.first else {
            return "Paper Notes"
        }
        guard papers.count > 1 else {
            return "\(firstPaper.title) Notes"
        }
        return "\(firstPaper.title) + \(papers.count - 1) Notes"
    }

    func updateSelection(_ selection: PDFSelectionInfo?) {
        currentSelection = selection
    }

    func clearCurrentSelection() {
        currentSelection = nil
    }

    func refreshCodexDiagnostic() async {
        codexDiagnostic = nil
        codexDefaultModelID = CodexCLI.configuredDefaultModelID() ?? ""
        let modelOverride = codexModelOverride
        let diagnostic = await Task.detached(priority: .utility) {
            CodexCLI.diagnose(modelOverride: modelOverride)
        }.value
        codexDiagnostic = diagnostic
    }

    func refreshAvailableCodexModels() async {
        guard !isRefreshingCodexModels else {
            return
        }
        isRefreshingCodexModels = true
        defer {
            isRefreshingCodexModels = false
        }
        do {
            let result = try await Task.detached(priority: .utility) {
                let defaultModelID = CodexCLI.configuredDefaultModelID()
                let executable = try CodexCLI.findCodexExecutable()
                let models = try CodexCLI(executablePath: executable).availableModelIDs()
                return (models: models, defaultModelID: defaultModelID)
            }.value
            codexDefaultModelID = result.defaultModelID ?? ""
            availableCodexModelIDs = uniqueCodexModelIDs(
                result.models + [codexModelOverride, discoverCodexModelOverride]
            )
        } catch {
            codexDefaultModelID = CodexCLI.configuredDefaultModelID() ?? ""
            availableCodexModelIDs = uniqueCodexModelIDs(
                CodexCLI.fallbackAvailableModelIDs(configuredModelID: codexDefaultModelID)
                    + [codexModelOverride, discoverCodexModelOverride]
            )
            errorMessage = String(describing: error)
        }
    }

    func refreshAgentRuntimeDiagnostics() async {
        await agentRuntimeStore.refreshDiagnostics()
    }

    func setSelectedChatRuntimeID(_ runtimeID: String) {
        agentRuntimeStore.setSelectedChatRuntimeID(runtimeID)
        postNotice(kind: .success, title: "Chat Runtime Selected", message: selectedChatRuntimeDisplayName)
    }

    func setSelectedEnrichmentRuntimeID(_ runtimeID: String) {
        agentRuntimeStore.setSelectedEnrichmentRuntimeID(runtimeID)
        let name = agentRuntimeStore.selectedEnrichmentRuntime.displayName
        postNotice(kind: .success, title: "Explore Runtime Selected", message: name)
    }

    func setAgentRuntimeEnabled(_ runtimeID: String, enabled: Bool) {
        agentRuntimeStore.setRuntimeEnabled(runtimeID, enabled: enabled)
    }

    func setAgentRuntimeModelOverride(_ model: String, for runtimeID: String) {
        agentRuntimeStore.setModelOverride(model, for: runtimeID)
        if runtimeID == "codex" {
            setCodexModelOverride(model)
        }
    }

    func setAgentRuntimeProviderOverride(_ provider: String, for runtimeID: String) {
        agentRuntimeStore.setProviderOverride(provider, for: runtimeID)
    }

    func setAgentRuntimeMCPMode(_ mode: AgentRuntimeMCPMode, for runtimeID: String) {
        agentRuntimeStore.setMCPMode(mode, for: runtimeID)
    }

    func setCodexModelOverride(_ model: String) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        codexModelOverride = trimmed
        if agentRuntimeStore.modelOverride(for: "codex") != trimmed {
            agentRuntimeStore.setModelOverride(trimmed, for: "codex")
        }
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: codexModelOverrideDefaultsKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: codexModelOverrideDefaultsKey)
        }
        Task {
            await refreshCodexDiagnostic()
        }
        mergeAvailableCodexModelIDs([trimmed])
    }

    func setCodexReasoningEffort(_ effort: CodexReasoningEffort) {
        codexReasoningEffort = effort
        if effort == .default {
            UserDefaults.standard.removeObject(forKey: codexReasoningEffortDefaultsKey)
        } else {
            UserDefaults.standard.set(effort.rawValue, forKey: codexReasoningEffortDefaultsKey)
        }
    }

    func setInAppCodexMCPEnabled(_ enabled: Bool) {
        inAppCodexMCPEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: inAppCodexMCPEnabledDefaultsKey)
        postNotice(
            kind: .success,
            title: enabled ? "Episteme MCP Enabled" : "Episteme MCP Disabled",
            message: inAppCodexMCPStatusText
        )
    }

    func installOrUpdateCodexPlugin() async {
        guard let endpoint = mcpEndpoint else {
            errorMessage = "Episteme MCP server is still starting."
            return
        }
        isInstallingCodexPlugin = true
        defer { isInstallingCodexPlugin = false }
        do {
            let status = try codexPluginInstaller().installOrUpdate(
                endpoint: endpoint,
                appVersion: appVersionForPluginManifest()
            )
            codexPluginInstallationStatus = status
            postNotice(kind: .success, title: "Codex Plugin Installed", message: status.detail)
        } catch {
            errorMessage = "Codex plugin installation failed: \(String(describing: error))"
        }
    }

    private func refreshInstalledCodexPluginIfNeeded() {
        guard let endpoint = mcpEndpoint else {
            codexPluginInstallationStatus = codexPluginInstaller().status(currentEndpoint: nil)
            return
        }
        let installer = codexPluginInstaller()
        do {
            codexPluginInstallationStatus = try installer.refreshIfInstalled(
                endpoint: endpoint,
                appVersion: appVersionForPluginManifest()
            )
        } catch {
            codexPluginInstallationStatus = installer.status(currentEndpoint: endpoint)
            errorMessage = "Codex plugin refresh failed: \(String(describing: error))"
        }
    }

    private func codexPluginInstaller() -> CodexPluginInstaller {
        CodexPluginInstaller(
            codexHome: CodexPluginInstaller.defaultCodexHome(),
            supportRoot: supportRoot
        )
    }

    private func appVersionForPluginManifest() -> String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let version = shortVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "0.1.0" : version
    }

    func cancelActiveCodexRun() {
        let targetSessionID = selectedSession?.id ?? activeCodexRunsBySessionID.values.sorted { $0.startedAt < $1.startedAt }.first?.sessionID
        guard let targetSessionID,
              let run = activeCodexRunsBySessionID[targetSessionID] else {
            return
        }
        cancellingCodexRunSessionIDs.insert(targetSessionID)
        activeCodexRunHandlesBySessionID[targetSessionID]?.cancel()
        postNotice(kind: .info, title: "Stopping Codex", message: run.title)
    }

    func startAgentTerminal(columns: Int = 120, rows: Int = 32) async {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard let session = selectedSession else {
                throw AppModelError.noSelectedSession
            }
            let fallbackPaper = try fallbackPaper(for: session, repository: repository)
            let runtimeProfile = agentRuntimeStore.selectedChatRuntime
            guard runtimeProfile.supportsPTY else {
                throw AppModelError.runtimeDoesNotSupportTerminal(runtimeProfile.displayName)
            }

            stopAgentTerminal()
            let context = try loadSessionPaperContext(session: session, fallbackPaper: fallbackPaper, repository: repository)
            try workspaceManager.writeWorkspace(
                session: session,
                papers: context.papers,
                pagesByPaperID: context.pagesByPaperID,
                spansByPaperID: context.spansByPaperID,
                anchorsByPaperID: context.anchorsByPaperID,
                mcpEndpoint: mcpEndpoint,
                materializationMode: session.workspaceMaterializationMode
            )

            let workspacePath = URL(fileURLWithPath: session.workspacePath, isDirectory: true)
            let turnsURL = workspacePath.appendingPathComponent("turns", isDirectory: true)
            try FileManager.default.createDirectory(at: turnsURL, withIntermediateDirectories: true)
            let logURL = turnsURL.appendingPathComponent("\(UUID().uuidString.lowercased())-\(runtimeProfile.id).terminal.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil)

            let command = try agentTerminalCommand(
                for: runtimeProfile,
                session: session,
                workspacePath: workspacePath
            )
            let terminalID = UUID().uuidString.lowercased()
            let process = LocalPTYProcess(
                configuration: LocalPTYProcessConfiguration(
                    executablePath: command.executablePath,
                    arguments: command.arguments,
                    workingDirectoryPath: command.currentDirectoryPath ?? session.workspacePath,
                    environment: command.environmentOverrides,
                    columns: columns,
                    rows: rows
                )
            )
            agentTerminalState = AgentTerminalState(
                id: terminalID,
                sessionID: session.id,
                runtimeID: runtimeProfile.id,
                runtimeName: runtimeProfile.displayName,
                workspacePath: session.workspacePath,
                logPath: logURL.path,
                output: "",
                isRunning: true,
                startedAt: Date(),
                columns: columns,
                rows: rows
            )
            try process.start { [weak self, terminalID, logURL] data in
                Task { @MainActor in
                    self?.appendAgentTerminalOutput(data: data, terminalID: terminalID, logURL: logURL)
                }
            }
            activeAgentTerminalProcess = process
            DispatchQueue.global(qos: .utility).async { [weak self, process, terminalID] in
                let status = process.waitUntilExit()
                DispatchQueue.main.async {
                    self?.finishAgentTerminal(terminalID: terminalID, status: status)
                }
            }
            postNotice(kind: .success, title: "Terminal Started", message: runtimeProfile.displayName)
        } catch {
            agentTerminalState = nil
            activeAgentTerminalProcess = nil
            errorMessage = String(describing: error)
        }
    }

    func sendAgentTerminalInput(_ text: String) {
        do {
            guard let activeAgentTerminalProcess else {
                throw AppModelError.noActiveAgentTerminal
            }
            let payload = text.hasSuffix("\n") ? text : "\(text)\n"
            try activeAgentTerminalProcess.write(payload)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func resizeAgentTerminal(columns: Int, rows: Int) {
        do {
            guard let activeAgentTerminalProcess else {
                return
            }
            try activeAgentTerminalProcess.resize(columns: columns, rows: rows)
            if var state = agentTerminalState {
                state.columns = columns
                state.rows = rows
                agentTerminalState = state
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func stopAgentTerminal() {
        activeAgentTerminalProcess?.terminate()
        activeAgentTerminalProcess = nil
        if var state = agentTerminalState {
            state.isRunning = false
            agentTerminalState = state
        }
    }

    func jumpToCitation(_ citationID: String) {
        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            if let selectedPaper, let readerPosition = pendingReaderPosition ?? readerPosition {
                citationReturnPoint = CitationReturnPoint(
                    paperID: selectedPaper.id,
                    paperTitle: selectedPaper.title,
                    position: readerPosition,
                    label: "Before citation jump"
                )
            }
            if let span = try repository.fetchSpan(id: citationID) {
                if selectedPaper?.id != span.paperID, let paper = papers.first(where: { $0.id == span.paperID }) {
                    try focusPaperInCurrentReaderSession(paper)
                }
                pdfJumpTarget = PDFJumpTarget(
                    id: span.id,
                    paperID: span.paperID,
                    page: span.page,
                    bboxList: [span.bbox],
                    label: span.text
                )
                return
            }
            if let baseSpanID = CitationParser.baseSpanCitationID(for: citationID),
               baseSpanID != citationID,
               let span = try repository.fetchSpan(id: baseSpanID) {
                if selectedPaper?.id != span.paperID, let paper = papers.first(where: { $0.id == span.paperID }) {
                    try focusPaperInCurrentReaderSession(paper)
                }
                pdfJumpTarget = PDFJumpTarget(
                    id: citationID,
                    paperID: span.paperID,
                    page: span.page,
                    bboxList: [span.bbox],
                    label: span.text
                )
                return
            }
            if let anchor = try repository.fetchAnchor(id: citationID) {
                if selectedPaper?.id != anchor.paperID, let paper = papers.first(where: { $0.id == anchor.paperID }) {
                    try focusPaperInCurrentReaderSession(paper)
                }
                pdfJumpTarget = PDFJumpTarget(
                    id: anchor.id,
                    paperID: anchor.paperID,
                    page: anchor.page,
                    bboxList: anchor.bboxList,
                    label: anchor.selectedText
                )
                return
            }
            throw AppModelError.sourceNotFound(citationID)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func returnFromCitationJump() {
        do {
            guard let returnPoint = citationReturnPoint else {
                return
            }
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            if selectedPaper?.id != returnPoint.paperID,
               let paper = try repository.fetchPapers(ids: [returnPoint.paperID]).first {
                try focusPaperInCurrentReaderSession(paper)
            }
            var position = returnPoint.position
            position.updatedAt = Date()
            readerPosition = position
            sendPDFKitCommand(.restorePosition(position))
            pdfJumpTarget = nil
            citationReturnPoint = nil
            postNotice(kind: .info, title: "Returned to Previous Reading Position", message: returnPoint.paperTitle)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func sendMessage(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }
        var runSessionID: String?
        defer {
            if let runSessionID {
                finishCodexRun(sessionID: runSessionID)
            }
        }

        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard let paper = selectedPaper else {
                throw AppModelError.noSelectedPaper
            }
            guard var session = selectedSession else {
                throw AppModelError.noSelectedSession
            }
            guard session.paperIDs.contains(paper.id) else {
                throw AppModelError.sessionPaperMismatch
            }
            let sessionID = session.id
            guard !isSessionSending(sessionID) else {
                return
            }
            runSessionID = sessionID

            let context = try loadSessionPaperContext(session: session, fallbackPaper: paper, repository: repository)
            let focusedSpans = context.spansByPaperID[paper.id] ?? []
            var content = trimmed
            if let selection = currentSelection {
                let anchorID = PaperCodexCore.Anchor.makeID(paperID: paper.id, page: selection.page, suffix: UUID().uuidString.lowercased())
                guard let anchor = AnchorResolver().resolve(
                    paperID: paper.id,
                    page: selection.page,
                    selectedText: selection.text,
                    bboxList: selection.bboxList,
                    spans: focusedSpans,
                    anchorID: anchorID,
                    sessionID: session.id,
                    createdAt: Date()
                ) else {
                    throw AppModelError.anchorMatchFailed
                }
                let nearbySpans = anchor.matchedSpanIDs.isEmpty ? "none" : anchor.matchedSpanIDs.joined(separator: ", ")
                let beforeContext = anchor.beforeContext.isEmpty ? "none" : anchor.beforeContext
                let afterContext = anchor.afterContext.isEmpty ? "none" : anchor.afterContext
                content += """

                [selected source]
                anchor_id: \(anchor.id)
                paper_id: \(anchor.paperID)
                page: \(anchor.page)
                text: "\(anchor.selectedText)"
                nearby_spans: \(nearbySpans)
                before: "\(beforeContext)"
                after: "\(afterContext)"
                """
                try repository.upsertAnchor(anchor)
                currentSelection = nil
            }

            let message = ChatMessage(
                id: UUID().uuidString.lowercased(),
                sessionID: session.id,
                role: .user,
                content: content,
                createdAt: Date()
            )
            try repository.appendMessage(message)
            session.updatedAt = Date()
            try repository.upsertSession(session)
            try refreshVisibleSessionState(session: session, paperID: paper.id, repository: repository)
            try refreshRecentSessions(repository: repository)

            let updatedSession = try await runAgentTurn(
                content: content,
                session: session,
                fallbackPaper: paper,
                repository: repository
            )
            try refreshVisibleSessionState(session: updatedSession, paperID: paper.id, repository: repository)
            try refreshRecentSessions(repository: repository)
        } catch AppModelError.anchorMatchFailed {
            errorMessage = AppModelError.anchorMatchFailed.description
        } catch {
            if let runSessionID, cancellingCodexRunSessionIDs.contains(runSessionID) {
                await appendCodexCancellationMessage(sessionID: runSessionID)
                return
            }
            if let runSessionID {
                await appendCodexFailureMessage(String(describing: error), sessionID: runSessionID)
            } else {
                errorMessage = String(describing: error)
            }
        }
    }

    func retryCodexFailure(messageID: String) async {
        var runSessionID: String?
        defer {
            if let runSessionID {
                finishCodexRun(sessionID: runSessionID)
            }
        }

        do {
            guard let repository else {
                throw AppModelError.repositoryUnavailable
            }
            guard let session = selectedSession else {
                throw AppModelError.noSelectedSession
            }
            let sessionID = session.id
            guard !isSessionSending(sessionID) else {
                return
            }
            runSessionID = sessionID
            guard let failureIndex = messages.firstIndex(where: { $0.id == messageID }),
                  CodexFailureNotice.parse(messages[failureIndex].content) != nil else {
                throw AppModelError.noRecoverableCodexTurn
            }
            guard let userMessage = messages[..<failureIndex].last(where: { $0.role == .user }) else {
                throw AppModelError.noRecoverableCodexTurn
            }

            let fallbackPaper = try fallbackPaper(for: session, repository: repository)
            let updatedSession = try await runAgentTurn(
                content: userMessage.content,
                session: session,
                fallbackPaper: fallbackPaper,
                repository: repository
            )
            try refreshVisibleSessionState(session: updatedSession, paperID: fallbackPaper.id, repository: repository)
            try refreshRecentSessions(repository: repository)
        } catch {
            if let runSessionID, cancellingCodexRunSessionIDs.contains(runSessionID) {
                await appendCodexCancellationMessage(sessionID: runSessionID)
                return
            }
            if let runSessionID {
                await appendCodexFailureMessage(String(describing: error), sessionID: runSessionID)
            } else {
                errorMessage = String(describing: error)
            }
        }
    }

    func goToLibrary() {
        setLibrarySelection(surface: .papers, categoryID: nil, tagID: nil)
        route = .library
    }

    func returnFromReader() {
        let destination = readerReturnRoute
        switch destination {
        case .discover:
            route = .discover
            startDiscoverCacheWarmupIfNeeded()
        case .search:
            route = .search
        case .library, .settings, .reader:
            route = .library
        }
    }

    private func scheduleDiscoverCacheWarmup() {
        routeDeferredWorkTask?.cancel()
        routeDeferredWorkTask = Task { [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.route == .discover else {
                return
            }
            self.startDiscoverCacheWarmupIfNeeded()
            self.routeDeferredWorkTask = nil
        }
    }

    private func scheduleRecentSessionsRefresh() {
        routeDeferredWorkTask?.cancel()
        routeDeferredWorkTask = Task { [weak self] in
            await Task.yield()
            guard let self,
                  !Task.isCancelled,
                  self.route == .library,
                  self.selectedLibrarySurface == .recentConversations else {
                return
            }
            self.refreshRecentSessions()
            self.routeDeferredWorkTask = nil
        }
    }

    private func clearActiveCodexRunIfIdle() {
        if !isSending {
            activeCodexRunsBySessionID.removeAll()
            activeCodexRunHandlesBySessionID.removeAll()
            cancellingCodexRunSessionIDs.removeAll()
        }
    }

    private func refreshVisibleSessionState(
        session: PaperSession,
        paperID: String,
        repository: PaperRepository
    ) throws {
        if selectedPaper?.id == paperID {
            sessions = try sessionsForPaperSet(paperIDs: session.paperIDs, repository: repository)
        }
        guard selectedSession?.id == session.id else {
            return
        }
        selectedSession = session
        messages = try repository.fetchMessages(sessionID: session.id)
    }

    private func loadSessionPaperContext(
        session: PaperSession,
        fallbackPaper: Paper,
        repository: PaperRepository
    ) throws -> SessionPaperContext {
        let paperIDs = session.paperIDs.isEmpty ? [fallbackPaper.id] : uniqueIDs(session.paperIDs)
        let fetchedPapers = try repository.fetchPapers(ids: paperIDs)
        let papers = fetchedPapers.isEmpty ? [fallbackPaper] : fetchedPapers
        var pagesByPaperID: [String: [PageIndex]] = [:]
        var spansByPaperID: [String: [Span]] = [:]
        var anchorsByPaperID: [String: [PaperCodexCore.Anchor]] = [:]
        for paper in papers {
            pagesByPaperID[paper.id] = try repository.fetchPages(paperID: paper.id)
            spansByPaperID[paper.id] = try repository.fetchSpans(paperID: paper.id)
            anchorsByPaperID[paper.id] = try repository.fetchAnchors(paperID: paper.id)
        }
        return SessionPaperContext(
            papers: papers,
            pagesByPaperID: pagesByPaperID,
            spansByPaperID: spansByPaperID,
            anchorsByPaperID: anchorsByPaperID
        )
    }

    private func anchorsReferenced(in content: String, context: SessionPaperContext) -> [PaperCodexCore.Anchor] {
        let allAnchors = context.anchorsByPaperID.values.flatMap { $0 }
        let anchorIDs = content
            .components(separatedBy: .newlines)
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("anchor_id:") else {
                    return nil
                }
                return trimmed
                    .dropFirst("anchor_id:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        return anchorIDs.compactMap { anchorID in
            allAnchors.first { $0.id == anchorID }
        }
    }

    private func uniqueIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids where !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }

    private func mergeAvailableCodexModelIDs(_ ids: [String]) {
        availableCodexModelIDs = uniqueCodexModelIDs(availableCodexModelIDs + ids)
    }

    private func uniqueCodexModelIDs(_ ids: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for id in ids {
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                continue
            }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private func mergeAndSaveArxivDate(_ date: String) throws {
        let merged = Array(Set(arxivDates + [date])).sorted()
        arxivDates = merged
        try arxivCache.saveDates(ArxivFeedDateIndex(dates: merged, latest: merged.last))
    }

    private func cacheAndDisplayArxivFeed(_ liveFeed: ArxivFeedResponse, title: String) throws {
        let feed = applyLocalDiscoverPreferences(to: liveFeed)
        try arxivCache.saveFeed(feed)
        try mergeAndSaveArxivDate(feed.date)
        selectedArxivDate = feed.date
        arxivFeed = feed
        try loadDiscoverEnrichments(for: feed.papers)
        let summary = try arxivCache.assetCacheSummary(for: feed, includeLarge: false)
        arxivCacheProgress = ArxivCacheProgress(
            date: feed.date,
            title: title,
            detail: "Preview images \(summary.cached)/\(summary.total)",
            completed: summary.cached,
            total: summary.total
        )
        if let selected = selectedArxivPaper,
           feed.papers.contains(where: { $0.id == selected.id }) {
            selectedArxivPaper = selected
        } else {
            selectedArxivPaper = feed.papers.first
        }
        reloadCachedArxivAssets()
    }

    private func displayDiscoverFeed(
        _ liveFeed: ArxivFeedResponse,
        query: DiscoverQuery,
        progressTitle: String,
        cacheRangeFeed: Bool = true,
        cacheQueryResult: Bool = true
    ) throws {
        let feed = applyLocalDiscoverPreferences(to: liveFeed)
        if cacheRangeFeed {
            try arxivCache.saveFeed(feed)
        }
        try mergeAndSaveArxivDate(feed.date)
        if cacheQueryResult {
            guard !feed.papers.isEmpty else {
                selectedArxivDate = feed.date
                arxivFeed = feed
                discoverResultIDs = []
                selectedArxivPaper = nil
                discoverEnrichmentsByID = [:]
                arxivCacheProgress = ArxivCacheProgress(
                    date: feed.date,
                    title: progressTitle,
                    detail: "0 papers",
                    completed: 0,
                    total: 0
                )
                reloadCachedArxivAssets()
                return
            }
            try localDiscoverCache.saveQueryResult(
                DiscoverQueryResult(
                    query: query.normalized,
                    arxivIDs: feed.papers.map(\.id),
                    generatedAt: Date(),
                    feed: feed
                )
            )
        }
        selectedArxivDate = feed.date
        arxivFeed = feed
        discoverResultIDs = feed.papers.map(\.id)
        selectedArxivPaper = feed.papers.first
        try loadDiscoverEnrichments(for: feed.papers)
        arxivCacheProgress = ArxivCacheProgress(
            date: feed.date,
            title: progressTitle,
            detail: "\(feed.papers.count) papers",
            completed: feed.papers.count,
            total: feed.papers.count
        )
        reloadCachedArxivAssets()
    }

    private func resetDiscoverRanking(in feed: ArxivFeedResponse) -> ArxivFeedResponse {
        let isSearchFeed = feed.date == "search"
        let deduplicatedFeed = feed.deduplicatedByCanonicalID(preservingCount: isSearchFeed)
        let papers = deduplicatedFeed.papers.map { paper -> ArxivFeedPaper in
            var resetPaper = paper
            resetPaper.similarity = nil
            resetPaper.filterGroup = nil
            return resetPaper
        }
        return ArxivFeedResponse(
            date: deduplicatedFeed.date,
            count: isSearchFeed ? deduplicatedFeed.count : papers.count,
            papers: papers,
            groups: deduplicatedFeed.groups,
            tagOptions: deduplicatedFeed.tagOptions,
            sourceCategories: deduplicatedFeed.sourceCategories
        )
        .deduplicatedByCanonicalID(preservingCount: isSearchFeed)
    }

    private func filterDiscoverFeed(_ feed: ArxivFeedResponse, keyword: String) -> ArxivFeedResponse {
        filteredDiscoverFeed(feed, keyword: keyword)
    }

    @discardableResult
    private func loadAndDisplayCachedDiscoverSearch(
        query: DiscoverQuery,
        allowPartialFragments: Bool = false
    ) async throws -> CachedDiscoverSearchLoadResult {
        let supportRoot = supportRoot
        let cacheTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try loadCachedDiscoverSearchSnapshot(
                query: query,
                supportRoot: supportRoot,
                allowPartialFragments: allowPartialFragments
            )
        }
        let result = try await withTaskCancellationHandler {
            try await cacheTask.value
        } onCancel: {
            cacheTask.cancel()
        }
        if let hit = result.hit {
            try displayDiscoverFeed(
                hit.feed,
                query: query,
                progressTitle: hit.progressTitle,
                cacheRangeFeed: hit.cacheRangeFeed,
                cacheQueryResult: hit.cacheQueryResult
            )
        }
        return result
    }

    private func loadDiscoverEnrichments(for papers: [ArxivFeedPaper]) throws {
        var enrichments = discoverEnrichmentsByID
        for paper in papers {
            if let enrichment = try localDiscoverCache.loadEnrichment(arxivID: paper.id) {
                enrichments[paper.id] = enrichment
            }
        }
        discoverEnrichmentsByID = enrichments.filter { entry in
            papers.contains { $0.id == entry.key }
        }
    }

    private func mergeDiscoverEnrichments(for papers: [ArxivFeedPaper]) {
        var enrichments = discoverEnrichmentsByID
        for paper in papers {
            if let enrichment = try? localDiscoverCache.loadEnrichment(arxivID: paper.id) {
                enrichments[paper.id] = enrichment
            }
        }
        discoverEnrichmentsByID = enrichments
    }

    private func mergeDiscoverEmbeddings(from papers: [ArxivFeedPaper]) {
        let vectorsByID = Dictionary(uniqueKeysWithValues: papers.compactMap { paper in
            paper.embedding.map { (paper.id, $0) }
        })
        guard !vectorsByID.isEmpty else {
            return
        }
        if let feed = arxivFeed {
            arxivFeed = feed.mergingEmbeddings(vectorsByID)
        }
        if let feed = arxivSearchFeed {
            arxivSearchFeed = feed.mergingEmbeddings(vectorsByID)
        }
    }

    private func discoverProcessingDateLabel(for papers: [ArxivFeedPaper]) -> String {
        selectedArxivDate
            ?? papers.compactMap(\.listDate).first
            ?? "\(discoverStartDate)...\(discoverEndDate)"
    }

    private func updateDiscoverProcessingProgress(
        completed: Int,
        cached: Int,
        failed: Int,
        total: Int,
        tokenUsage: CodexTokenUsage? = nil
    ) {
        let processed = max(completed - cached - failed, 0)
        var detail = "\(processed) processed · \(cached) cached · \(failed) failed · \(completed)/\(total)"
        if let tokenUsage {
            detail += " · \(tokenUsage.compactSummary)"
        }
        discoverProcessingProgress = ArxivCacheProgress(
            date: selectedArxivDate ?? "\(discoverStartDate)...\(discoverEndDate)",
            title: isCancellingDiscoverProcessing ? "Stopping processing" : "Processing results",
            detail: detail,
            completed: completed,
            total: total
        )
    }

    private func updateDiscoverPDFCacheProgress(completed: Int, cached: Int, failed: Int, total: Int) {
        let downloaded = max(completed - cached - failed, 0)
        discoverPDFCacheProgress = ArxivCacheProgress(
            date: selectedArxivDate ?? "\(discoverStartDate)...\(discoverEndDate)",
            title: isCancellingDiscoverPDFCache ? "Stopping PDF cache" : "Caching PDFs",
            detail: "\(downloaded) downloaded · \(cached) already cached · \(failed) failed · \(completed)/\(total)",
            completed: completed,
            total: total
        )
    }

    private func uniqueArxivPapers(_ papers: [ArxivFeedPaper]) -> [ArxivFeedPaper] {
        var seen: Set<String> = []
        var result: [ArxivFeedPaper] = []
        for paper in papers where !seen.contains(paper.id) {
            seen.insert(paper.id)
            result.append(paper)
        }
        return result
    }

    private func cachedArxivPDFURL(for paper: ArxivFeedPaper) throws -> URL? {
        if let url = try arxivCache.cachedPDFURL(arxivID: paper.id, date: arxivPDFCacheDate(for: paper)) {
            return url
        }
        return try arxivCache.cachedPDFURL(arxivID: paper.id)
    }

    private func arxivPDFCacheDate(for paper: ArxivFeedPaper) -> String {
        paper.listDate ?? selectedArxivDate ?? arxivFeed?.date ?? DiscoverDateRange.isoDate()
    }

    private func ensureArxivPDFCached(_ paper: ArxivFeedPaper, client: LocalArxivClient? = nil) async throws -> URL {
        if let cachedURL = try cachedArxivPDFURL(for: paper) {
            return cachedURL
        }
        let data = try await (client ?? makeLocalArxivClient()).fetchPDF(for: paper)
        guard data.starts(with: Data("%PDF-".utf8)) else {
            throw AppModelError.downloadedFileIsNotPDF(paper.id)
        }
        return try arxivCache.savePDF(data, arxivID: paper.id, date: arxivPDFCacheDate(for: paper))
    }

    @discardableResult
    private func refreshDiscoverPDFThumbnails(for paper: ArxivFeedPaper, pdfURL: URL) throws -> [URL] {
        let urls = try thumbnailCache.thumbnails(
            forPDFAt: pdfURL,
            cacheID: "arxiv-\(paper.id)",
            pageLimit: 5,
            size: CGSize(width: 164, height: 212)
        )
        arxivPDFThumbnailURLsByID[paper.id] = urls
        return urls
    }

    @discardableResult
    private func loadCachedArxivFeed(date: String) throws -> Bool {
        guard let cachedFeed = try arxivCache.loadFeed(date: date) else {
            return false
        }
        selectedArxivDate = date
        let feed = applyLocalDiscoverPreferences(to: cachedFeed)
        arxivFeed = feed
        try loadDiscoverEnrichments(for: feed.papers)
        if let selected = selectedArxivPaper,
           feed.papers.contains(where: { $0.id == selected.id }) {
            selectedArxivPaper = selected
        } else {
            selectedArxivPaper = feed.papers.first
        }
        reloadCachedArxivAssets()
        let summary = try arxivCache.assetCacheSummary(for: feed, includeLarge: false)
        arxivCacheProgress = ArxivCacheProgress(
            date: date,
            title: "Offline cache",
            detail: "Preview images \(summary.cached)/\(summary.total)",
            completed: summary.cached,
            total: summary.total
        )
        return true
    }

    private func refreshDiscoverEnrichmentsForCurrentFeed() {
        do {
            guard let arxivFeed else {
                return
            }
            try loadDiscoverEnrichments(for: arxivFeed.papers)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func preloadArxivAssets(includeLarge: Bool, feed: ArxivFeedResponse) async throws {
        let assets = feed.uniqueAssets(includeLarge: includeLarge)
        guard !assets.isEmpty else {
            arxivCacheProgress = ArxivCacheProgress(
                date: feed.date,
                title: includeLarge ? "Full images ready" : "Preview images ready",
                detail: "No preview assets in this feed",
                completed: 0,
                total: 0
            )
            return
        }

        isPreloadingArxivAssets = true
        defer {
            isPreloadingArxivAssets = false
        }

        var cachedPaths: Set<String> = []
        for asset in assets where try arxivCache.cachedAssetURL(path: asset.path) != nil {
            cachedPaths.insert(asset.path)
        }
        var completed = cachedPaths.count
        arxivCacheProgress = ArxivCacheProgress(
            date: feed.date,
            title: includeLarge ? "Caching full images" : "Caching preview images",
            detail: "\(completed)/\(assets.count) already cached",
            completed: completed,
            total: assets.count
        )

        for asset in assets {
            if cachedPaths.contains(asset.path) {
                continue
            }
            let data = try await fetchArxivAsset(asset)
            arxivAssetURLs[asset.path] = try arxivCache.saveAsset(data, path: asset.path)
            completed += 1
            arxivCacheProgress = ArxivCacheProgress(
                date: feed.date,
                title: includeLarge ? "Caching full images" : "Caching preview images",
                detail: "\(completed)/\(assets.count) cached",
                completed: completed,
                total: assets.count
            )
        }

        reloadCachedArxivAssets()
        arxivCacheProgress = ArxivCacheProgress(
            date: feed.date,
            title: includeLarge ? "Full images ready" : "Preview images ready",
            detail: "\(completed)/\(assets.count) cached",
            completed: completed,
            total: assets.count
        )
    }

    private func loadCachedArxivState() {
        if let cachedDates = try? arxivCache.loadDates() {
            arxivDates = cachedDates.dates
            selectedArxivDate = cachedDates.latest ?? cachedDates.dates.last
        }
        if let date = selectedArxivDate {
            _ = try? loadCachedArxivFeed(date: date)
        }
    }

    private func loadLastDiscoverResultsState() throws -> Bool {
        guard let queryResult = try localDiscoverCache.loadLastQueryResult(),
              let feed = queryResult.feed,
              !feed.papers.isEmpty else {
            return false
        }

        let query = queryResult.query.normalized
        discoverKeyword = query.keyword
        discoverStartDate = query.dateRange.start
        discoverEndDate = query.dateRange.end
        discoverSelectedCategories = query.categories
        discoverSelectedSimilaritySourceIDs = query.similaritySourceIDs
        try displayDiscoverFeed(feed, query: query, progressTitle: "Last search", cacheRangeFeed: false, cacheQueryResult: false)
        return true
    }

    private func reloadCachedArxivAssets() {
        guard let arxivFeed else {
            return
        }
        var urls = arxivAssetURLs
        for paper in arxivFeed.papers {
            for asset in [paper.assets.small, paper.assets.large].compactMap({ $0 }) {
                if let url = try? arxivCache.cachedAssetURL(path: asset.path) {
                    urls[asset.path] = url
                }
            }
        }
        arxivAssetURLs = urls
        reloadCachedArxivPDFThumbnails()
    }

    private func reloadCachedArxivPDFThumbnails() {
        guard let arxivFeed else {
            arxivPDFThumbnailURLsByID = [:]
            return
        }
        var urlsByID = arxivPDFThumbnailURLsByID
        let visibleIDs = Set(arxivFeed.papers.map(\.id))
        for paper in arxivFeed.papers where urlsByID[paper.id]?.isEmpty != false {
            guard let pdfURL = try? cachedArxivPDFURL(for: paper),
                  let urls = try? thumbnailCache.thumbnails(
                    forPDFAt: pdfURL,
                    cacheID: "arxiv-\(paper.id)",
                    pageLimit: 5,
                    size: CGSize(width: 164, height: 212)
                  ),
                  !urls.isEmpty else {
                continue
            }
            urlsByID[paper.id] = urls
        }
        arxivPDFThumbnailURLsByID = urlsByID.filter { visibleIDs.contains($0.key) }
    }

    private func importArxivPaper(_ arxivPaper: ArxivFeedPaper, isSaved: Bool) async throws -> Paper {
        guard let repository else {
            throw AppModelError.repositoryUnavailable
        }
        isAddingArxivPaper = true
        arxivDownloadingPaperIDs.insert(arxivPaper.id)
        arxivDownloadProgressByID[arxivPaper.id] = 0.1
        defer {
            isAddingArxivPaper = false
            arxivDownloadingPaperIDs.remove(arxivPaper.id)
            arxivDownloadProgressByID.removeValue(forKey: arxivPaper.id)
        }

        let client = makeLocalArxivClient()
        let pdfURL = try await ensureArxivPDFCached(arxivPaper, client: client)
        arxivDownloadProgressByID[arxivPaper.id] = 0.65
        _ = try refreshDiscoverPDFThumbnails(for: arxivPaper, pdfURL: pdfURL)

        let metadata = PaperImportMetadata(
            title: arxivPaper.displayTitle(language: globalLanguageMode.metadataLanguageCode),
            authors: arxivPaper.authors,
            year: arxivPaper.publishedYear,
            sourceURL: arxivPaper.links.abs
        )
        let result = try PaperLibraryImporter(repository: repository, supportRoot: supportRoot)
            .importPDF(
                from: pdfURL,
                metadata: metadata,
                isSaved: isSaved,
                storageSubpath: isSaved ? arxivStorageSubpath(for: arxivPaper) : nil
            )
        arxivDownloadProgressByID[arxivPaper.id] = 1
        return result.paper
    }

    private func assignCategories(
        categoryIDs: [String],
        newCategoryNames: [String],
        newCategories: [SaveToLibraryNewCategory],
        to paper: Paper,
        repository: PaperRepository
    ) throws {
        try LibraryCategoryAssigner().assign(
            paperID: paper.id,
            existingCategoryIDs: categoryIDs,
            newCategoryNames: newCategoryNames,
            newCategories: newCategories,
            repository: repository,
            onCategoryCreated: { category in
                self.includeCategoryInSimilarityDefaults(category.id)
            }
        )
    }

    private func normalizedIdentifiers(_ values: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                continue
            }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private func arxivStorageSubpath(for paper: ArxivFeedPaper) -> String? {
        switch arxivSaveOrganization {
        case .primaryCategory:
            return paper.primaryCategory ?? paper.categories.first ?? "arxiv"
        case .firstTag:
            return paper.tags.first ?? paper.primaryCategory ?? "arxiv"
        case .date:
            return paper.listDate ?? selectedArxivDate ?? "arxiv"
        case .flat:
            return nil
        }
    }

    private func arxivStorageSubpath(forCachedPaper paper: Paper) -> String? {
        guard arxivSaveOrganization != .flat else {
            return nil
        }
        if let arxivPaper = arxivFeed?.papers.first(where: { candidate in
            paper.sourceURL == candidate.links.abs || paper.sourceURL?.contains(candidate.id) == true
        }) {
            return arxivStorageSubpath(for: arxivPaper)
        }
        return "arxiv"
    }

    private func removeDirectoryIfExists(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func removeManagedPaperStorage(for paper: Paper) throws {
        let paperDirectory = URL(fileURLWithPath: paper.filePath)
            .standardizedFileURL
            .deletingLastPathComponent()
        let managedRoots = [
            supportRoot.appendingPathComponent("papers", isDirectory: true).standardizedFileURL,
            supportRoot.appendingPathComponent("cache/papers", isDirectory: true).standardizedFileURL
        ]
        guard managedRoots.contains(where: { root in
            paperDirectory.path == root.path || paperDirectory.path.hasPrefix(root.path + "/")
        }) else {
            return
        }
        try removeDirectoryIfExists(paperDirectory)
    }

    private func discoverRankingVersion() -> String {
        let embedding = localDiscoverPreferences.normalized.embedding
        let model = embedding.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard embedding.enabled, !model.isEmpty else {
            return "local-rank-v3-no-embedding"
        }
        return "local-rank-v3-category-average-\(model)"
    }

    private func applyDiscoverRanking(to feed: ArxivFeedResponse, query: DiscoverQuery) async throws -> ArxivFeedResponse {
        let deduplicatedFeed = feed.deduplicatedByCanonicalID()
        let preferences = localDiscoverPreferences.normalized
        let sourceIDs = query.similaritySourceIDs
        guard preferences.embedding.enabled, !sourceIDs.isEmpty else {
            return applyLocalDiscoverPreferences(to: deduplicatedFeed)
        }

        let embeddingSettings = preferences.embedding
        let model = embeddingSettings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = embeddingProviderAPIKeyValue().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !embeddingSettings.baseURL.isEmpty, !model.isEmpty, !apiKey.isEmpty else {
            errorMessage = "Embedding similarity is enabled, but Base URL, API key, or model is missing."
            return applyLocalDiscoverPreferences(to: deduplicatedFeed)
        }

        let categorySources = similarityCategorySources(for: sourceIDs)
        let sourcePapers = uniquePapers(categorySources.flatMap(\.papers))
        guard !categorySources.isEmpty, !sourcePapers.isEmpty else {
            errorMessage = "No library papers matched the selected similarity source."
            return applyLocalDiscoverPreferences(to: deduplicatedFeed)
        }

        guard let repository else {
            throw AppModelError.repositoryUnavailable
        }

        arxivCacheProgress = ArxivCacheProgress(
            date: feed.date,
            title: "Embedding ranking",
            detail: "Preparing \(sourcePapers.count) library sources",
            completed: 0,
            total: sourcePapers.count + deduplicatedFeed.papers.count
        )

        let client = try OpenAICompatibleEmbeddingClient(settings: embeddingSettings, apiKey: apiKey)
        let interestInputs = try sourcePapers.map { paper in
            DiscoverEmbeddingInput(
                sourceID: "paper:\(paper.id)",
                text: try libraryEmbeddingText(for: paper, repository: repository)
            )
        }
        let sourceVectors = try await cachedEmbeddings(
            inputs: interestInputs,
            model: model,
            client: client,
            progressDate: feed.date,
            progressTitle: "Embedding library sources",
            totalOffset: 0
        )
        let sourceVectorsByID = Dictionary(uniqueKeysWithValues: zip(interestInputs.map(\.sourceID), sourceVectors))
        let interestVectorGroups = categorySources.map { source in
            source.papers.compactMap { paper in
                sourceVectorsByID["paper:\(paper.id)"]
            }
        }
        guard !interestVectorGroups.flatMap({ $0 }).isEmpty else {
            return applyLocalDiscoverPreferences(to: deduplicatedFeed)
        }

        let paperInputs = deduplicatedFeed.papers.map { paper in
            DiscoverEmbeddingInput(
                sourceID: "arxiv:\(paper.id)",
                text: trimmedEmbeddingText(DiscoverEmbeddingText.arxivPaperText(paper))
            )
        }
        let paperVectors = try await cachedEmbeddings(
            inputs: paperInputs,
            model: model,
            client: client,
            progressDate: feed.date,
            progressTitle: "Embedding arXiv results",
            totalOffset: interestInputs.count
        )

        let vectorsByID = Dictionary(uniqueKeysWithValues: zip(paperInputs.map(\.sourceID), paperVectors))
        let papersWithEmbeddings = deduplicatedFeed.papers.map { paper -> ArxivFeedPaper in
            var rankedPaper = paper
            rankedPaper.embedding = vectorsByID["arxiv:\(paper.id)"]
            return rankedPaper
        }
        let rankedPapers = SimilarityRanker.rank(
            papers: papersWithEmbeddings,
            whitelistTags: preferences.whitelistTags,
            blacklistTags: preferences.blacklistTags,
            interestVectorGroups: interestVectorGroups
        )
        arxivCacheProgress = ArxivCacheProgress(
            date: feed.date,
            title: "Embedding ranking ready",
            detail: "\(rankedPapers.filter { $0.similarity != nil }.count)/\(rankedPapers.count) scored",
            completed: rankedPapers.count,
            total: rankedPapers.count
        )
        return ArxivFeedResponse(
            date: deduplicatedFeed.date,
            count: rankedPapers.count,
            papers: rankedPapers,
            groups: [
                ArxivFeedGroup(key: "white", count: rankedPapers.filter { $0.filterGroup == "white" }.count),
                ArxivFeedGroup(key: "neutral", count: rankedPapers.filter { $0.filterGroup == "neutral" }.count),
                ArxivFeedGroup(key: "black", count: rankedPapers.filter { $0.filterGroup == "black" }.count)
            ],
            tagOptions: Array(Set(rankedPapers.flatMap(\.tags))).sorted(),
            sourceCategories: deduplicatedFeed.sourceCategories
        )
        .deduplicatedByCanonicalID()
    }

    private func rerankEmbeddedDiscoverFeed(
        _ feed: ArxivFeedResponse,
        model: String,
        client: OpenAICompatibleEmbeddingClient,
        progressDate: String,
        progressTitle: String
    ) async throws -> ArxivFeedResponse {
        let deduplicatedFeed = feed.deduplicatedByCanonicalID(preservingCount: feed.date == "search")
        let preferences = localDiscoverPreferences.normalized
        let sourceIDs = effectiveDiscoverSimilaritySourceIDs()
        guard preferences.embedding.enabled, !sourceIDs.isEmpty else {
            return applyLocalDiscoverPreferences(to: deduplicatedFeed)
        }

        let categorySources = similarityCategorySources(for: sourceIDs)
        let sourcePapers = uniquePapers(categorySources.flatMap(\.papers))
        guard !categorySources.isEmpty, !sourcePapers.isEmpty else {
            return applyLocalDiscoverPreferences(to: deduplicatedFeed)
        }

        guard let repository else {
            throw AppModelError.repositoryUnavailable
        }

        let sourceInputs = try sourcePapers.map { paper in
            DiscoverEmbeddingInput(
                sourceID: "paper:\(paper.id)",
                text: try libraryEmbeddingText(for: paper, repository: repository)
            )
        }
        let sourceVectors = try await cachedEmbeddings(
            inputs: sourceInputs,
            model: model,
            client: client,
            progressDate: progressDate,
            progressTitle: progressTitle,
            totalOffset: 0,
            progressDestination: .discoverProcessing
        )
        let sourceVectorsByID = Dictionary(uniqueKeysWithValues: zip(sourceInputs.map(\.sourceID), sourceVectors))
        let interestVectorGroups = categorySources.map { source in
            source.papers.compactMap { paper in
                sourceVectorsByID["paper:\(paper.id)"]
            }
        }
        guard !interestVectorGroups.flatMap({ $0 }).isEmpty else {
            return applyLocalDiscoverPreferences(to: deduplicatedFeed)
        }

        let rankedPapers = SimilarityRanker.rank(
            papers: deduplicatedFeed.papers,
            whitelistTags: preferences.whitelistTags,
            blacklistTags: preferences.blacklistTags,
            interestVectorGroups: interestVectorGroups
        )
        discoverProcessingProgress = ArxivCacheProgress(
            date: progressDate,
            title: progressTitle,
            detail: "\(rankedPapers.filter { $0.similarity != nil }.count)/\(rankedPapers.count) scored",
            completed: rankedPapers.count,
            total: rankedPapers.count
        )
        return ArxivFeedResponse(
            date: deduplicatedFeed.date,
            count: deduplicatedFeed.count,
            papers: rankedPapers,
            groups: [
                ArxivFeedGroup(key: "white", count: rankedPapers.filter { $0.filterGroup == "white" }.count),
                ArxivFeedGroup(key: "neutral", count: rankedPapers.filter { $0.filterGroup == "neutral" }.count),
                ArxivFeedGroup(key: "black", count: rankedPapers.filter { $0.filterGroup == "black" }.count)
            ],
            tagOptions: Array(Set(rankedPapers.flatMap(\.tags))).sorted(),
            sourceCategories: deduplicatedFeed.sourceCategories
        )
        .deduplicatedByCanonicalID(preservingCount: deduplicatedFeed.date == "search")
    }

    private func cachedEmbeddings(
        inputs: [DiscoverEmbeddingInput],
        model: String,
        client: OpenAICompatibleEmbeddingClient,
        progressDate: String,
        progressTitle: String,
        totalOffset: Int,
        progressDestination: EmbeddingProgressDestination = .arxivCache
    ) async throws -> [[Double]] {
        guard !inputs.isEmpty else {
            return []
        }
        var vectorsBySourceID: [String: [Double]] = [:]
        var missing: [DiscoverEmbeddingInput] = []
        for input in inputs {
            if let cached = try localDiscoverCache.loadEmbedding(sourceID: input.sourceID, model: model, text: input.text) {
                vectorsBySourceID[input.sourceID] = cached.vector
            } else {
                missing.append(input)
            }
        }

        updateEmbeddingProgress(
            destination: progressDestination,
            date: progressDate,
            title: progressTitle,
            detail: "\(inputs.count - missing.count)/\(inputs.count) cached",
            completed: totalOffset + inputs.count - missing.count,
            total: totalOffset + inputs.count
        )

        if !missing.isEmpty {
            let cachedCount = inputs.count - missing.count
            var generatedCount = 0
            for batch in OpenAICompatibleEmbeddingClient.embeddingBatches(missing) {
                let vectors = try await client.embed(texts: batch.map(\.text))
                for (input, vector) in zip(batch, vectors) {
                    let record = DiscoverEmbeddingRecord(
                        sourceID: input.sourceID,
                        model: model,
                        textHash: DiscoverEmbeddingText.hash(input.text),
                        vector: vector,
                        generatedAt: Date()
                    )
                    try localDiscoverCache.saveEmbedding(record)
                    vectorsBySourceID[input.sourceID] = vector
                }
                generatedCount += batch.count
                updateEmbeddingProgress(
                    destination: progressDestination,
                    date: progressDate,
                    title: progressTitle,
                    detail: "\(cachedCount + generatedCount)/\(inputs.count) ready",
                    completed: totalOffset + cachedCount + generatedCount,
                    total: totalOffset + inputs.count
                )
            }
        }

        updateEmbeddingProgress(
            destination: progressDestination,
            date: progressDate,
            title: progressTitle,
            detail: "\(inputs.count)/\(inputs.count) ready",
            completed: totalOffset + inputs.count,
            total: totalOffset + inputs.count
        )
        return inputs.compactMap { vectorsBySourceID[$0.sourceID] }
    }

    private func updateEmbeddingProgress(
        destination: EmbeddingProgressDestination,
        date: String,
        title: String,
        detail: String,
        completed: Int,
        total: Int
    ) {
        let progress = ArxivCacheProgress(
            date: date,
            title: title,
            detail: detail,
            completed: completed,
            total: total
        )
        switch destination {
        case .arxivCache:
            arxivCacheProgress = progress
        case .discoverProcessing:
            discoverProcessingProgress = progress
        }
    }

    private func effectiveDiscoverSimilaritySourceIDs() -> [String] {
        let selected = normalizedSimilaritySourceIDs(discoverSelectedSimilaritySourceIDs)
        if !selected.isEmpty {
            return selected
        }
        return effectiveDiscoverSimilarityCategoryIDs().map { "category:\($0)" }
    }

    private func effectiveDiscoverSimilarityCategoryIDs() -> [String] {
        let configured = localDiscoverPreferences.normalized.similarityCategoryIDs ?? categories.map(\.id)
        return normalizedIdentifiers(configured).filter { categoryID in
            categories.contains { $0.id == categoryID }
        }
    }

    private func normalizedSimilaritySourceIDs(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }
            let normalized = similaritySourceID(from: trimmed)
            guard !seen.contains(normalized) else {
                continue
            }
            seen.insert(normalized)
            result.append(normalized)
        }
        return result
    }

    private func similaritySourceID(from value: String) -> String {
        if value.hasPrefix("tag:") || value.hasPrefix("category:") {
            return value
        }
        if let tag = tags.first(where: { $0.id == value || $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }) {
            return "tag:\(tag.id)"
        }
        if let category = categories.first(where: { $0.id == value || $0.name.localizedCaseInsensitiveCompare(value) == .orderedSame }) {
            return "category:\(category.id)"
        }
        return value
    }

    private func similarityCategorySources(for sourceIDs: [String]) -> [DiscoverSimilarityCategorySource] {
        var seenCategoryIDs: Set<String> = []
        var sources: [DiscoverSimilarityCategorySource] = []
        for sourceID in sourceIDs {
            guard sourceID.hasPrefix("category:") else {
                continue
            }
            let categoryID = String(sourceID.dropFirst("category:".count))
            guard !seenCategoryIDs.contains(categoryID),
                  categories.contains(where: { $0.id == categoryID }) else {
                continue
            }
            let categoryIDs = Set([categoryID]).union(categoryDescendantIDs(of: categoryID))
            let sourcePapers = papers.filter { paper in
                !Set(paperCategoryIDsByID[paper.id, default: []]).isDisjoint(with: categoryIDs)
            }
            if !sourcePapers.isEmpty {
                seenCategoryIDs.insert(categoryID)
                sources.append(DiscoverSimilarityCategorySource(categoryID: categoryID, papers: sourcePapers))
            }
        }
        return sources
    }

    private func uniquePapers(_ values: [Paper]) -> [Paper] {
        var seen: Set<String> = []
        var result: [Paper] = []
        for paper in values where !seen.contains(paper.id) {
            seen.insert(paper.id)
            result.append(paper)
        }
        return result
    }

    private func libraryEmbeddingText(for paper: Paper, repository: PaperRepository) throws -> String {
        let pageText = try repository.fetchPages(paperID: paper.id)
            .prefix(5)
            .map(\.text)
            .joined(separator: "\n")
        let categoryNames = paperCategoryIDsByID[paper.id, default: []].compactMap { categoryID in
            categories.first { $0.id == categoryID }?.name
        }
        let tagNames = paperTagsByID[paper.id, default: []].map(\.name)
        return trimmedEmbeddingText(
            DiscoverEmbeddingText.libraryPaperText(
                title: paper.title,
                authors: paper.authors,
                tags: tagNames,
                categories: categoryNames,
                indexedText: pageText
            )
        )
    }

    private func trimmedEmbeddingText(_ text: String) -> String {
        String(DiscoverEmbeddingText.normalized(text).prefix(12_000))
    }

    private func applyLocalDiscoverPreferences(to feed: ArxivFeedResponse) -> ArxivFeedResponse {
        let preferences = localDiscoverPreferences.normalized
        let deduplicatedFeed = feed.deduplicatedByCanonicalID(preservingCount: feed.date == "search")
        let rankedPapers = SimilarityRanker.rank(
            papers: deduplicatedFeed.papers,
            whitelistTags: preferences.whitelistTags,
            blacklistTags: preferences.blacklistTags,
            interestVectors: []
        )
        return ArxivFeedResponse(
            date: deduplicatedFeed.date,
            count: deduplicatedFeed.date == "search" ? deduplicatedFeed.count : rankedPapers.count,
            papers: rankedPapers,
            groups: [
                ArxivFeedGroup(key: "white", count: rankedPapers.filter { $0.filterGroup == "white" }.count),
                ArxivFeedGroup(key: "neutral", count: rankedPapers.filter { $0.filterGroup == "neutral" }.count),
                ArxivFeedGroup(key: "black", count: rankedPapers.filter { $0.filterGroup == "black" }.count)
            ],
            tagOptions: Array(Set(rankedPapers.flatMap(\.tags))).sorted(),
            sourceCategories: deduplicatedFeed.sourceCategories
        )
        .deduplicatedByCanonicalID(preservingCount: deduplicatedFeed.date == "search")
    }

    private func fetchArxivAsset(_ asset: ArxivFeedAsset) async throws -> Data {
        guard let url = URL(string: asset.url), url.scheme != nil else {
            throw LocalArxivClientError.invalidURL(asset.url)
        }
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 30
        var request = URLRequest(url: url)
        request.setValue("Episteme/0.1 (+https://arxiv.org)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession(configuration: configuration).data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            throw LocalArxivClientError.badStatus(http.statusCode, url.absoluteString)
        }
        return data
    }

    private func makeLocalArxivClient(categories overrideCategories: [String]? = nil) -> LocalArxivClient {
        let preferences = localDiscoverPreferences.normalized
        let categories = overrideCategories ?? (preferences.categories.isEmpty ? LocalArxivClient.defaultCategories : preferences.categories)
        let configuration = URLSessionConfiguration.default
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 180
        return LocalArxivClient(
            configuration: LocalArxivClientConfiguration(categories: categories),
            session: URLSession(configuration: configuration)
        )
    }

    private func runDiscoverAgentEnrichment(
        for paper: ArxivFeedPaper,
        actions: Set<DiscoverProcessAction>,
        runtimeProfile: AgentRuntimeProfile,
        existing: DiscoverPaperEnrichment?,
        modelOverride: String,
        reasoningEffort: CodexReasoningEffort
    ) async throws -> (enrichment: DiscoverPaperEnrichment, tokenUsage: CodexTokenUsage?) {
        let workspaceURL = supportRoot
            .appendingPathComponent("discover-processing", isDirectory: true)
            .appendingPathComponent("\(makeSlug(from: paper.id))-\(UUID().uuidString.lowercased())", isDirectory: true)
        let outputURL = workspaceURL.appendingPathComponent("last-message.json")
        let eventLogURL = workspaceURL.appendingPathComponent("events.jsonl")
        let normalizedModelOverride = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = discoverEnrichmentPrompt(for: paper, actions: actions)
        let runHandle = CodexRunHandle()
        activeDiscoverCodexRunHandles.append(runHandle)
        defer {
            activeDiscoverCodexRunHandles.removeAll { $0 === runHandle }
        }
        let result = try await agentRunCoordinator.runDiscoverEnrichment(
            AgentDiscoverEnrichmentRequest(
                prompt: prompt,
                arxivID: paper.id,
                workspaceURL: workspaceURL,
                outputURL: outputURL,
                eventLogURL: eventLogURL,
                runtimeProfile: runtimeProfile,
                modelOverride: normalizedModelOverride,
                providerOverride: agentRuntimeStore.providerOverride(for: runtimeProfile.id),
                reasoningEffort: reasoningEffort,
                modelIdentity: discoverModelIdentity(
                    runtimeProfile: runtimeProfile,
                    modelOverride: normalizedModelOverride,
                    reasoningEffort: reasoningEffort
                ),
                runHandle: runHandle
            )
        )
        return (mergeDiscoverEnrichment(result.enrichment, existing: existing, actions: actions), result.tokenUsage)
    }

    private func mergeDiscoverEnrichment(
        _ parsed: DiscoverPaperEnrichment,
        existing: DiscoverPaperEnrichment?,
        actions: Set<DiscoverProcessAction>
    ) -> DiscoverPaperEnrichment {
        let currentExisting = existing?.isCurrent == true && existing?.error == nil ? existing : nil
        return DiscoverPaperEnrichment(
            arxivID: parsed.arxivID,
            processorVersion: parsed.processorVersion,
            promptVersion: parsed.promptVersion,
            modelIdentity: parsed.modelIdentity,
            titleZH: actions.contains(.translate) ? parsed.titleZH : currentExisting?.titleZH ?? "",
            summaryZH: actions.contains(.summarize) ? parsed.summaryZH : currentExisting?.summaryZH ?? "",
            contribution: actions.contains(.summarize) ? parsed.contribution : currentExisting?.contribution ?? "",
            tags: actions.contains(.summarize) ? parsed.tags : currentExisting?.tags ?? [],
            links: actions.contains(.summarize) ? parsed.links : currentExisting?.links ?? [:],
            generatedAt: parsed.generatedAt,
            error: nil
        )
    }

    private func discoverEnrichmentPrompt(for paper: ArxivFeedPaper, actions: Set<DiscoverProcessAction>) -> String {
        var schemaLines: [String] = []
        var taskLines: [String] = []
        if actions.contains(.translate) {
            schemaLines.append(#"  "title_zh": "Chinese translation of the title""#)
            taskLines.append("- Translate the title into concise Chinese.")
        }
        if actions.contains(.summarize) {
            schemaLines.append(#"  "summary_zh": "2 concise Chinese sentences summarizing the paper from title and abstract""#)
            schemaLines.append(#"  "contribution": "1 concise Chinese sentence naming the main contribution""#)
            schemaLines.append(#"  "tags": ["3-8 short lowercase tags"]"#)
            schemaLines.append(#"  "links": {"github": "https://...", "project": "https://...", "hugging_face": "https://..."}"#)
            taskLines.append("- Summarize the paper and extract discovery tags plus useful project links.")
        }
        let schema = "{\n\(schemaLines.joined(separator: ",\n"))\n}"
        let tasks = taskLines.joined(separator: "\n")
        return """
        You are helping Episteme enrich an arXiv discovery card.
        Return strict JSON only. Do not wrap the JSON in Markdown.

        Required JSON schema:
        \(schema)

        Selected tasks:
        \(tasks)

        Include only the selected schema keys. Use empty strings or omit link keys when no link is present.
        Tags should be useful for paper discovery.

        arXiv ID: \(paper.id)
        Primary category: \(paper.primaryCategory ?? paper.categories.first ?? "unknown")
        Categories: \(paper.categories.joined(separator: ", "))
        Title: \(paper.title.en)
        Authors: \(paper.authors.joined(separator: ", "))
        Abstract: \(paper.abstract.en)
        Comment: \(paper.comment)
        Known links:
        abs: \(paper.links.abs ?? "")
        pdf: \(paper.links.pdf ?? "")
        github: \(paper.links.github ?? "")
        project: \(paper.links.project ?? "")
        hugging_face: \(paper.links.huggingFace ?? "")
        """
    }

    private func makeManualID(prefix: String, name: String) -> String {
        let slug = makeSlug(from: name)
        return "\(prefix)-\(slug.isEmpty ? "item" : slug)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    private func makeSlug(from text: String) -> String {
        text
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? character : "-"
            }
            .reduce(into: "") { partial, character in
                if character == "-", partial.last == "-" {
                    return
                }
                partial.append(character)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func scanWatchedFolder(_ folder: WatchedFolder) throws {
        guard let repository else {
            throw AppModelError.repositoryUnavailable
        }
        _ = try WatchedFolderScanner(repository: repository, supportRoot: supportRoot)
            .scan(folder: folder)
    }

    private func beginCodexRun(sessionID: String, title: String) -> String {
        let runID = UUID().uuidString.lowercased()
        activeCodexRunsBySessionID[sessionID] = ActiveCodexRun(
            id: runID,
            sessionID: sessionID,
            title: title,
            startedAt: Date(),
            events: [
                CodexRunEvent(kind: .status, title: "Preparing", detail: "Preparing paper context and Codex workspace")
            ]
        )
        return runID
    }

    private func appendCodexRunEvent(_ event: CodexRunEvent, runID: String) {
        guard let sessionID = activeCodexRunsBySessionID.first(where: { $0.value.id == runID })?.key else {
            return
        }
        activeCodexRunsBySessionID[sessionID]?.events.appendCoalescingStreamingChunk(event, maxCount: 80)
    }

    private func finishCodexRun(sessionID: String) {
        activeCodexRunsBySessionID[sessionID] = nil
        activeCodexRunHandlesBySessionID[sessionID] = nil
        cancellingCodexRunSessionIDs.remove(sessionID)
    }

    private func startWatchedFolderAutoScan() {
        watchedFolderAutoScanTask?.cancel()
        watchedFolderAutoScanTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                guard !Task.isCancelled else {
                    return
                }
                self?.scanWatchedFoldersIfNeeded()
            }
        }
    }

    private func scanWatchedFoldersIfNeeded() {
        guard !watchedFolders.isEmpty else {
            return
        }
        scanWatchedFolders()
    }

    private func inAppCodexMCPServers() -> [CodexMCPServerConfig] {
        guard inAppCodexMCPEnabled, let endpoint = mcpEndpoint else {
            return []
        }
        return [
            CodexMCPServerConfig(
                name: "paper-codex",
                url: endpoint.url,
                bearerTokenEnvironmentVariable: "PAPER_CODEX_MCP_TOKEN",
                bearerToken: endpoint.token
            )
        ]
    }

    private func agentTerminalCommand(
        for runtimeProfile: AgentRuntimeProfile,
        session: PaperSession,
        workspacePath: URL
    ) throws -> AgentRuntimeCommand {
        let mcpConfigPath = workspacePath.appendingPathComponent("mcp.json").path
        let agentInstructionsPath = workspacePath.appendingPathComponent("agent_instructions.md").path
        let skillsPath = workspacePath
            .appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("papercodex-agent-workspace", isDirectory: true)
            .path
        let modelID = agentRuntimeStore.modelOverride(for: runtimeProfile.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let providerID = agentRuntimeStore.providerOverride(for: runtimeProfile.id)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch runtimeProfile.backend {
        case .codex:
            let executable = try CodexRuntimeAdapter.findExecutable()
            return CodexRuntimeAdapter(executablePath: executable).terminalCommand(
                workspacePath: session.workspacePath,
                modelOverride: effectiveModelOverride(prefersWorkspaceImageOutput: false),
                reasoningEffort: codexReasoningEffort,
                mcpServers: inAppCodexMCPServers()
            )
        case .claudeCode:
            let executable = try ClaudeCodeRuntimeAdapter.findExecutable()
            return ClaudeCodeRuntimeAdapter(executablePath: executable).terminalCommand(
                workspacePath: session.workspacePath,
                mcpConfigPath: FileManager.default.fileExists(atPath: mcpConfigPath) ? mcpConfigPath : nil
            )
        case .acp:
            throw AppModelError.runtimeDoesNotSupportTerminal(runtimeProfile.displayName)
        case .hermes:
            let executable = try HermesRuntimeAdapter.findExecutable()
            return HermesRuntimeAdapter(executablePath: executable).terminalCommand(
                workspacePath: session.workspacePath,
                provider: providerID.isEmpty ? nil : providerID,
                model: modelID.isEmpty ? runtimeProfile.defaultModelID : modelID,
                skillsPath: FileManager.default.fileExists(atPath: skillsPath) ? skillsPath : nil
            )
        case .kimiCLI:
            let executable = try KimiRuntimeAdapter.findExecutable()
            return KimiRuntimeAdapter(executablePath: executable).terminalCommand(
                workspacePath: session.workspacePath,
                sessionID: session.runtimeSessionID(for: runtimeProfile.id),
                modelID: modelID.isEmpty ? runtimeProfile.defaultModelID : modelID,
                skillsPath: FileManager.default.fileExists(atPath: skillsPath) ? skillsPath : nil
            )
        case .openClawKimi:
            let executable = try OpenClawRuntimeAdapter.findExecutable()
            return OpenClawRuntimeAdapter(executablePath: executable).terminalCommand(
                workspacePath: session.workspacePath,
                sessionID: session.runtimeSessionID(for: runtimeProfile.id) ?? session.id,
                modelID: modelID.isEmpty ? runtimeProfile.defaultModelID : modelID
            )
        case .pi:
            let executable = try PiRuntimeAdapter.findExecutable()
            return PiRuntimeAdapter(executablePath: executable).terminalCommand(
                workspacePath: session.workspacePath,
                systemPrompt: "Use Episteme citations.",
                agentInstructionsPath: FileManager.default.fileExists(atPath: agentInstructionsPath) ? agentInstructionsPath : nil
            )
        }
    }

    private func appendAgentTerminalOutput(data: Data, terminalID: String, logURL: URL) {
        guard var state = agentTerminalState, state.id == terminalID else {
            return
        }
        do {
            let handle = try FileHandle(forWritingTo: logURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            errorMessage = "Terminal log write failed: \(error)"
        }
        state.output += String(decoding: data, as: UTF8.self)
        if state.output.count > 80_000 {
            state.output = String(state.output.suffix(80_000))
        }
        agentTerminalState = state
    }

    private func finishAgentTerminal(terminalID: String, status: Int32) {
        guard var state = agentTerminalState, state.id == terminalID else {
            return
        }
        state.isRunning = false
        if !state.output.hasSuffix("\n") {
            state.output += "\n"
        }
        state.output += "[process exited: \(status)]\n"
        agentTerminalState = state
        activeAgentTerminalProcess = nil
    }

    private func effectiveModelOverride(prefersWorkspaceImageOutput: Bool) -> String {
        let trimmed = codexModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prefersWorkspaceImageOutput else {
            return trimmed
        }
        if trimmed.isEmpty || trimmed == "gpt-5.5" {
            return "gpt-5.4-mini"
        }
        return trimmed
    }

    private func effectiveDiscoverModelOverride(for runtimeProfile: AgentRuntimeProfile) -> String {
        if runtimeProfile.id == "codex" {
            return discoverCodexModelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return agentRuntimeStore.modelOverride(for: runtimeProfile.id)
    }

    private func discoverModelIdentity(
        runtimeProfile: AgentRuntimeProfile,
        modelOverride: String,
        reasoningEffort: CodexReasoningEffort
    ) -> String {
        let trimmedModel = modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        var identity = trimmedModel.isEmpty ? runtimeProfile.id : "\(runtimeProfile.id):\(trimmedModel)"
        if runtimeProfile.id == "codex", reasoningEffort != .default {
            identity += ":think-\(reasoningEffort.rawValue)"
        }
        return identity
    }

    private func runAgentTurn(
        content: String,
        session: PaperSession,
        fallbackPaper: Paper,
        repository: PaperRepository
    ) async throws -> PaperSession {
        let prefersWorkspaceImageOutput = ImageGenerationRequestDetector.isImageRequest(content)
        let runtimeProfile = prefersWorkspaceImageOutput
            ? (AgentRuntimeProfile.defaultProfile(id: "codex") ?? agentRuntimeStore.selectedChatRuntime)
            : agentRuntimeStore.selectedChatRuntime
        let runID = beginCodexRun(sessionID: session.id, title: "\(runtimeProfile.displayName) is working")
        let context = try loadSessionPaperContext(session: session, fallbackPaper: fallbackPaper, repository: repository)
        let selectedAnchors = anchorsReferenced(in: content, context: context)
        let runHandle = CodexRunHandle()
        activeCodexRunHandlesBySessionID[session.id] = runHandle
        let eventSink: @Sendable (CodexRunEvent) -> Void = { [weak self] event in
            Task { @MainActor in
                self?.appendCodexRunEvent(event, runID: runID)
            }
        }
        let modelOverride = runtimeProfile.id == "codex"
            ? effectiveModelOverride(prefersWorkspaceImageOutput: prefersWorkspaceImageOutput)
            : agentRuntimeStore.modelOverride(for: runtimeProfile.id)
        let result = try await agentRunCoordinator.runChatTurn(
            AgentChatTurnRequest(
                content: content,
                session: session,
                context: AgentChatTurnContext(
                    papers: context.papers,
                    pagesByPaperID: context.pagesByPaperID,
                    spansByPaperID: context.spansByPaperID,
                    anchorsByPaperID: context.anchorsByPaperID,
                    selectedAnchors: selectedAnchors
                ),
                runtimeProfile: runtimeProfile,
                codexSystemPrompt: codexSystemPrompt,
                languageMode: globalLanguageMode,
                mcpEndpoint: mcpEndpoint,
                mcpServers: inAppCodexMCPServers(),
                modelOverride: modelOverride,
                providerOverride: agentRuntimeStore.providerOverride(for: runtimeProfile.id),
                reasoningEffort: codexReasoningEffort,
                prefersWorkspaceImageOutput: prefersWorkspaceImageOutput
            ),
            runHandle: runHandle,
            onEvent: eventSink
        )
        try repository.upsertSession(result.updatedSession)
        try repository.appendMessage(result.message)
        if let tokenUsage = result.tokenUsage {
            postNotice(
                kind: .info,
                title: "Chat Tokens",
                message: tokenUsage.compactSummary,
                autoDismissAfter: 8
            )
        }
        return result.updatedSession
    }

    private func codexMessageContent(lastMessage: String, stdout: String, generatedImages: [URL]) -> String {
        let imageMarkdown = GeneratedImageCollector.markdown(for: generatedImages)
        let trimmedLastMessage = lastMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLastMessage.isEmpty {
            return imageMarkdown.isEmpty ? stdout : imageMarkdown
        }
        guard !imageMarkdown.isEmpty else {
            return lastMessage
        }
        let missingImageMarkdown = imageMarkdown
            .components(separatedBy: "\n\n")
            .filter { !lastMessage.contains($0) }
            .joined(separator: "\n\n")
        guard !missingImageMarkdown.isEmpty else {
            return lastMessage
        }
        return "\(lastMessage)\n\n\(missingImageMarkdown)"
    }

    private func fallbackPaper(for session: PaperSession, repository: PaperRepository) throws -> Paper {
        if let selectedPaper {
            return selectedPaper
        }
        guard let firstPaperID = session.paperIDs.first,
              let paper = try repository.fetchPapers(ids: [firstPaperID]).first else {
            throw AppModelError.noSelectedPaper
        }
        return paper
    }

    private func appendCodexFailureMessage(_ failure: String, sessionID: String) async {
        guard let repository else {
            errorMessage = failure
            return
        }
        do {
            let message = ChatMessage(
                id: UUID().uuidString.lowercased(),
                sessionID: sessionID,
                role: .codex,
                content: CodexFailureNotice(detail: failure).messageContent,
                createdAt: Date()
            )
            try repository.appendMessage(message)
            if selectedSession?.id == sessionID {
                messages = try repository.fetchMessages(sessionID: sessionID)
            }
        } catch {
            errorMessage = "\(failure)\n\nAlso failed to store error message: \(error)"
        }
    }

    private func appendCodexCancellationMessage(sessionID: String) async {
        guard let repository else {
            return
        }
        do {
            let message = ChatMessage(
                id: UUID().uuidString.lowercased(),
                sessionID: sessionID,
                role: .codex,
                content: "_Codex run stopped by the user._",
                createdAt: Date()
            )
            try repository.appendMessage(message)
            if selectedSession?.id == sessionID {
                messages = try repository.fetchMessages(sessionID: sessionID)
            }
            let sessionTitle = try repository.fetchSession(id: sessionID)?.title ?? "Session"
            postNotice(kind: .info, title: "Codex Stopped", message: sessionTitle)
        } catch {
            errorMessage = "Codex stopped, but the cancellation note could not be saved: \(error)"
        }
    }
}

private extension ArxivFeedResponse {
    func mergingEmbeddings(_ vectorsByID: [String: [Double]]) -> ArxivFeedResponse {
        let embeddedPapers = papers.map { paper -> ArxivFeedPaper in
            guard let vector = vectorsByID[paper.id] else {
                return paper
            }
            var embeddedPaper = paper
            embeddedPaper.embedding = vector
            return embeddedPaper
        }
        return ArxivFeedResponse(
            date: date,
            count: count,
            papers: embeddedPapers,
            groups: groups,
            tagOptions: tagOptions,
            sourceCategories: sourceCategories
        )
        .deduplicatedByCanonicalID(preservingCount: date == "search")
    }
}

enum AppModelError: Error, CustomStringConvertible {
    case repositoryUnavailable
    case noSelectedPaper
    case noSelectedSession
    case emptyName
    case sessionPaperMismatch
    case sourceNotFound(String)
    case anchorMatchFailed
    case noRecoverableCodexTurn
    case downloadedFileIsNotPDF(String)
    case arxivMetadataNotFound(String)
    case categoryNotFound(String)
    case invalidCategoryMove
    case paperNotFound(String)
    case missingMCPCommandArgument(String)
    case runtimeDoesNotSupportTerminal(String)
    case noActiveAgentTerminal

    var description: String {
        switch self {
        case .repositoryUnavailable:
            "Local repository is not available."
        case .noSelectedPaper:
            "No paper is selected."
        case .noSelectedSession:
            "No Codex session is selected."
        case .emptyName:
            "Name cannot be empty."
        case .sessionPaperMismatch:
            "This chat session belongs to a different paper. Open a session for the current paper before sending."
        case let .sourceNotFound(id):
            "No source was found for citation \(id)."
        case .anchorMatchFailed:
            "The selected PDF text could not be matched to the paper index. Try selecting a slightly larger or smaller passage."
        case .noRecoverableCodexTurn:
            "No failed Codex turn could be retried."
        case let .downloadedFileIsNotPDF(arxivID):
            "Downloaded content for \(arxivID) was not a PDF."
        case let .arxivMetadataNotFound(arxivID):
            "No arXiv metadata was found for \(arxivID)."
        case let .categoryNotFound(categoryID):
            "No folder was found for \(categoryID)."
        case .invalidCategoryMove:
            "A category cannot be moved into itself or one of its subcategories."
        case let .paperNotFound(paperID):
            "No paper was found for \(paperID)."
        case let .missingMCPCommandArgument(name):
            "MCP command is missing \(name)."
        case let .runtimeDoesNotSupportTerminal(runtimeName):
            "\(runtimeName) does not support Terminal mode."
        case .noActiveAgentTerminal:
            "No agent terminal is running."
        }
    }
}
