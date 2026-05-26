//
//  SourceAggregator.swift
//  IPTVPlayer
//

import Foundation

actor SourceAggregator {

    // 默认源:优先使用 IPv4 流地址，避免大多数用户网络不支持 IPv6 的问题
    // 如果需要更多源(咪咕/体育等),用 UI 上的"+"号自助添加
    nonisolated static let defaultSources: [String] = [
        // fanmingming IPv4 版本（原 ipv6.m3u 已替换，IPv6 流在多数网络不通）
        "https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv4.m3u",
        // 中国频道聚合
        "https://iptv-org.github.io/iptv/countries/cn.m3u",
        // YueChan 整理的中文直播源（含港澳台）
        "https://raw.githubusercontent.com/YueChan/Live/main/IPTV.m3u",
        // YanG-1989 聚合源
        "https://raw.githubusercontent.com/YanG-1989/m3u/main/Gather.m3u",
        // joevess 中文聚合（补充更多可用频道）
        "https://raw.githubusercontent.com/joevess/IPTV/main/m3u/iptv.m3u",
        // 国际体育频道
        "https://iptv-org.github.io/iptv/categories/sports.m3u",
    ]

    // 可选追加源(用户可以选择附加)
    nonisolated static let optionalSources: [String: [String]] = [
        "咪咕": [
            "https://raw.githubusercontent.com/YueChan/Live/main/Migu.m3u",
            "https://raw.githubusercontent.com/YanG-1989/m3u/main/Migu.m3u",
        ],
        "海外体育": [
            "https://raw.githubusercontent.com/iptv-org/iptv/master/streams/us_sports.m3u",
            "https://raw.githubusercontent.com/iptv-org/iptv/master/streams/uk_sports.m3u",
            "https://raw.githubusercontent.com/imDazui/Tvlist-awesome-m3u-m3u8/master/m3u/Sports.m3u",
        ],
        "中文聚合": [
            "https://iptv-org.github.io/iptv/languages/zho.m3u",
            "https://live.fanmingming.com/tv/m3u/global.m3u",
            "https://raw.githubusercontent.com/joevess/IPTV/main/iptv-search.m3u",
        ],
        "国际精选": [
            "https://raw.githubusercontent.com/Free-TV/IPTV/master/playlist.m3u8",
        ],
    ]

    func fetchAll(from urls: [String]? = nil) async -> [Channel] {
        let catalog = Self.loadSourceCatalog()
        let sources = urls ?? (catalog.isEmpty ? Self.defaultSources : catalog)
        var merged: [String: Channel] = [:]
        var order: [String] = []

        await withTaskGroup(of: [Channel].self) { group in
            for u in sources {
                group.addTask { await Self.fetchOne(u) }
            }
            for await channels in group {
                for ch in channels {
                    if var existing = merged[ch.id] {
                        for s in ch.sources where !existing.sources.contains(where: { $0.url == s.url }) {
                            existing.sources.append(s)
                        }
                        if existing.logoURL == nil { existing.logoURL = ch.logoURL }
                        if existing.groupTitle == nil { existing.groupTitle = ch.groupTitle }
                        merged[ch.id] = existing
                    } else {
                        merged[ch.id] = ch
                        order.append(ch.id)
                    }
                }
            }
        }

        return order.compactMap { merged[$0] }
    }

    nonisolated private static func loadSourceCatalog() -> [String] {
        let fm = FileManager.default
        if let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let path = appSupport.appendingPathComponent("IPTVPlayer/source_catalog.json")
            if let data = try? Data(contentsOf: path),
               let urls = try? JSONDecoder().decode([String].self, from: data),
               !urls.isEmpty {
                return urls
            }
        }
        if let bundleURL = Bundle.main.url(forResource: "source_catalog", withExtension: "json"),
           let data = try? Data(contentsOf: bundleURL),
           let urls = try? JSONDecoder().decode([String].self, from: data),
           !urls.isEmpty {
            return urls
        }
        return []
    }

    nonisolated private static func fetchOne(_ urlString: String) async -> [Channel] {
        guard let url = URL(string: urlString) else { return [] }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("Mozilla/5.0 IPTVPlayer", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                print("Source \(urlString) returned HTTP \(http.statusCode)")
                return []
            }
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return M3UParser.parse(text)
        } catch {
            print("Failed to fetch \(urlString): \(error.localizedDescription)")
            return []
        }
    }
}
