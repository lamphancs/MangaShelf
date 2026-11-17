import Foundation

nonisolated struct WebsiteChapter: Identifiable, Sendable {
    var id: String { url.absoluteString }
    let title: String
    let url: URL
    let number: Decimal?
    let volume: String?
    /// Release date as shown on the website's chapter row (absolute or relative text).
    var date: String? = nil
    /// The website marks this chapter as new.
    var isNew = false
    var filename: String? { number.map { "Chapter \(NSDecimalNumber(decimal: $0).stringValue).pdf" } }
}

nonisolated enum WebsiteProvider: String, CaseIterable, Sendable {
    case toonGod, omega, damconuong, truyenQQ
    init?(url: URL) {
        switch url.host?.lowercased().replacingOccurrences(of: "www.", with: "") {
        case "toongod.org": self = .toonGod
        case "omegascans.org": self = .omega
        case "damconuong.cool", "damconuong.tech": self = .damconuong
        case "truyenqqko.com": self = .truyenQQ
        default: return nil
        }
    }
    static func canonical(_ url: URL) -> URL {
        var c = URLComponents(url: url, resolvingAgainstBaseURL: true)!
        c.fragment = nil; c.query = nil
        c.host = c.host?.lowercased().replacingOccurrences(of: "www.", with: "")
        if c.host == "damconuong.cool" { c.host = "damconuong.tech" }
        while c.path.hasSuffix("/") { c.path.removeLast() }
        return c.url!
    }
    static func number(_ text: String) -> Decimal? {
        let pattern = #"(?i)(?:chapter|chap|ch\.|chương|chuong|hồi|hoi)[\s_:/\-]*(\d+(?:[.,]\d+)?)"#
        guard let r = text.range(of: pattern, options: .regularExpression),
              let n = text[r].range(of: #"\d+(?:[.,]\d+)?"#, options: .regularExpression) else { return nil }
        return Decimal(string: String(text[n]).replacingOccurrences(of: ",", with: "."), locale: Locale(identifier: "en_US_POSIX"))
    }
    static func volume(_ text: String) -> String? {
        guard let range = text.range(of: #"(?i)(?:volume|vol\.|tập|tap)[\s_-]*(\d+)"#, options: .regularExpression),
              let digits = text[range].range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return String(text[digits])
    }
    /// API timestamps (ISO 8601) become a short local date; website text is kept as shown.
    static func displayDate(_ text: String) -> String {
        for style in [Date.ISO8601FormatStyle(includingFractionalSeconds: true), Date.ISO8601FormatStyle()] {
            if let date = try? style.parse(text) { return date.formatted(date: .abbreviated, time: .omitted) }
        }
        return text
    }
    func chapters(_ links: [[String: String]], series: URL) -> [WebsiteChapter] {
        let base = Self.canonical(series)
        var seen = Set<URL>()
        return links.compactMap { link in
            guard let href = link["url"], let raw = URL(string: href, relativeTo: series),
                  ["https", "http"].contains(raw.scheme ?? "") else { return nil }
            let url = Self.canonical(raw.absoluteURL)
            guard url.host == base.host, url != base else { return nil }
            let matches: Bool
            switch self {
            case .toonGod, .omega, .damconuong:
                matches = url.deletingLastPathComponent().path == base.path
            case .truyenQQ:
                matches = url.path.hasPrefix(base.path.replacingOccurrences(of: ".html", with: "") + "-chap-")
            }
            guard matches, seen.insert(url).inserted else { return nil }
            let title = link["title"] ?? url.lastPathComponent
            return WebsiteChapter(title: title, url: url, number: Self.number(title) ?? Self.number(url.lastPathComponent), volume: link["volume"] ?? Self.volume(title),
                                  date: link["date"].flatMap { $0.isEmpty ? nil : Self.displayDate($0) }, isNew: link["new"] == "1")
        }.sorted {
            if let a = $0.number, let b = $1.number, a != b { return a < b }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    var linkSelector: String {
        switch self {
        case .toonGod: "li.wp-manga-chapter a, .listing-chapters_wrap a, .chapter-list a"
        case .omega, .damconuong: "a[href]"
        case .truyenQQ: ".works-chapter-item .name-chap a, .list-chapter a"
        }
    }
    var imageSelector: String {
        switch self {
        case .toonGod: ".reading-content, .read-container, #readerarea, .chapter-content"
        case .omega: "img[data-fallback-index]"
        case .damconuong: "#chapter-content"
        case .truyenQQ: ".page-chapter"
        }
    }
    static let omegaListScript = #"""
        const slug = location.pathname.split('/').filter(Boolean)[1];
        let id = null;
        function walk(o) {
          if (!o || typeof o !== 'object') return;
          if (o.series_slug === slug && (o.id || o.series_id)) id = o.id || o.series_id;
          for (const v of Object.values(o)) if (v && typeof v === 'object') walk(v);
        }
        function flight(entry) {
          if (!Array.isArray(entry) || typeof entry[1] !== 'string') return;
          for (const line of entry[1].split('\n')) {
            const colon = line.indexOf(':');
            if (colon < 0) continue;
            try { walk(JSON.parse(line.slice(colon+1))); } catch {}
          }
        }
        for (const s of document.scripts) {
          try { walk(JSON.parse(s.textContent)); } catch {}
          // Hydration may drain __next_f. Parse the original JSON arguments,
          // without evaluating website script text ourselves.
          const match = s.textContent.match(/self\.__next_f\.push\((\[[\s\S]*\])\)/);
          if (match) { try { flight(JSON.parse(match[1])); } catch {} }
        }
        for (const entry of (self.__next_f || [])) flight(entry);
        if (!id) throw new Error('Không xác định được series_id của bộ truyện');
        let links=[], expected=null;
        for(let page=1;page<=1000;page++) {
          const r=await fetch('https://api.omegascans.org/chapter/query?page='+page+'&perPage=100&series_id='+encodeURIComponent(id));
          if(!r.ok) throw new Error('HTTP '+r.status);
          const j=await r.json();
          if(!Array.isArray(j.data) || !j.meta || Number(j.meta.current_page)!==page) throw new Error('Metadata phân trang không hợp lệ');
          if(expected===null) expected=Number(j.meta.total);
          if(Number(j.meta.total)!==expected) throw new Error('Danh sách thay đổi trong lúc tải');
          for(const c of j.data) {
            if(c.series?.series_slug!==slug || String(c.series.id)!==String(id)) throw new Error('Sai bộ truyện');
            const link={url:location.origin+'/series/'+slug+'/'+c.chapter_slug,title:(c.chapter_name || '')+' '+(c.chapter_title || '')};
            if(typeof c.created_at==='string') link.date=c.created_at;
            links.push(link);
          }
          if(page===Number(j.meta.last_page)) {
            if(links.length!==expected || new Set(links.map(c=>c.url)).size!==expected) throw new Error('Danh sách chưa đủ');
            return links;
          }
        }
        throw new Error('Quá nhiều trang');
        """#

    /// Defines `chapterLink(a, url)`: the link plus the date and "new" badge shown on its chapter row.
    /// Every value is a string so the result bridges to `[[String: String]]`.
    static let chapterLinkFunction = #"""
        function chapterLink(a, url = a.href) {
          const link = {url, title: a.textContent.trim()};
          let row = a.closest('li, tr, .works-chapter-item, .wp-manga-chapter') || a.parentElement;
          // A container holding several chapters is a list, not this chapter's row.
          if (!row || row.querySelectorAll('a[href]').length > 3) row = a;
          const dateRE = /^(?:\d{1,2}[\/.-]\d{1,2}[\/.-]\d{2,4}|\d{4}-\d{2}-\d{2}|[a-z]{3,9}\.? \d{1,2},? \d{4}|\d{1,2} [a-z]{3,9},? \d{4}|(?:\d+|an?|một) ?(?:giây|phút|giờ|ngày|tuần|tháng|năm|sec|second|min|minute|hour|day|week|month|year)s? ?(?:trước|ago))$/i;
          const leaves = [...row.querySelectorAll('*')].filter(e => !e.children.length).map(e => [e, e.textContent.trim()]);
          const dateNode = row.querySelector('.chapter-release-date, .time-chap, time');
          const newTag = row.querySelector('.c-new-tag, [class~="new"], [class*="new-tag"], [class*="badge-new"], [class*="chapter-new"], img[src*="new" i]');
          const date = dateNode?.textContent.trim() || newTag?.getAttribute('title')?.trim()
            || dateNode?.getAttribute('datetime') || leaves.find(([, t]) => dateRE.test(t))?.[1];
          if (date) link.date = date;
          const newLeaf = leaves.find(([, t]) => /^(?:new|mới)!?$/i.test(t));
          if (newTag || newLeaf) link.new = '1';
          // When the whole row is the link, keep the date/badge out of the chapter title.
          for (const extra of [date, newLeaf?.[1]]) {
            if (extra && row === a && link.title !== extra) link.title = link.title.replace(extra, '').trim();
          }
          return link;
        }
        """#

    var linksScript: String {
        "(() => { \(Self.chapterLinkFunction) return Array.from(document.querySelectorAll('\(linkSelector)'), a => chapterLink(a)); })()"
    }
    /// Parse inert HTML: no navigation, subresource loading, script execution or scrolling.
    func staticImagesScript(html: String, url: URL) throws -> String {
        let htmlJSON = String(data: try JSONEncoder().encode(html), encoding: .utf8)!
        let urlJSON = String(data: try JSONEncoder().encode(url.absoluteString), encoding: .utf8)!
        let extraction = imagesScript
            .replacingOccurrences(of: "document.querySelectorAll", with: "doc.querySelectorAll")
            .replacingOccurrences(of: "document.body.innerText", with: "doc.textContent")
            .replacingOccurrences(of: "location.href", with: "baseURL")
        return "const template = document.createElement('template'); template.innerHTML = \(htmlJSON); const doc = template.content; const baseURL = \(urlJSON); const result = \(extraction); result.requiresScript = !!doc.querySelector('[data-cipher-path],[data-cipher-decoder]'); return result;"
    }

    var imagesScript: String {
        #"""
        (() => {
          const roots = [...document.querySelectorAll('SELECTOR')];
          const nodes = roots.flatMap(r => r.matches('img') ? [r] : [...r.querySelectorAll('picture, img:not(picture img)')]);
          const urls = [], seen = new Set(); let pending = 0;
          function source(n) {
            for (const key of ['data-original','data-src','data-lazy-src','data-cfsrc']) {
              const v = n.getAttribute(key); if (v) return v;
            }
            const set = n.getAttribute('data-srcset') || n.getAttribute('srcset');
            if (set) return set.split(',').map(s=>s.trim().split(/\s+/)).sort((a,b)=>(parseFloat(b[1])||0)-(parseFloat(a[1])||0))[0][0];
            return n.currentSrc || n.getAttribute('src');
          }
          for (const n of nodes) {
            if (n.closest('.ads-wrapper,.ads,.advertisement,[data-ad]')) continue;
            const img = n.matches('picture') ? n.querySelector('img') : n;
            const choices = n.matches('picture') ? [...n.querySelectorAll('source'), img].filter(Boolean) : [n];
            let value = choices.map(source).find(Boolean);
            if (!value || /placeholder|loading\.(gif|png)|transparent|spacer/i.test(value)) { pending++; continue; }
            if (img && img.complete && img.naturalWidth > 0 && img.naturalWidth <= 2 && value === (img.currentSrc || img.src)) { pending++; continue; }
            try { value = new URL(value, location.href).href; } catch { pending++; continue; }
            if (!seen.has(value)) { seen.add(value); urls.push(value); }
          }
          const totals = roots.map(r=>Number(r.dataset.totalPages || r.dataset.pageCount || 0));
          return {urls, pending, total: Math.max(0,...totals), text: document.body.innerText.slice(0,12000)};
        })()
        """#.replacingOccurrences(of: "SELECTOR", with: imageSelector)
    }
}

nonisolated struct WebsiteDownloadError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
