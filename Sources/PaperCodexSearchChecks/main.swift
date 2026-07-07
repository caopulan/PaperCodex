import Foundation
import PaperCodexCore

struct SearchCheckFailure: Error, CustomStringConvertible {
    var description: String
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw SearchCheckFailure(description: message)
    }
}

func makeSearchCheckPaper(
    id: String,
    categories: [String],
    primaryCategory: String,
    listCategories: [String],
    title: String = "Cached paper"
) -> ArxivFeedPaper {
    ArxivFeedPaper(
        id: id,
        arxivID: id,
        arxivIDVersioned: "\(id)v1",
        title: ArxivLocalizedText(en: title, zh: ""),
        abstract: ArxivLocalizedText(en: "Cached range paper", zh: ""),
        summary: ArxivLocalizedText(en: "", zh: ""),
        authors: ["Ada Lovelace"],
        categories: categories,
        primaryCategory: primaryCategory,
        listCategories: listCategories,
        tags: [],
        comment: "",
        published: "2026-01-03T00:00:00Z",
        updated: nil,
        listDate: "2026-01-03",
        thumbnailVersion: nil,
        embedding: nil,
        links: ArxivFeedLinks(abs: nil, pdf: nil),
        assets: ArxivFeedAssets(small: nil, large: nil)
    )
}

do {
    let categoryAndYearQuery = try LocalArxivClient.composedUserSearchQuery(
        "diffusion models",
        requiredCategories: ["cs.CV", "cs.LG", "cs.CV"],
        fromYear: 2022,
        throughYear: 2024
    )
    try check(
        categoryAndYearQuery == "(all:diffusion models) AND (cat:cs.CV OR cat:cs.LG) AND submittedDate:[202201010000 TO 202412312359]",
        "arXiv search should combine user query, required categories, and closed year range"
    )

    let filterOnlyQuery = try LocalArxivClient.composedUserSearchQuery(
        "",
        requiredCategories: ["cs.CV"],
        fromYear: 2020,
        throughYear: nil
    )
    try check(
        filterOnlyQuery == "cat:cs.CV AND submittedDate:[202001010000 TO 999912312359]",
        "arXiv search should allow category/year-only searches"
    )

    do {
        _ = try LocalArxivClient.composedUserSearchQuery(
            "all:diffusion",
            requiredCategories: [],
            fromYear: 2025,
            throughYear: 2020
        )
        throw SearchCheckFailure(description: "arXiv search should reject inverted year ranges")
    } catch is LocalArxivClientError {
        // Expected.
    }

    let range = try DiscoverDateRange(start: "2026-01-01", end: "2026-01-07")
    let aiOnlyRangeFeed = ArxivFeedResponse(
        date: range.cacheLabel,
        count: 1,
        papers: [
            makeSearchCheckPaper(
                id: "2601.00001",
                categories: ["cs.AI", "cs.CV"],
                primaryCategory: "cs.AI",
                listCategories: ["cs.AI"]
            )
        ],
        sourceCategories: ["cs.AI"]
    )
    try check(
        aiOnlyRangeFeed.coversSourceCategories(["cs.AI"]),
        "AI range cache should cover AI queries"
    )
    try check(
        !aiOnlyRangeFeed.coversSourceCategories(["cs.CV"]),
        "AI range cache should not cover CV queries just because a cached paper has a CV category tag"
    )

    let legacyRangeFeed = ArxivFeedResponse(
        date: range.cacheLabel,
        count: 1,
        papers: aiOnlyRangeFeed.papers
    )
    try check(
        !legacyRangeFeed.coversSourceCategories(["cs.CV"]),
        "legacy range cache without source categories should not be treated as category-complete"
    )

    let cvQuery = DiscoverQuery(
        keyword: "",
        dateRange: range,
        categories: ["cs.CV"],
        similaritySourceIDs: [],
        rankingVersion: "local-rank-v3-no-embedding"
    ).normalized
    try check(
        aiOnlyRangeFeed.scoped(to: cvQuery).papers.isEmpty,
        "category-scoped cache filtering should not turn an AI-only range cache into CV search results"
    )

    print("search-filters: pass")
} catch {
    fputs("check failed: \(error)\n", stderr)
    exit(1)
}
