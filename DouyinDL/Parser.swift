import Foundation
import CoreFoundation

// MARK: - 数据模型

enum MediaKind: String {
    case image, live, video
}

struct MediaItem: Identifiable, Hashable {
    let id = UUID()
    var kind: MediaKind
    var index: Int
    var url: String
    var name: String
    var width: Int
    var height: Int

    var isVideo: Bool { kind != .image }
}

struct ParsedWork {
    var awemeId: String
    var title: String
    var author: String
    var cover: String?
    var items: [MediaItem]
    var type: String
    var duration: Int
    var note: String

    var summary: String {
        let v = items.filter { $0.kind == .video }.count
        if v > 0 { return "视频 1 个 · \(items.first?.width ?? 0)×\(items.first?.height ?? 0)" }
        let imgN = items.filter { $0.kind == .image }.count
        let liveN = items.filter { $0.kind == .live }.count
        return "图片 \(imgN) 张" + (liveN > 0 ? " · 动图 \(liveN) 个" : "")
    }
}

enum ParseError: LocalizedError {
    case noLink
    case shortLinkDead
    case noId
    case noData
    case noMedia

    var errorDescription: String? {
        switch self {
        case .noLink:
            return "没找到抖音链接。请把整段分享口令粘贴进来。"
        case .shortLinkDead:
            return "短链打不开，可能已失效。请在抖音里重新复制一次链接。"
        case .noId:
            return "识别不出作品 ID。这个链接可能是主页、直播或合集，暂不支持。"
        case .noData:
            return "抖音没返回作品数据。作品可能已删除、设为私密，或临时限制了访问。稍等几秒再试。"
        case .noMedia:
            return "解析到作品了，但里面没有可下载的内容。"
        }
    }
}

// MARK: - 网络

final class Net {
    static let mobileUA =
        "Mozilla/5.0 (Linux; Android 13; V2227A) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/116.0.0.0 Mobile Safari/537.36"

    let session: URLSession

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 60
        session = URLSession(configuration: cfg)
    }

    @discardableResult
    func get(_ urlStr: String, referer: String? = "https://www.douyin.com/") async throws -> (Data, URL?) {
        guard let u = URL(string: urlStr) else { throw URLError(.badURL) }
        var req = URLRequest(url: u)
        req.setValue(Net.mobileUA, forHTTPHeaderField: "User-Agent")
        if let r = referer { req.setValue(r, forHTTPHeaderField: "Referer") }
        req.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
                     forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        return (data, resp.url)
    }

    var ttwid: String? {
        guard let host = URL(string: "https://www.iesdouyin.com") else { return nil }
        let cs = HTTPCookieStorage.shared.cookies(for: host) ?? []
        return cs.first(where: { $0.name == "ttwid" })?.value
    }
}

// MARK: - 解析器

enum DouyinParser {

    static func parse(_ input: String) async throws -> ParsedWork {
        let net = Net()
        guard let raw = extractURL(input) else { throw ParseError.noLink }

        var id = awemeID(raw)
        if id == nil {
            do {
                let (_, finalURL) = try await net.get(raw, referer: nil)
                if let f = finalURL?.absoluteString { id = awemeID(f) ?? awemeID(raw) }
            } catch {
                throw ParseError.shortLinkDead
            }
        }
        guard let awemeId = id else { throw ParseError.noId }

        let item = try await fetchItem(net: net, id: awemeId)
        return try build(item: item, id: awemeId)
    }

    // MARK: 链接提取

