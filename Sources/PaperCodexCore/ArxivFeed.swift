import Foundation

public struct ArxivFeedDateIndex: Codable, Equatable, Sendable {
    public var dates: [String]
    public var latest: String?

    public init(dates: [String], latest: String?) {
        self.dates = dates
        self.latest = latest
    }
}

public struct ArxivFeedResponse: Codable, Equatable, Sendable {
    public var date: String
    public var count: Int
    public var papers: [ArxivFeedPaper]
    public var groups: [ArxivFeedGroup]?
    public var tagOptions: [String]?
    public var sourceCategories: [String]?

    public init(
        date: String,
        count: Int,
        papers: [ArxivFeedPaper],
        groups: [ArxivFeedGroup]? = nil,
        tagOptions: [String]? = nil,
        sourceCategories: [String]? = nil
    ) {
        self.date = date
        self.count = count
        self.papers = papers
        self.groups = groups
        self.tagOptions = tagOptions
        self.sourceCategories = Self.normalizedSourceCategories(sourceCategories)
    }

    private enum CodingKeys: String, CodingKey {
        case date
        case count
        case papers
        case groups
        case tagOptions = "tag_options"
        case sourceCategories = "source_categories"
    }

    private static func normalizedSourceCategories(_ values: [String]?) -> [String]? {
        guard let values else {
            return nil
        }
        let normalized = LocalArxivClient.normalizedSearchCategories(values)
        return normalized.isEmpty ? nil : normalized
    }

    public var normalizedSourceCategories: [String]? {
        Self.normalizedSourceCategories(sourceCategories)
    }

    public func coversSourceCategories(_ categories: [String]) -> Bool {
        let target = Set(LocalArxivClient.normalizedSearchCategories(categories).map { $0.lowercased() })
        guard !target.isEmpty else {
            return true
        }
        guard let sourceCategories = normalizedSourceCategories else {
            return false
        }
        let source = Set(sourceCategories.map { $0.lowercased() })
        return target.isSubset(of: source)
    }
}

public struct ArxivFeedGroup: Codable, Equatable, Sendable {
    public var key: String
    public var count: Int

    public init(key: String, count: Int) {
        self.key = key
        self.count = count
    }
}

public struct ArxivLocalizedText: Codable, Equatable, Sendable {
    public var en: String
    public var zh: String

    public init(en: String, zh: String) {
        self.en = en
        self.zh = zh
    }

    public func preferred(language: String) -> String {
        if language.lowercased().hasPrefix("zh"), !zh.isEmpty {
            return zh
        }
        if !en.isEmpty {
            return en
        }
        return zh
    }
}

public struct ArxivFeedLinks: Codable, Equatable, Sendable {
    public var abs: String?
    public var pdf: String?
    public var github: String?
    public var code: String?
    public var project: String?
    public var huggingFace: String?

    public init(
        abs: String?,
        pdf: String?,
        github: String? = nil,
        code: String? = nil,
        project: String? = nil,
        huggingFace: String? = nil
    ) {
        self.abs = abs
        self.pdf = pdf
        self.github = github
        self.code = code
        self.project = project
        self.huggingFace = huggingFace
    }

    private enum CodingKeys: String, CodingKey {
        case abs
        case pdf
        case github
        case code
        case project
        case huggingFace = "hugging_face"
    }
}

public struct ArxivFeedAsset: Codable, Equatable, Sendable {
    public var path: String
    public var url: String

    public init(path: String, url: String) {
        self.path = path
        self.url = url
    }
}

public struct ArxivFeedAssetCacheSummary: Equatable, Sendable {
    public var cached: Int
    public var total: Int

    public init(cached: Int, total: Int) {
        self.cached = cached
        self.total = total
    }
}

public struct ArxivFeedAssets: Codable, Equatable, Sendable {
    public var small: ArxivFeedAsset?
    public var large: ArxivFeedAsset?

    public init(small: ArxivFeedAsset?, large: ArxivFeedAsset?) {
        self.small = small
        self.large = large
    }
}

public extension ArxivFeedResponse {
    func deduplicatedByCanonicalID(preservingCount: Bool = false) -> ArxivFeedResponse {
        var papersByID: [String: ArxivFeedPaper] = [:]
        var orderedIDs: [String] = []
        for paper in papers {
            let canonicalID = paper.canonicalArxivFeedID
            guard !canonicalID.isEmpty else {
                continue
            }
            var normalizedPaper = paper
            normalizedPaper.id = canonicalID
            normalizedPaper.arxivID = canonicalID
            if let existing = papersByID[canonicalID] {
                papersByID[canonicalID] = existing.mergingDiscoverDuplicate(normalizedPaper)
            } else {
                papersByID[canonicalID] = normalizedPaper
                orderedIDs.append(canonicalID)
            }
        }
        let uniquePapers = orderedIDs.compactMap { papersByID[$0] }
        return ArxivFeedResponse(
            date: date,
            count: preservingCount ? count : uniquePapers.count,
            papers: uniquePapers,
            groups: groups,
            tagOptions: tagOptions,
            sourceCategories: sourceCategories
        )
    }

