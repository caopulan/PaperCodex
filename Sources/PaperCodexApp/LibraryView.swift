import PaperCodexCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isShowingWatchedFolders = false
    @State private var isShowingArxivImport = false
    @State private var isCreatingCategory = false
    @State private var isCreatingTag = false
    @State private var newCategoryName = ""
    @State private var newCategoryParentID = ""
    @State private var newTagName = ""
    @State private var selectedPaperIDs: Set<String> = []
    @State private var lastSelectedPaperID: String?
    @State private var lastPaperRowClick: LibraryPaperRowClick?
    @FocusState private var isPaperListFocused: Bool
    @State private var isShowingBulkCopy = false
    @State private var isShowingBulkTag = false
    @State private var isConfirmingBulkDelete = false
    @State private var collapsedCategoryIDs: Set<String> = []
    @State private var categoryPendingManagement: PaperCodexCore.Category?
    @State private var categoryPendingDelete: PaperCodexCore.Category?
    @State private var tagPendingManagement: PaperTag?
    @State private var tagPendingDelete: PaperTag?
    @State private var draggedCategoryID: String?
    @State private var liveCategoryDropKey: String?
    @State private var categoryDragPreviewCategories: [PaperCodexCore.Category]?
    @State private var categoryDragCommitTarget: CategoryDragDropTarget?
    @State private var categoryDragResetToken: UUID?
    @State private var watchedFolderPendingRemoval: WatchedFolder?
    @State private var noteTitle = ""
    @State private var noteBody = ""
    @State private var editingNoteID: String?
    @State private var selectedRecentSessionID: String?
    @State private var selectedPaperRevealRequestID: UUID?
    @State private var inspectorDetailsPaperID: String?
    @State private var inspectorDetailsRequestID: UUID?
    @State private var isInspectorReadButtonHovering = false
    @AppStorage("PaperCodexLibrarySortOption") private var librarySortRawValue = LibrarySortOption.addedNewest.rawValue
    @AppStorage("PaperCodexLibrarySortAscending") private var librarySortAscending = false
    @AppStorage("PaperCodexLibraryIncludeSubfolders") private var libraryIncludeSubfolders = true

    private var searchText: String {
        get { model.librarySearchText }
        nonmutating set { model.librarySearchText = newValue }
    }

    private var searchTextBinding: Binding<String> {
        Binding(
            get: { model.librarySearchText },
            set: { model.librarySearchText = $0 }
        )
    }

    private var selectedCategoryID: String? {
        get { model.librarySelectedCategoryID }
        nonmutating set { model.librarySelectedCategoryID = newValue }
    }

    private var selectedTagID: String? {
        get { model.librarySelectedTagID }
        nonmutating set { model.librarySelectedTagID = newValue }
    }

    private var selectedLibrarySurface: LibrarySurface {
        get { model.selectedLibrarySurface }
        nonmutating set { model.selectedLibrarySurface = newValue }
    }

    private var filteredPaperIDs: [String] {
        makePaperListState().paperIDs
    }

    private var sidebarCategories: [PaperCodexCore.Category] {
        categoryDragPreviewCategories ?? model.categories
    }

    private var sortedPapers: [Paper] {
        makePaperListState().papers
    }

    private var selectedPaperIDsInOrder: [String] {
        let selected = selectedPaperIDs
        return sortedPapers.map(\.id).filter { selected.contains($0) }
    }

    private var selectedReadablePaperIDsInOrder: [String] {
        selectedPaperIDsInOrder.filter { paperID in
            sortedPapers.first(where: { $0.id == paperID })?.isArxivImportPlaceholder == false
        }
    }

    private var selectedRecentSession: PaperSession? {
        if let selectedRecentSessionID,
           let session = model.recentSessions.first(where: { $0.id == selectedRecentSessionID }) {
            return session
        }
        return model.recentSessions.first
    }

    private func makePaperListState() -> LibraryPaperListState {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let derivedState = model.libraryDerivedState
        var paperIDFilter: Set<String>?

        if let selectedCategoryID {
            paperIDFilter = derivedState.paperIDsForCategoryFilter(
                selectedCategoryID,
                includeDescendants: libraryIncludeSubfolders
            )
        }

        if let selectedTagID {
            let tagPaperIDs = derivedState.paperIDsForTag(selectedTagID)
            if let existingFilter = paperIDFilter {
                paperIDFilter = existingFilter.intersection(tagPaperIDs)
            } else {
                paperIDFilter = tagPaperIDs
            }
        }

        var papers = model.papers
        if let paperIDFilter {
            papers = papers.filter { paperIDFilter.contains($0.id) }
        }
        if !query.isEmpty {
            papers = papers.filter { paper in
                derivedState.matchesSearch(paperID: paper.id, query: query)
            }
        }

        let option = LibrarySortOption(rawValue: librarySortRawValue) ?? .addedNewest
        let sortedPapers = option.sorted(papers, ascending: librarySortAscending)
        return LibraryPaperListState(
            papers: sortedPapers,
            paperIDs: sortedPapers.map(\.id),
            readablePaperIDs: sortedPapers.filter { !$0.isArxivImportPlaceholder }.map(\.id),
            hasActiveFilters: selectedCategoryID != nil || selectedTagID != nil || !query.isEmpty
        )
    }

    var body: some View {
        SidebarSplitLayout(minContentWidth: LibraryLayout.libraryContentMinimumWidth) {
            sidebar
        } content: {
            contentPane
        }
        .onChange(of: filteredPaperIDs) { _, _ in
            prunePaperSelection()
        }
        .onChange(of: model.recentSessions.map(\.id)) { _, _ in
            pruneRecentSessionSelection()
        }
        .onChange(of: model.selectedLibraryPaper?.id) { _, _ in
            if let paper = model.selectedLibraryPaper {
                scheduleInspectorDetailsAfterSelectionSettles(for: paper)
            } else {
                scheduleInspectorDetailsAfterSelectionSettles(for: nil)
            }
        }
        .onAppear {
            if let paper = model.selectedLibraryPaper {
                scheduleInspectorDetailsAfterSelectionSettles(for: paper)
            }
        }
        .alert("Delete selected papers?", isPresented: $isConfirmingBulkDelete) {
            Button("Delete", role: .destructive) {
                deleteSelectedPapers()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \(selectedPaperIDs.count) papers from the local library and deletes app-managed PDF/cache files. This cannot be undone.")
        }
        .alert("Delete category?", isPresented: Binding(
            get: { categoryPendingDelete != nil },
            set: { if !$0 { categoryPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let categoryPendingDelete {
                    model.deleteCategory(categoryPendingDelete.id)
                    selectedCategoryID = nil
                }
                categoryPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                categoryPendingDelete = nil
            }
        } message: {
            Text("This removes the category, its subcategories, and their assignments. Papers stay in the library.")
        }
        .alert("Delete tag?", isPresented: Binding(
            get: { tagPendingDelete != nil },
            set: { if !$0 { tagPendingDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let tagPendingDelete {
                    model.deleteTag(tagPendingDelete.id)
                    selectedTagID = nil
                }
                tagPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                tagPendingDelete = nil
            }
        } message: {
            Text("This removes the tag from every paper. Papers stay in the library.")
        }
        .alert("Remove watched folder?", isPresented: Binding(
            get: { watchedFolderPendingRemoval != nil },
            set: { if !$0 { watchedFolderPendingRemoval = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let watchedFolderPendingRemoval {
                    model.removeWatchedFolder(watchedFolderPendingRemoval)
                }
                watchedFolderPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                watchedFolderPendingRemoval = nil
            }
        } message: {
            Text("The folder will stop being scanned. Imported papers remain in the library.")
        }
        .sheet(isPresented: $isCreatingCategory) {
            CategoryEditorSheet(
                categoryItems: flattenedCategoryItems(),
                name: $newCategoryName,
                parentID: $newCategoryParentID
            ) { name, parentID in
                model.createCategory(name: name, parentID: parentID.isEmpty ? nil : parentID)
                newCategoryName = ""
                newCategoryParentID = ""
                isCreatingCategory = false
            } onCancel: {
                newCategoryName = ""
                newCategoryParentID = ""
                isCreatingCategory = false
            }
        }
        .sheet(isPresented: $isCreatingTag) {
            TagEditorSheet(name: $newTagName) { name in
                model.createTag(name: name)
                newTagName = ""
                isCreatingTag = false
            } onCancel: {
                newTagName = ""
                isCreatingTag = false
            }
        }
        .sheet(item: $categoryPendingManagement) { category in
            categoryManagementSheet(category)
        }
        .sheet(item: $tagPendingManagement) { tag in
            tagManagementSheet(tag)
        }
        .sheet(isPresented: $isShowingWatchedFolders) {
            WatchedFoldersSheet {
                presentWatchedFolderPanel()
            } onClose: {
                isShowingWatchedFolders = false
            } onRemove: { folder in
                watchedFolderPendingRemoval = folder
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $isShowingArxivImport) {
            LibraryArxivImportSheet(
                categoryItems: flattenedCategoryItems(),
                initialCategoryID: selectedCategoryID
            ) {
                isShowingArxivImport = false
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $isShowingBulkCopy) {
            LibraryBulkCopySheet(
                categoryItems: flattenedCategoryItems(),
                selectedCount: selectedPaperIDs.count
            ) { categoryID in
                if let categoryID {
                    model.copyPapers(selectedPaperIDsInOrder, toCategory: categoryID)
                    selectedCategoryID = categoryID
                    selectedTagID = nil
                }
                selectedPaperIDs.removeAll()
                lastSelectedPaperID = nil
                isShowingBulkCopy = false
            } onCancel: {
                isShowingBulkCopy = false
            }
        }
        .sheet(isPresented: $isShowingBulkTag) {
            LibraryBulkTagSheet(
                tags: model.tags,
                selectedCount: selectedPaperIDs.count
            ) { tagIDs in
                model.assignPapers(selectedPaperIDsInOrder, toTags: tagIDs)
                selectedPaperIDs.removeAll()
                lastSelectedPaperID = nil
                isShowingBulkTag = false
            } onCancel: {
                isShowingBulkTag = false
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            dropPDFs(from: providers)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Episteme")
                .font(.paperCodexSystem(size: 24, weight: .semibold))

            PrimaryNavigationSection()

            Divider()

            Label("Library Context", systemImage: "books.vertical")
                .font(.headline)
                .foregroundStyle(.secondary)

            ScrollView(.vertical) {
                sidebarLists
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .paperCodexSidebarChromePadding()
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sidebarLists: some View {
        VStack(alignment: .leading, spacing: 18) {
            categorySidebarSection
            Divider()
            tagSidebarSection
        }
        .padding(.trailing, 2)
        .padding(.bottom, 8)
    }

    private var categorySidebarSection: some View {
        let categoryTree = LibraryCategoryTreeSnapshot(
            categories: sidebarCategories,
            collapsedCategoryIDs: collapsedCategoryIDs
        )

        return VStack(alignment: .leading, spacing: 8) {
            sidebarHeader("Folders", systemImage: "folder") {
                startCreatingCategory(parentID: selectedCategoryID)
            }
            LibraryRootFolderRow(
                countText: "\(model.papers.count)",
                isSelected: selectedLibrarySurface == .papers && selectedCategoryID == nil && selectedTagID == nil,
                canDropCategory: {
                    guard let draggedCategoryID else {
                        return true
                    }
                    return CategoryMovePlanner.canMoveCategory(
                        draggedCategoryID,
                        toParent: nil,
                        in: sidebarCategories
                    )
                },
                onDropPapers: { paperIDs in
                    model.movePapers(paperIDs, toCategory: nil)
                    selectRootLibrary()
                },
                onDropCategory: { droppedCategoryID in
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        model.moveCategory(droppedCategoryID, toParent: nil)
                    }
                    clearCategoryDragPreview()
                }
            ) {
                selectRootLibrary()
            }
            if sidebarCategories.isEmpty {
                SidebarEmptyText("No categories")
            } else {
                VStack(alignment: .leading, spacing: LibraryLayout.categoryTreeRowSpacing) {
                    ForEach(categoryTree.visibleItems) { item in
                        CategorySidebarRow(
                            title: item.category.name,
                            countText: "\(paperCount(inCategory: item.category.id))",
                            systemImage: selectedCategoryID == item.category.id ? "folder.fill" : "folder",
                            isSelected: selectedLibrarySurface == .papers && selectedCategoryID == item.category.id,
                            depth: item.depth,
                            connectorContinuations: item.connectorContinuations,
                            hasChildren: categoryTree.hasChildren(item.category.id),
                            isExpanded: !collapsedCategoryIDs.contains(item.category.id),
                            isPinned: item.category.isPinned,
                            categoryDragPayload: categoryDragPayload(for: item.category),
                            onDragCategory: {
                                clearCategoryDragPreview()
                                draggedCategoryID = item.category.id
                            },
                            canDropCategory: { placement in
                                guard let draggedCategoryID else {
                                    return true
                                }
                                if draggedCategoryID == item.category.id {
                                    return categoryDragCommitTarget != nil
                                }
                                return CategoryMovePlanner.canDropCategory(
                                    draggedCategoryID,
                                    ontoCategory: item.category.id,
                                    placement: placement,
                                    in: sidebarCategories
                                )
                            },
                            onPreviewCategoryDrop: { placement in
                                guard let draggedCategoryID else {
                                    return
                                }
                                previewCategoryDrop(
                                    draggedCategoryID,
                                    relativeTo: item.category.id,
                                    placement: placement
                                )
                            },
                            onCategoryDropExited: {
                                scheduleCategoryDragPreviewReset()
                            },
                            onToggle: {
                                toggleCategoryCollapsed(item.category.id)
                            },
                            onSelect: {
                                selectLibraryCategory(item.category.id)
                            },
                            onCreateChild: {
                                newCategoryParentID = item.category.id
                                startCreatingCategory(parentID: item.category.id)
                            },
                            onManage: {
                                categoryPendingManagement = item.category
                            },
                            onTogglePinned: {
                                model.setCategoryPinned(item.category.id, pinned: !item.category.isPinned)
                            },
                            onDropPapers: { paperIDs in
                                dropPaperIDs(paperIDs, ontoCategory: item.category.id)
                                selectLibraryCategory(item.category.id)
                            },
                            onDropCategory: { droppedCategoryID, placement in
                                let dropTarget: CategoryDragDropTarget
                                if droppedCategoryID == item.category.id, let categoryDragCommitTarget {
                                    dropTarget = categoryDragCommitTarget
                                } else if droppedCategoryID != item.category.id {
                                    dropTarget = CategoryDragDropTarget(
                                        targetCategoryID: item.category.id,
                                        placement: placement
                                    )
                                } else {
                                    clearCategoryDragPreview()
                                    return
                                }
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                                    switch dropTarget.placement {
                                    case .inside:
                                        model.moveCategory(droppedCategoryID, toParent: dropTarget.targetCategoryID)
                                    case .before, .after:
                                        model.reorderCategory(
                                            droppedCategoryID,
                                            relativeTo: dropTarget.targetCategoryID,
                                            placement: dropTarget.placement
                                        )
                                    }
                                }
                                clearCategoryDragPreview()
                            }
                        )
                    }
                }
            }
        }
    }

    private var tagSidebarSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sidebarHeader("Tags", systemImage: "tag") {
                isCreatingTag = true
            }
            if model.tags.isEmpty {
                SidebarEmptyText("No tags")
            } else {
                ForEach(model.tags) { tag in
                    TagSidebarRow(
                        title: tag.name,
                        countText: "\(paperCount(forTag: tag.id))",
                        isSelected: selectedLibrarySurface == .papers && selectedTagID == tag.id
                    ) {
                        selectLibraryTag(tag.id)
                    } onManage: {
                        tagPendingManagement = tag
                    }
                }
            }
        }
    }

    private var contentPane: some View {
        GeometryReader { proxy in
            if isCompactLibraryContent(width: proxy.size.width) {
                primaryContentPane
                    .padding(.top, LibraryLayout.splitPaneTopInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    primaryContentPane
                        .padding(.top, LibraryLayout.splitPaneTopInset)
                        .frame(minWidth: LibraryLayout.libraryPrimaryPaneMinimumWidth)
                    secondaryContentPane
                        .padding(.top, LibraryLayout.splitPaneTopInset)
                        .frame(
                            minWidth: LibraryLayout.libraryInspectorMinimumWidth,
                            idealWidth: LibraryLayout.libraryInspectorIdealWidth,
                            maxWidth: LibraryLayout.libraryInspectorMaximumWidth
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var primaryContentPane: some View {
        switch selectedLibrarySurface {
        case .papers:
            paperList
        case .recentConversations:
            RecentConversationsContent(
                sessions: model.recentSessions,
                papersBySessionID: model.recentSessionPapersByID,
                categories: model.categories,
                paperCategoryIDsByID: model.paperCategoryIDsByID,
                paperTagsByID: model.paperTagsByID,
                paperThumbnailURLsByID: model.paperThumbnailURLsByID,
                selectedSessionID: Binding(
                    get: { selectedRecentSessionID ?? model.recentSessions.first?.id },
                    set: { selectedRecentSessionID = $0 }
                ),
                placeholderDetail: { paper in
                    model.arxivImportPlaceholderDetail(for: paper)
                },
                onOpen: { session in
                    model.openRecentSession(session)
                }
            )
        }
    }

    @ViewBuilder
    private var secondaryContentPane: some View {
        switch selectedLibrarySurface {
        case .papers:
            inspector
        case .recentConversations:
            RecentConversationDetailPanel(
                session: selectedRecentSession,
                papers: selectedRecentSession.map { model.papersForSession($0) } ?? [],
                onOpen: { session in
                    model.openRecentSession(session)
                }
            )
        }
    }

    private var paperList: some View {
        let listState = makePaperListState()
        return VStack(alignment: .leading, spacing: 16) {
            LibraryInlineControlRow(
                searchText: searchTextBinding,
                sortRawValue: $librarySortRawValue,
                sortAscending: $librarySortAscending,
                includeSubfolders: $libraryIncludeSubfolders,
                paperCount: listState.papers.count,
                showsFolderScope: selectedCategoryID != nil,
                showsReadActions: selectedCategoryID != nil,
                canRead: !listState.readablePaperIDs.isEmpty,
                hasActiveFilters: listState.hasActiveFilters,
                onRead: {
                    model.openPapersForReading(listState.readablePaperIDs)
                },
                onChat: {
                    model.openPapersForChat(listState.readablePaperIDs)
                },
                onClearFilters: clearLibraryFilters,
                onShowWatchedFolders: {
                    isShowingWatchedFolders = true
                },
                onShowArxivImport: {
                    isShowingArxivImport = true
                },
                onImportPDF: presentPDFImportPanel
            )

            if listState.papers.isEmpty {
                ContentUnavailableView("No Papers", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scrollProxy in
                    LibraryPaperList(papers: listState.papers) { paper in
                        PaperRow(
                            paper: paper,
                            categories: categories(for: paper),
                            tags: model.paperTagsByID[paper.id, default: []],
                            thumbnailURLs: model.paperThumbnailURLsByID[paper.id, default: []],
                            isImportPlaceholder: paper.isArxivImportPlaceholder,
                            placeholderDetail: model.arxivImportPlaceholderDetail(for: paper),
                            isSelected: model.selectedLibraryPaper?.id == paper.id,
                            isMultiSelected: selectedPaperIDs.contains(paper.id),
                            onToggleStar: {
                                model.togglePaperStar(paper)
                            },
                            onRead: {
                                model.openPaper(paper)
                            }
                        )
                        .contentShape(Rectangle())
                        .onDrag {
                            clearCategoryDragPreview()
                            return NSItemProvider(object: paperDragPayload(for: paper) as NSString)
                        } preview: {
                            PaperDragPreview(
                                paper: paper,
                                selectedCount: dragPreviewPaperIDs(for: paper).count
                            )
                        }
                        .onTapGesture {
                            handlePaperRowClick(paper)
                            isPaperListFocused = true
                        }
                    }
                    .focusable()
                    .focused($isPaperListFocused)
                    .background(
                        LibraryPaperKeyboardBridge(
                            isActive: isPaperListFocused,
                            onMoveUp: {
                                moveFocusedPaperSelection(by: -1)
                            },
                            onMoveDown: {
                                moveFocusedPaperSelection(by: 1)
                            }
                        )
                    )
                    .onChange(of: model.selectedLibraryPaper?.id) { _, selectedPaperID in
                        guard selectedPaperRevealRequestID != nil else {
                            return
                        }
                        selectedPaperRevealRequestID = nil
                        guard isPaperListFocused,
                              let selectedPaperID,
                              listState.paperIDs.contains(selectedPaperID) else {
                            return
                        }
                        withAnimation(PaperCodexMotion.selection) {
                            scrollProxy.scrollTo(selectedPaperID, anchor: .center)
                        }
                    }
                }
                .overlay(alignment: .top) {
                    bulkActionBarOverlay
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 14)
        .padding(.bottom, 24)
    }

    private var bulkActionBarOverlay: some View {
        Group {
            if selectedPaperIDs.count > 1 {
                BulkLibraryActionBar(
                    selectedCount: selectedPaperIDs.count,
                    canMove: true,
                    canTag: !model.tags.isEmpty,
                    canOpenConversation: !selectedReadablePaperIDsInOrder.isEmpty,
                    onRead: openSelectedPapersForReading,
                    onChat: openSelectedPapersForChat,
                    onCopy: {
                        isShowingBulkCopy = true
                    },
                    onTag: {
                        isShowingBulkTag = true
                    },
                    onDelete: {
                        isConfirmingBulkDelete = true
                    },
                    onClear: {
                        selectedPaperIDs.removeAll()
                        lastSelectedPaperID = nil
                    }
                )
                .padding(.horizontal, 10)
                .padding(.top, LibraryLayout.bulkActionBarOverlayYOffset)
                .opacity(LibraryLayout.bulkActionBarOverlayOpacity)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .shadow(color: Color.black.opacity(0.10), radius: 12, y: 5)
            }
        }
        .animation(.easeOut(duration: 0.16), value: selectedPaperIDs.count > 1)
    }

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paper Details")
                .font(.paperCodexSystem(size: 20, weight: .semibold))

            if let paper = model.selectedLibraryPaper {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .top, spacing: 8) {
                                Text(paper.title)
                                    .font(.headline)
                                Spacer(minLength: 8)
                                PaperCodexIconButton(
                                    title: paper.isStarred ? "Remove Star" : "Star Paper",
                                    systemImage: paper.isStarred ? "star.fill" : "star",
                                    tint: paper.isStarred ? .yellow : .secondary,
                                    disabled: paper.isArxivImportPlaceholder
                                ) {
                                    model.togglePaperStar(paper)
                                }
                            }
                            Text(paper.isArxivImportPlaceholder ? model.arxivImportPlaceholderDetail(for: paper) : (paper.authors.isEmpty ? "Authors not set" : paper.authors.joined(separator: ", ")))
                                .foregroundStyle(.secondary)
                            Text(paper.isArxivImportPlaceholder ? (paper.sourceURL ?? paper.title) : paper.filePath)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }

                        Button {
                            model.openPaper(paper)
                        } label: {
                            Label("Read", systemImage: "book")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(LibraryInspectorReadButtonStyle(isHovering: isInspectorReadButtonHovering, disabled: paper.isArxivImportPlaceholder))
                        .disabled(paper.isArxivImportPlaceholder)
                        .onHover { hovering in
                            withAnimation(PaperCodexMotion.hover) {
                                isInspectorReadButtonHovering = hovering
                            }
                        }

                        if inspectorDetailsPaperID == paper.id {
                            Divider()

                            let metadata = model.libraryArxivMetadata(for: paper)
                            if let metadata {
                                paperMetadataSection(for: paper, metadata: metadata)
                                Divider()
                            }

                            categoryAssignments(for: paper)
                            Divider()
                            tagAssignments(for: paper)
                            Divider()
                            paperNotesSection(for: paper)
                        }
                    }
                    .padding(.trailing, 4)
                }
            } else {
                ContentUnavailableView("Select Paper", systemImage: "sidebar.right")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func paperMetadataSection(for paper: Paper, metadata: LibraryPaperArxivMetadata) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("解析信息", systemImage: "sparkles")
                .font(.headline)
            if !metadata.titleZH.isEmpty, metadata.titleZH != paper.title {
                LibraryMetadataBlock(title: "中文标题", text: metadata.titleZH)
            }
            if !metadata.summaryZH.isEmpty {
                LibraryMetadataBlock(title: "中文摘要", text: metadata.summaryZH)
            }
            if !metadata.contribution.isEmpty {
                LibraryMetadataBlock(title: "贡献总结", text: metadata.contribution)
            }
            if !metadata.abstractZH.isEmpty {
                LibraryMetadataBlock(title: "中文 Abstract", text: metadata.abstractZH)
            }
            if !metadata.abstractEN.isEmpty {
                LibraryMetadataBlock(title: "Abstract", text: metadata.abstractEN)
            }
            if !metadata.tags.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(metadata.tags.prefix(10), id: \.self) { tag in
                        SmallChip(title: tag, systemImage: "tag")
                    }
                }
            }
        }
    }

    private func categoryAssignments(for paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Categories", systemImage: "folder")
                    .font(.headline)
                Spacer()
                Button {
                    newCategoryParentID = ""
                    isCreatingCategory = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Category")
            }

            if model.categories.isEmpty {
                SidebarEmptyText("No categories")
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(flattenedCategoryItems()) { item in
                        Toggle(isOn: Binding(
                            get: {
                                model.paperCategoryIDsByID[paper.id, default: []].contains(item.category.id)
                            },
                            set: { isAssigned in
                                model.setCategory(item.category.id, assigned: isAssigned, for: paper)
                            }
                        )) {
                            Text(item.category.name)
                                .padding(.leading, CGFloat(item.depth * 14))
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
        }
    }

    private func tagAssignments(for paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Tags", systemImage: "tag")
                    .font(.headline)
                Spacer()
                Button {
                    isCreatingTag = true
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Tag")
            }

            if model.tags.isEmpty {
                SidebarEmptyText("No tags")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(model.tags) { tag in
                        let assigned = model.paperTagsByID[paper.id, default: []].contains { $0.id == tag.id }
                        TagToggleChip(tag: tag, isAssigned: assigned) {
                            model.setTag(tag.id, assigned: !assigned, for: paper)
                        }
                    }
                }
            }
        }
    }

    private func paperNotesSection(for paper: Paper) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Notes", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                if editingNoteID != nil {
                    Button("New") {
                        clearNoteDraft()
                    }
                    .buttonStyle(.borderless)
                }
            }

            let notes = model.paperNotesByID[paper.id, default: []]
            if notes.isEmpty {
                SidebarEmptyText("No notes")
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes) { note in
                        PaperNoteRow(note: note) {
                            editingNoteID = note.id
                            noteTitle = note.title
                            noteBody = note.bodyMarkdown
                        } onDelete: {
                            model.deleteNote(note)
                            if editingNoteID == note.id {
                                clearNoteDraft()
                            }
                        }
                    }
                }
            }

            TextField("Note title", text: $noteTitle)
                .textFieldStyle(.roundedBorder)
            TextEditor(text: $noteBody)
                .font(.paperCodexSystem(size: 12.5))
                .frame(minHeight: 72)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 7))
            HStack {
                Button {
                    model.saveNote(paperID: paper.id, noteID: editingNoteID, title: noteTitle, bodyMarkdown: noteBody)
                    clearNoteDraft()
                } label: {
                    Label(editingNoteID == nil ? "Add Note" : "Save Note", systemImage: "checkmark")
                }
                .buttonStyle(.bordered)
                .disabled(noteTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && noteBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if editingNoteID != nil {
                    Button("Cancel") {
                        clearNoteDraft()
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private func sidebarHeader(_ title: String, systemImage: String, onAdd: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            Button(action: onAdd) {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("New \(title.dropLast())")
        }
    }

    private func filterButton(
        title: String,
        systemImage: String,
        isSelected: Bool,
        depth: Int = 0,
        action: @escaping () -> Void
    ) -> some View {
        SidebarRowButton(
            title: title,
            systemImage: systemImage,
            selected: isSelected,
            depth: depth,
            action: action
        )
    }

    private func startCreatingCategory(parentID: String?) {
        newCategoryParentID = parentID ?? ""
        isCreatingCategory = true
    }

    private func handlePaperRowClick(_ paper: Paper) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        let canOpenOnSecondClick = modifiers.isEmpty
        let clickedAt = Date()
        handlePaperRowTap(paper)

        guard canOpenOnSecondClick else {
            lastPaperRowClick = nil
            return
        }

        if let lastPaperRowClick,
           lastPaperRowClick.paperID == paper.id,
           clickedAt.timeIntervalSince(lastPaperRowClick.clickedAt) <= 0.38,
           !paper.isArxivImportPlaceholder {
            model.openPaper(paper)
            self.lastPaperRowClick = nil
        } else {
            lastPaperRowClick = LibraryPaperRowClick(paperID: paper.id, clickedAt: clickedAt)
        }
    }

    private func handlePaperRowTap(_ paper: Paper) {
        let modifiers = NSEvent.modifierFlags.intersection([.command, .shift])
        if modifiers.contains(.shift) {
            selectPaperRange(through: paper)
        } else if modifiers.contains(.command) {
            togglePaperSelection(paper)
        } else {
            clearPaperMultiSelection()
            lastSelectedPaperID = paper.id
            focusLibraryPaper(paper)
        }
    }

    private func moveFocusedPaperSelection(by offset: Int) {
        guard selectedLibrarySurface == .papers else {
            return
        }
        let visiblePapers = sortedPapers
        guard !visiblePapers.isEmpty else {
            return
        }
        let currentIndex = model.selectedLibraryPaper.flatMap { selectedPaper in
            visiblePapers.firstIndex { $0.id == selectedPaper.id }
        }
        let lastIndex = visiblePapers.index(before: visiblePapers.endIndex)
        let nextIndex: Int
        if let currentIndex {
            nextIndex = min(max(currentIndex + offset, visiblePapers.startIndex), lastIndex)
        } else {
            nextIndex = offset < 0 ? lastIndex : visiblePapers.startIndex
        }
        let nextPaper = visiblePapers[nextIndex]
        clearPaperMultiSelection()
        lastSelectedPaperID = nextPaper.id
        selectedPaperRevealRequestID = UUID()
        focusLibraryPaper(nextPaper)
        isPaperListFocused = true
    }

    private func togglePaperSelection(_ paper: Paper) {
        var nextSelection = seedSelectionForCommandToggle(startingWith: paper)
        if nextSelection.contains(paper.id) {
            nextSelection.remove(paper.id)
        } else {
            nextSelection.insert(paper.id)
        }
        applyPaperSelection(nextSelection, focusedPaper: paper)
    }

    private func seedSelectionForCommandToggle(startingWith paper: Paper) -> Set<String> {
        guard selectedPaperIDs.isEmpty else {
            return selectedPaperIDs
        }
        guard let focusedPaper = model.selectedLibraryPaper,
              sortedPapers.contains(where: { $0.id == focusedPaper.id }) else {
            return []
        }
        return [focusedPaper.id]
    }

    private func applyPaperSelection(_ paperIDs: Set<String>, focusedPaper: Paper) {
        let visibleIDs = Set(sortedPapers.map(\.id))
        let visibleSelection = paperIDs.intersection(visibleIDs)
        if visibleSelection.count > 1 {
            selectedPaperIDs = visibleSelection
            lastSelectedPaperID = focusedPaper.id
            focusLibraryPaper(focusedPaper)
            return
        }

        clearPaperMultiSelection()
        if let remainingID = visibleSelection.first,
           let remainingPaper = sortedPapers.first(where: { $0.id == remainingID }) {
            lastSelectedPaperID = remainingID
            focusLibraryPaper(remainingPaper)
        } else if visibleIDs.contains(focusedPaper.id) {
            lastSelectedPaperID = focusedPaper.id
            focusLibraryPaper(focusedPaper)
        } else {
            lastSelectedPaperID = nil
            clearFocusedLibraryPaper()
        }
    }

    private func clearPaperMultiSelection() {
        selectedPaperIDs.removeAll()
    }

    private func selectPaperRange(through paper: Paper) {
        let visibleIDs = sortedPapers.map(\.id)
        guard let currentIndex = visibleIDs.firstIndex(of: paper.id) else {
            togglePaperSelection(paper)
            return
        }
        let anchorID = lastSelectedPaperID ?? paper.id
        guard let anchorIndex = visibleIDs.firstIndex(of: anchorID) else {
            applyPaperSelection([paper.id], focusedPaper: paper)
            return
        }
        let lower = min(anchorIndex, currentIndex)
        let upper = max(anchorIndex, currentIndex)
        applyPaperSelection(Set(visibleIDs[lower...upper]), focusedPaper: paper)
    }

    private func prunePaperSelection() {
        let visibleIDs = Set(sortedPapers.map(\.id))
        selectedPaperIDs = selectedPaperIDs.intersection(visibleIDs)
        if selectedPaperIDs.count < 2 {
            clearPaperMultiSelection()
        }
        if let lastSelectedPaperID, !selectedPaperIDs.isEmpty, !selectedPaperIDs.contains(lastSelectedPaperID) {
            self.lastSelectedPaperID = selectedPaperIDsInOrder.last
        }
    }

    private func pruneRecentSessionSelection() {
        if let selectedRecentSessionID,
           model.recentSessions.contains(where: { $0.id == selectedRecentSessionID }) {
            return
        }
        selectedRecentSessionID = model.recentSessions.first?.id
    }

    private func deleteSelectedPapers() {
        let paperIDs = selectedPaperIDsInOrder
        guard !paperIDs.isEmpty else {
            return
        }
        model.deletePapers(paperIDs)
        selectedPaperIDs.removeAll()
        lastSelectedPaperID = nil
    }

    private func openSelectedPapersForReading() {
        let paperIDs = selectedReadablePaperIDsInOrder
        guard !paperIDs.isEmpty else {
            return
        }
        model.openPapersForReading(paperIDs)
    }

    private func openSelectedPapersForChat() {
        let paperIDs = selectedReadablePaperIDsInOrder
        guard !paperIDs.isEmpty else {
            return
        }
        model.openPapersForChat(paperIDs)
    }

    private func clearNoteDraft() {
        editingNoteID = nil
        noteTitle = ""
        noteBody = ""
    }

    private func focusLibraryPaper(_ paper: Paper) {
        applyFastLibrarySelection {
            model.selectLibraryPaper(paper)
        }
    }

    private func clearFocusedLibraryPaper() {
        applyFastLibrarySelection {
            model.selectedLibraryPaper = nil
        }
    }

    private func scheduleInspectorDetailsAfterSelectionSettles(for paper: Paper?) {
        inspectorDetailsPaperID = nil
        let requestID = UUID()
        inspectorDetailsRequestID = requestID
        guard let paper else {
            return
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: LibraryLayout.inspectorDetailSettleDelayNanoseconds)
            guard inspectorDetailsRequestID == requestID,
                  model.selectedLibraryPaper?.id == paper.id else {
                return
            }
            inspectorDetailsPaperID = paper.id
            model.loadPaperNotes(for: paper)
        }
    }

    private func applyFastLibrarySelection(_ update: () -> Void) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            update()
        }
    }

    private func selectRootLibrary() {
        applyFastLibrarySelection {
            model.setLibrarySelection(surface: .papers, categoryID: nil, tagID: nil)
        }
    }

    private func selectLibraryCategory(_ categoryID: String) {
        applyFastLibrarySelection {
            model.setLibrarySelection(surface: .papers, categoryID: categoryID, tagID: nil)
        }
    }

    private func selectLibraryTag(_ tagID: String) {
        applyFastLibrarySelection {
            model.setLibrarySelection(surface: .papers, categoryID: nil, tagID: tagID)
        }
    }

    private func clearLibraryFilters() {
        applyFastLibrarySelection {
            searchText = ""
            model.setLibrarySelection(surface: .papers, categoryID: nil, tagID: nil)
        }
    }

    private func isCompactLibraryContent(width: CGFloat) -> Bool {
        width < LibraryLayout.compactContentWidthThreshold
    }

    private func toggleCategoryCollapsed(_ categoryID: String) {
        withAnimation(PaperCodexMotion.selection) {
            if collapsedCategoryIDs.contains(categoryID) {
                collapsedCategoryIDs.remove(categoryID)
            } else {
                collapsedCategoryIDs.insert(categoryID)
            }
        }
    }

    private func dropPaperIDs(_ paperIDs: [String], ontoCategory categoryID: String) {
        if shouldMoveDroppedPapers(toCategory: categoryID) {
            model.movePapers(paperIDs, toCategory: categoryID)
        } else {
            model.copyPapers(paperIDs, toCategory: categoryID)
        }
    }

    private func previewCategoryDrop(
        _ draggedCategoryID: String,
        relativeTo targetCategoryID: String,
        placement: LibraryCategoryDropPlacement
    ) {
        cancelCategoryDragPreviewReset()
        guard draggedCategoryID != targetCategoryID else {
            return
        }
        guard placement == .before || placement == .after else {
            return
        }
        let dropKey = "\(draggedCategoryID)|\(targetCategoryID)|\(placement)"
        guard liveCategoryDropKey != dropKey else {
            return
        }
        let previewBaseCategories = sidebarCategories
        guard CategoryMovePlanner.canDropCategory(
            draggedCategoryID,
            ontoCategory: targetCategoryID,
            placement: placement,
            in: previewBaseCategories
        ) else {
            return
        }
        guard let previewCategories = try? CategoryMovePlanner.reorderedCategories(
            movingCategoryID: draggedCategoryID,
            relativeTo: targetCategoryID,
            placement: placement,
            in: previewBaseCategories
        ), previewCategories != previewBaseCategories else {
            return
        }
        liveCategoryDropKey = dropKey
        categoryDragCommitTarget = CategoryDragDropTarget(
            targetCategoryID: targetCategoryID,
            placement: placement
        )
        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
            categoryDragPreviewCategories = previewCategories
        }
    }

    private func clearCategoryDragPreview() {
        draggedCategoryID = nil
        liveCategoryDropKey = nil
        categoryDragPreviewCategories = nil
        categoryDragCommitTarget = nil
        categoryDragResetToken = nil
    }

    private func cancelCategoryDragPreviewReset() {
        categoryDragResetToken = nil
    }

    private func scheduleCategoryDragPreviewReset() {
        guard categoryDragPreviewCategories != nil else {
            return
        }
        let resetToken = UUID()
        categoryDragResetToken = resetToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            guard categoryDragResetToken == resetToken else {
                return
            }
            withAnimation(.easeOut(duration: 0.16)) {
                clearCategoryDragPreview()
            }
        }
    }

    private func shouldMoveDroppedPapers(toCategory categoryID: String) -> Bool {
        guard let selectedCategoryID else {
            return false
        }
        return categoryID == selectedCategoryID || model.categoryIsDescendant(categoryID, of: selectedCategoryID)
    }

    private func paperCount(inCategory categoryID: String) -> Int {
        model.libraryDerivedState.categoryPaperCountsByID[categoryID, default: 0]
    }

    private func paperCount(forTag tagID: String) -> Int {
        model.libraryDerivedState.tagPaperCountsByID[tagID, default: 0]
    }

    private func dropPDFs(from providers: [NSItemProvider]) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else {
            return false
        }
        for provider in fileProviders {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let itemURL = item as? URL {
                    url = itemURL
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let nsURL = item as? NSURL {
                    url = nsURL as URL
                } else {
                    url = nil
                }
                guard let url else {
                    return
                }
                DispatchQueue.main.async {
                    model.importPDFs(from: [url])
                }
            }
        }
        return true
    }

    private func paperIDsForDrag(startingWith paper: Paper) -> [String] {
        if selectedPaperIDs.count > 1, selectedPaperIDs.contains(paper.id) {
            return selectedPaperIDsInOrder
        }
        return [paper.id]
    }

    private func dragPreviewPaperIDs(for paper: Paper) -> [String] {
        paperIDsForDrag(startingWith: paper)
    }

    private func paperDragPayload(for paper: Paper) -> String {
        paperIDsForDrag(startingWith: paper).joined(separator: "\n")
    }

    private func categoryDragPayload(for category: PaperCodexCore.Category) -> String {
        "\(LibraryLayout.categoryDragPayloadPrefix)\(category.id)"
    }

    private func categories(for paper: Paper) -> [PaperCodexCore.Category] {
        let ids = Set(model.paperCategoryIDsByID[paper.id, default: []])
        return model.categories.filter { ids.contains($0.id) }
    }

    private func presentPDFImportPanel() {
        let panel = NSOpenPanel()
        panel.title = "Import PDF"
        panel.prompt = "Import"
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.resolvesAliases = true
        beginOpenPanel(panel) { url in
            model.importPDF(from: url)
        }
    }

    private func presentWatchedFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "Add Watched Folder"
        panel.prompt = "Add Folder"
        panel.allowedContentTypes = [.folder]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.resolvesAliases = true
        beginOpenPanel(panel) { url in
            model.addWatchedFolder(from: url)
        }
    }

    private func beginOpenPanel(_ panel: NSOpenPanel, onSelection: @escaping (URL) -> Void) {
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else {
                    return
                }
                onSelection(url)
            }
        } else {
            panel.begin { response in
                guard response == .OK, let url = panel.url else {
                    return
                }
                onSelection(url)
            }
        }
    }

    private func flattenedCategoryItems(parentID: String? = nil, depth: Int = 0) -> [CategoryListItem] {
        model.categories
            .filter { $0.parentID == parentID }
            .sorted { left, right in
                if left.isPinned != right.isPinned {
                    return left.isPinned
                }
                if left.sortOrder == right.sortOrder {
                    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
                return left.sortOrder < right.sortOrder
            }
            .flatMap { category in
                [CategoryListItem(category: category, depth: depth)]
                    + flattenedCategoryItems(parentID: category.id, depth: depth + 1)
            }
    }

    private func visibleCategoryItems(parentID: String? = nil, depth: Int = 0) -> [CategoryListItem] {
        model.categories
            .filter { $0.parentID == parentID }
            .sorted { left, right in
                if left.isPinned != right.isPinned {
                    return left.isPinned
                }
                if left.sortOrder == right.sortOrder {
                    return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
                }
                return left.sortOrder < right.sortOrder
            }
            .flatMap { category in
                let children = collapsedCategoryIDs.contains(category.id) ? [] : visibleCategoryItems(parentID: category.id, depth: depth + 1)
                return [CategoryListItem(category: category, depth: depth)] + children
            }
    }

    private func categoryManagementSheet(_ category: PaperCodexCore.Category) -> some View {
        CategoryManagementSheet(
            category: category,
            categoryItems: flattenedCategoryItems().filter { $0.category.id != category.id },
            onSave: { name, parentID in
                model.updateCategory(category.id, name: name, parentID: parentID)
                categoryPendingManagement = nil
            },
            onDelete: {
                categoryPendingManagement = nil
                categoryPendingDelete = category
            },
            onCancel: {
                categoryPendingManagement = nil
            }
        )
    }

    private func tagManagementSheet(_ tag: PaperTag) -> some View {
        TagManagementSheet(
            tag: tag,
            onSave: { name in
                model.updateTag(tag.id, name: name)
                tagPendingManagement = nil
            },
            onDelete: {
                tagPendingManagement = nil
                tagPendingDelete = tag
            },
            onCancel: {
                tagPendingManagement = nil
            }
        )
    }
}

