//
//  WeebCentralSource.swift
//  MangaCarta
//
//  WeebCentral (weebcentral.com) as source #2 — a server-rendered HTML site behind
//  Cloudflare, with no JSON API. Every method loads a page through the context's
//  WebView (which clears Cloudflare) and runs a small JS extraction script whose
//  result is JSON; decoded DTOs are mapped to domain types stamped with
//  `sourceId = "weebcentral"`. DOM selectors were ported (technique only) from the
//  inkdex/general-extensions WeebCentral parsers and verified against live HTML —
//  they are the most volatile part of this source; when WeebCentral redesigns,
//  update the scripts below.
//

import Foundation

struct WeebCentralSource: MangaSource {
    /// Single source of truth for this source's identifier (mirrors `MangaDexSource.sourceID`).
    static let sourceID = "weebcentral"

    let id = WeebCentralSource.sourceID
    let name = "WeebCentral"
    let isNSFW = false

    /// True orderings of the three browse feeds ("Popularity" / latest chapter
    /// updates / "Recently Added" — see the fetches below).
    var homeRailEyebrows: [String] { ["By popularity", "New chapters", "Just added"] }

    private let context: SourceContext
    private static let base = URL(string: "https://weebcentral.com")!

    init(context: SourceContext) {
        self.context = context
    }

    // MARK: - MangaSource

    func search(title: String, limit: Int, offset: Int) async throws -> [Manga] {
        try await seriesList(url: Self.searchURL(text: title, sort: "Best Match", limit: limit, offset: offset))
    }

    func popular(limit: Int, offset: Int) async throws -> [Manga] {
        try await seriesList(url: Self.searchURL(text: nil, sort: "Popularity", limit: limit, offset: offset))
    }

    func newTitles(limit: Int, offset: Int) async throws -> [Manga] {
        try await seriesList(url: Self.searchURL(text: nil, sort: "Recently Added", limit: limit, offset: offset))
    }

    func latestUpdates(limitTitles: Int, language: String, offset: Int) async throws -> [MangaUpdate] {
        // `language` ignored: WeebCentral is English-only.
        // The site paginates by 1-based page number, not by item offset.
        let page = limitTitles > 0 ? offset / limitTitles + 1 : 1
        let url = Self.base.appending(path: "latest-updates/\(page)")
        let items = try await context.webView.extract(from: url, script: Self.latestUpdatesScript,
                                                      as: [WCUpdateItem].self)
        return items.prefix(limitTitles).map { item in
            MangaUpdate(chapterId: item.chapterId, manga: manga(id: item.mangaId, title: item.title, cover: item.cover))
        }
    }

    func mangaDetail(id: String) async throws -> MangaDetail {
        let url = Self.base.appending(path: "series/\(id)")
        let detail = try await context.webView.extract(from: url, script: Self.detailScript, as: WCDetail.self)
        let tags = detail.tags.map { Tag(id: "", name: $0, group: "") }
        return MangaDetail(
            description: detail.description ?? "",
            authors: detail.authors,
            tags: tags,
            contentRating: detail.adult == true ? "erotica" : "safe"
        )
    }

    func chapters(mangaId: String) async throws -> [Chapter] {
        let url = Self.base.appending(path: "series/\(mangaId)/full-chapter-list")
        let items = try await context.webView.extract(from: url, script: Self.chaptersScript,
                                                      as: [WCChapterItem].self)
        return items.map { Chapter(id: $0.id, number: Self.chapterNumber(fromTitle: $0.title),
                                   title: $0.title, date: Chapter.parseISO8601($0.date)) }
    }

    func pageURLs(chapterId: String, preferDataSaver: Bool) async throws -> [URL] {
        // `preferDataSaver` ignored: WeebCentral serves a single image size.
        let url = Self.base.appending(path: "chapters/\(chapterId)/images")
            .appending(queryItems: [URLQueryItem(name: "reading_style", value: "long_strip")])
        let strings = try await context.webView.extract(from: url, script: Self.pagesScript, as: [String].self)
        return strings.compactMap(URL.init(string:))
    }

    func webURL(forManga id: String) async throws -> URL? {
        Self.base.appending(path: "series/\(id)")
    }

    // MARK: - Mapping helpers

    private func seriesList(url: URL) async throws -> [Manga] {
        let items = try await context.webView.extract(from: url, script: Self.seriesListScript,
                                                      as: [WCSeriesItem].self)
        return items.map { manga(id: $0.id, title: $0.title, cover: $0.cover) }
    }

    /// List feeds carry only id/title/cover — description and status arrive with `mangaDetail`.
    private func manga(id: String, title: String, cover: String?) -> Manga {
        Manga(id: id, sourceId: Self.sourceID, title: title, description: "",
              status: "unknown", year: nil, coverURL: cover.flatMap(URL.init(string:)), malId: nil)
    }