    func uniqueAssets(includeLarge: Bool) -> [ArxivFeedAsset] {
        var result: [ArxivFeedAsset] = []
        var seen: Set<String> = []
        for paper in papers {
            var paperAssets = [paper.assets.small].compactMap { $0 }
            if includeLarge {
                paperAssets += [paper.assets.large].compactMap { $0 }
            }
            for asset in paperAssets {
                let path = asset.path.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !path.isEmpty, !seen.contains(path) else {
                    continue
                }
                seen.insert(path)
                result.append(asset)
            }
        }
        return result
    }
}

private extension ArxivFeedPaper {
    var canonicalArxivFeedID: String {
        for candidate in [arxivID, id, arxivIDVersioned].compactMap({ $0 }) {
            let normalized = LocalArxivClient.normalizeArxivID(candidate)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                return normalized
            }
        }
        return ""
    }

    func mergingDiscoverDuplicate(_ duplicate: ArxivFeedPaper) -> ArxivFeedPaper {
        var merged = self
        merged.arxivIDVersioned = preferredNonEmpty(arxivIDVersioned, duplicate.arxivIDVersioned)
        merged.title = title.mergingMissingText(from: duplicate.title)
        merged.abstract = abstract.mergingMissingText(from: duplicate.abstract)
        merged.summary = summary.mergingMissingText(from: duplicate.summary)
        merged.authors = authors.isEmpty ? duplicate.authors : authors
        merged.categories = mergedUnique(categories, duplicate.categories)
        merged.primaryCategory = preferredNonEmpty(primaryCategory, duplicate.primaryCategory)
        merged.listCategories = mergedUnique(listCategories, duplicate.listCategories)
        merged.tags = mergedUnique(tags, duplicate.tags)
        merged.comment = preferredNonEmpty(comment, duplicate.comment)
        merged.published = preferredNonEmpty(published, duplicate.published)
        merged.updated = preferredNonEmpty(updated, duplicate.updated)
        merged.listDate = preferredNonEmpty(listDate, duplicate.listDate)
        merged.thumbnailVersion = thumbnailVersion ?? duplicate.thumbnailVersion
        merged.embedding = embedding ?? duplicate.embedding
        merged.similarity = similarity ?? duplicate.similarity
        merged.filterGroup = preferredNonEmpty(filterGroup, duplicate.filterGroup)
        merged.links = links.mergingMissingLinks(from: duplicate.links)
        merged.assets = assets.mergingMissingAssets(from: duplicate.assets)
        return merged
    }
}

private extension ArxivLocalizedText {
    func mergingMissingText(from duplicate: ArxivLocalizedText) -> ArxivLocalizedText {
        ArxivLocalizedText(
            en: preferredNonEmpty(en, duplicate.en),
            zh: preferredNonEmpty(zh, duplicate.zh)
        )
    }
}

private extension ArxivFeedLinks {
    func mergingMissingLinks(from duplicate: ArxivFeedLinks) -> ArxivFeedLinks {
        ArxivFeedLinks(
            abs: abs ?? duplicate.abs,
            pdf: pdf ?? duplicate.pdf,
            github: github ?? duplicate.github,
            code: code ?? duplicate.code,
            project: project ?? duplicate.project,
            huggingFace: huggingFace ?? duplicate.huggingFace
        )
    }
}

private extension ArxivFeedAssets {
    func mergingMissingAssets(from duplicate: ArxivFeedAssets) -> ArxivFeedAssets {
        ArxivFeedAssets(
            small: small ?? duplicate.small,
            large: large ?? duplicate.large
        )
    }
}

private func preferredNonEmpty(_ current: String?, _ duplicate: String?) -> String? {
    let currentValue = current?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !currentValue.isEmpty {
        return current
    }
    let duplicateValue = duplicate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return duplicateValue.isEmpty ? current : duplicate
}

private func preferredNonEmpty(_ current: String, _ duplicate: String) -> String {
    current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? duplicate : current
}

private func mergedUnique(_ first: [String], _ second: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in first + second {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            continue
        }
        let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !seen.contains(key) else {
            continue
        }
        seen.insert(key)
        result.append(value)
    }
    return result
}

