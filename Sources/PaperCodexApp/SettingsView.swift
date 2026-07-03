import PaperCodexCore
import SwiftUI

private enum SettingsSectionID: String, CaseIterable, Identifiable {
    case language
    case chatAppearance
    case arxivFeed
    case localRanking
    case codexEnrichment
    case codexSystemPrompt
    case codexMCP
    case agentRuntimes
    case exploreProcessing
    case embeddingProvider
    case quickPrompts
    case savedPaperOrganization
    case disposableCache

    var id: String { rawValue }

    var title: String {
        switch self {
        case .language:
            "Language"
        case .chatAppearance:
            "Reader Chat"
        case .arxivFeed:
            "arXiv Feed"
        case .localRanking:
            "Local Ranking"
        case .codexEnrichment:
            "Codex Enrichment"
        case .codexSystemPrompt:
            "System Prompt"
        case .codexMCP:
            "Episteme MCP"
        case .agentRuntimes:
            "Agent Runtimes"
        case .exploreProcessing:
            "Explore Processing"
        case .embeddingProvider:
            "Embedding Provider"
        case .quickPrompts:
            "Quick Prompts"
        case .savedPaperOrganization:
            "Saved Papers"
        case .disposableCache:
            "Disposable Cache"
        }
    }

    var systemImage: String {
        switch self {
        case .language:
            "globe"
        case .chatAppearance:
            "text.bubble"
        case .arxivFeed:
            "network"
        case .localRanking:
            "slider.horizontal.3"
        case .codexEnrichment:
            "sparkles"
        case .codexSystemPrompt:
            "text.quote"
        case .codexMCP:
            "point.3.connected.trianglepath.dotted"
        case .agentRuntimes:
            "terminal"
        case .exploreProcessing:
            "cpu"
        case .embeddingProvider:
            "point.3.connected.trianglepath.dotted"
        case .quickPrompts:
            "text.bubble"
        case .savedPaperOrganization:
            "folder.badge.gearshape"
        case .disposableCache:
            "internaldrive"
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var activeSettingsSection: SettingsSectionID = .language
    @State private var draftArxivCategories = ""
    @State private var draftWhitelistTags = ""
    @State private var draftBlacklistTags = ""
    @State private var draftSimilarityCategoryIDs: Set<String> = []
    @State private var collapsedSimilarityCategoryIDs: Set<String> = []
    @State private var hasInitializedSimilarityCategoryCollapse = false
    @State private var draftAutoEnrichOnOpen = false
    @State private var draftAutoEnrichOnSave = false
    @State private var draftCodexSystemPrompt = PromptBuilder.defaultSystemPrompt
    @State private var draftDiscoverCodexModel = ""
    @State private var draftDiscoverCodexReasoningEffort: CodexReasoningEffort = .default
    @State private var draftDiscoverCodexConcurrency = 10
    @State private var draftChatMessageFontSize = ChatAppearanceDefaults.defaultMessageFontSize
    @State private var draftChatComposerFontSize = ChatAppearanceDefaults.defaultComposerFontSize
    @State private var draftChatFontFamily: ChatFontFamily = .system
    @State private var draftEmbeddingEnabled = false
    @State private var draftEmbeddingBaseURL = ""
    @State private var draftEmbeddingAPIKey = ""
    @State private var draftEmbeddingModel = ""
    @State private var newPromptTitle = ""
    @State private var newPromptContent = ""
    @State private var isConfirmingClearCache = false
    @State private var isEditingCodexSystemPrompt = false
    @State private var editingPrompt: QuickPrompt?
    @State private var editingPromptTitle = ""
    @State private var editingPromptContent = ""

    private var isArxivFeedDirty: Bool {
        splitDraftList(draftArxivCategories) != model.localDiscoverPreferences.normalized.categories
    }

    private var isRankingDirty: Bool {
        let preferences = model.localDiscoverPreferences.normalized
        let selection = CategoryHierarchySelection(categories: model.categories)
        return splitDraftList(draftWhitelistTags) != preferences.whitelistTags
            || splitDraftList(draftBlacklistTags) != preferences.blacklistTags
            || selection.normalizedSelection(draftSimilarityCategoryIDs) != selection.normalizedSelection(Set(model.similarityCategoryIDsForSettings()))
    }

    private var isEnrichmentDirty: Bool {
        let enrichment = model.localDiscoverPreferences.normalized.enrichment
        return draftAutoEnrichOnOpen != enrichment.autoEnrichOnOpen
            || draftAutoEnrichOnSave != enrichment.autoEnrichOnSave
    }

    private var isProcessingDirty: Bool {
        draftDiscoverCodexModel.trimmingCharacters(in: .whitespacesAndNewlines) != model.discoverCodexModelOverride
            || draftDiscoverCodexReasoningEffort != model.discoverCodexReasoningEffort
            || draftDiscoverCodexConcurrency != model.discoverCodexConcurrency
    }

    private var isChatAppearanceDirty: Bool {
        ChatAppearanceDefaults.clampedMessageFontSize(draftChatMessageFontSize) != model.chatMessageFontSize
            || ChatAppearanceDefaults.clampedComposerFontSize(draftChatComposerFontSize) != model.chatComposerFontSize
            || draftChatFontFamily != model.chatFontFamily
    }

    private var isEmbeddingDirty: Bool {
        let embedding = model.localDiscoverPreferences.normalized.embedding
        return draftEmbeddingEnabled != embedding.enabled
            || draftEmbeddingBaseURL.trimmingCharacters(in: .whitespacesAndNewlines) != embedding.baseURL
            || draftEmbeddingModel.trimmingCharacters(in: .whitespacesAndNewlines) != embedding.model
            || !draftEmbeddingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectedExploreRuntimeUsesCodex: Bool {
        model.selectedEnrichmentRuntimeID == "codex"
    }

    private var exploreProcessingModelOverride: String {
        selectedExploreRuntimeUsesCodex
            ? draftDiscoverCodexModel
            : model.agentRuntimeModelOverride(for: model.selectedEnrichmentRuntimeID)
    }

    private var isRefreshingExploreRuntimeModels: Bool {
        selectedExploreRuntimeUsesCodex
            ? model.isRefreshingCodexModels
            : model.isRefreshingAgentRuntimeDiagnostics
    }

    private var exploreProcessingSummary: String {
        if selectedExploreRuntimeUsesCodex {
            return "\(model.discoverCodexConcurrency) workers · Think \(model.discoverCodexReasoningEffort.displayName)"
        }
        let override = model.agentRuntimeModelOverride(for: model.selectedEnrichmentRuntimeID)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if override.isEmpty {
            return "\(model.selectedEnrichmentRuntimeDisplayName) · Default"
        }
        return "\(model.selectedEnrichmentRuntimeDisplayName) · \(override)"
    }

    var body: some View {
        ScrollViewReader { settingsScrollProxy in
            SidebarSplitLayout(minContentWidth: 760) {
                sidebar(settingsScrollProxy: settingsScrollProxy)
            } content: {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        header
                        settingsSectionDivider
                        globalLanguageSettings
                        settingsSectionDivider
                        chatAppearanceSettings
                        settingsSectionDivider
                        arxivFeedSettings
                        settingsSectionDivider
                        localRankingSettings
                        settingsSectionDivider
                        codexEnrichmentSettings
                        settingsSectionDivider
                        codexSystemPromptSettings
                        settingsSectionDivider
                        codexMCPSettings
                        settingsSectionDivider
                        agentRuntimeSettings
                        settingsSectionDivider
                        discoverCodexProcessingSettings
                        settingsSectionDivider
                        embeddingProviderSettings
                        settingsSectionDivider
                        quickPromptSettings
                        settingsSectionDivider
                        storageRules
                        settingsSectionDivider
                        cacheControls
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 28)
                    .frame(maxWidth: 860, alignment: .leading)
                }
                .frame(minWidth: 0)
            }
        }
        .alert("Clear arXiv cache?", isPresented: $isConfirmingClearCache) {
            Button("Clear", role: .destructive) {
                model.clearArxivCaches()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes cached feed JSON, temporary PDFs, and unsaved opened arXiv papers.")
        }
        .sheet(item: $editingPrompt) { prompt in
            quickPromptEditSheet(prompt)
        }
        .sheet(isPresented: $isEditingCodexSystemPrompt) {
            codexSystemPromptEditSheet
        }
        .onAppear {
            syncLocalDrafts()
            model.refreshCacheStorageSummary()
        }
        .onChange(of: model.localDiscoverPreferences) { _, _ in
            syncLocalDrafts()
        }
        .onChange(of: model.categories) { _, _ in
            syncLocalDrafts()
        }
        .onChange(of: model.codexSystemPrompt) { _, newValue in
            draftCodexSystemPrompt = newValue
        }
    }

    private func sidebar(settingsScrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Episteme")
                .font(.paperCodexSystem(size: 24, weight: .semibold))

            PrimaryNavigationSection()

            Divider()

            settingsNavigation(settingsScrollProxy: settingsScrollProxy)

            Spacer(minLength: 0)
        }
        .paperCodexSidebarChromePadding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func settingsNavigation(settingsScrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Settings", systemImage: "gearshape")
                .font(.paperCodexSystem(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(SettingsSectionID.allCases) { section in
                        SettingsNavigationRow(
                            section: section,
                            selected: activeSettingsSection == section
                        ) {
                            activeSettingsSection = section
                            withAnimation(.easeInOut(duration: 0.22)) {
                                settingsScrollProxy.scrollTo(section, anchor: .top)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxHeight: 430, alignment: .top)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.paperCodexSystem(size: 30, weight: .semibold))
            Text("Local arXiv, storage, ranking, and Codex preferences.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var arxivFeedSettings: some View {
        settingsSection(.arxivFeed) {
            TextField("Categories, comma separated", text: $draftArxivCategories)
                .textFieldStyle(.roundedBorder)
            HStack {
                SettingsActionButton(kind: .primary, disabled: !isArxivFeedDirty) {
                    model.setLocalArxivCategories(splitDraftList(draftArxivCategories))
                    Task {
                        await model.refreshArxivDatesAndFeed()
                    }
                } label: {
                    Label(isArxivFeedDirty ? "Save Categories" : "Saved", systemImage: isArxivFeedDirty ? "checkmark" : "checkmark.circle")
                }

                SettingsActionButton(disabled: model.isRefreshingArxivDates) {
                    Task {
                        await model.refreshArxivDatesAndFeed()
                    }
                } label: {
                    Label(model.isRefreshingArxivDates ? "Refreshing" : "Refresh arXiv", systemImage: "arrow.clockwise")
                }

                Spacer()

                Text(model.selectedArxivDate ?? "No cached date")
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var globalLanguageSettings: some View {
        settingsSection(.language) {
            Picker("App language", selection: Binding(
                get: { model.globalLanguageMode },
                set: { model.setGlobalLanguageMode($0) }
            )) {
                ForEach(PaperCodexLanguageMode.allCases) { mode in
                    Text(mode.title(appLanguage: model.globalLanguageMode)).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text("Controls the whole app interface, Explore language, and the default Codex prompt.")
                .font(.paperCodexSystem(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var chatAppearanceSettings: some View {
        settingsSection(.chatAppearance) {
            Picker("Chat font", selection: $draftChatFontFamily) {
                ForEach(ChatFontFamily.allCases) { family in
                    Text(family.title).tag(family)
                }
            }
            .pickerStyle(.segmented)

            Stepper(
                "Message text: \(Int(ChatAppearanceDefaults.clampedMessageFontSize(draftChatMessageFontSize))) pt",
                value: $draftChatMessageFontSize,
                in: ChatAppearanceDefaults.messageFontSizeRange,
                step: 1
            )

            Stepper(
                "Composer text: \(Int(ChatAppearanceDefaults.clampedComposerFontSize(draftChatComposerFontSize))) pt",
                value: $draftChatComposerFontSize,
                in: ChatAppearanceDefaults.composerFontSizeRange,
                step: 1
            )

            ChatAppearancePreview(
                messageFontSize: draftChatMessageFontSize,
                composerFontSize: draftChatComposerFontSize,
                fontFamily: draftChatFontFamily
            )

            HStack {
                SettingsActionButton(kind: .primary, disabled: !isChatAppearanceDirty) {
                    model.setChatAppearance(
                        messageFontSize: draftChatMessageFontSize,
                        composerFontSize: draftChatComposerFontSize,
                        fontFamily: draftChatFontFamily
                    )
                    syncLocalDrafts()
                } label: {
                    Label(isChatAppearanceDirty ? "Save Chat Appearance" : "Saved", systemImage: isChatAppearanceDirty ? "checkmark" : "checkmark.circle")
                }

                SettingsActionButton {
                    model.resetChatAppearance()
                    syncLocalDrafts()
                } label: {
                    Label("Default", systemImage: "arrow.counterclockwise")
                }

                Spacer()

                Text("\(model.chatFontFamily.title) · \(Int(model.chatMessageFontSize))/\(Int(model.chatComposerFontSize)) pt")
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(isChatAppearanceDirty ? .orange : .secondary)
            }
        }
    }

    private var localRankingSettings: some View {
        settingsSection(.localRanking) {
            TextField("Whitelist tags, comma separated", text: $draftWhitelistTags)
                .textFieldStyle(.roundedBorder)
            TextField("Blacklist tags, comma separated", text: $draftBlacklistTags)
                .textFieldStyle(.roundedBorder)
            similarityCategoryTree
            HStack {
                SettingsActionButton(kind: .primary, disabled: !isRankingDirty) {
                    model.setLocalTagFilters(
                        whitelist: splitDraftList(draftWhitelistTags),
                        blacklist: splitDraftList(draftBlacklistTags)
                    )
                    model.setLocalSimilarityCategoryIDs(selectedSimilarityCategoryIDsInOrder)
                } label: {
                    Label(isRankingDirty ? "Save Ranking" : "Saved", systemImage: isRankingDirty ? "line.3.horizontal.decrease.circle" : "checkmark.circle")
                }

                Spacer()

                Text("\(model.localDiscoverPreferences.whitelistTags.count) white · \(model.localDiscoverPreferences.blacklistTags.count) black · \(draftSimilarityCategoryIDs.count)/\(model.categories.count) cats")
                    .font(.paperCodexSystem(size: 13, weight: .medium))
                    .foregroundStyle(isRankingDirty ? .orange : .secondary)
            }
        }
    }

    private var similarityCategoryTree: some View {
        let selection = CategoryHierarchySelection(categories: model.categories)
        let tree = SettingsSimilarityCategoryTreeSnapshot(
            categories: model.categories,
            collapsedCategoryIDs: collapsedSimilarityCategoryIDs
        )
        let rootSelectionState = similarityRootSelectionState(selection)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Similarity categories")
                    .font(.paperCodexSystem(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Text("\(draftSimilarityCategoryIDs.count)/\(model.categories.count) folders")
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 0) {
                Divider()
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: SettingsSimilarityCategoryLayout.rowSpacing) {
                        if model.categories.isEmpty {
                            Text("No library folders")
                                .font(.paperCodexSystem(size: 13, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            SettingsSimilarityRootFolderRow(
                                selectionState: rootSelectionState,
                                selectedCount: selection.normalizedSelection(draftSimilarityCategoryIDs).count,
                                totalCount: model.categories.count
                            ) {
                                toggleAllSimilarityCategories()
                            }

                            ForEach(tree.visibleItems) { item in
                                SettingsSimilarityCategoryRow(
                                    title: item.category.name,
                                    selectionState: selection.selectionState(
                                        for: item.category.id,
                                        selectedIDs: draftSimilarityCategoryIDs
                                    ),
                                    depth: item.depth,
                                    connectorContinuations: item.connectorContinuations,
                                    hasChildren: selection.hasChildren(item.category.id),
                                    isExpanded: !collapsedSimilarityCategoryIDs.contains(item.category.id),
                                    isPinned: item.category.isPinned,
                                    onToggleExpanded: {
                                        toggleSimilarityCategoryCollapsed(item.category.id)
                                    },
                                    onToggleSelected: {
                                        toggleSimilarityCategory(item.category.id)
                                    }
                                )
                            }
                        }
                    }
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 230)
                Divider()
            }
        }
    }

    private func toggleSimilarityCategory(_ categoryID: String) {
        let selection = CategoryHierarchySelection(categories: model.categories)
        draftSimilarityCategoryIDs = selection.toggledSelection(
            categoryID: categoryID,
            selectedIDs: draftSimilarityCategoryIDs
        )
    }

    private func toggleAllSimilarityCategories() {
        let selection = CategoryHierarchySelection(categories: model.categories)
        let selected = selection.normalizedSelection(draftSimilarityCategoryIDs)
        let allCategoryIDs = Set(model.categories.map(\.id))
        if !allCategoryIDs.isEmpty, allCategoryIDs.isSubset(of: selected) {
            draftSimilarityCategoryIDs.removeAll()
        } else {
            draftSimilarityCategoryIDs = selection.normalizedSelection(allCategoryIDs)
        }
    }

    private func toggleSimilarityCategoryCollapsed(_ categoryID: String) {
        if collapsedSimilarityCategoryIDs.contains(categoryID) {
            collapsedSimilarityCategoryIDs.remove(categoryID)
        } else {
            collapsedSimilarityCategoryIDs.insert(categoryID)
        }
    }

    private func setExploreProcessingModelOverride(_ value: String) {
        if selectedExploreRuntimeUsesCodex {
            draftDiscoverCodexModel = value
        } else {
            model.setAgentRuntimeModelOverride(value, for: model.selectedEnrichmentRuntimeID)
        }
    }

    private var codexEnrichmentSettings: some View {
        settingsSection(.codexEnrichment) {
            Toggle("Auto-enrich when opening arXiv papers", isOn: $draftAutoEnrichOnOpen)
                .toggleStyle(.checkbox)
            Toggle("Auto-enrich when saving to Library", isOn: $draftAutoEnrichOnSave)
                .toggleStyle(.checkbox)
            SettingsActionButton(kind: .primary, disabled: !isEnrichmentDirty) {
                model.setLocalEnrichmentPreferences(
                    autoOpen: draftAutoEnrichOnOpen,
                    autoSave: draftAutoEnrichOnSave
                )
            } label: {
                Label(isEnrichmentDirty ? "Save Enrichment" : "Saved", systemImage: isEnrichmentDirty ? "checkmark" : "checkmark.circle")
            }
        }
    }

    private var discoverCodexProcessingSettings: some View {
        settingsSection(.exploreProcessing) {
            RuntimeModelOverrideControl(
                defaultModelID: model.agentRuntimeDefaultModelID(for: model.selectedEnrichmentRuntimeID),
                availableModelIDs: model.availableAgentRuntimeModelIDs(for: model.selectedEnrichmentRuntimeID),
                modelOverride: Binding(
                    get: { exploreProcessingModelOverride },
                    set: { setExploreProcessingModelOverride($0) }
                )
            )

            if selectedExploreRuntimeUsesCodex {
                Picker("Thinking", selection: $draftDiscoverCodexReasoningEffort) {
                    ForEach(CodexReasoningEffort.allCases, id: \.self) { effort in
                        Text(effort.displayName).tag(effort)
                    }
                }
                .pickerStyle(.menu)

                Stepper(
                    "Concurrent Codex processes: \(draftDiscoverCodexConcurrency)",
                    value: $draftDiscoverCodexConcurrency,
                    in: 1...20
                )
            }

            HStack {
                if selectedExploreRuntimeUsesCodex {
                    SettingsActionButton(kind: .primary, disabled: !isProcessingDirty) {
                        model.setDiscoverCodexSettings(
                            modelOverride: draftDiscoverCodexModel,
                            concurrency: draftDiscoverCodexConcurrency,
                            reasoningEffort: draftDiscoverCodexReasoningEffort
                        )
                    } label: {
                        Label(isProcessingDirty ? "Save Processing" : "Saved", systemImage: isProcessingDirty ? "checkmark" : "checkmark.circle")
                    }
                }

                SettingsActionButton(disabled: isRefreshingExploreRuntimeModels) {
                    Task {
                        if selectedExploreRuntimeUsesCodex {
                            await model.refreshAvailableCodexModels()
                        } else {
                            await model.refreshAgentRuntimeDiagnostics()
                        }
                    }
                } label: {
                    Label(isRefreshingExploreRuntimeModels ? "Refreshing" : "Refresh Models", systemImage: "arrow.clockwise")
                }

                Spacer()

                Text(exploreProcessingSummary)
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var codexSystemPromptSettings: some View {
        settingsSection(.codexSystemPrompt) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Template")
                            .font(.paperCodexSystem(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("Workspace placeholder: \(PromptBuilder.workspacePathPlaceholder)")
                            .font(.paperCodexSystem(size: 13.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("\(model.codexSystemPrompt.count) characters")
                        .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack {
                    SettingsActionButton(kind: .primary) {
                        draftCodexSystemPrompt = model.codexSystemPrompt
                        isEditingCodexSystemPrompt = true
                    } label: {
                        Label("Edit Prompt", systemImage: "pencil")
                    }
                    .help("Edit System Prompt")

                    SettingsActionButton {
                        model.resetCodexSystemPrompt()
                        draftCodexSystemPrompt = model.codexSystemPrompt
                    } label: {
                        Label("Default", systemImage: "arrow.counterclockwise")
                    }
                    .help("Restore Default System Prompt")

                    Spacer()

                    Text(PromptBuilder.isBuiltInSystemPrompt(model.codexSystemPrompt) ? "Default" : "Custom")
                        .font(.paperCodexSystem(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var codexMCPSettings: some View {
        settingsSection(.codexMCP) {
            Toggle(
                "Enable for in-app Codex",
                isOn: Binding(
                    get: { model.inAppCodexMCPEnabled },
                    set: { model.setInAppCodexMCPEnabled($0) }
                )
            )
            .toggleStyle(.checkbox)

            HStack {
                Text(model.inAppCodexMCPStatusText)
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex Plugin")
                        .font(.paperCodexSystem(size: 13.5, weight: .semibold))
                    Text(model.codexPluginInstallationStatus?.detail ?? "Not checked")
                        .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle((model.codexPluginInstallationStatus?.current ?? false) ? .green : .secondary)
                }

                Spacer()

                SettingsActionButton(disabled: model.isInstallingCodexPlugin || !model.paperCodexMCPServerReady) {
                    Task {
                        await model.installOrUpdateCodexPlugin()
                    }
                } label: {
                    Label(model.isInstallingCodexPlugin ? "Installing" : "Install / Update", systemImage: "puzzlepiece.extension")
                }
                .help("Install or update the Episteme plugin in local Codex")
            }
        }
    }

    private var agentRuntimeSettings: some View {
        settingsSection(.agentRuntimes) {
            HStack(spacing: 12) {
                Picker("Chat", selection: Binding(
                    get: { model.selectedChatRuntimeID },
                    set: { model.setSelectedChatRuntimeID($0) }
                )) {
                    ForEach(model.agentRuntimeProfiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)

                Picker("Explore", selection: Binding(
                    get: { model.selectedEnrichmentRuntimeID },
                    set: { model.setSelectedEnrichmentRuntimeID($0) }
                )) {
                    ForEach(model.agentRuntimeProfiles) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                SettingsActionButton(disabled: model.isRefreshingAgentRuntimeDiagnostics) {
                    Task {
                        await model.refreshAgentRuntimeDiagnostics()
                    }
                } label: {
                    Label(model.isRefreshingAgentRuntimeDiagnostics ? "Checking" : "Check Runtimes", systemImage: "arrow.clockwise")
                }
            }

            if let warning = model.agentRuntimeProfileLoadWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(warning)
                        .font(.paperCodexSystem(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .help(model.agentRuntimeProfileConfigPath)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.agentRuntimeProfiles) { profile in
                    agentRuntimeRow(profile)
                    if profile.id != model.agentRuntimeProfiles.last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func agentRuntimeRow(_ profile: AgentRuntimeProfile) -> some View {
        let diagnostic = model.agentRuntimeDiagnostic(for: profile.id)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Toggle(
                    profile.displayName,
                    isOn: Binding(
                        get: { model.isAgentRuntimeEnabled(profile.id) },
                        set: { model.setAgentRuntimeEnabled(profile.id, enabled: $0) }
                    )
                )
                .toggleStyle(.checkbox)
                .font(.paperCodexSystem(size: 13, weight: .semibold))

                Text(diagnostic?.title ?? "Not checked")
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(diagnostic?.state.settingsColor ?? .secondary)

                Spacer()

                Text(profile.executableName)
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if let path = diagnostic?.executablePath {
                    Text(path)
                        .font(.paperCodexSystem(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(diagnostic?.detail ?? "Executable has not been checked yet.")
                        .font(.paperCodexSystem(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Text(model.agentRuntimeAuthSummary(for: profile.id))
                    .font(.paperCodexSystem(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            HStack(spacing: 10) {
                if profile.backend == .hermes || profile.backend == .pi {
                    TextField("Provider", text: Binding(
                        get: { model.agentRuntimeProviderOverride(for: profile.id) },
                        set: { model.setAgentRuntimeProviderOverride($0, for: profile.id) }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
                }

                RuntimeModelOverrideControl(
                    defaultModelID: model.agentRuntimeDefaultModelID(for: profile.id),
                    availableModelIDs: model.availableAgentRuntimeModelIDs(for: profile.id),
                    modelOverride: Binding(
                        get: { model.agentRuntimeModelOverride(for: profile.id) },
                        set: { model.setAgentRuntimeModelOverride($0, for: profile.id) }
                    )
                )

                Picker("MCP", selection: Binding(
                    get: { model.agentRuntimeMCPMode(for: profile.id) },
                    set: { model.setAgentRuntimeMCPMode($0, for: profile.id) }
                )) {
                    ForEach(AgentRuntimeMCPMode.allCases, id: \.self) { mode in
                        Text(mode.settingsTitle).tag(mode)
                    }
                }
                .pickerStyle(.menu)

                Spacer()

                Text(profile.capabilitySummary)
                    .font(.paperCodexSystem(size: 13.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }

    private var embeddingProviderSettings: some View {
        settingsSection(.embeddingProvider) {
            Toggle("Enable embedding similarity", isOn: $draftEmbeddingEnabled)
                .toggleStyle(.checkbox)
            TextField("Base URL", text: $draftEmbeddingBaseURL)
                .textFieldStyle(.roundedBorder)
            SecureField("API key (leave blank to keep saved)", text: $draftEmbeddingAPIKey)
                .textFieldStyle(.roundedBorder)
            TextField("Model", text: $draftEmbeddingModel)
                .textFieldStyle(.roundedBorder)
            HStack {
                SettingsActionButton(kind: .primary, disabled: !isEmbeddingDirty) {
                    model.setEmbeddingProviderSettings(
                        enabled: draftEmbeddingEnabled,
                        baseURL: draftEmbeddingBaseURL,
                        apiKey: draftEmbeddingAPIKey,
                        model: draftEmbeddingModel
                    )
                } label: {
                    Label(isEmbeddingDirty ? "Save Embedding" : "Saved", systemImage: isEmbeddingDirty ? "key" : "checkmark.circle")
                }

                SettingsActionButton(disabled: model.isTestingEmbeddingProvider) {
                    Task {
                        await model.testEmbeddingProvider(
                            baseURL: draftEmbeddingBaseURL,
                            apiKey: draftEmbeddingAPIKey,
                            model: draftEmbeddingModel
                        )
                    }
                } label: {
                    Label(model.isTestingEmbeddingProvider ? "Testing" : "Test", systemImage: "bolt.horizontal.circle")
                }

                Spacer()

                Text(model.embeddingProviderTestStatus ?? (model.localDiscoverPreferences.embedding.enabled ? "Enabled" : "Disabled"))
                    .font(.paperCodexSystem(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var quickPromptSettings: some View {
        settingsSection(.quickPrompts) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(model.quickPrompts) { prompt in
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prompt.title)
                                .font(.paperCodexSystem(size: 13.5, weight: .semibold))
                            Text(prompt.content)
                                .font(.paperCodexSystem(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        Spacer()
                        PaperCodexIconButton(title: "Move Up", systemImage: "chevron.up") {
                            model.moveQuickPrompt(prompt, direction: -1)
                        }
                        PaperCodexIconButton(title: "Move Down", systemImage: "chevron.down") {
                            model.moveQuickPrompt(prompt, direction: 1)
                        }
                        PaperCodexIconButton(title: "Edit Prompt", systemImage: "pencil") {
                            editingPromptTitle = prompt.title
                            editingPromptContent = prompt.content
                            editingPrompt = prompt
                        }
                        PaperCodexIconButton(title: "Delete Prompt", systemImage: "trash", tint: .red) {
                            model.deleteQuickPrompt(prompt)
                        }
                    }
                    .padding(.vertical, 7)

                    if prompt.id != model.quickPrompts.last?.id {
                        Divider()
                    }
                }

                TextField("Prompt title", text: $newPromptTitle)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $newPromptContent)
                    .font(.paperCodexSystem(size: 13))
                    .frame(minHeight: 78)
                    .scrollContentBackground(.hidden)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("New quick prompt editor")
                    .accessibilityValue("\(newPromptContent.count) characters")
                SettingsActionButton(disabled: newPromptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || newPromptContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    model.addQuickPrompt(title: newPromptTitle, content: newPromptContent)
                    if model.errorMessage == nil {
                        newPromptTitle = ""
                        newPromptContent = ""
                    }
                } label: {
                    Label("Add Prompt", systemImage: "plus")
                }
            }
        }
    }

    private var storageRules: some View {
        settingsSection(.savedPaperOrganization) {
            Picker("Folder rule", selection: Binding(
                get: { model.arxivSaveOrganization },
                set: { model.setArxivSaveOrganization($0) }
            )) {
                ForEach(ArxivSaveOrganization.allCases) { option in
                    Text(LocalizedStringKey(option.title)).tag(option)
                }
            }
            .pickerStyle(.radioGroup)

            pathRow(label: "Library root", value: model.paperLibraryRootPath)
        }
    }

    private var cacheControls: some View {
        settingsSection(.disposableCache) {
            pathRow(label: "Cache root", value: model.arxivDisposableCachePath)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.cacheStorageSummary.detailText)
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text("arXiv \(CacheStorageSummary.formatBytes(model.cacheStorageSummary.arxivCacheBytes)) · thumbnails \(CacheStorageSummary.formatBytes(model.cacheStorageSummary.thumbnailBytes))")
                    .font(.paperCodexSystem(size: 13.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            HStack {
                SettingsActionButton(kind: .destructive, role: .destructive) {
                    isConfirmingClearCache = true
                } label: {
                    Label("Clear arXiv Cache", systemImage: "trash")
                }

                SettingsActionButton {
                    model.refreshCacheStorageSummary()
                } label: {
                    Label("Refresh Size", systemImage: "arrow.clockwise")
                }

                Text("Clears feed JSON, temporary PDFs, and unsaved opened papers.")
                    .font(.paperCodexSystem(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var settingsSectionDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.10))
            .frame(height: 1)
    }

    private func settingsSection<Content: View>(
        _ section: SettingsSectionID,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Label {
                Text(LocalizedStringKey(section.title))
            } icon: {
                Image(systemName: section.systemImage)
            }
            .font(.paperCodexSystem(size: 15, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 176, alignment: .leading)
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 11) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(section)
    }

    private var codexSystemPromptEditSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Edit System Prompt", systemImage: "text.quote")
                .font(.title3.weight(.semibold))
            Text("Workspace placeholder: \(PromptBuilder.workspacePathPlaceholder)")
                .font(.paperCodexSystem(size: 13.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
            TextEditor(text: $draftCodexSystemPrompt)
                .font(.paperCodexSystem(size: 13, design: .monospaced))
                .frame(minHeight: 320)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("System prompt template editor")
                .accessibilityValue("\(draftCodexSystemPrompt.count) characters")
            HStack {
                Text("\(draftCodexSystemPrompt.count) characters")
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                SettingsActionButton {
                    draftCodexSystemPrompt = model.codexSystemPrompt
                    isEditingCodexSystemPrompt = false
                } label: {
                    Text("Cancel")
                }
                SettingsActionButton {
                    model.resetCodexSystemPrompt()
                    draftCodexSystemPrompt = model.codexSystemPrompt
                    isEditingCodexSystemPrompt = false
                } label: {
                    Label("Default", systemImage: "arrow.counterclockwise")
                }
                SettingsActionButton(kind: .primary, disabled: draftCodexSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    model.setCodexSystemPrompt(draftCodexSystemPrompt)
                    isEditingCodexSystemPrompt = false
                } label: {
                    Label("Save", systemImage: "checkmark")
                }
            }
        }
        .padding(22)
        .frame(width: 720, height: 520)
    }

    private func quickPromptEditSheet(_ prompt: QuickPrompt) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Edit Quick Prompt", systemImage: "pencil")
                .font(.title3.weight(.semibold))
            TextField("Prompt title", text: $editingPromptTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $editingPromptContent)
                .font(.paperCodexSystem(size: 13))
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Quick prompt editor")
                .accessibilityValue("\(editingPromptContent.count) characters")
            HStack {
                Spacer()
                SettingsActionButton {
                    editingPrompt = nil
                } label: {
                    Text("Cancel")
                }
                SettingsActionButton(kind: .primary, disabled: editingPromptTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || editingPromptContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    model.updateQuickPrompt(prompt, title: editingPromptTitle, content: editingPromptContent)
                    editingPrompt = nil
                } label: {
                    Text("Save")
                }
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private func pathRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(label))
                .font(.paperCodexSystem(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                Text(value)
                    .font(.paperCodexSystem(size: 13))
                    .textSelection(.enabled)
                    .lineLimit(2)
                Spacer()
                PaperCodexIconButton(title: "Reveal in Finder", systemImage: "folder") {
                    model.revealPath(value)
                }
            }
        }
    }

    private func syncLocalDrafts() {
        let preferences = model.localDiscoverPreferences.normalized
        draftArxivCategories = preferences.categories.joined(separator: ", ")
        draftWhitelistTags = preferences.whitelistTags.joined(separator: ", ")
        draftBlacklistTags = preferences.blacklistTags.joined(separator: ", ")
        let selection = CategoryHierarchySelection(categories: model.categories)
        draftSimilarityCategoryIDs = selection.normalizedSelection(Set(model.similarityCategoryIDsForSettings()))
        collapsedSimilarityCategoryIDs.formIntersection(Set(model.categories.map(\.id)))
        initializeDefaultSimilarityCategoryCollapseIfNeeded(selection)
        draftAutoEnrichOnOpen = preferences.enrichment.autoEnrichOnOpen
        draftAutoEnrichOnSave = preferences.enrichment.autoEnrichOnSave
        draftCodexSystemPrompt = model.codexSystemPrompt
        draftDiscoverCodexModel = model.discoverCodexModelOverride
        draftDiscoverCodexReasoningEffort = model.discoverCodexReasoningEffort
        draftDiscoverCodexConcurrency = model.discoverCodexConcurrency
        draftChatMessageFontSize = model.chatMessageFontSize
        draftChatComposerFontSize = model.chatComposerFontSize
        draftChatFontFamily = model.chatFontFamily
        draftEmbeddingEnabled = preferences.embedding.enabled
        draftEmbeddingBaseURL = preferences.embedding.baseURL
        draftEmbeddingModel = preferences.embedding.model
        draftEmbeddingAPIKey = ""
    }

    private func splitDraftList(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var selectedSimilarityCategoryIDsInOrder: [String] {
        CategoryHierarchySelection(categories: model.categories)
            .orderedSelectedIDs(draftSimilarityCategoryIDs)
    }

    private func similarityRootSelectionState(
        _ selection: CategoryHierarchySelection
    ) -> CategoryHierarchySelectionState {
        let allCategoryIDs = Set(model.categories.map(\.id))
        guard !allCategoryIDs.isEmpty else {
            return .none
        }
        let selected = selection.normalizedSelection(draftSimilarityCategoryIDs)
        if allCategoryIDs.isSubset(of: selected) {
            return .all
        }
        return selected.isDisjoint(with: allCategoryIDs) ? .none : .partial
    }

    private func initializeDefaultSimilarityCategoryCollapseIfNeeded(
        _ selection: CategoryHierarchySelection
    ) {
        guard !hasInitializedSimilarityCategoryCollapse, !model.categories.isEmpty else {
            return
        }
        collapsedSimilarityCategoryIDs = selection.defaultCollapsedRootCategoryIDs()
        hasInitializedSimilarityCategoryCollapse = true
    }

}

private enum SettingsActionButtonKind {
    case primary
    case secondary
    case destructive

    var tint: Color {
        switch self {
        case .primary:
            Color.accentColor
        case .secondary:
            Color.secondary
        case .destructive:
            Color.red
        }
    }
}

private struct ChatAppearancePreview: View {
    var messageFontSize: Double
    var composerFontSize: Double
    var fontFamily: ChatFontFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.paperCodexSystem(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .foregroundStyle(Color.accentColor)
                    .background(Color.accentColor.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 5) {
                    Text("Agent response preview")
                        .font(fontFamily.swiftUIFont(size: max(11, messageFontSize - 4), weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Formula messages, citations, lists, and code blocks follow this reading size.")
                        .font(fontFamily.swiftUIFont(size: messageFontSize))
                        .lineSpacing(2)
                        .foregroundStyle(.primary.opacity(0.90))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
            )

            Text("Composer text preview")
                .font(fontFamily.swiftUIFont(size: composerFontSize))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        }
    }
}

private struct SettingsNavigationRow: View {
    @State private var isHovering = false

    var section: SettingsSectionID
    var selected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: section.systemImage)
                    .font(.paperCodexSystem(size: 12, weight: .semibold))
                    .frame(width: 16)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                Text(section.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.paperCodexSystem(size: 12.5, weight: selected ? .semibold : .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SettingsNavigationRowButtonStyle(selected: selected, isHovering: isHovering))
        .onHover { hovering in
            withAnimation(PaperCodexMotion.hover) {
                isHovering = hovering
            }
        }
    }
}

private struct SettingsNavigationRowButtonStyle: ButtonStyle {
    var selected: Bool
    var isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        configuration.label
            .foregroundStyle(labelColor(isPressed: isPressed))
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isPressed: isPressed))
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Color.accentColor.opacity(0.72))
                        .frame(width: 3, height: 16)
                        .padding(.leading, 3)
                }
            }
            .scaleEffect(isPressed ? 0.985 : 1, anchor: .center)
            .animation(PaperCodexMotion.press, value: configuration.isPressed)
            .animation(PaperCodexMotion.hover, value: isHovering)
            .animation(PaperCodexMotion.selection, value: selected)
    }

    private func labelColor(isPressed: Bool) -> Color {
        if selected || isPressed || isHovering {
            return Color.primary.opacity(0.92)
        }
        return Color.primary.opacity(0.82)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(0.16)
        }
        if selected {
            return Color.accentColor.opacity(0.10)
        }
        return isHovering ? Color.primary.opacity(0.045) : Color.clear
    }
}

private enum SettingsSimilarityCategoryLayout {
    static let rowSpacing: CGFloat = 0
    static let treeConnectorHeight: CGFloat = 32
    static let treeIndentWidth: CGFloat = 22
    static let rowHorizontalPadding: CGFloat = 8
    static let rowContentSpacing: CGFloat = 7
    static let disclosureColumnWidth: CGFloat = 16
    static let selectionIndicatorWidth: CGFloat = 18
    static let folderContentSpacing: CGFloat = 8
    static let folderIconWidth: CGFloat = 17
    static let connectorTargetInset: CGFloat = 7
    static let connectorLineWidth: CGFloat = 1
    static let connectorOpacity = 0.24

    static var folderIconCenterX: CGFloat {
        rowHorizontalPadding + disclosureColumnWidth + rowContentSpacing + selectionIndicatorWidth + folderContentSpacing + folderIconWidth / 2
    }

    static func folderIconCenterX(depth: Int) -> CGFloat {
        folderIconCenterX + CGFloat(depth) * treeIndentWidth
    }
}

private extension CategoryHierarchySelectionState {
    var isActive: Bool {
        self != .none
    }

    var isComplete: Bool {
        self == .all
    }

    var indicatorSystemImage: String {
        switch self {
        case .all:
            "checkmark.circle.fill"
        case .partial:
            "minus.circle.fill"
        case .none:
            "circle"
        }
    }

    var indicatorTint: Color {
        switch self {
        case .all:
            Color.accentColor
        case .partial:
            Color.accentColor.opacity(0.72)
        case .none:
            Color.secondary.opacity(0.62)
        }
    }
}

private struct SettingsSimilarityRootFolderRow: View {
    @State private var isHovering = false

    var selectionState: CategoryHierarchySelectionState
    var selectedCount: Int
    var totalCount: Int
    var onToggleSelected: () -> Void

    var body: some View {
        Button(action: onToggleSelected) {
            HStack(spacing: 8) {
                Image(systemName: selectionState.indicatorSystemImage)
                    .font(.paperCodexSystem(size: 13, weight: .semibold))
                    .frame(width: 18)
                    .foregroundStyle(selectionState.indicatorTint)
                Image(systemName: selectionState.isComplete ? "tray.full.fill" : "tray.full")
                    .font(.paperCodexSystem(size: 13, weight: .medium))
                    .frame(width: 19)
                    .foregroundStyle(selectionState.isActive ? Color.accentColor.opacity(0.9) : Color.secondary)
                Text("All Folders")
                    .font(.paperCodexSystem(size: 13, weight: selectionState.isActive ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(countText)
                    .font(.paperCodexSystem(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.045) : Color.clear)
        )
        .animation(PaperCodexMotion.hover, value: isHovering)
        .animation(PaperCodexMotion.selection, value: selectionState)
        .onHover { hovering in
            withAnimation(PaperCodexMotion.hover) {
                isHovering = hovering
            }
        }
        .help(selectionState.isComplete ? "Deselect all library folders" : "Select all library folders")
    }

    private var countText: String {
        selectionState.isComplete ? "\(totalCount)" : "\(selectedCount)/\(totalCount)"
    }
}

private struct SettingsSimilarityCategoryRow: View {
    @State private var isHovering = false

    var title: String
    var selectionState: CategoryHierarchySelectionState
    var depth: Int
    var connectorContinuations: [Bool]
    var hasChildren: Bool
    var isExpanded: Bool
    var isPinned: Bool
    var onToggleExpanded: () -> Void
    var onToggleSelected: () -> Void

    var body: some View {
        HStack(spacing: SettingsSimilarityCategoryLayout.rowContentSpacing) {
            Group {
                if hasChildren {
                    Button(action: onToggleExpanded) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.paperCodexSystem(size: 11, weight: .semibold))
                            .frame(width: SettingsSimilarityCategoryLayout.disclosureColumnWidth, height: 24)
                            .foregroundStyle(Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(folderIconHelp)
                } else {
                    Color.clear
                        .frame(width: SettingsSimilarityCategoryLayout.disclosureColumnWidth, height: 22)
                }
            }

            Button(action: onToggleSelected) {
                HStack(spacing: SettingsSimilarityCategoryLayout.folderContentSpacing) {
                    Image(systemName: selectionState.indicatorSystemImage)
                        .font(.paperCodexSystem(size: 13, weight: .semibold))
                        .frame(width: SettingsSimilarityCategoryLayout.selectionIndicatorWidth)
                        .foregroundStyle(selectionState.indicatorTint)

                    Image(systemName: folderIconName)
                        .font(.paperCodexSystem(size: 13, weight: .medium))
                        .frame(width: SettingsSimilarityCategoryLayout.folderIconWidth)
                        .foregroundStyle(selectionState.isActive || isExpanded ? Color.accentColor.opacity(0.9) : Color.secondary)

                    Text(title)
                        .font(.paperCodexSystem(size: 13, weight: selectionState.isActive ? .semibold : .medium))
                        .foregroundStyle(selectionState.isActive ? Color.primary : Color.primary.opacity(0.82))
                        .lineLimit(1)

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.paperCodexSystem(size: 12.5, weight: .medium))
                            .foregroundStyle(Color.accentColor.opacity(0.72))
                    }

                    Spacer(minLength: 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(title)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SettingsSimilarityCategoryLayout.rowHorizontalPadding)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovering ? Color.primary.opacity(0.045) : Color.clear)
        )
        .padding(.leading, CGFloat(depth) * SettingsSimilarityCategoryLayout.treeIndentWidth)
        .frame(minHeight: SettingsSimilarityCategoryLayout.treeConnectorHeight)
        .background(alignment: .leading) {
            SettingsSimilarityCategoryTreeConnector(
                depth: depth,
                connectorContinuations: connectorContinuations
            )
            .allowsHitTesting(false)
        }
        .animation(PaperCodexMotion.hover, value: isHovering)
        .animation(PaperCodexMotion.selection, value: selectionState)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggleSelected)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var folderIconName: String {
        hasChildren ? (isExpanded ? "folder.fill" : "folder") : "folder"
    }

    private var folderIconHelp: String {
        isExpanded ? "Collapse \(title)" : "Expand \(title)"
    }
}

private struct SettingsSimilarityCategoryTreeConnector: View {
    var depth: Int
    var connectorContinuations: [Bool]

    var body: some View {
        if depth == 0 || connectorContinuations.isEmpty {
            Color.clear
                .frame(height: SettingsSimilarityCategoryLayout.treeConnectorHeight)
        } else {
            SettingsSimilarityCategoryTreeConnectorLevel(
                depth: depth,
                connectorContinuations: connectorContinuations
            )
            .stroke(
                Color.primary.opacity(SettingsSimilarityCategoryLayout.connectorOpacity),
                style: StrokeStyle(
                    lineWidth: SettingsSimilarityCategoryLayout.connectorLineWidth,
                    lineCap: .butt,
                    lineJoin: .round
                )
            )
            .frame(
                width: SettingsSimilarityCategoryLayout.folderIconCenterX(depth: depth) + 1,
                height: SettingsSimilarityCategoryLayout.treeConnectorHeight
            )
        }
    }
}

private struct SettingsSimilarityCategoryTreeConnectorLevel: Shape {
    var depth: Int
    var connectorContinuations: [Bool]

    func path(in rect: CGRect) -> Path {
        Path { path in
            let midY = rect.midY
            let currentIconX = SettingsSimilarityCategoryLayout.folderIconCenterX(depth: depth)
            let currentTargetX = currentIconX - SettingsSimilarityCategoryLayout.connectorTargetInset
            let parentIconX = SettingsSimilarityCategoryLayout.folderIconCenterX(depth: depth - 1)
            let currentBranchContinues = connectorContinuations.indices.contains(depth - 1)
                ? connectorContinuations[depth - 1]
                : false

            if depth > 1 {
                for level in 0..<(depth - 1) where connectorContinuations.indices.contains(level) && connectorContinuations[level] {
                    let ancestorIconX = SettingsSimilarityCategoryLayout.folderIconCenterX(depth: level)
                    path.move(to: CGPoint(x: ancestorIconX, y: rect.minY))
                    path.addLine(to: CGPoint(x: ancestorIconX, y: rect.maxY))
                }
            }

            path.move(to: CGPoint(x: parentIconX, y: rect.minY))
            path.addLine(to: CGPoint(x: parentIconX, y: currentBranchContinues ? rect.maxY : midY))
            path.move(to: CGPoint(x: parentIconX, y: midY))
            path.addLine(to: CGPoint(x: currentTargetX, y: midY))
        }
    }
}

private struct SettingsSimilarityCategoryTreeSnapshot {
    var visibleItems: [SettingsSimilarityCategoryItem]

    private var childrenByParentID: [String: [PaperCodexCore.Category]]

    init(categories: [PaperCodexCore.Category], collapsedCategoryIDs: Set<String>) {
        var rootCategories: [PaperCodexCore.Category] = []
        var childrenByParentID: [String: [PaperCodexCore.Category]] = [:]

        for category in categories {
            if let parentID = category.parentID {
                childrenByParentID[parentID, default: []].append(category)
            } else {
                rootCategories.append(category)
            }
        }

        rootCategories.sort(by: Self.sortCategories)
        for parentID in Array(childrenByParentID.keys) {
            childrenByParentID[parentID, default: []].sort(by: Self.sortCategories)
        }

        self.childrenByParentID = childrenByParentID
        self.visibleItems = Self.visibleItems(
            categories: rootCategories,
            childrenByParentID: childrenByParentID,
            collapsedCategoryIDs: collapsedCategoryIDs,
            depth: 0,
            ancestorContinuations: []
        )
    }

    func hasChildren(_ categoryID: String) -> Bool {
        childrenByParentID[categoryID]?.isEmpty == false
    }

    private static func visibleItems(
        categories: [PaperCodexCore.Category],
        childrenByParentID: [String: [PaperCodexCore.Category]],
        collapsedCategoryIDs: Set<String>,
        depth: Int,
        ancestorContinuations: [Bool]
    ) -> [SettingsSimilarityCategoryItem] {
        categories.enumerated().flatMap { index, category in
            let isLast = index == categories.count - 1
            let connectorContinuations = depth == 0 ? [] : ancestorContinuations + [!isLast]
            let item = SettingsSimilarityCategoryItem(
                category: category,
                depth: depth,
                connectorContinuations: connectorContinuations
            )
            guard !collapsedCategoryIDs.contains(category.id) else {
                return [item]
            }
            return [item] + visibleItems(
                categories: childrenByParentID[category.id, default: []],
                childrenByParentID: childrenByParentID,
                collapsedCategoryIDs: collapsedCategoryIDs,
                depth: depth + 1,
                ancestorContinuations: connectorContinuations
            )
        }
    }

    private static func sortCategories(_ left: PaperCodexCore.Category, _ right: PaperCodexCore.Category) -> Bool {
        if left.isPinned != right.isPinned {
            return left.isPinned && !right.isPinned
        }
        if left.sortOrder != right.sortOrder {
            return left.sortOrder < right.sortOrder
        }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
}

private struct SettingsSimilarityCategoryItem: Identifiable {
    var category: PaperCodexCore.Category
    var depth: Int
    var connectorContinuations: [Bool]

    var id: String { category.id }
}

private struct RuntimeModelOverrideControl: View {
    var defaultModelID: String
    var availableModelIDs: [String]
    @Binding var modelOverride: String

    var body: some View {
        HStack(spacing: 8) {
            if showsModelPicker {
                Picker("Model", selection: $modelOverride) {
                    Text(defaultModelLabel).tag("")
                    ForEach(availableModelIDs, id: \.self) { modelID in
                        Text(modelID).tag(modelID)
                    }
                    if !trimmedOverride.isEmpty,
                       !availableModelIDs.contains(trimmedOverride) {
                        Text("\(trimmedOverride) (custom)").tag(trimmedOverride)
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 190)
            }

            TextField(textFieldPlaceholder, text: $modelOverride)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: showsModelPicker ? 180 : 220)
        }
    }

    private var showsModelPicker: Bool {
        !availableModelIDs.isEmpty || !trimmedDefaultModelID.isEmpty || !trimmedOverride.isEmpty
    }

    private var textFieldPlaceholder: String {
        if availableModelIDs.isEmpty, !trimmedDefaultModelID.isEmpty {
            return trimmedDefaultModelID
        }
        return "Custom model"
    }

    private var defaultModelLabel: String {
        trimmedDefaultModelID.isEmpty ? "Default" : "Default (\(trimmedDefaultModelID))"
    }

    private var trimmedDefaultModelID: String {
        defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedOverride: String {
        modelOverride.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct SettingsActionButton<Label: View>: View {
    @State private var isHovering = false

    var kind: SettingsActionButtonKind = .secondary
    var disabled = false
    var role: ButtonRole?
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    var body: some View {
        Button(role: role, action: action) {
            label()
        }
        .buttonStyle(SettingsActionButtonStyle(kind: kind, disabled: disabled, isHovering: isHovering))
        .disabled(disabled)
        .onHover { hovering in
            withAnimation(PaperCodexMotion.hover) {
                isHovering = hovering
            }
        }
    }
}

private struct SettingsActionButtonStyle: ButtonStyle {
    var kind: SettingsActionButtonKind
    var disabled: Bool
    var isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && !disabled
        configuration.label
            .font(.paperCodexSystem(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(foregroundColor(isPressed: isPressed))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor(isPressed: isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor(isPressed: isPressed), lineWidth: 1)
            )
            .shadow(color: shadowColor(isPressed: isPressed), radius: isPressed ? 3 : 7, y: isPressed ? 1 : 3)
            .scaleEffect(buttonScale(isPressed: isPressed), anchor: .center)
            .animation(PaperCodexMotion.press, value: configuration.isPressed)
            .animation(PaperCodexMotion.hover, value: isHovering)
            .animation(PaperCodexMotion.hover, value: disabled)
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        if disabled {
            return Color.secondary.opacity(0.48)
        }
        switch kind {
        case .primary:
            return .white
        case .secondary, .destructive:
            return isPressed || isHovering ? kind.tint : Color.primary.opacity(0.82)
        }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if disabled {
            return Color(nsColor: .controlBackgroundColor).opacity(0.56)
        }
        switch kind {
        case .primary:
            return Color.accentColor.opacity(isPressed ? 0.82 : (isHovering ? 0.96 : 0.90))
        case .secondary, .destructive:
            if isPressed {
                return kind.tint.opacity(0.18)
            }
            return isHovering ? kind.tint.opacity(0.12) : Color(nsColor: .controlBackgroundColor)
        }
    }

    private func borderColor(isPressed: Bool) -> Color {
        if disabled {
            return Color.black.opacity(0.06)
        }
        switch kind {
        case .primary:
            return Color.accentColor.opacity(isPressed ? 0.62 : (isHovering ? 0.48 : 0.34))
        case .secondary, .destructive:
            if isPressed {
                return kind.tint.opacity(0.54)
            }
            return isHovering ? kind.tint.opacity(0.38) : Color.black.opacity(0.10)
        }
    }

    private func shadowColor(isPressed: Bool) -> Color {
        if disabled {
            return .clear
        }
        return kind.tint.opacity(isPressed ? 0.10 : (isHovering ? 0.16 : 0))
    }

    private func buttonScale(isPressed: Bool) -> CGFloat {
        if disabled {
            return 1
        }
        return isPressed ? 0.97 : (isHovering ? 1.02 : 1)
    }
}

private extension AgentRuntimeMCPMode {
    var settingsTitle: String {
        switch self {
        case .codexConfigOverrides:
            "Codex config"
        case .mcpConfigFile:
            "MCP file"
        case .acpSession:
            "ACP session"
        case .configuredExternally:
            "External"
        case .workspaceOnly:
            "Workspace"
        }
    }
}

private extension AgentRuntimeDiagnosticState {
    var settingsColor: Color {
        switch self {
        case .checking:
            .secondary
        case .ready:
            .green
        case .warning:
            .orange
        case .blocked:
            .red
        }
    }
}

private extension AgentRuntimeProfile {
    var capabilitySummary: String {
        var parts: [String] = []
        if supportsNonInteractiveRuns {
            parts.append("chat")
        }
        if supportsPTY {
            parts.append("tui")
        }
        if supportsStructuredOutput {
            parts.append("json")
        }
        if supportsMCPConfig {
            parts.append("mcp")
        }
        return parts.joined(separator: " · ")
    }
}
