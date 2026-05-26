//
//  M3UParser.swift
//  IPTVPlayer
//

import Foundation

enum M3UParser {

    // MARK: - 分组规范化：把任意 group-title 映射到更清晰的固定类别
    // 匹配规则：逐条关键词匹配（不区分大小写），未命中的归入"综合"
    static let normalizedGroups = ["综合", "新闻", "体育", "影视", "儿童", "国际"]

    nonisolated static func normalizeGroup(_ raw: String?) -> String {
        guard let g = raw, !g.isEmpty else { return "综合" }
        let lower = g.lowercased()

        // 新闻
        let news = ["新闻", "news", "资讯", "财经", "cctv-13", "cctv13",
                    "凤凰资讯", "nbс news", "cnn", "bbc", "时事"]
        if news.contains(where: { lower.contains($0) }) { return "新闻" }

        // 体育
        let sports = ["体育", "sport", "足球", "篮球", "网球", "赛事", "运动",
                      "football", "basketball", "tennis", "golf", "esport",
                      "电竞", "奥运", "olympic"]
        if sports.contains(where: { lower.contains($0) }) { return "体育" }

        // 影视
        let movie = ["电影", "影院", "影视", "剧场", "电视剧", "综艺", "纪录", "music", "音乐"]
        if movie.contains(where: { lower.contains($0) }) { return "影视" }

        // 儿童
        let kids = ["少儿", "卡通", "动漫", "儿童", "亲子", "动画", "kid"]
        if kids.contains(where: { lower.contains($0) }) { return "儿童" }

        // 国际（港澳台 + 海外）
        let intl = ["国际", "海外", "港", "澳", "台", "tvb", "hk", "tw",
                    "international", "global", "world", "欧美", "日本",
                    "韩国", "英国", "美国", "france", "germany", "japan",
                    "korea", "uk", "us", "foreign", "境外"]
        if intl.contains(where: { lower.contains($0) }) { return "国际" }

        return "综合"
    }

    nonisolated static func parse(_ content: String) -> [Channel] {
        var byID: [String: Channel] = [:]
        var ordered: [String] = []

        var name: String?
        var tvgID: String?
        var logo: String?
        var group: String?
        var userAgent: String?
        var referer: String?

        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTM3U") {
                continue
            } else if line.hasPrefix("#EXTINF:") {
                tvgID = extractAttr(from: line, name: "tvg-id")
                logo = extractAttr(from: line, name: "tvg-logo")
                group = extractAttr(from: line, name: "group-title")
                userAgent = nil
                referer = nil

                if let commaIdx = line.lastIndex(of: ",") {
                    name = line[line.index(after: commaIdx)...]
                        .trimmingCharacters(in: .whitespaces)
                }
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let opt = String(line.dropFirst("#EXTVLCOPT:".count))
                if let v = stripPrefix(opt, "http-user-agent=") { userAgent = v }
                if let v = stripPrefix(opt, "http-referrer=") { referer = v }
            } else if line.hasPrefix("#KODIPROP:") {
                continue
            } else if line.hasPrefix("#") {
                continue
            } else if let n = name, let url = URL(string: line), url.scheme != nil {
                let id = (tvgID?.isEmpty == false ? tvgID! : n)
                let src = StreamSource(url: line, userAgent: userAgent, referer: referer)

                if var existing = byID[id] {
                    if !existing.sources.contains(where: { $0.url == line }) {
                        existing.sources.append(src)
                        byID[id] = existing
                    }
                } else {
                    byID[id] = Channel(
                        id: id,
                        name: n,
                        logoURL: logo,
                        groupTitle: normalizeGroup(group),
                        sources: [src]
                    )
                    ordered.append(id)
                }

                name = nil
                tvgID = nil
                logo = nil
                group = nil
                userAgent = nil
                referer = nil
            }
        }

        return ordered.compactMap { byID[$0] }
    }

    nonisolated private static func extractAttr(from line: String, name: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        if let match = regex.firstMatch(in: line, range: range),
           let r = Range(match.range(at: 1), in: line) {
            return String(line[r])
        }
        return nil
    }

    nonisolated private static func stripPrefix(_ s: String, _ prefix: String) -> String? {
        s.hasPrefix(prefix) ? String(s.dropFirst(prefix.count)) : nil
    }
}
