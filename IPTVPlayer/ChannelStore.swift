//
//  ChannelStore.swift
//  IPTVPlayer
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class ChannelStore: ObservableObject {

    // 显式声明 nonisolated 的 objectWillChange,
    // 否则 @MainActor 类下自动合成的会被推断成 MainActor 隔离,
    // 不满足 ObservableObject 协议要求 -> 编译报"does not conform"。
    nonisolated let objectWillChange = ObservableObjectPublisher()

    @Published var channels: [Channel] = []
    @Published var isRefreshing: Bool = false
    @Published var refreshProgress: String = ""
    @Published var lastRefreshDate: Date?

    // channelId -> WatchRecord
    @Published private(set) var watchHistory: [String: WatchRecord] = [:]

    /// 最近观看，最多 20 条，按时间倒序
    var recentChannels: [Channel] {
        watchHistory.values
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .prefix(20)
            .compactMap { rec in channels.first { $0.id == rec.channelId } }
    }

    /// 猜你喜欢：同分组未看过的频道，按兴趣分综合评分排序
    var recommendedChannels: [Channel] {
        let recentIds = Set(recentChannels.map { $0.id })
        let interestGroups = Set(
            channels
                .filter { $0.isFavorite || recentIds.contains($0.id) }
                .compactMap { $0.groupTitle }
        )
        guard !interestGroups.isEmpty else { return [] }

        return channels
            .filter { !recentIds.contains($0.id) }
            .map { ch -> (Channel, Int) in
                let wc = watchHistory[ch.id]?.watchCount ?? 0
                let score = (ch.isFavorite ? 200 : 0)
                    + (interestGroups.contains(ch.groupTitle ?? "") ? 100 : 0)
                    + wc * 10
                    + Int((ch.bestSource?.score ?? 0) * 5)
                return (ch, score)
            }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(20)
            .map { $0.0 }
    }

    private let aggregator = SourceAggregator()
    private let validator = StreamValidator()
    private var refreshTimer: Timer?

    private var storeURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("IPTVPlayer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("channels.json")
    }

    private struct StoredData: Codable {
        var channels: [Channel]
        var lastRefreshDate: Date?
        var watchHistory: [String: WatchRecord]?
    }

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode(StoredData.self, from: data) else {
            return
        }
        channels = decoded.channels
        lastRefreshDate = decoded.lastRefreshDate
        watchHistory = decoded.watchHistory ?? [:]
    }

    func save() {
        let payload = StoredData(channels: channels,
                                 lastRefreshDate: lastRefreshDate,
                                 watchHistory: watchHistory)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }

    func recordWatch(_ channelId: String) {
        let existing = watchHistory[channelId]
        watchHistory[channelId] = WatchRecord(
            channelId: channelId,
            lastWatchedAt: Date(),
            watchCount: (existing?.watchCount ?? 0) + 1
        )
        save()
    }

    /// 清除本地缓存并强制重新拉取所有频道（用于修复旧数据积累的失效流地址）
    func clearAndRefresh() async {
        validationTask?.cancel()
        channels = []
        lastRefreshDate = nil
        try? FileManager.default.removeItem(at: storeURL)
        await refresh()
    }

    func refreshIfNeeded() async {
        if channels.isEmpty {
            await refresh()
            return
        }
        if let last = lastRefreshDate,
           Date().timeIntervalSince(last) > 24 * 3600 {
            await refresh()
        }
    }

    /// 后台验证任务句柄,允许取消
    private var validationTask: Task<Void, Never>?

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        // 取消任何正在进行的验证
        validationTask?.cancel()

        refreshProgress = "正在拉取频道列表..."
        let fetched = await aggregator.fetchAll()

        guard !fetched.isEmpty else {
            refreshProgress = "拉取失败,保留现有频道"
            isRefreshing = false
            save()
            return
        }

        let favoriteIDs = Set(channels.filter { $0.isFavorite }.map { $0.id })
        let oldSourceByURL: [String: StreamSource] = Dictionary(
            channels.flatMap { $0.sources }.map { ($0.url, $0) },
            uniquingKeysWith: { a, _ in a }
        )

        channels = fetched.map { ch -> Channel in
            var c = ch
            c.isFavorite = favoriteIDs.contains(c.id)
            c.sources = c.sources.map { src in
                if let known = oldSourceByURL[src.url] {
                    var merged = src
                    merged.score = known.score
                    merged.lastChecked = known.lastChecked
                    merged.lastWorked = known.lastWorked
                    merged.latencyMs = known.latencyMs
                    return merged
                }
                return src
            }
            return c
        }

        lastRefreshDate = Date()
        refreshProgress = "已加载 \(channels.count) 个频道"
        save()

        // 刷新结束:列表已可见,UI 不再处于"loading"状态
        isRefreshing = false

        // 在后台静默地异步验证(不阻塞 UI,不显示进度阻碍交互)
        validationTask = Task { [weak self] in
            await self?.validateAllInBackground()
        }
    }

    /// 后台验证:大并发、短超时、不阻塞 UI、可取消
    private func validateAllInBackground() async {
        let total = channels.count
        let chunkSize = 48  // 大幅提升并发(原来 8)
        let localValidator = validator

        for start in stride(from: 0, to: channels.count, by: chunkSize) {
            if Task.isCancelled { break }
            let end = min(start + chunkSize, channels.count)
            let slice = Array(channels[start..<end])

            await withTaskGroup(of: Channel.self) { group in
                for ch in slice {
                    group.addTask { await localValidator.validateChannel(ch, limit: 1) }
                }
                for await updated in group {
                    if Task.isCancelled { break }
                    if let idx = channels.firstIndex(where: { $0.id == updated.id }) {
                        channels[idx] = updated
                    }
                }
            }
        }
        if !Task.isCancelled {
            refreshProgress = ""
            save()
        }
    }

    func cancelValidation() {
        validationTask?.cancel()
        refreshProgress = ""
    }

    func toggleFavorite(_ channel: Channel) {
        guard let idx = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[idx].isFavorite.toggle()
        save()
    }

    func scheduleDailyRefresh() {
        refreshTimer?.invalidate()
        // Timer 闭包是 @Sendable 的;用弱引用并跳回 MainActor 上下文
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    func importLocal(url: URL) {
        // 处理 macOS 安全沙盒下的安全作用域资源
        let needsScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if needsScopedAccess { url.stopAccessingSecurityScopedResource() }
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            refreshProgress = "无法读取文件: \(url.lastPathComponent)"
            return
        }
        mergeChannels(M3UParser.parse(text))
        refreshProgress = "导入完成: \(url.lastPathComponent)"
    }

    /// 通过用户提供的 URL 添加一个 m3u 源(支持 http/https/file)
    func addRemoteSource(_ urlString: String) async {
        guard let url = URL(string: urlString) else {
            refreshProgress = "无效 URL"
            return
        }
        if url.isFileURL {
            importLocal(url: url)
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            refreshProgress = ""
            save()
        }
        refreshProgress = "正在拉取 \(url.host ?? urlString)..."
        do {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("IPTVPlayer/1.0", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let text = String(data: data, encoding: .utf8) else {
                refreshProgress = "无法解码"
                return
            }
            mergeChannels(M3UParser.parse(text))
            refreshProgress = "已添加,共 \(channels.count) 个频道"
        } catch {
            refreshProgress = "失败: \(error.localizedDescription)"
        }
    }

    private func mergeChannels(_ imported: [Channel]) {
        let favoriteIDs = Set(channels.filter { $0.isFavorite }.map { $0.id })

        var byID: [String: Channel] = Dictionary(uniqueKeysWithValues: channels.map { ($0.id, $0) })
        for ch in imported {
            if var existing = byID[ch.id] {
                for s in ch.sources where !existing.sources.contains(where: { $0.url == s.url }) {
                    existing.sources.append(s)
                }
                byID[ch.id] = existing
            } else {
                var c = ch
                c.isFavorite = favoriteIDs.contains(c.id)
                byID[c.id] = c
            }
        }
        channels = Array(byID.values).sorted { $0.name < $1.name }
        save()
    }
}
