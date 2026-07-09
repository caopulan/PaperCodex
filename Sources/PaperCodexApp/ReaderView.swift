import PaperCodexCore
import SwiftUI

struct ReaderView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowingAddPaperToSessionSheet = false
    @State private var isPDFSplitVisible = false
    @State private var pdfSplitTarget: PDFInternalLinkTarget?
    @State private var pendingPDFSplitTarget: PDFInternalLinkTarget?
    @State private var isPDFSplitContentReady = false
    @State private var pdfSplitOpenGeneration = 0

    var body: some View {
        ZStack {
            if model.isReaderTabContentLoading {
                ReaderTabLoadingView(title: model.activeReaderTabTitle)
            } else {
                HSplitView {
                    pdfPane
                        .frame(minWidth: ReaderPDFLayout.minimumPaneWidth, maxWidth: .infinity)
                    ChatView()
                        .frame(minWidth: 330, idealWidth: 420, maxWidth: .infinity)
                }
                .transition(.opacity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.selectedPaper?.id) { _, _ in
            resetPDFSplit()
        }
        .sheet(isPresented: $isShowingAddPaperToSessionSheet) {
            AddPaperToSessionSheet(
                papers: model.papers.filter { paper in
                    !paper.isArxivImportPlaceholder && !model.currentSessionPapers.contains(where: { $0.id == paper.id })
                },
                onAdd: { paper in
                    model.addPaperToCurrentSession(paper)
                    isShowingAddPaperToSessionSheet = false
                },
                onCancel: {
                    isShowingAddPaperToSessionSheet = false
                }
            )
        }
    }

    private var pdfPane: some View {
        ZStack {
            if let paper = model.selectedPaper {
                VStack(spacing: 0) {
                    ReaderPDFToolbar(
                        status: model.pdfDocumentStatus,
                        papers: model.currentSessionPapers,
                        activePaperID: model.readerTabState.activePaperID ?? model.selectedPaper?.id,
                        returnPoint: model.citationReturnPoint,
                        isSplitVisible: isPDFSplitVisible,
                        onSelectPaper: { paper in
                            model.selectReaderPaper(paper)
                        },
                        onAddPaper: {
                            isShowingAddPaperToSessionSheet = true
                        },
                        onRemoveActivePaper: {
                            if let paperID = model.selectedPaper?.id {
                                model.removePaperFromCurrentSession(paperID)
                            }
                        },
                        onCommand: { model.sendPDFKitCommand($0) },
                        onReturn: { model.returnFromCitationJump() },
                        onToggleSplit: { togglePDFSplit() }
                    )
                    Divider()
                    pdfContent(for: paper)
                }
            } else {
                ContentUnavailableView("No Paper Selected", systemImage: "doc.text")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder
    private func pdfContent(for paper: Paper) -> some View {
        Group {
            if isPDFSplitVisible {
                VSplitView {
                    primaryPDFView(for: paper)
                        .frame(minHeight: ReaderPDFLayout.minimumSplitPaneHeight, maxHeight: .infinity)
                    secondaryPDFView(for: paper)
                        .frame(minHeight: ReaderPDFLayout.minimumSplitPaneHeight, maxHeight: .infinity)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                primaryPDFView(for: paper)
                    .transition(.opacity)
            }
        }
        .animation(PaperCodexMotion.accessible(PaperCodexMotion.pdfSplitOpen, reduceMotion: reduceMotion), value: isPDFSplitVisible)
        .animation(PaperCodexMotion.accessible(PaperCodexMotion.pdfSplitContent, reduceMotion: reduceMotion), value: isPDFSplitContentReady)
    }

    private func primaryPDFView(for paper: Paper) -> some View {
        PDFKitView(
            filePath: paper.filePath,
            jumpTarget: model.pdfJumpTarget,
            readingContextID: model.readerPositionContextID,
            readingPosition: model.readerPosition,
            command: model.pdfKitCommand,
            internalLinkTarget: nil,
            onSelection: { selection in
                model.updateSelection(selection)
            },
            onReadingPositionChange: { position in
                model.updateReaderPosition(position)
            },
            onDocumentStatusChange: { status in
                model.updatePDFDocumentStatus(status)
            },
            onInternalLinkSplit: { target in
                openPDFSplit(target)
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func secondaryPDFView(for paper: Paper) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Link Preview", systemImage: "rectangle.split.2x1")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    closePDFSplit()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Close Split")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            ZStack {
                if isPDFSplitContentReady {
                    PDFKitView(
                        filePath: paper.filePath,
                        jumpTarget: nil,
                        readingContextID: "split-\(paper.id)",
                        readingPosition: nil,
                        command: nil,
                        internalLinkTarget: pdfSplitTarget,
                        onSelection: { selection in
                            model.updateSelection(selection)
                        },
                        onReadingPositionChange: { _ in },
                        onDocumentStatusChange: { _ in },
                        onInternalLinkSplit: { target in
                            openPDFSplit(target)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
                } else {
                    PDFSplitPreparingView(target: pendingPDFSplitTarget ?? pdfSplitTarget)
                        .transition(.opacity)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func openPDFSplit(_ target: PDFInternalLinkTarget) {
        guard !isPDFSplitVisible else {
            if isPDFSplitContentReady {
                PaperCodexMotion.perform(PaperCodexMotion.pdfSplitContent, reduceMotion: reduceMotion) {
                    pdfSplitTarget = target
                }
            } else {
                pendingPDFSplitTarget = target
            }
            return
        }
        beginPDFSplitOpen(target: target)
    }

    private func closePDFSplit() {
        pdfSplitOpenGeneration += 1
        PaperCodexMotion.perform(PaperCodexMotion.pdfSplitOpen, reduceMotion: reduceMotion) {
            isPDFSplitVisible = false
            isPDFSplitContentReady = false
        }
        pendingPDFSplitTarget = nil
        pdfSplitTarget = nil
    }

    private func resetPDFSplit() {
        pdfSplitOpenGeneration += 1
        isPDFSplitVisible = false
        isPDFSplitContentReady = false
        pendingPDFSplitTarget = nil
        pdfSplitTarget = nil
    }

    private func togglePDFSplit() {
        if isPDFSplitVisible {
            closePDFSplit()
        } else {
            beginPDFSplitOpen(target: nil)
        }
    }

    private func beginPDFSplitOpen(target: PDFInternalLinkTarget?) {
        pdfSplitOpenGeneration += 1
        let generation = pdfSplitOpenGeneration
        pendingPDFSplitTarget = target
        isPDFSplitContentReady = false
        pdfSplitTarget = nil

        PaperCodexMotion.perform(PaperCodexMotion.pdfSplitOpen, reduceMotion: reduceMotion) {
            isPDFSplitVisible = true
        }
        schedulePDFSplitContentMount(generation: generation)
    }

    private func schedulePDFSplitContentMount(generation: Int) {
        let delay = reduceMotion ? 0 : ReaderPDFLayout.splitContentMountDelay
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard generation == pdfSplitOpenGeneration, isPDFSplitVisible else {
                return
            }
            let target = pendingPDFSplitTarget
            PaperCodexMotion.perform(PaperCodexMotion.pdfSplitContent, reduceMotion: reduceMotion) {
                pdfSplitTarget = target
                pendingPDFSplitTarget = nil
                isPDFSplitContentReady = true
            }
        }
    }
}

private enum ReaderPDFLayout {
    static let minimumPaneWidth: CGFloat = 360
    static let minimumSplitPaneHeight: CGFloat = 220
    static let splitContentMountDelay: TimeInterval = 0.20
}

private struct PDFSplitPreparingView: View {
    var target: PDFInternalLinkTarget?

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(LocalizedStringKey(target == nil ? "Preparing split view" : "Preparing link preview"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ReaderTabLoadingView: View {
    var title: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Loading paper")
                .font(.paperCodexSystem(size: 13, weight: .semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct AddPaperToSessionSheet: View {
    var papers: [Paper]
    var onAdd: (Paper) -> Void
    var onCancel: () -> Void

    @State private var query = ""

    private var filteredPapers: [Paper] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return papers
        }
        return papers.filter { paper in
            paper.title.localizedCaseInsensitiveContains(trimmed)
                || paper.authors.joined(separator: " ").localizedCaseInsensitiveContains(trimmed)
                || (paper.year.map(String.init) ?? "").contains(trimmed)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Add Paper", systemImage: "plus")
                .font(.title3.weight(.semibold))
            TextField("Search library", text: $query)
                .textFieldStyle(.roundedBorder)
            if filteredPapers.isEmpty {
                ContentUnavailableView("No Papers", systemImage: "doc.text.magnifyingglass")
                    .frame(width: 520, height: 220)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredPapers) { paper in
                            Button {
                                onAdd(paper)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc.text")
                                        .foregroundStyle(Color.accentColor)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(paper.title)
                                            .font(.headline)
                                            .lineLimit(1)
                                        Text(paper.authors.isEmpty ? "Authors not set" : paper.authors.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(width: 520, height: 280)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
            }
        }
        .padding(22)
        .frame(width: 560)
    }
}

private struct ReaderPDFToolbar: View {
    var status: PDFDocumentStatus?
    var papers: [Paper]
    var activePaperID: String?
    var returnPoint: CitationReturnPoint?
    var isSplitVisible: Bool
    var onSelectPaper: (Paper) -> Void
    var onAddPaper: () -> Void
    var onRemoveActivePaper: () -> Void
    var onCommand: (PDFKitCommandKind) -> Void
    var onReturn: () -> Void
    var onToggleSplit: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            PaperCodexIconButton(title: "Previous Page", systemImage: "chevron.up", tint: .secondary) {
                onCommand(.previousPage)
            }

            PaperCodexIconButton(title: "Next Page", systemImage: "chevron.down", tint: .secondary) {
                onCommand(.nextPage)
            }

            Text(pageText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
                .contentTransition(.numericText())

            Divider()
                .frame(height: 18)

            PaperCodexIconButton(title: "Zoom Out", systemImage: "minus.magnifyingglass", tint: .secondary) {
                onCommand(.zoomOut)
            }

            PaperCodexIconButton(title: "Zoom In", systemImage: "plus.magnifyingglass", tint: .secondary) {
                onCommand(.zoomIn)
            }

            PaperCodexIconButton(title: "Fit Width", systemImage: "arrow.left.and.right", tint: .secondary) {
                onCommand(.fitWidth)
            }

            Text(zoomText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
                .contentTransition(.numericText())

            Divider()
                .frame(height: 18)

            paperSelector

            PaperCodexIconButton(
                title: isSplitVisible ? "Close PDF Split" : "Open PDF Split",
                systemImage: isSplitVisible ? "rectangle.split.2x1.fill" : "rectangle.split.2x1",
                tint: isSplitVisible ? .accentColor : .secondary,
                action: onToggleSplit
            )
            .keyboardShortcut("\\", modifiers: [.command, .shift])

            Spacer()

            if let returnPoint {
                Button(action: onReturn) {
                    Label("Back to source", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(returnPoint.paperTitle)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var paperSelector: some View {
        HStack(spacing: 5) {
            Image(systemName: papers.count > 1 ? "square.stack.3d.up.fill" : "doc.text")
                .font(.paperCodexSystem(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("\(papers.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 14, alignment: .leading)
                .contentTransition(.numericText())

            Picker("Paper", selection: selectedPaperBinding) {
                ForEach(papers) { paper in
                    Text(paper.title)
                        .tag(paper.id)
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(minWidth: 130, idealWidth: 220, maxWidth: 260)
            .help(activePaperTitle)

            PaperCodexIconButton(title: "Add Paper", systemImage: "plus", tint: .secondary, action: onAddPaper)

            PaperCodexIconButton(
                title: "Remove Current Paper",
                systemImage: "xmark",
                tint: .secondary,
                disabled: papers.count <= 1,
                action: onRemoveActivePaper
            )
        }
        .layoutPriority(1)
    }

    private var selectedPaperBinding: Binding<String> {
        Binding(
            get: {
                activePaperID ?? ""
            },
            set: { paperID in
                guard let paper = papers.first(where: { $0.id == paperID }) else {
                    return
                }
                onSelectPaper(paper)
            }
        )
    }

    private var activePaperTitle: String {
        guard let activePaperID,
              let paper = papers.first(where: { $0.id == activePaperID }) else {
            return "Select Paper"
        }
        return paper.title
    }

    private var pageText: String {
        guard let status, status.pageCount > 0 else {
            return "Page --"
        }
        return "Page \(status.pageIndex + 1)/\(status.pageCount)"
    }

    private var zoomText: String {
        guard let status else {
            return "--%"
        }
        return "\(Int((status.scaleFactor * 100).rounded()))%"
    }
}
