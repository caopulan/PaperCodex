import Foundation
import PaperCodexCore

struct DiscoverCachedState: Sendable {
    var feed: ArxivFeedResponse
    var query: DiscoverQuery?
    var arxivDates: [String]
    var selectedDate: String
    var progressTitle: String
    var enrichmentsByID: [String: DiscoverPaperEnrichment]
    var assetURLs: [String: URL]
    var pdfThumbnailURLsByID: [String: [URL]]
    var assetCacheSummary: ArxivFeedAssetCacheSummary
}

enum DiscoverCacheLoader {
    static func loadInitialState(
        supportRoot: URL,
        preferences: LocalDiscoverPreferences,
        selectedDate: String?
    ) throws -> DiscoverCachedState? {
        let arxivCache = ArxivFeedCache(root: supportRoot.appendingPathComponent("arxiv-cache", isDirectory: true))
        let localDiscoverCache = LocalDiscoverCache(root: supportRoot.appendingPathComponent("discover-cache", isDirectory: true))
        let thumbnailCache = PDFThumbnailCache(root: supportRoot.appendingPathComponent("thumbnails", isDirectory: true))
        let cachedDates = try arxivCache.loadDates()

        if let queryResult = try localDiscoverCache.loadLastQueryResult(),
           let feed = queryResult.feed,
           !feed.papers.isEmpty {
            let normalizedFeed = apply(preferences: preferences, to: feed)
            return try makeState(
                feed: normalizedFeed,
                query: queryResult.query.normalized,
                progressTitle: "Last search",
                cachedDates: cachedDates,
                arxivCache: arxivCache,
                localDiscoverCache: localDiscoverCache,
                thumbnailCache: thumbnailCache
            )
        }

        let fallbackDate = selectedDate ?? cachedDates?.latest ?? cachedDates?.dates.last
        guard let fallbackDate,
              let feed = try arxivCache.loadFeed(date: fallbackDate),
              !feed.papers.isEmpty else {
            return nil
        }
        let normalizedFeed = apply(preferences: preferences, to: feed)
        return try makeState(
            feed: normalizedFeed,
            query: nil,
            progressTitle: "Offline cache",
            cachedDates: cachedDates,
            arxivCache: arxivCache,
            localDiscoverCache: localDiscoverCache,
            thumbnailCache: thumbnailCache
        )
    }

    private static func makeState(
        feed: ArxivFeedResponse,
        query: DiscoverQuery?,
        progressTitle: String,
        cachedDates: ArxivFeedDateIndex?,
        arxivCache: ArxivFeedCache,
        localDiscoverCache: LocalDiscoverCache,
        thumbnailCache: PDFThumbnailCache
    ) throws -> DiscoverCachedState {
        let enrichments = try loadEnrichments(for: feed.papers, localDiscoverCache: localDiscoverCache)
        let assetURLs = try loadAssetURLs(for: feed, arxivCache: arxivCache)
        let pdfThumbnailURLs = loadPDFThumbnailURLs(for: feed, arxivCache: arxivCache, thumbnailCache: thumbnailCache)
        let summary = try arxivCache.assetCacheSummary(for: feed, includeLarge: false)
        var dates = cachedDates?.dates ?? []
        if !dates.contains(feed.date) {
            dates.append(feed.date)
            dates.sort()
        }
        return DiscoverCachedState(
            feed: feed,
            query: query,
            arxivDates: dates,
            selectedDate: feed.date,
            progressTitle: progressTitle,
            enrichmentsByID: enrichments,
            assetURLs: assetURLs,
            pdfThumbnailURLsByID: pdfThumbnailURLs,
            assetCacheSummary: summary
        )
    }

    private static func apply(preferences: LocalDiscoverPreferences, to feed: ArxivFeedResponse) -> ArxivFeedResponse {
        let normalized = preferences.normalized
        let deduplicatedFeed = feed.deduplicatedByCanonicalID()
        let rankedPapers = SimilarityRanker.rank(
            papers: deduplicatedFeed.papers,
            whitelistTags: normalized.whitelistTags,
            blacklistTags: normalized.blacklistTags,
            interestVectors: []
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
    }

    private static func loadEnrichments(
        for papers: [ArxivFeedPaper],
        localDiscoverCache: LocalDiscoverCache
    ) throws -> [String: DiscoverPaperEnrichment] {
        var enrichments: [String: DiscoverPaperEnrichment] = [:]
        for paper in papers {
            if let enrichment = try localDiscoverCache.loadEnrichment(arxivID: paper.id) {
                enrichments[paper.id] = enrichment
            }
        }
        return enrichments
    }

    private static func loadAssetURLs(
        for feed: ArxivFeedResponse,
        arxivCache: ArxivFeedCache
    ) throws -> [String: URL] {
        var urls: [String: URL] = [:]
        for paper in feed.papers {
            for asset in [paper.assets.small, paper.assets.large].compactMap({ $0 }) {
                if let url = try arxivCache.cachedAssetURL(path: asset.path) {
                    urls[asset.path] = url
                }
            }
        }
        return urls
    }

    private static func loadPDFThumbnailURLs(
        for feed: ArxivFeedResponse,
        arxivCache: ArxivFeedCache,
        thumbnailCache: PDFThumbnailCache
    ) -> [String: [URL]] {
        var urlsByID: [String: [URL]] = [:]
        for paper in feed.papers {
            let urls = thumbnailCache.cachedThumbnailURLs(cacheID: "arxiv-\(paper.id)", pageLimit: 5)
            if !urls.isEmpty {
                urlsByID[paper.id] = urls
            }
        }
        return urlsByID
    }
}

enum CacheStorageSummaryLoader {
    static func load(supportRoot: URL) -> CacheStorageSummary {
        let libraryRoot = supportRoot.appendingPathComponent("papers", isDirectory: true)
        let disposableCacheRoot = supportRoot.appendingPathComponent("cache", isDirectory: true)
        let arxivCacheRoot = supportRoot.appendingPathComponent("arxiv-cache", isDirectory: true)
        let thumbnailRoot = supportRoot.appendingPathComponent("thumbnails", isDirectory: true)
        return CacheStorageSummary(
            libraryBytes: directorySize(libraryRoot),
            disposableCacheBytes: directorySize(disposableCacheRoot),
            arxivCacheBytes: directorySize(arxivCacheRoot),
            thumbnailBytes: directorySize(thumbnailRoot),
            refreshedAt: Date()
        )
    }

    private static func directorySize(_ root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else {
                continue
            }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