public struct ArxivFeedPaper: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var arxivID: String
    public var arxivIDVersioned: String?
    public var title: ArxivLocalizedText
    public var abstract: ArxivLocalizedText
    public var summary: ArxivLocalizedText
    public var authors: [String]
    public var categories: [String]
    public var primaryCategory: String?
    public var listCategories: [String]
    public var tags: [String]
    public var comment: String
    public var published: String?
    public var updated: String?
    public var listDate: String?
    public var thumbnailVersion: Int?
    public var embedding: [Double]?
    public var similarity: Double?
    public var filterGroup: String?
    public var links: ArxivFeedLinks
    public var assets: ArxivFeedAssets

    public init(
        id: String,
        arxivID: String,
        arxivIDVersioned: String?,
        title: ArxivLocalizedText,
        abstract: ArxivLocalizedText,
        summary: ArxivLocalizedText,
        authors: [String],
        categories: [String],
        primaryCategory: String?,
        listCategories: [String],
        tags: [String],
        comment: String,
        published: String?,
        updated: String?,
        listDate: String?,
        thumbnailVersion: Int?,
        embedding: [Double]?,
        similarity: Double? = nil,
        filterGroup: String? = nil,
        links: ArxivFeedLinks,
        assets: ArxivFeedAssets
    ) {
        self.id = id
        self.arxivID = arxivID
        self.arxivIDVersioned = arxivIDVersioned
        self.title = title
        self.abstract = abstract
        self.summary = summary
        self.authors = authors
        self.categories = categories
        self.primaryCategory = primaryCategory
        self.listCategories = listCategories
        self.tags = tags
        self.comment = comment
        self.published = published
        self.updated = updated
        self.listDate = listDate
        self.thumbnailVersion = thumbnailVersion
        self.embedding = embedding
        self.similarity = similarity
        self.filterGroup = filterGroup
        self.links = links
        self.assets = assets
    }

    public func displayTitle(language: String) -> String {
        title.preferred(language: language)
    }

    public func displaySummary(language: String) -> String {
        summary.preferred(language: language)
    }

    public var publishedYear: Int? {
        guard let published, published.count >= 4 else {
            return nil
        }
        return Int(published.prefix(4))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case arxivID = "arxiv_id"
        case arxivIDVersioned = "arxiv_id_versioned"
        case title
        case abstract
        case summary
        case authors
        case categories
        case primaryCategory = "primary_category"
        case listCategories = "list_categories"
        case tags
        case comment
        case published
        case updated
        case listDate = "list_date"
        case thumbnailVersion = "thumbnail_version"
        case embedding
        case similarity
        case filterGroup = "filter_group"
        case links
        case assets
    }
}

public struct PaperImportMetadata: Equatable, Sendable {
    public var title: String?
    public var authors: [String]
    public var year: Int?
    public var sourceURL: String?

    public init(title: String?, authors: [String], year: Int?, sourceURL: String?) {
        self.title = title
        self.authors = authors
        self.year = year
        self.sourceURL = sourceURL
    }
}

public enum ArxivFeedCacheError: Error, CustomStringConvertible, Equatable {
    case unsafePath(String)

    public var description: String {
        switch self {
        case let .unsafePath(path):
            "Unsafe arXiv feed cache path: \(path)"
        }
    }
}

public final class ArxivFeedCache {
    private let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let fileManager: FileManager

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func saveDates(_ dates: ArxivFeedDateIndex) throws {
        try writeJSON(dates, to: root.appendingPathComponent("dates.json"))
    }

    public func loadDates() throws -> ArxivFeedDateIndex? {
        let url = root.appendingPathComponent("dates.json")
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try decoder.decode(ArxivFeedDateIndex.self, from: Data(contentsOf: url))
    }

    public func saveFeed(_ feed: ArxivFeedResponse) throws {
        try writeJSON(feed, to: feedURL(date: feed.date))
    }

    public func loadFeed(date: String) throws -> ArxivFeedResponse? {
        let url = feedURL(date: date)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        return try decoder.decode(ArxivFeedResponse.self, from: Data(contentsOf: url))
    }

    public func loadFeed(containing range: DiscoverDateRange) throws -> ArxivFeedResponse? {
        if let exactRangeFeed = try loadFeed(date: range.cacheLabel) {
            return exactRangeFeed
        }
        if range.start == range.end,
           let exactDailyFeed = try loadFeed(date: range.start) {
            return exactDailyFeed
        }

        let feedsRoot = root.appendingPathComponent("feeds", isDirectory: true)
        guard fileManager.fileExists(atPath: feedsRoot.path),
              let enumerator = fileManager.enumerator(
                at: feedsRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var bestMatch: (span: Int, label: String, feed: ArxivFeedResponse)?
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            let feed = try decoder.decode(ArxivFeedResponse.self, from: Data(contentsOf: url))
            let cachedRange = try DiscoverDateRange(cacheLabel: feed.date)
            guard cachedRange.contains(range) else {
                continue
            }
            let span = cachedRange.dates.count
            if bestMatch == nil ||
                span < bestMatch!.span ||
                (span == bestMatch!.span && cachedRange.cacheLabel > bestMatch!.label) {
                bestMatch = (span, cachedRange.cacheLabel, feed)
            }
        }
        return bestMatch?.feed
    }

