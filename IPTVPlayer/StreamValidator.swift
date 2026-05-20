//
//  StreamValidator.swift
//  IPTVPlayer
//

import Foundation

actor StreamValidator {

    nonisolated static func validate(_ source: StreamSource) async -> StreamSource {
        var result = source
        result.lastChecked = Date()

        guard let url = URL(string: source.url) else {
            result.score = -1
            return result
        }

        // 验证策略:
        // 1. 用 Range header 只取头部 8KB,减少带宽
        // 2. 超时拉长到 10s
        // 3. 用 AVFoundation 风格的 UA,提升服务器接受率
        // 4. 网络错误不直接打红,降权为黄(因为 AVPlayer 可能仍能播放)
        // 5. 只有完全失败(无响应/DNS)才打红
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "GET"
        req.setValue("bytes=0-8191", forHTTPHeaderField: "Range")
        // 使用类似 AVFoundation/Safari 的 User-Agent
        let defaultUA = source.userAgent
            ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        req.setValue(defaultUA, forHTTPHeaderField: "User-Agent")
        if let ref = source.referer { req.setValue(ref, forHTTPHeaderField: "Referer") }

        let start = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            result.latencyMs = Int(Date().timeIntervalSince(start) * 1000)

            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            // 2xx, 206 (partial content), 3xx: 全部视为可达
            if (200...299).contains(statusCode) || statusCode == 206 || (300...399).contains(statusCode) {
                let head = data.prefix(8192)
                if let text = String(data: head, encoding: .utf8),
                   text.contains("#EXTM3U") || text.contains("#EXTINF") {
                    result.score = 1.0  // 明确是 HLS playlist
                } else if data.count > 0 {
                    result.score = 0.7  // 有数据返回,可能是直推或 master 嵌套
                } else {
                    result.score = 0.3  // 空响应但 HTTP 成功
                }
                result.lastWorked = Date()
            } else if statusCode == 403 || statusCode == 404 || statusCode == 410 {
                // 客户端错误:服务器明确拒绝,可能仍可播但概率小
                result.score = 0.1
            } else {
                // 其他 4xx/5xx:不确定,给黄色
                result.score = 0.3
            }
        } catch let error as URLError {
            // 注意:URLSession 报错不代表 AVPlayer 也会失败
            // (DNS 路由、IPv6 fallback、UA 接受度都可能不同)
            // 所以即便是 DNS/连接失败,这里也不打红,只降权
            switch error.code {
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .notConnectedToInternet:
                result.score = 0.05  // 几乎肯定不行,但留给用户尝试
            case .timedOut:
                result.score = 0.1
            default:
                result.score = 0.2
            }
        } catch {
            result.score = 0.2
        }

        return result
    }

    func validateChannel(_ channel: Channel, limit: Int = 3) async -> Channel {
        var updated = channel
        let toCheck = Array(channel.sources.prefix(limit))
        let rest = Array(channel.sources.dropFirst(limit))

        var validated: [StreamSource] = []
        await withTaskGroup(of: StreamSource.self) { group in
            for s in toCheck {
                group.addTask { await Self.validate(s) }
            }
            for await v in group { validated.append(v) }
        }

        updated.sources = (validated + rest).sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return (lhs.latencyMs ?? Int.max) < (rhs.latencyMs ?? Int.max)
        }
        return updated
    }
}