private struct WatchedFoldersSheet: View {
    @EnvironmentObject private var model: AppModel
    var onAdd: () -> Void
    var onClose: () -> Void
    var onRemove: (WatchedFolder) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Watched Folders")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button(action: onAdd) {
                    Label("Add Folder", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                Button {
                    model.scanWatchedFolders()
                } label: {
                    Label(model.isScanningWatchedFolders ? "Scanning" : "Scan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.watchedFolders.isEmpty || model.isScanningWatchedFolders)
            }

            if model.watchedFolders.isEmpty {
                ContentUnavailableView("No Folders", systemImage: "folder")
                    .frame(width: 520, height: 220)
            } else {
                List {
                    ForEach(model.watchedFolders) { folder in
                        WatchedFolderRow(folder: folder) {
                            onRemove(folder)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(width: 560, height: 260)
            }

            HStack {
                Spacer()
                Button("Close", action: onClose)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600)
    }
}

private struct WatchedFolderRow: View {
    var folder: WatchedFolder
    var onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(folderExists ? Color.accentColor : Color.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: folder.path).lastPathComponent)
                    .font(.paperCodexSystem(size: 13, weight: .medium))
                Text(folder.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(lastScannedText)
                    .font(.caption2)
                    .foregroundStyle(folderExists ? Color.secondary.opacity(0.72) : Color.orange)
            }
            Spacer()
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Remove Folder")
        }
        .padding(.vertical, 4)
    }

    private var lastScannedText: String {
        guard folderExists else {
            return "Folder missing"
        }
        guard let date = folder.lastScannedAt else {
            return "Not scanned"
        }
        return "Scanned \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var folderExists: Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

private struct CategoryListItem: Identifiable {
    var category: PaperCodexCore.Category
    var depth: Int
    var connectorContinuations: [Bool] = []

    var id: String { category.id }
}

private struct CategoryDragDropTarget: Equatable {
    var targetCategoryID: String
    var placement: LibraryCategoryDropPlacement
}

struct LibraryPaperArxivMetadata: Equatable {
    var arxivID: String
    var titleZH: String
    var summaryZH: String
    var contribution: String
    var abstractZH: String
    var abstractEN: String
    var tags: [String]
}

private struct LibraryRootFolderRow: View {
    @State private var isHovering = false
    @State private var isDropTargeted = false

    var countText: String
    var isSelected: Bool
    var canDropCategory: () -> Bool
    var onDropPapers: ([String]) -> Void
    var onDropCategory: (String) -> Void
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            ZStack(alignment: .trailing) {
                HStack(spacing: 8) {
                    Image(systemName: isSelected ? "tray.full.fill" : "tray.full")
                        .frame(width: 18)
                        .foregroundStyle(isSelected || isDropTargeted ? Color.accentColor : Color.secondary)
                    Text("All Papers")
                        .font(.paperCodexSystem(size: 13, weight: isSelected ? .semibold : .medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)

                if isDropTargeted {
                    Label("Top Level", systemImage: "arrow.up.to.line")
                        .font(.paperCodexSystem(size: 11, weight: .semibold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .foregroundStyle(Color.accentColor)
                        .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                        .padding(.trailing, 6)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                } else {
                    Text(countText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                        .padding(.trailing, 9)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                }
            }
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.12) : (isSelected ? Color.accentColor.opacity(0.13) : (isHovering ? Color.primary.opacity(0.045) : Color.clear)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropTargeted ? Color.accentColor.opacity(0.55) : (isSelected ? Color.accentColor.opacity(0.22) : (isHovering ? Color.accentColor.opacity(0.18) : Color.clear)), lineWidth: isDropTargeted ? 1.5 : 1)
        )
        .overlay(alignment: .leading) {
            if isSelected {
                Capsule()
                    .fill(Color.accentColor.opacity(0.72))
                    .frame(width: 3, height: 18)
                    .padding(.leading, 3)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }
        }
        .scaleEffect(isDropTargeted ? 1.02 : (isHovering ? 1.01 : 1), anchor: .center)
        .animation(PaperCodexMotion.hover, value: isHovering)
        .animation(PaperCodexMotion.hover, value: isDropTargeted)
        .animation(PaperCodexMotion.selection, value: isSelected)
        .contentShape(Rectangle())
        .onDrop(
            of: LibraryLayout.categoryDropContentTypes,
            delegate: LibraryRootFolderDropDelegate(
                isTargeted: $isDropTargeted,
                canDropCategory: canDropCategory,
                onDrop: loadDroppedItems(from:)
            )
        )
        .help("Show all papers or drop a folder here to move it to the top level")
        .onHover { hovering in
            withAnimation(PaperCodexMotion.hover) {
                isHovering = hovering
            }
        }
    }

    private func loadDroppedItems(from providers: [NSItemProvider]) -> Bool {
        let textProviders = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !textProviders.isEmpty else {
            return false
        }
        for provider in textProviders {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = (object as? NSString).map(String.init) else {
                    return
                }
                let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                if let droppedCategoryID = LibraryLayout.droppedCategoryID(from: trimmedPayload) {
                    DispatchQueue.main.async {
                        onDropCategory(droppedCategoryID)
                    }
                    return
                }
                let paperIDs = trimmedPayload
                    .components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !paperIDs.isEmpty else {
                    return
                }
                DispatchQueue.main.async {
                    onDropPapers(paperIDs)
                }
            }
        }
        return true
    }
}

private struct LibraryInlineControlRow: View {
    @EnvironmentObject private var model: AppModel
    @FocusState private var isLibrarySearchFocused: Bool

    @Binding var searchText: String
    @Binding var sortRawValue: String
    @Binding var sortAscending: Bool
    @Binding var includeSubfolders: Bool

    var paperCount: Int
    var showsFolderScope: Bool
    var showsReadActions: Bool
    var canRead: Bool
    var hasActiveFilters: Bool
    var onRead: () -> Void
    var onChat: () -> Void
    var onClearFilters: () -> Void
    var onShowWatchedFolders: () -> Void
    var onShowArxivImport: () -> Void
    var onImportPDF: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Library")
                .font(.paperCodexSystem(size: 22, weight: .semibold))
                .fixedSize()

            searchField

            Text("\(paperCount) papers")
                .font(.paperCodexSystem(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .contentTransition(.numericText())

            if showsFolderScope {
                scopeToggle
            }

            Spacer(minLength: 8)

            if hasActiveFilters {
                PaperCodexIconButton(title: "Clear Filters", systemImage: "line.3.horizontal.decrease.circle", tint: .secondary) {
                    onClearFilters()
                }
            }

            if showsReadActions {
                readButton
                chatButton
            }

            PaperCodexIconButton(title: "Folders", systemImage: "folder.badge.plus", tint: .secondary) {
                onShowWatchedFolders()
            }
            PaperCodexIconButton(title: "arXiv", systemImage: "number", tint: .secondary) {
                onShowArxivImport()
            }
            sortPicker
            sortDirectionButton
            PaperCodexToolbarButton(title: "Import PDF", systemImage: "plus", tint: .blue) {
                onImportPDF()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 34)
        .lineLimit(1)
        .controlSize(.small)
        .onChange(of: model.searchFocusRequestID) { _, _ in
            guard model.route == .library else {
                return
            }
            isLibrarySearchFocused = true
        }
    }

    private var searchField: some View {
        TextField("Search title, author, tag, category, year, or source", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .font(.paperCodexSystem(size: 14))
            .frame(minWidth: 180, maxWidth: .infinity)
            .layoutPriority(1)
            .focused($isLibrarySearchFocused)
            .overlay(alignment: .trailing) {
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .padding(.trailing, 6)
                    .help("Clear Search")
                }
            }
    }

    private var scopeToggle: some View {
        Button {
            includeSubfolders.toggle()
        } label: {
            Label(includeSubfolders ? "All levels" : "This folder", systemImage: includeSubfolders ? "folder.badge.gearshape" : "folder")
                .labelStyle(.titleAndIcon)
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .help(includeSubfolders ? "Showing current folder and subfolders" : "Showing current folder only")
        .accessibilityLabel(includeSubfolders ? "Show Current Folder Only" : "Show Current Folder And Subfolders")
    }

    private var readButtonTitle: String {
        paperCount == 1 ? "Read" : "Read All"
    }

    private var chatButtonTitle: String {
        paperCount == 1 ? "Chat" : "Chat All"
    }

    private var readButton: some View {
        Button(action: onRead) {
            Label(readButtonTitle, systemImage: "book")
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .disabled(!canRead)
        .help(paperCount == 1 ? "Read visible paper" : "Read all visible papers together")
    }

    private var chatButton: some View {
        Button(action: onChat) {
            Label(chatButtonTitle, systemImage: "text.bubble")
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
        .disabled(!canRead)
        .help(paperCount == 1 ? "Chat with visible paper" : "Chat with all visible papers")
    }

    private var sortPicker: some View {
        Picker("Sort", selection: $sortRawValue) {
            ForEach(LibrarySortOption.allCases) { option in
                Label {
                    Text(LocalizedStringKey(option.title))
                } icon: {
                    Image(systemName: option.systemImage)
                }
                .tag(option.rawValue)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 108)
        .help("Sort Library")
    }

    private var sortDirectionButton: some View {
        Button {
            sortAscending.toggle()
        } label: {
            Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .fixedSize()
        .help(sortAscending ? "Ascending" : "Descending")
        .accessibilityLabel(sortAscending ? "Sort Ascending" : "Sort Descending")
    }
}

private struct LibraryPaperListState {
    var papers: [Paper]
    var paperIDs: [String]
    var readablePaperIDs: [String]
    var hasActiveFilters: Bool
}

private struct LibraryInspectorReadButtonStyle: ButtonStyle {
    var isHovering: Bool
    var disabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed && !disabled
        configuration.label
            .font(.paperCodexSystem(size: 13.5, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .foregroundStyle(foregroundColor(isPressed: isPressed))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor(isPressed: isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor(isPressed: isPressed), lineWidth: 1)
            )
            .shadow(color: shadowColor(isPressed: isPressed), radius: isPressed ? 4 : 8, y: isPressed ? 1 : 3)
            .scaleEffect(buttonScale(isPressed: isPressed), anchor: .center)
            .animation(PaperCodexMotion.press, value: configuration.isPressed)
            .animation(PaperCodexMotion.hover, value: isHovering)
            .animation(PaperCodexMotion.hover, value: disabled)
    }

    private func foregroundColor(isPressed: Bool) -> Color {
        if disabled {
            return Color.secondary.opacity(0.48)
        }
        return .white
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if disabled {
            return Color(nsColor: .controlBackgroundColor).opacity(0.56)
        }
        if isPressed {
            return Color.accentColor.opacity(0.84)
        }
        return Color.accentColor.opacity(isHovering ? 0.96 : 0.90)
    }

    private func borderColor(isPressed: Bool) -> Color {
        if disabled {
            return Color.black.opacity(0.06)
        }
        return Color.accentColor.opacity(isPressed ? 0.62 : (isHovering ? 0.48 : 0.34))
    }

    private func shadowColor(isPressed: Bool) -> Color {
        if disabled {
            return .clear
        }
        return Color.accentColor.opacity(isPressed ? 0.14 : (isHovering ? 0.22 : 0.16))
    }

    private func buttonScale(isPressed: Bool) -> CGFloat {
        if disabled {
            return 1
        }
        return isPressed ? 0.976 : (isHovering ? 1.012 : 1)
    }
}

private struct LibraryCategoryTreeSnapshot {
    var visibleItems: [CategoryListItem]

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
    ) -> [CategoryListItem] {
        categories.enumerated().flatMap { index, category in
            let isLast = index == categories.count - 1
            let connectorContinuations = depth == 0 ? [] : ancestorContinuations + [!isLast]
            let item = CategoryListItem(
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
            return left.isPinned
        }
        if left.sortOrder == right.sortOrder {
            return left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
        }
        return left.sortOrder < right.sortOrder
    }
}

private struct LibraryPaperList<RowContent: View>: View {
    var papers: [Paper]
    @ViewBuilder var rowContent: (Paper) -> RowContent

    var body: some View {
        List(papers) { paper in
            rowContent(paper)
                .id(paper.id)
                .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LibraryPaperKeyboardBridge: NSViewRepresentable {
    var isActive: Bool
    var onMoveUp: () -> Void
    var onMoveDown: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installMonitor()
        DispatchQueue.main.async { [weak view, weak coordinator = context.coordinator] in
            coordinator?.targetWindow = view?.window
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.targetWindow = view.window
        context.coordinator.isActive = isActive
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.installMonitor()
    }

    final class Coordinator {
        weak var targetWindow: NSWindow?
        var isActive = false
        var onMoveUp: () -> Void = {}
        var onMoveDown: () -> Void = {}
        private var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func installMonitor() {
            guard monitor == nil else {
                return
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleKeyDown(event) ?? event
            }
        }

        private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
            guard isActive,
                  targetWindow === event.window else {
                return event
            }
            let disallowedModifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
            guard disallowedModifiers.isEmpty else {
                return event
            }
            switch event.keyCode {
            case 126:
                onMoveUp()
                return nil
            case 125:
                onMoveDown()
                return nil
            default:
                return event
            }
        }
    }
}

private struct LibraryPaperRowClick: Equatable {
    var paperID: String
    var clickedAt: Date
}

private enum LibraryLayout {
    static let libraryContentMinimumWidth: CGFloat = 560
    static let libraryPrimaryPaneMinimumWidth: CGFloat = 330
    static let libraryInspectorMinimumWidth: CGFloat = 220
    static let libraryInspectorIdealWidth: CGFloat = 300
    static let libraryInspectorMaximumWidth: CGFloat = 380
    static let compactContentWidthThreshold: CGFloat = 860
    static let splitPaneTopInset: CGFloat = 0
    static let bulkActionBarOverlayYOffset: CGFloat = 148
    static let bulkActionBarOverlayOpacity = 0.66
    static let paperRowThumbnailLimit = 3
    static let paperRowThumbnailMaxPixelSize = 128
    static let inspectorDetailSettleDelayNanoseconds: UInt64 = 80_000_000
    static let categoryTreeRowSpacing: CGFloat = 0
    static let categoryTreeConnectorHeight: CGFloat = 32
    static let categoryTreeIndentWidth: CGFloat = 22
    static let categoryTreeFolderButtonLeadingPadding: CGFloat = 8
    static let categoryTreeFolderIconWidth: CGFloat = 17
    static let categoryTreeConnectorTargetInset: CGFloat = 7
    static let categoryTreeConnectorLineWidth: CGFloat = 1
    static let categoryTreeConnectorOpacity = 0.16
    static let categoryDropContentTypes: [UTType] = [.plainText]
    static let categoryDragPayloadPrefix = "papercodex-category-id:"

    static var categoryTreeFolderIconCenterX: CGFloat {
        categoryTreeFolderButtonLeadingPadding + categoryTreeFolderIconWidth / 2
    }

    static func categoryTreeFolderIconCenterX(depth: Int) -> CGFloat {
        categoryTreeFolderIconCenterX + CGFloat(depth) * categoryTreeIndentWidth
    }

    static func droppedCategoryID(from payload: String) -> String? {
        guard payload.hasPrefix(categoryDragPayloadPrefix) else {
            return nil
        }
        let categoryID = String(payload.dropFirst(categoryDragPayloadPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return categoryID.isEmpty ? nil : categoryID
    }
}

private struct PaperRow: View {
    var paper: Paper
    var categories: [PaperCodexCore.Category]
    var tags: [PaperTag]
    var thumbnailURLs: [URL]
    var sessionFooterText: String? = nil
    var sessionFooterSystemImage = "text.bubble"
    var isImportPlaceholder: Bool
    var placeholderDetail: String
    var isSelected: Bool
    var isMultiSelected: Bool
    var onToggleStar: () -> Void
    var onRead: () -> Void
    var onOpenSession: (() -> Void)? = nil

    @State private var isHovering = false
    @State private var isPressing = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            ThumbnailStrip(urls: Array(thumbnailURLs.prefix(LibraryLayout.paperRowThumbnailLimit)))
                .frame(width: 132, height: 54)
                .opacity(isImportPlaceholder ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 7) {
                Text(paper.title)
                    .font(.headline)
                    .foregroundStyle(isImportPlaceholder ? .secondary : .primary)
                    .lineLimit(2)
                Text(isImportPlaceholder ? placeholderDetail : (paper.authors.isEmpty ? "Authors not set" : paper.authors.joined(separator: ", ")))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let arxivDisplayID {
                        SmallChip(title: arxivDisplayID, systemImage: "number")
                    }
                    ForEach(categories.prefix(2)) { category in
                        SmallChip(title: category.name, systemImage: "folder")
                    }
                    ForEach(tags.prefix(3)) { tag in
                        SmallChip(title: tag.name, systemImage: "tag")
                    }
                }
                if let sessionFooterText {
                    Label(sessionFooterText, systemImage: sessionFooterSystemImage)
                        .font(.paperCodexSystem(size: 12.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let onOpenSession {
                PaperCodexIconButton(title: "Open Session", systemImage: "arrow.forward.circle", tint: .accentColor, disabled: isImportPlaceholder, action: onOpenSession)
            } else {
                PaperCodexIconButton(
                    title: paper.isStarred ? "Remove Star" : "Star Paper",
                    systemImage: paper.isStarred ? "star.fill" : "star",
                    tint: paper.isStarred ? .yellow : .secondary,
                    disabled: isImportPlaceholder,
                    action: onToggleStar
                )

                PaperCodexIconButton(title: "Read", systemImage: "book", tint: .secondary, disabled: isImportPlaceholder, action: onRead)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 21)
        .background(rowBackground)
        .opacity(isImportPlaceholder ? 0.66 : 1)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(rowBorderColor, lineWidth: isMultiSelected ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: rowShadowColor, radius: isPressing ? 4 : 6, y: isPressing ? 1 : 2)
        .scaleEffect(rowScale, anchor: .center)
        .overlay(alignment: .leading) {
            if isSelected || isMultiSelected || isPressing {
                Capsule()
                    .fill(Color.accentColor.opacity(leadingIndicatorOpacity))
                    .frame(width: 4)
                    .padding(.vertical, 12)
                    .padding(.leading, 4)
                    .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .onLongPressGesture(
            minimumDuration: .infinity,
            maximumDistance: 16,
            pressing: { isPressing in
                withAnimation(PaperCodexMotion.press) {
                    self.isPressing = isPressing && !isImportPlaceholder
                }
            },
            perform: {}
        )
        .animation(PaperCodexMotion.press, value: isPressing)
        .animation(PaperCodexMotion.hover, value: isHovering)
        .animation(PaperCodexMotion.selection, value: isSelected)
        .animation(PaperCodexMotion.selection, value: isMultiSelected)
        .onHover { hovering in
            withAnimation(PaperCodexMotion.hover) {
                isHovering = hovering
            }
        }
    }

    private var arxivDisplayID: String? {
        paper.arxivImportPlaceholderCanonicalID
            ?? paper.sourceURL.flatMap(ArxivIDExtractor.firstCanonicalID(in:))
    }

    private var rowBackground: Color {
        if isMultiSelected {
            return Color.accentColor.opacity(0.16)
        }
        if isPressing && !isImportPlaceholder {
            return Color.accentColor.opacity(0.12)
        }
        if isSelected {
            return Color.accentColor.opacity(0.10)
        }
        if isHovering {
            return Color(nsColor: .textBackgroundColor)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    private var rowBorderColor: Color {
        if isMultiSelected {
            return Color.accentColor.opacity(0.62)
        }
        if isPressing && !isImportPlaceholder {
            return Color.accentColor.opacity(0.48)
        }
        if isSelected {
            return Color.accentColor.opacity(0.38)
        }
        if isHovering {
            return Color.primary.opacity(0.10)
        }
        return Color.clear
    }

    private var rowShadowColor: Color {
        if isImportPlaceholder {
            return .clear
        }
        if isPressing {
            return Color.accentColor.opacity(0.12)
        }
        return isHovering ? Color.black.opacity(0.10) : .clear
    }

    private var rowScale: CGFloat {
        if isImportPlaceholder {
            return 1
        }
        return isPressing ? 0.992 : (isHovering ? 1.006 : 1)
    }

    private var leadingIndicatorOpacity: Double {
        if isMultiSelected {
            return 0.82
        }
        return isPressing ? 0.70 : 0.62
    }
}

private struct PaperDragPreview: View {
    var paper: Paper
    var selectedCount: Int = 1

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .font(.paperCodexSystem(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(paper.title)
                    .font(.paperCodexSystem(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(paper.authors.isEmpty ? "Authors not set" : paper.authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if selectedCount > 1 {
                    Text("\(selectedCount) papers")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.numericText())
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
        )
    }
}

private struct ThumbnailStrip: View {
    var urls: [URL]

    var body: some View {
        HStack(spacing: -18) {
            if urls.isEmpty {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(Color(nsColor: .windowBackgroundColor))
                    Image(systemName: "doc.richtext")
                        .foregroundStyle(.blue)
                }
                .frame(width: 42, height: 54)
            } else {
                let visibleURLs = Array(urls.prefix(LibraryLayout.paperRowThumbnailLimit))
                ForEach(Array(visibleURLs.enumerated()), id: \.offset) { index, url in
                    LocalThumbnailImage(url: url, maxPixelSize: LibraryLayout.paperRowThumbnailMaxPixelSize) {
                        Color(nsColor: .textBackgroundColor)
                    }
                    .padding(2)
                    .frame(width: 42, height: 54)
                    .background(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.black.opacity(0.12), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .zIndex(Double(visibleURLs.count - index))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SmallChip: View {
    var title: String
    var systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.paperCodexSystem(size: 12.5, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct LibraryMetadataBlock: View {
    var title: String
    var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.paperCodexSystem(size: 12.8))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}

private struct TagToggleChip: View {
    var tag: PaperTag
    var isAssigned: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(tag.name, systemImage: isAssigned ? "checkmark.circle.fill" : "circle")
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .tint(isAssigned ? .accentColor : .secondary)
    }
}

private struct SidebarEmptyText: View {
    var text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(LocalizedStringKey(text))
            .foregroundStyle(.secondary)
            .padding(.vertical, 5)
    }
}

private struct RecentConversationsContent: View {
    var sessions: [PaperSession]
    var papersBySessionID: [String: [Paper]]
    var categories: [PaperCodexCore.Category]
    var paperCategoryIDsByID: [String: [String]]
    var paperTagsByID: [String: [PaperTag]]
    var paperThumbnailURLsByID: [String: [URL]]
    @Binding var selectedSessionID: String?
    var placeholderDetail: (Paper) -> String
    var onOpen: (PaperSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Text("Recent Conversations")
                    .font(.paperCodexSystem(size: 28, weight: .semibold))
                Spacer()
            }

            if sessions.isEmpty {
                ContentUnavailableView("No Conversations", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(sessions) { session in
                            let sessionPapers = papers(for: session)
                            RecentConversationRow(
                                session: session,
                                papers: sessionPapers,
                                categories: categories,
                                paperCategoryIDsByID: paperCategoryIDsByID,
                                paperTagsByID: paperTagsByID,
                                paperThumbnailURLsByID: paperThumbnailURLsByID,
                                isSelected: selectedSessionID == session.id,
                                placeholderDetail: placeholderDetail,
                                onSelect: {
                                    selectedSessionID = session.id
                                },
                                onOpen: {
                                    onOpen(session)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(24)
    }

    private func papers(for session: PaperSession) -> [Paper] {
        let visiblePapers = papersBySessionID[session.id, default: []]
        let orderedPapers = session.paperIDs.compactMap { paperID in
            visiblePapers.first { $0.id == paperID }
        }
        return orderedPapers.isEmpty ? visiblePapers : orderedPapers
    }
}

private struct RecentConversationRow: View {
    @State private var isHovering = false

    var session: PaperSession
    var papers: [Paper]
    var categories: [PaperCodexCore.Category]
    var paperCategoryIDsByID: [String: [String]]
    var paperTagsByID: [String: [PaperTag]]
    var paperThumbnailURLsByID: [String: [URL]]
    var isSelected: Bool
    var placeholderDetail: (Paper) -> String
    var onSelect: () -> Void
    var onOpen: () -> Void

    var body: some View {
        Group {
            if let displayPaper {
                PaperRow(
                    paper: displayPaper,
                    categories: categories(for: displayPaper),
                    tags: paperTagsByID[displayPaper.id, default: []],
                    thumbnailURLs: thumbnailURLs,
                    sessionFooterText: renamedSessionFooterText,
                    isImportPlaceholder: displayPaper.isArxivImportPlaceholder,
                    placeholderDetail: placeholderDetail(displayPaper),
                    isSelected: isSelected,
                    isMultiSelected: false,
                    onToggleStar: {},
                    onRead: {},
                    onOpenSession: onOpen
                )
            } else {
                missingPaperRow
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .help(session.title)
        .onHover { hovering in
            withAnimation(PaperCodexMotion.hover) {
                isHovering = hovering
            }
        }
    }

    private var displayPaper: Paper? {
        session.paperIDs.compactMap { paperID in
            papers.first { $0.id == paperID }
        }.first ?? papers.first
    }

    private var missingPaperRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: session.paperIDs.count > 1 ? "square.stack.3d.up.fill" : "doc.text")
                .font(.paperCodexSystem(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 132, height: 54)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("\(session.paperIDs.count) paper\(session.paperIDs.count == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            PaperCodexIconButton(title: "Open Session", systemImage: "arrow.forward.circle", tint: .accentColor, action: onOpen)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 21)
        .background(isSelected ? Color.accentColor.opacity(0.10) : (isHovering ? Color(nsColor: .textBackgroundColor) : Color(nsColor: .controlBackgroundColor)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.38) : (isHovering ? Color.primary.opacity(0.10) : Color.clear), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var thumbnailURLs: [URL] {
        guard let displayPaper else {
            return []
        }
        let orderedPapers = session.paperIDs.compactMap { paperID in
            papers.first { $0.id == paperID }
        }
        guard orderedPapers.count > 1 else {
            return paperThumbnailURLsByID[displayPaper.id, default: []]
        }
        let sessionThumbnails = orderedPapers.flatMap { paper in
            paperThumbnailURLsByID[paper.id, default: []].prefix(1)
        }
        return sessionThumbnails.isEmpty ? paperThumbnailURLsByID[displayPaper.id, default: []] : sessionThumbnails
    }

    private var renamedSessionFooterText: String? {
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty,
              trimmedTitle != defaultSessionTitle else {
            return nil
        }
        return "Session: \(trimmedTitle)"
    }

    private var defaultSessionTitle: String {
        guard let displayPaper else {
            return "Paper Notes"
        }
        guard session.paperIDs.count > 1 else {
            return "\(displayPaper.title) Notes"
        }
        return "\(displayPaper.title) + \(session.paperIDs.count - 1) Notes"
    }

    private func categories(for paper: Paper) -> [PaperCodexCore.Category] {
        let ids = Set(paperCategoryIDsByID[paper.id, default: []])
        return categories.filter { ids.contains($0.id) }
    }
}

private struct RecentConversationDetailPanel: View {
    @State private var isOpenButtonHovering = false

    var session: PaperSession?
    var papers: [Paper]
    var onOpen: (PaperSession) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Conversation Details")
                .font(.paperCodexSystem(size: 20, weight: .semibold))

            if let session {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: session.paperIDs.count > 1 ? "square.stack.3d.up.fill" : "doc.text")
                                    .foregroundStyle(Color.accentColor)
                                Text(session.title)
                                    .font(.headline)
                                    .lineLimit(3)
                            }
                            Text("\(session.paperIDs.count) paper\(session.paperIDs.count == 1 ? "" : "s")")
                                .foregroundStyle(.secondary)
                            Text(Self.relativeFormatter.localizedString(for: session.updatedAt, relativeTo: Date()))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                        }

                        Button {
                            onOpen(session)
                        } label: {
                            Label("Open Session", systemImage: "arrow.forward.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RecentConversationDetailOpenButtonStyle(isHovering: isOpenButtonHovering))
                        .onHover { hovering in
                            withAnimation(PaperCodexMotion.hover) {
                                isOpenButtonHovering = hovering
                            }
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 10) {
                            Label("Papers", systemImage: "doc.on.doc")
                                .font(.headline)
                            if papers.isEmpty {
                                SidebarEmptyText("No papers")
                            } else {
                                ForEach(papers) { paper in
                                    HStack(alignment: .top, spacing: 8) {
                                        Image(systemName: "doc.text")
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(paper.title)
                                                .font(.paperCodexSystem(size: 13, weight: .semibold))
                                                .lineLimit(2)
                                            Text(paper.authors.isEmpty ? "Authors not set" : paper.authors.joined(separator: ", "))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.trailing, 4)
                }
            } else {
                ContentUnavailableView("Select Conversation", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Spacer(minLength: 0)
        }
        .padding(22)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

private struct RecentConversationDetailOpenButtonStyle: ButtonStyle {
    var isHovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = configuration.isPressed
        configuration.label
            .font(.paperCodexSystem(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(Color.white)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(backgroundColor(isPressed: isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(isPressed ? 0.64 : 0.36), lineWidth: 1)
            )
            .shadow(color: Color.accentColor.opacity(shadowOpacity(isPressed: isPressed)), radius: isPressed ? 4 : 7, y: isPressed ? 1 : 3)
            .scaleEffect(isPressed ? 0.985 : (isHovering ? 1.012 : 1), anchor: .center)
            .animation(PaperCodexMotion.press, value: configuration.isPressed)
            .animation(PaperCodexMotion.hover, value: isHovering)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.accentColor.opacity(0.86)
        }
        return Color.accentColor.opacity(isHovering ? 0.96 : 0.92)
    }

    private func shadowOpacity(isPressed: Bool) -> Double {
        if isPressed {
            return 0.14
        }
        return isHovering ? 0.22 : 0.16
    }
}

private struct BulkLibraryActionBar: View {
    var selectedCount: Int
    var canMove: Bool
    var canTag: Bool
    var canOpenConversation: Bool
    var onRead: () -> Void
    var onChat: () -> Void
    var onCopy: () -> Void
    var onTag: () -> Void
    var onDelete: () -> Void
    var onClear: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Label("\(selectedCount) selected", systemImage: "checkmark.circle.fill")
                .font(.paperCodexSystem(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .contentTransition(.numericText())
            Spacer()
            Button(action: onRead) {
                Label("Read", systemImage: "book")
            }
            .disabled(!canOpenConversation)
            .help("Read selected papers together")
            Button(action: onChat) {
                Label("Chat", systemImage: "text.bubble")
            }
            .disabled(!canOpenConversation)
            .help("Chat with selected papers together")
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .disabled(!canMove)
            .help("Copy selected papers to a folder")
            Button(action: onTag) {
                Label("Tag", systemImage: "tag")
            }
            .disabled(!canTag)
            .help("Add tags to selected papers")
            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .help("Delete selected papers")
            Button(action: onClear) {
                Label("Clear", systemImage: "xmark.circle")
            }
            .help("Clear selection")
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.accentColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
    }
}

private struct LibraryBulkCopySheet: View {
    var categoryItems: [CategoryListItem]
    var selectedCount: Int
    var onCopy: (String?) -> Void
    var onCancel: () -> Void

    @State private var targetCategoryID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Copy Papers", systemImage: "doc.on.doc")
                .font(.title3.weight(.semibold))
            Text("\(selectedCount) selected papers")
                .foregroundStyle(.secondary)
            Picker("Destination", selection: $targetCategoryID) {
                Text("No folder").tag("")
                ForEach(categoryItems) { item in
                    Text(String(repeating: "  ", count: item.depth) + item.category.name)
                        .tag(item.category.id)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button {
                    onCopy(targetCategoryID.isEmpty ? nil : targetCategoryID)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(targetCategoryID.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

private struct LibraryBulkTagSheet: View {
    var tags: [PaperTag]
    var selectedCount: Int
    var onApply: ([String]) -> Void
    var onCancel: () -> Void

    @State private var selectedTagIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Add Tags", systemImage: "tag")
                .font(.title3.weight(.semibold))
            Text("\(selectedCount) selected papers")
                .foregroundStyle(.secondary)
            if tags.isEmpty {
                ContentUnavailableView("No Tags", systemImage: "tag")
                    .frame(width: 380, height: 120)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 126), spacing: 8)], alignment: .leading, spacing: 8) {
                    ForEach(tags) { tag in
                        Button {
                            toggle(tag.id)
                        } label: {
                            Label(tag.name, systemImage: selectedTagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.bordered)
                        .tint(selectedTagIDs.contains(tag.id) ? .accentColor : .secondary)
                    }
                }
                .frame(width: 420)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button {
                    onApply(Array(selectedTagIDs))
                } label: {
                    Label("Apply", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedTagIDs.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 470)
    }

    private func toggle(_ tagID: String) {
        if selectedTagIDs.contains(tagID) {
            selectedTagIDs.remove(tagID)
        } else {
            selectedTagIDs.insert(tagID)
        }
    }
}

private enum LibrarySortOption: String, CaseIterable, Identifiable {
    case addedNewest
    case title
    case arxivID

    var id: String { rawValue }

    var title: String {
        switch self {
        case .addedNewest:
            "Added"
        case .title:
            "Title"
        case .arxivID:
            "arXiv ID"
        }
    }

    var systemImage: String {
        switch self {
        case .addedNewest:
            "clock.arrow.circlepath"
        case .title:
            "textformat"
        case .arxivID:
            "number"
        }
    }

    func sorted(_ papers: [Paper], ascending: Bool) -> [Paper] {
        let arxivIDsByPaperID: [String: String]
        if self == .arxivID {
            arxivIDsByPaperID = Dictionary(
                uniqueKeysWithValues: papers.compactMap { paper in
                    arxivID(for: paper).map { (paper.id, $0) }
                }
            )
        } else {
            arxivIDsByPaperID = [:]
        }

        return papers.sorted { left, right in
            if left.isStarred != right.isStarred {
                return left.isStarred
            }
            switch self {
            case .addedNewest:
                if left.importedAt != right.importedAt {
                    return ascending ? left.importedAt < right.importedAt : left.importedAt > right.importedAt
                }
                return titleComesBefore(left, right, ascending: true)
            case .title:
                return titleComesBefore(left, right, ascending: ascending)
            case .arxivID:
                return arxivIDComesBefore(left, right, ascending: ascending, arxivIDsByPaperID: arxivIDsByPaperID)
            }
        }
    }

    private func titleComesBefore(_ left: Paper, _ right: Paper, ascending: Bool) -> Bool {
        let titleComparison = left.title.localizedStandardCompare(right.title)
        if titleComparison != .orderedSame {
            return ascending ? titleComparison == .orderedAscending : titleComparison == .orderedDescending
        }
        return left.id < right.id
    }

    private func arxivIDComesBefore(
        _ left: Paper,
        _ right: Paper,
        ascending: Bool,
        arxivIDsByPaperID: [String: String]
    ) -> Bool {
        let leftID = arxivIDsByPaperID[left.id]
        let rightID = arxivIDsByPaperID[right.id]
        switch (leftID, rightID) {
        case let (leftID?, rightID?):
            let comparison = leftID.localizedStandardCompare(rightID)
            if comparison != .orderedSame {
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }
            return titleComesBefore(left, right, ascending: true)
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return titleComesBefore(left, right, ascending: true)
        }
    }

    private func arxivID(for paper: Paper) -> String? {
        paper.arxivImportPlaceholderCanonicalID
            ?? paper.sourceURL.flatMap(ArxivIDExtractor.firstCanonicalID(in:))
    }
}

private struct LibraryArxivImportSheet: View {
    @EnvironmentObject private var model: AppModel
    var categoryItems: [CategoryListItem]
    var onClose: () -> Void

    @State private var inputText = ""
    @State private var targetCategoryID: String
    @FocusState private var isInputFocused: Bool

    init(categoryItems: [CategoryListItem], initialCategoryID: String?, onClose: @escaping () -> Void) {
        self.categoryItems = categoryItems
        self.onClose = onClose
        _targetCategoryID = State(initialValue: initialCategoryID ?? "")
    }

    private var parsedIDs: [String] {
        ArxivIDExtractor.extractVersionedIDs(from: inputText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Add arXiv Papers", systemImage: "number")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Close", action: onClose)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: $inputText)
                    .font(.paperCodexSystem(size: 13, design: .monospaced))
                    .frame(minHeight: 110)
                    .focused($isInputFocused)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
                    )
                if parsedIDs.isEmpty {
                    Text("Paste arXiv IDs, links, PDFs, or any text containing one or more IDs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(parsedIDs, id: \.self) { id in
                            Text(id)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                }
            }

            Picker("Folder", selection: $targetCategoryID) {
                Text("No folder").tag("")
                ForEach(categoryItems) { item in
                    Text(String(repeating: "  ", count: item.depth) + item.category.name)
                        .tag(item.category.id)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onClose)
                Button {
                    let ids = parsedIDs
                    model.enqueueArxivIDsForLibrary(
                        ids,
                        categoryID: targetCategoryID.isEmpty ? nil : targetCategoryID
                    )
                    onClose()
                } label: {
                    Label("Add", systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(parsedIDs.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 540)
        .onAppear {
            isInputFocused = true
        }
    }

}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct CategorySidebarRow: View {
    @State private var isHovering = false
    @State private var isDropTargeted = false
    @State private var dropPlacement: LibraryCategoryDropPlacement?

    var title: String
    var countText: String
    var systemImage: String
    var isSelected: Bool
    var depth: Int
    var connectorContinuations: [Bool]
    var hasChildren: Bool
    var isExpanded: Bool
    var isPinned: Bool
    var categoryDragPayload: String
    var onDragCategory: () -> Void
    var canDropCategory: (LibraryCategoryDropPlacement) -> Bool
    var onPreviewCategoryDrop: (LibraryCategoryDropPlacement) -> Void
    var onCategoryDropExited: () -> Void
    var onToggle: () -> Void
    var onSelect: () -> Void
    var onCreateChild: () -> Void
    var onManage: () -> Void
    var onTogglePinned: () -> Void
    var onDropPapers: ([String]) -> Void
    var onDropCategory: (String, LibraryCategoryDropPlacement) -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            HStack(spacing: 8) {
                Button(action: toggleFolderExpansion) {
                    Image(systemName: folderIconName)
                        .frame(width: 17)
                        .foregroundStyle(isSelected || isExpanded ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
                .help(folderIconHelp)

                Button(action: onSelect) {
                    HStack(spacing: 0) {
                        Text(title)
                            .font(.paperCodexSystem(size: 13, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                        Spacer(minLength: 58)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(title)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.13) : (isHovering ? Color.primary.opacity(0.045) : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor.opacity(0.22) : Color.clear, lineWidth: 1)
            )
            .padding(.leading, CGFloat(depth) * LibraryLayout.categoryTreeIndentWidth)
            .frame(minHeight: LibraryLayout.categoryTreeConnectorHeight)
            .background(alignment: .leading) {
                CategoryTreeConnector(
                    depth: depth,
                    connectorContinuations: connectorContinuations
                )
                .allowsHitTesting(false)
            }

            if isDropActive {
                Label(dropLabel, systemImage: dropIconName)
                    .font(.paperCodexSystem(size: 11, weight: .semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .foregroundStyle(Color.accentColor)
                    .background(Capsule().fill(Color.accentColor.opacity(0.16)))
                    .padding(.trailing, 6)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                HStack(spacing: 3) {
                    Text(countText)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    if isHovering || isSelected {
                        Button(action: onCreateChild) {
                            Image(systemName: "plus")
                                .font(.paperCodexSystem(size: 11, weight: .semibold))
                                .frame(width: 22, height: 22)
                                .foregroundStyle(Color.accentColor)
                                .background(Circle().fill(Color.accentColor.opacity(isHovering ? 0.16 : 0.10)))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("New subcategory under \(title)")

                        Button(action: onTogglePinned) {
                            Image(systemName: isPinned ? "pin.fill" : "pin")
                                .font(.paperCodexSystem(size: 11, weight: .bold))
                                .frame(width: 22, height: 22)
                                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(isPinned ? "Unpin \(title)" : "Pin \(title)")

                        Button(action: onManage) {
                            Image(systemName: "ellipsis")
                                .font(.paperCodexSystem(size: 11, weight: .bold))
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.plain)
                        .help("Manage \(title)")
                    }
                }
                .padding(.trailing, 6)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropActive ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isDropActive ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1.5)
        )
        .overlay(alignment: dropLineAlignment) {
            if dropPlacement == .before || dropPlacement == .after {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(height: 2)
                    .padding(.leading, CGFloat(depth) * LibraryLayout.categoryTreeIndentWidth + 8)
                    .padding(.trailing, 8)
                    .transition(.opacity)
            }
        }
        .scaleEffect(isDropActive ? 1.02 : 1, anchor: .center)
        .animation(PaperCodexMotion.hover, value: isHovering)
        .animation(PaperCodexMotion.selection, value: isSelected)
        .animation(PaperCodexMotion.hover, value: isDropActive)
        .animation(.easeOut(duration: 0.10), value: dropPlacement)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onDrag {
            onDragCategory()
            return NSItemProvider(object: categoryDragPayload as NSString)
        }
        .onDrop(
            of: LibraryLayout.categoryDropContentTypes,
            delegate: CategorySidebarDropDelegate(
                isTargeted: $isDropTargeted,
                placement: $dropPlacement,
                canDrop: canDropCategory,
                onPreviewDrop: onPreviewCategoryDrop,
                onDropExited: onCategoryDropExited,
                onDrop: loadDroppedItems(from:placement:)
            )
        )
        .help("Drop papers or folders into \(title)")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }

    private var isDropActive: Bool {
        isDropTargeted
    }

    private var dropLabel: String {
        switch dropPlacement {
        case .before:
            "Before"
        case .after:
            "After"
        case .inside, .none:
            "Drop"
        }
    }

    private var dropIconName: String {
        switch dropPlacement {
        case .before, .after:
            "arrow.up.arrow.down"
        case .inside, .none:
            "arrow.down.doc"
        }
    }

    private var dropLineAlignment: Alignment {
        dropPlacement == .after ? .bottom : .top
    }

    private var folderIconName: String {
        hasChildren ? (isExpanded ? "folder.fill" : "folder") : systemImage
    }

    private var folderIconHelp: String {
        guard hasChildren else {
            return title
        }
        return isExpanded ? "Collapse \(title)" : "Expand \(title)"
    }

    private func toggleFolderExpansion() {
        if hasChildren {
            onToggle()
        } else {
            onSelect()
        }
    }

    private func loadDroppedItems(from providers: [NSItemProvider], placement: LibraryCategoryDropPlacement) -> Bool {
        let textProviders = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !textProviders.isEmpty else {
            return false
        }
        for provider in textProviders {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let payload = (object as? NSString).map(String.init) else {
                    return
                }
                let trimmedPayload = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                if let droppedCategoryID = LibraryLayout.droppedCategoryID(from: trimmedPayload) {
                    DispatchQueue.main.async {
                        onDropCategory(droppedCategoryID, placement)
                    }
                    return
                }
                let paperIDs = trimmedPayload
                    .components(separatedBy: .whitespacesAndNewlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard !paperIDs.isEmpty else {
                    return
                }
                DispatchQueue.main.async {
                    onDropPapers(paperIDs)
                }
            }
        }
        return true
    }
}

private struct LibraryRootFolderDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    var canDropCategory: () -> Bool
    var onDrop: ([NSItemProvider]) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: LibraryLayout.categoryDropContentTypes) && canDropCategory()
    }

    func dropEntered(info: DropInfo) {
        isTargeted = updateDropState(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        isTargeted = updateDropState(info: info)
        return isTargeted ? DropProposal(operation: .move) : nil
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func performDrop(info: DropInfo) -> Bool {
        guard canDropCategory() else {
            isTargeted = false
            return false
        }
        isTargeted = false
        return onDrop(info.itemProviders(for: LibraryLayout.categoryDropContentTypes))
    }

    private func updateDropState(info _: DropInfo) -> Bool {
        if isTargeted {
            return true
        }
        return canDropCategory()
    }
}

private struct CategorySidebarDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    @Binding var placement: LibraryCategoryDropPlacement?
    var canDrop: (LibraryCategoryDropPlacement) -> Bool
    var onPreviewDrop: (LibraryCategoryDropPlacement) -> Void
    var onDropExited: () -> Void
    var onDrop: ([NSItemProvider], LibraryCategoryDropPlacement) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: LibraryLayout.categoryDropContentTypes) && validPlacement(for: info) != nil
    }

    func dropEntered(info: DropInfo) {
        _ = updateDropState(info: info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateDropState(info: info) == nil ? nil : DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        placement = nil
        onDropExited()
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let finalPlacement = validPlacement(for: info) else {
            isTargeted = false
            placement = nil
            return false
        }
        isTargeted = false
        placement = nil
        return onDrop(info.itemProviders(for: LibraryLayout.categoryDropContentTypes), finalPlacement)
    }

    private func updateDropState(info: DropInfo) -> LibraryCategoryDropPlacement? {
        let candidatePlacement = placement(for: info)
        if isTargeted, placement == candidatePlacement {
            return candidatePlacement
        }
        guard canDrop(candidatePlacement) else {
            isTargeted = false
            placement = nil
            return nil
        }
        let validPlacement = candidatePlacement
        isTargeted = true
        placement = validPlacement
        onPreviewDrop(validPlacement)
        return validPlacement
    }

    private func validPlacement(for info: DropInfo) -> LibraryCategoryDropPlacement? {
        let placement = placement(for: info)
        return canDrop(placement) ? placement : nil
    }

    private func placement(for info: DropInfo) -> LibraryCategoryDropPlacement {
        let rowHeight = max(LibraryLayout.categoryTreeConnectorHeight, 1)
        let y = min(max(info.location.y, 0), rowHeight)
        if y < rowHeight * 0.28 {
            return .before
        }
        if y > rowHeight * 0.72 {
            return .after
        }
        return .inside
    }
}

private struct CategoryTreeConnector: View {
    var depth: Int
    var connectorContinuations: [Bool]

    var body: some View {
        if depth == 0 || connectorContinuations.isEmpty {
            Color.clear
                .frame(height: LibraryLayout.categoryTreeConnectorHeight)
        } else {
            TreeConnectorLevel(
                depth: depth,
                connectorContinuations: connectorContinuations
            )
            .stroke(
                Color.primary.opacity(LibraryLayout.categoryTreeConnectorOpacity),
                style: StrokeStyle(
                    lineWidth: LibraryLayout.categoryTreeConnectorLineWidth,
                    lineCap: .butt,
                    lineJoin: .round
                )
            )
            .frame(
                width: LibraryLayout.categoryTreeFolderIconCenterX(depth: depth) + 1,
                height: LibraryLayout.categoryTreeConnectorHeight
            )
        }
    }
}

private struct TreeConnectorLevel: Shape {
    var depth: Int
    var connectorContinuations: [Bool]

    func path(in rect: CGRect) -> Path {
        Path { path in
            let midY = rect.midY
            let currentIconX = LibraryLayout.categoryTreeFolderIconCenterX(depth: depth)
            let currentTargetX = currentIconX - LibraryLayout.categoryTreeConnectorTargetInset
            let parentIconX = LibraryLayout.categoryTreeFolderIconCenterX(depth: depth - 1)
            let currentBranchContinues = connectorContinuations.indices.contains(depth - 1)
                ? connectorContinuations[depth - 1]
                : false

            if depth > 1 {
                for level in 0..<(depth - 1) where connectorContinuations.indices.contains(level) && connectorContinuations[level] {
                    let ancestorIconX = LibraryLayout.categoryTreeFolderIconCenterX(depth: level)
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

private struct TagSidebarRow: View {
    @State private var isHovering = false

    var title: String
    var countText: String
    var isSelected: Bool
    var onSelect: () -> Void
    var onManage: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            SidebarRowButton(
                title: title,
                systemImage: isSelected ? "tag.fill" : "tag",
                selected: isSelected,
                trailingReserve: 58,
                action: onSelect
            )
            HStack(spacing: 4) {
                Text(countText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                if isHovering || isSelected {
                    Button(action: onManage) {
                        Image(systemName: "ellipsis")
                            .font(.paperCodexSystem(size: 11, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Manage \(title)")
                }
            }
            .padding(.trailing, 6)
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
    }
}

private struct CategoryManagementSheet: View {
    var category: PaperCodexCore.Category
    var categoryItems: [CategoryListItem]
    var onSave: (String, String?) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var name: String
    @State private var parentID: String

    init(
        category: PaperCodexCore.Category,
        categoryItems: [CategoryListItem],
        onSave: @escaping (String, String?) -> Void,
        onDelete: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.category = category
        self.categoryItems = categoryItems
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: category.name)
        _parentID = State(initialValue: category.parentID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Manage Category", systemImage: "folder")
                .font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            Picker("Parent", selection: $parentID) {
                Text("Top Level").tag("")
                ForEach(categoryItems) { item in
                    Text(String(repeating: "  ", count: item.depth) + item.category.name)
                        .tag(item.category.id)
                }
            }
            HStack {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(name, parentID.isEmpty ? nil : parentID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 390)
    }
}

private struct TagManagementSheet: View {
    var tag: PaperTag
    var onSave: (String) -> Void
    var onDelete: () -> Void
    var onCancel: () -> Void

    @State private var name: String

    init(tag: PaperTag, onSave: @escaping (String) -> Void, onDelete: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.tag = tag
        self.onSave = onSave
        self.onDelete = onDelete
        self.onCancel = onCancel
        _name = State(initialValue: tag.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Manage Tag", systemImage: "tag")
                .font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save") {
                    onSave(name)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 340)
    }
}

private struct PaperNoteRow: View {
    var note: PaperNote
    var onEdit: () -> Void
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button(action: onEdit) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title)
                        .font(.paperCodexSystem(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !note.bodyMarkdown.isEmpty {
                        Text(note.bodyMarkdown)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Delete Note")
        }
        .padding(9)
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

private struct CategoryEditorSheet: View {
    var categoryItems: [CategoryListItem]
    @Binding var name: String
    @Binding var parentID: String
    var onCreate: (String, String) -> Void
    var onCancel: () -> Void
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Category")
                .font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
            Picker("Parent", selection: $parentID) {
                Text("Top Level").tag("")
                ForEach(categoryItems) { item in
                    Text(String(repeating: "  ", count: item.depth) + item.category.name)
                        .tag(item.category.id)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Create") {
                    onCreate(name, parentID)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onAppear {
            isNameFocused = true
        }
    }
}

private struct TagEditorSheet: View {
    @Binding var name: String
    var onCreate: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Tag")
                .font(.title3.weight(.semibold))
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Create") {
                    onCreate(name)
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 320)
    }
}