    /// `/search/data` is the server-rendered results fragment the site itself fetches;
    /// its `sort` values ("Best Match" / "Popularity" / "Recently Added") back all three
    /// browse feeds with real limit/offset pagination.
    static func searchURL(text: String?, sort: String, limit: Int, offset: Int) -> URL {
        var items = [
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "display_mode", value: "Full Display"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let text, !text.isEmpty {
            items.append(URLQueryItem(name: "text", value: text))
        }
        return base.appending(path: "search/data").appending(queryItems: items)
    }

    /// Chapter rows read like "Chapter 105" / "Special 3.5" — the display number is the
    /// LAST numeric token; rows with no number (e.g. "Oneshot") show "?".
    static func chapterNumber(fromTitle title: String) -> String {
        guard let match = title.matches(of: /\d+(\.\d+)?/).last else { return "?" }
        return String(title[match.range])
    }
}

// MARK: - Wire DTOs (shape produced by the JS extraction scripts)

private struct WCSeriesItem: Decodable {
    let id: String
    let title: String
    let cover: String?
}

private struct WCDetail: Decodable {
    let description: String?
    let authors: [String]
    let tags: [String]
    let adult: Bool?
}

private struct WCChapterItem: Decodable {
    let id: String
    let title: String
    let date: String?
}

private struct WCUpdateItem: Decodable {
    let mangaId: String
    let chapterId: String
    let title: String
    let cover: String?
}

// MARK: - JS extraction scripts
//
// Each script is an IIFE whose final expression is a JSON string (the WebView seam's
// contract). Selectors ported from the reference extension and verified live; the
// shared `seg(href, name)` helper pulls the path segment AFTER a given one, so both
// "/series/{id}" and "/series/{id}/{slug}" URL shapes yield the id.

private extension WeebCentralSource {
    static let seriesListScript = #"""
    (() => {
      const seg = (href, name) => {
        const parts = (href || '').replace(/\/$/, '').split('/');
        const i = parts.indexOf(name);
        return i >= 0 && parts[i + 1] ? parts[i + 1] : null;
      };
      const items = [...document.querySelectorAll('article.flex.gap-4')].map(el => {
        const link = el.querySelector('a[href*="/series/"]');
        const titleEl = el.querySelector('a.link.link-hover') || link;
        const img = el.querySelector('img');
        const rawCover = img ? (img.getAttribute('src') || img.getAttribute('data-src')) : null;
        return {
          id: link ? seg(link.getAttribute('href'), 'series') : null,
          title: titleEl ? titleEl.textContent.trim() : '',
          cover: rawCover ? new URL(rawCover, location.href).href : null
        };
      }).filter(x => x.id && x.title);
      return JSON.stringify(items);
    })()
    """#

    static let detailScript = #"""
    (() => {
      const strongWith = (label) =>
        [...document.querySelectorAll('strong')].find(s => s.textContent.includes(label));
      const collect = (root, selector) => {
        const out = [];
        if (root && root.parentElement) {
          root.parentElement.querySelectorAll(selector).forEach(a => {
            const t = a.textContent.trim();
            if (t) out.push(t);
          });
        }
        return out;
      };
      const descEl = document.querySelector('.whitespace-pre-wrap');
      const adultStrong = strongWith('Adult Content');
      const adult = adultStrong && adultStrong.nextElementSibling
        ? adultStrong.nextElementSibling.textContent.trim().toLowerCase() === 'yes'
        : false;
      return JSON.stringify({
        description: descEl ? descEl.textContent.trim() : null,
        authors: collect(strongWith('Author'), 'span a'),
        tags: collect(strongWith('Tag'), 'a'),
        adult
      });
    })()
    """#

    static let chaptersScript = #"""
    (() => {
      const seg = (href, name) => {
        const parts = (href || '').replace(/\/$/, '').split('/');
        const i = parts.indexOf(name);
        return i >= 0 && parts[i + 1] ? parts[i + 1] : null;
      };
      const items = [...document.querySelectorAll('a.flex.items-center')].map(a => {
        const titleEl = a.querySelector('span.grow.flex.gap-2 span')
          || a.querySelector('span.grow span')
          || a.querySelector('span');
        const timeEl = a.querySelector('time[datetime]');
        return {
          id: seg(a.getAttribute('href'), 'chapters'),
          title: titleEl ? titleEl.textContent.trim() : '',
          date: timeEl ? timeEl.getAttribute('datetime') : null
        };
      }).filter(x => x.id);
      return JSON.stringify(items);
    })()
    """#

    static let pagesScript = #"""
    (() => {
      const urls = [...document.querySelectorAll('section.cursor-pointer img')]
        .map(img => img.getAttribute('src') || img.getAttribute('data-src'))
        .filter(Boolean)
        .map(u => new URL(u, location.href).href);
      return JSON.stringify(urls);
    })()
    """#

    static let latestUpdatesScript = #"""
    (() => {
      const seg = (href, name) => {
        const parts = (href || '').replace(/\/$/, '').split('/');
        const i = parts.indexOf(name);
        return i >= 0 && parts[i + 1] ? parts[i + 1] : null;
      };
      const items = [...document.querySelectorAll('article')].map(el => {
        const mangaLink = el.querySelector('a.aspect-square') || el.querySelector('a[href*="/series/"]');
        const chapterLink = el.querySelector('a.min-w-0') || el.querySelector('a[href*="/chapters/"]');
        const titleEl = el.querySelector('div.font-semibold');
        const img = el.querySelector('a img');
        const rawCover = img ? (img.getAttribute('src') || img.getAttribute('data-src')) : null;
        return {
          mangaId: mangaLink ? seg(mangaLink.getAttribute('href'), 'series') : null,
          chapterId: chapterLink ? seg(chapterLink.getAttribute('href'), 'chapters') : null,
          title: titleEl ? titleEl.textContent.trim() : '',
          cover: rawCover ? new URL(rawCover, location.href).href : null
        };
      }).filter(x => x.mangaId && x.chapterId && x.title);
      return JSON.stringify(items);
    })()
    """#
}