    static func extractURL(_ text: String) -> String? {
        let ns = text as NSString
        let pattern = "https?://[^\\s，,。、；;\"'）)】\\]]+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let found = re.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
        if found.isEmpty {
            let bare = "(?:v\\.douyin\\.com|www\\.douyin\\.com|www\\.iesdouyin\\.com)/[^\\s，,。、；\"']+"
            if let r2 = try? NSRegularExpression(pattern: bare),
               let m = r2.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                return "https://" + ns.substring(with: m.range)
            }
            return nil
        }
        func score(_ u: String) -> Int {
            if u.contains("v.douyin.com") { return 3 }
            if u.contains("douyin.com/video/") || u.contains("douyin.com/note/") { return 2 }
            if u.contains("douyin.com") { return 1 }
            return 0
        }
        return found.max(by: { score($0) < score($1) })
    }

    static func awemeID(_ url: String) -> String? {
        let patterns = [
            "/video/(\\d{15,25})",
            "/note/(\\d{15,25})",
            "/slides/(\\d{15,25})",
            "[?&]modal_id=(\\d{15,25})",
            "[?&]aweme_id=(\\d{15,25})",
            "/share/(?:video|note|slides)/(\\d{15,25})",
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p),
               let m = re.firstMatch(in: url, range: NSRange(location: 0, length: (url as NSString).length)),
               m.numberOfRanges > 1 {
                return (url as NSString).substring(with: m.range(at: 1))
            }
        }
        return nil
    }

    // MARK: 抓作品

    private static func fetchItem(net: Net, id: String) async throws -> [String: Any] {
        _ = try? await net.get("https://www.iesdouyin.com/share/video/\(id)/")
        if net.ttwid == nil { await registerTtwid() }

        for path in ["video", "note", "slides"] {
            let url = "https://www.iesdouyin.com/share/\(path)/\(id)/"
            guard let res = try? await net.get(url),
                  let html = decode(res.0),
                  html.contains("_ROUTER_DATA") else { continue }

            if let item = itemFrom(html: html) { return item }

            // 空壳页面：抖音偶尔要第二次带 ttwid 才给数据
            if net.ttwid == nil { await registerTtwid() }
            if let res2 = try? await net.get(url),
               let h2 = decode(res2.0),
               let item = itemFrom(html: h2) {
                return item
            }
        }
        throw ParseError.noData
    }

    private static func registerTtwid() async {
        let body = #"{"region":"cn","aid":1768,"needFid":false,"service":"www.ixigua.com","migrate_info":{"ticket":"","source":"node"},"cbUrlProtocol":"https","union":true}"#
        guard let u = URL(string: "https://ttwid.bytedance.com/ttwid/union/register/") else { return }
        var req = URLRequest(url: u)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://www.ixigua.com", forHTTPHeaderField: "Origin")
        req.setValue("https://www.ixigua.com/", forHTTPHeaderField: "Referer")
        req.setValue(Net.mobileUA, forHTTPHeaderField: "User-Agent")
        req.httpBody = body.data(using: .utf8)

        let cfg = URLSessionConfiguration.default
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpShouldSetCookies = true
        let s = URLSession(configuration: cfg)
        if let res = try? await s.data(for: req),
           let http = res.1 as? HTTPURLResponse,
           let ttwid = cookieValue("ttwid", in: http) {
            let c = HTTPCookie(properties: [
                .domain: ".iesdouyin.com",
                .path: "/",
                .name: "ttwid",
                .value: ttwid,
                .secure: "TRUE",
                .expires: Date().addingTimeInterval(86400 * 30),
            ])
            if let c = c { HTTPCookieStorage.shared.setCookie(c) }
        }
    }

    /// iOS 的 allHeaderFields 会合并多条 Set-Cookie，这里从原始串里兜底捞一次
    private static func cookieValue(_ name: String, in resp: HTTPURLResponse) -> String? {
        for (k, v) in resp.allHeaderFields {
            guard let key = k as? String, key.lowercased() == "set-cookie" else { continue }
            let s = String(describing: v)
            guard let r = s.range(of: name + "=") else { continue }
            let val = s[r.upperBound...].prefix(while: { $0 != ";" && $0 != "," && $0 != " " })
            if !val.isEmpty { return String(val) }
        }
        return nil
    }

    static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: gb))
    }

    // MARK: 从 HTML 抠 JSON

    static func cutRouterData(_ html: String) -> String? {
        guard let key = html.range(of: "_ROUTER_DATA") else { return nil }
        let tail = html[key.upperBound...]
        guard let brace = tail.firstIndex(of: "{") else { return nil }

        let chars = Array(html[brace...])
        var depth = 0
        var inStr = false
        var esc = false
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if inStr {
                if esc { esc = false }
                else if ch == "\\" { esc = true }
                else if ch == "\"" { inStr = false }
            } else {
                if ch == "\"" { inStr = true }
                else if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { return String(chars[0...i]) }
                }
            }
            i += 1
        }
        return nil
    }

    private static func itemFrom(html: String) -> [String: Any]? {
        guard let json = cutRouterData(html),
              let data = json.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        if let ld = root["loaderData"] as? [String: Any] {
            for (_, page) in ld {
                guard let p = page as? [String: Any],
                      let res = p["videoInfoRes"] as? [String: Any],
                      let list = res["item_list"] as? [[String: Any]],
                      let first = list.first,
                      first["aweme_id"] != nil
                else { continue }
                return first
            }
        }
        return deepFind(root, 0)
    }

    private static func deepFind(_ node: Any, _ depth: Int) -> [String: Any]? {
        if depth > 12 { return nil }
        if let dict = node as? [String: Any] {
            if dict["aweme_id"] != nil && (dict["video"] != nil || dict["images"] != nil) {
                return dict
            }
            for (_, v) in dict {
                if let r = deepFind(v, depth + 1) { return r }
            }
        } else if let arr = node as? [Any] {
            for v in arr {
                if let r = deepFind(v, depth + 1) { return r }
            }
        }
        return nil
    }

    // MARK: 组装可下载项

    struct VideoPick {
        var url: String
        var rate: Int
        var width: Int
        var height: Int
    }

    private static func intOf(_ v: Any?) -> Int {
        if let n = v as? NSNumber { return n.intValue }
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let i = Int(s) { return i }
        return 0
    }

    static func cleanURL(_ s: String?) -> String? {
        guard var u = s else { return nil }
        u = u.replacingOccurrences(of: "&amp;", with: "&")
        u = u.replacingOccurrences(of: "\\u002F", with: "/")
        u = u.trimmingCharacters(in: .whitespacesAndNewlines)
        return u.isEmpty ? nil : u
    }

    static func pickImage(_ img: [String: Any]) -> String? {
        let lists: [[String]] = [
            img["url_list"] as? [String] ?? [],
            img["download_url_list"] as? [String] ?? [],
        ]
        var fallback: String?
        for list in lists {
            for raw in list {
                guard let u = cleanURL(raw), u.hasPrefix("http") else { continue }
                if u.contains("water") { continue }
                if fallback == nil { fallback = u }
                let low = u.lowercased()
                if low.contains(".jpeg") || low.contains(".jpg") { return u }
            }
        }
        if let f = fallback { return f }
        for list in lists {
            for raw in list {
                if let u = cleanURL(raw), u.hasPrefix("http") { return u }
            }
        }
        return nil
    }

    static func pickVideo(_ video: [String: Any]) -> VideoPick? {
        var best: VideoPick?
        var bestRate = -1

        if let rates = video["bit_rate"] as? [[String: Any]] {
            for b in rates {
                guard let pa = b["play_addr"] as? [String: Any],
                      let list = pa["url_list"] as? [String],
                      let u = cleanURL(list.first) else { continue }
                let rate = intOf(b["bit_rate"])
                if rate >= bestRate {
                    bestRate = rate
                    best = VideoPick(url: u,
                                     rate: rate,
                                     width: intOf(pa["width"]) != 0 ? intOf(pa["width"]) : intOf(video["width"]),
                                     height: intOf(pa["height"]) != 0 ? intOf(pa["height"]) : intOf(video["height"]))
                }
            }
        }
        if best == nil, let pa = video["play_addr"] as? [String: Any],
           let list = pa["url_list"] as? [String], let u = cleanURL(list.first) {
            best = VideoPick(url: u, rate: 0,
                             width: intOf(pa["width"]) != 0 ? intOf(pa["width"]) : intOf(video["width"]),
                             height: intOf(pa["height"]) != 0 ? intOf(pa["height"]) : intOf(video["height"]))
        }
        if best == nil, let da = video["download_addr"] as? [String: Any],
           let list = da["url_list"] as? [String], let u = cleanURL(list.first) {
            best = VideoPick(url: u, rate: 0,
                             width: intOf(da["width"]) != 0 ? intOf(da["width"]) : intOf(video["width"]),
                             height: intOf(da["height"]) != 0 ? intOf(da["height"]) : intOf(video["height"]))
        }
        guard var b = best else { return nil }
        b.url = b.url.replacingOccurrences(of: "playwm", with: "play")
        return b
    }

    /// 图集作品顶层的 video 十有八九是背景音乐，尺寸跟图片走、时长为 0
    static func looksLikeAudio(_ video: [String: Any], _ pick: VideoPick) -> Bool {
        let dur = intOf(video["duration"])
        let u = pick.url
        if u.contains("tos-cn-ve-2774") || u.contains("douyinstatic.com") { return true }
        if dur == 0 { return true }
        if dur > 30000 { return true }
        return false
    }

    static func safeName(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        var out = s.components(separatedBy: bad).joined(separator: " ")
        out = out.components(separatedBy: .controlCharacters).joined(separator: " ")
        out = out.replacingOccurrences(of: "\n", with: " ")
        out = out.replacingOccurrences(of: "  ", with: " ")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func baseName(author: String, desc: String, id: String) -> String {
        var n = safeName(author + "_" + desc)
        if n.count > 40 { n = String(n.prefix(40)) }
        return n.isEmpty ? "douyin_" + id : n
    }

    private static func build(item: [String: Any], id: String) throws -> ParsedWork {
        let authorInfo = item["author"] as? [String: Any]
        let author = authorInfo?["nickname"] as? String ?? ""
        let desc = item["desc"] as? String ?? ""
        let base = baseName(author: author, desc: desc, id: id)
        let images = item["images"] as? [[String: Any]] ?? []
        var out: [MediaItem] = []
        var liveCount = 0

        var cover: String?
        if let v = item["video"] as? [String: Any],
           let c = v["cover"] as? [String: Any],
           let list = c["url_list"] as? [String],
           let u = cleanURL(list.first) {
            cover = u
        }

        if !images.isEmpty {
            for (i, img) in images.enumerated() {
                if let u = pickImage(img) {
                    let ext = u.lowercased().contains(".png") ? ".png" : ".jpg"
                    out.append(MediaItem(kind: .image, index: i + 1, url: u,
                                         name: "\(base)_\(i + 1)\(ext)",
                                         width: intOf(img["width"]),
                                         height: intOf(img["height"])))
                }
                if let iv = img["video"] as? [String: Any],
                   let best = pickVideo(iv),
                   !looksLikeAudio(iv, best) {
                    out.append(MediaItem(kind: .live, index: i + 1, url: best.url,
                                         name: "\(base)_\(i + 1)_动图.mp4",
                                         width: best.width, height: best.height))
                    liveCount += 1
                }
            }
            if liveCount == 0, let tv = item["video"] as? [String: Any],
               let best = pickVideo(tv), !looksLikeAudio(tv, best) {
                let dur = intOf(tv["duration"])
                if dur > 0 && dur <= 30000 {
                    out.append(MediaItem(kind: .live, index: 0, url: best.url,
                                         name: "\(base)_动图.mp4",
                                         width: best.width, height: best.height))
                    liveCount += 1
                }
            }
            out.sort { a, b in
                if a.index != b.index { return a.index < b.index }
                return a.kind == .image
            }
        } else if let v = item["video"] as? [String: Any], let best = pickVideo(v) {
            out.append(MediaItem(kind: .video, index: 1, url: best.url,
                                 name: "\(base).mp4",
                                 width: best.width, height: best.height))
        }

        guard !out.isEmpty else { throw ParseError.noMedia }

        let hasVideo = out.contains { $0.kind == .video }
        let note: String
        if !hasVideo && liveCount == 0 {
            note = "这条是 live 动图作品。抖音对未登录访问只提供高清封面原图，动图视频需要登录态才能取到，所以这里给到的是原图。"
        } else {
            note = ""
        }

        return ParsedWork(awemeId: id,
                          title: desc,
                          author: author,
                          cover: cover,
                          items: out,
                          type: hasVideo ? "video" : "images",
                          duration: intOf((item["video"] as? [String: Any])?["duration"]) / 1000,
                          note: note)
    }
}