    public func loadPaper(arxivID rawID: String) throws -> ArxivFeedPaper? {
        let targetID = LocalArxivClient.normalizeArxivID(rawID)
        let feedsRoot = root.appendingPathComponent("feeds", isDirectory: true)
        guard fileManager.fileExists(atPath: feedsRoot.path),
              let enumerator = fileManager.enumerator(
                at: feedsRoot,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var newestMatch: (date: String, paper: ArxivFeedPaper)?
        for case let url as URL in enumerator where url.pathExtension == "json" {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                continue
            }
            let feed = try decoder.decode(ArxivFeedResponse.self, from: Data(contentsOf: url))
            guard let paper = feed.papers.first(where: { paper in
                paper.id == targetID || paper.arxivID == targetID || paper.arxivIDVersioned.map(LocalArxivClient.normalizeArxivID) == targetID
            }) else {
                continue
            }
            if newestMatch == nil || feed.date > newestMatch!.date {
                newestMatch = (feed.date, paper)
            }
        }
        return newestMatch?.paper
    }

    @discardableResult
    public func saveAsset(_ data: Data, path: String) throws -> URL {
        let url = try assetURL(path: path)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return url
    }

    public func cachedAssetURL(path: String) throws -> URL? {
        let url = try assetURL(path: path)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    @discardableResult
    public func savePDF(_ data: Data, arxivID: String, date: String) throws -> URL {
        let url = try pdfURL(arxivID: arxivID, date: date)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        return url
    }

    public func cachedPDFURL(arxivID: String, date: String? = nil) throws -> URL? {
        if let date {
            let url = try pdfURL(arxivID: arxivID, date: date)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }

        let pdfsRoot = root.appendingPathComponent("pdfs", isDirectory: true)
        guard fileManager.fileExists(atPath: pdfsRoot.path) else {
            return nil
        }
        let fileName = "\(try safeCacheComponent(arxivID)).pdf"
        guard let enumerator = fileManager.enumerator(
            at: pdfsRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        for case let candidate as URL in enumerator where candidate.lastPathComponent == fileName {
            return candidate
        }
        return nil
    }

    public func pdfCacheSummary(for feed: ArxivFeedResponse) throws -> ArxivFeedAssetCacheSummary {
        var cached = 0
        var seen: Set<String> = []
        for paper in feed.papers {
            guard !seen.contains(paper.id) else {
                continue
            }
            seen.insert(paper.id)
            if try cachedPDFURL(arxivID: paper.id, date: paper.listDate ?? feed.date) != nil ||
                (try cachedPDFURL(arxivID: paper.id)) != nil {
                cached += 1
            }
        }
        return ArxivFeedAssetCacheSummary(cached: cached, total: seen.count)
    }

    public func assetCacheSummary(for feed: ArxivFeedResponse, includeLarge: Bool) throws -> ArxivFeedAssetCacheSummary {
        let assets = feed.uniqueAssets(includeLarge: includeLarge)
        var cached = 0
        for asset in assets where try cachedAssetURL(path: asset.path) != nil {
            cached += 1
        }
        return ArxivFeedAssetCacheSummary(cached: cached, total: assets.count)
    }

    public func feedURL(date: String) -> URL {
        root
            .appendingPathComponent("feeds", isDirectory: true)
            .appendingPathComponent("\(date).json")
    }

    public func assetURL(path: String) throws -> URL {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ArxivFeedCacheError.unsafePath(path)
        }
        let components = path.split(separator: "/").map(String.init)
        guard !components.isEmpty,
              !components.contains(".."),
              !path.hasPrefix("/") else {
            throw ArxivFeedCacheError.unsafePath(path)
        }
        return components.reduce(root) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    public func pdfURL(arxivID: String, date: String) throws -> URL {
        root
            .appendingPathComponent("pdfs", isDirectory: true)
            .appendingPathComponent(try safeCacheComponent(date), isDirectory: true)
            .appendingPathComponent("\(try safeCacheComponent(arxivID)).pdf")
    }

    private func safeCacheComponent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/") else {
            throw ArxivFeedCacheError.unsafePath(value)
        }
        var result = ""
        for scalar in trimmed.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || ".-_".unicodeScalars.contains(scalar) {
                result.unicodeScalars.append(scalar)
            } else if scalar == "/" {
                result.append("_")
            } else {
                result.append("-")
            }
        }
        guard !result.isEmpty, result != ".", result != "..", !result.contains("..") else {
            throw ArxivFeedCacheError.unsafePath(value)
        }
        return result
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }
}
