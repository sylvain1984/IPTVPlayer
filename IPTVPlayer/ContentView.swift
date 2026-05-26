//
//  ContentView.swift
//  IPTVPlayer
//

import SwiftUI
import UniformTypeIdentifiers

private enum ChannelFilterMode: String, CaseIterable {
    case all         = "全部"
    case exclusive   = "专属"
    case favorites   = "收藏"
    case recent      = "最近"
    case recommended = "推荐"
}

struct ContentView: View {
    @EnvironmentObject var store: ChannelStore
    @State private var selectedChannelID: String?
    @State private var searchText: String = ""
    @State private var selectedGroup: String? = nil
    @State private var selectedSubcategory: String? = nil
    @State private var filterMode: ChannelFilterMode = .all
    @State private var manualSourceURL: String?
    @State private var pendingPINChannel: Channel? = nil
    @State private var unlockedChannelIDs: Set<String> = []
    @State private var showAddURLSheet = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var isRtcFullscreen = false
    @State private var newSourceURL = ""
    @State private var showFileImporter = false


    private var selectedChannel: Channel? {
        guard let id = selectedChannelID else { return nil }
        return store.channels.first { $0.id == id }
    }

    private var activeSource: StreamSource? {
        guard let ch = selectedChannel else { return nil }
        if let url = manualSourceURL, let s = ch.sources.first(where: { $0.url == url }) {
            return s
        }
        return ch.bestSource
    }

    private var groups: [String] {
        Array(Set(store.channels.filter { !$0.isRtc }.compactMap { $0.groupTitle })).sorted()
    }

    private let subcategoryOrder = ["儿童", "地方", "港澳台", "纪录片", "动漫", "音乐", "赛事专区"]

    private var availableSubcategories: [String] {
        subcategoryOrder.filter { tag in
            store.channels.contains { !$0.isRtc && matchesSubcategory($0, tag: tag) }
        }
    }

    private var filteredChannels: [Channel] {
        let base: [Channel]
        switch filterMode {
        case .exclusive:
            base = store.channels.filter { $0.isRtc }
        case .favorites:
            base = store.channels.filter { $0.isFavorite }
        case .recent:
            base = store.recentChannels
        case .recommended:
            base = store.recommendedChannels
        case .all:
            base = store.channels.filter { ch in
                if ch.isRtc { return false }
                if let g = selectedGroup, ch.groupTitle != g { return false }
                if let sub = selectedSubcategory, !matchesSubcategory(ch, tag: sub) { return false }
                return true
            }
        }
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 420)
        } detail: {
            detail
        }
        .onChange(of: isRtcFullscreen) { _, fullscreen in
            let window = NSApp.keyWindow
            let isWindowFS = window?.styleMask.contains(.fullScreen) ?? false
            if fullscreen {
                columnVisibility = .detailOnly
                if !isWindowFS { window?.toggleFullScreen(nil) }
            } else {
                columnVisibility = .automatic
                if isWindowFS { window?.toggleFullScreen(nil) }
            }
        }
        .sheet(isPresented: $showAddURLSheet) {
            addURLSheet
        }
        .sheet(item: $pendingPINChannel) { ch in
            PINEntryView(channel: ch) { unlocked in
                unlockedChannelIDs.insert(unlocked.id)
                selectedChannelID = unlocked.id
                store.recordWatch(unlocked.id)
            }
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: fileImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    store.importLocal(url: url)
                }
            case .failure(let err):
                print("File importer error: \(err)")
            }
        }
    }

    private var fileImportTypes: [UTType] {
        var types: [UTType] = [.plainText, .text, .data]
        if let m3u = UTType(filenameExtension: "m3u") { types.append(m3u) }
        if let m3u8 = UTType(filenameExtension: "m3u8") { types.append(m3u8) }
        return types
    }

    private var addURLSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("添加 m3u 源").font(.headline)
            TextField("https://example.com/playlist.m3u",
                      text: $newSourceURL)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 420)

            // 一键添加预设源组
            Text("或选择预设源组:").font(.caption).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(SourceAggregator.optionalSources.keys.sorted()), id: \.self) { key in
                        Button(key) {
                            let urls = SourceAggregator.optionalSources[key] ?? []
                            showAddURLSheet = false
                            Task {
                                for u in urls { await store.addRemoteSource(u) }
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") { showAddURLSheet = false }
                Button("添加") {
                    let url = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    showAddURLSheet = false
                    newSourceURL = ""
                    Task { await store.addRemoteSource(url) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()

                if let last = store.lastRefreshDate {
                    Text(last.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button {
                    Task { await store.refresh() }
                } label: {
                    if store.isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.isRefreshing)
                .help("立即刷新")

                // 把次要操作收进 Menu,避免标题栏挤
                Menu {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("导入本地 .m3u 文件", systemImage: "folder")
                    }

                    Button {
                        showAddURLSheet = true
                    } label: {
                        Label("添加自定义 URL", systemImage: "link.badge.plus")
                    }

                    Divider()

                    Button(role: .destructive) {
                        store.cancelValidation()
                    } label: {
                        Label("停止后台验证", systemImage: "stop.circle")
                    }

                    Divider()

                    Button(role: .destructive) {
                        Task { await store.clearAndRefresh() }
                    } label: {
                        Label("清除缓存并重新拉取", systemImage: "trash.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 28)
                .help("更多")
            }
            .padding(8)

            if !store.refreshProgress.isEmpty {
                HStack(spacing: 4) {
                    if store.isRefreshing {
                        ProgressView().controlSize(.mini)
                    }
                    Text(store.refreshProgress)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ChannelFilterMode.allCases, id: \.self) { mode in
                        Button(mode.rawValue) { filterMode = mode }
                            .buttonStyle(.borderedProminent)
                            .tint(filterMode == mode ? .accentColor : .secondary.opacity(0.25))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }

            // 分类与子类合并为一条筛选带
            if filterMode == .all, (!groups.isEmpty || !availableSubcategories.isEmpty) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button("全部筛选") {
                            selectedGroup = nil
                            selectedSubcategory = nil
                        }
                            .buttonStyle(.bordered)
                            .tint(selectedGroup == nil && selectedSubcategory == nil ? .accentColor : .secondary.opacity(0.3))
                        ForEach(groups, id: \.self) { g in
                            Button(g) {
                                selectedSubcategory = nil
                                selectedGroup = (selectedGroup == g ? nil : g)
                            }
                                .buttonStyle(.bordered)
                                .tint(selectedGroup == g ? .accentColor : .secondary.opacity(0.3))
                        }
                        ForEach(availableSubcategories, id: \.self) { tag in
                            Button("·\(tag)") {
                                selectedGroup = nil
                                selectedSubcategory = (selectedSubcategory == tag ? nil : tag)
                            }
                                .buttonStyle(.bordered)
                                .tint(selectedSubcategory == tag ? .accentColor : .secondary.opacity(0.3))
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                }
            }

            Divider()

            // 列表区永远占据剩余高度,即使在拉取/验证中也保持可见
            List(selection: $selectedChannelID) {
                if filteredChannels.isEmpty && !store.channels.isEmpty {
                    Text(filterMode == .exclusive ? "暂无可用专属频道" : "无匹配结果")
                        .foregroundStyle(.secondary)
                        .padding()
                } else if store.channels.isEmpty && !store.isRefreshing {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("暂无频道").foregroundStyle(.secondary)
                        Text("点击 ⟳ 刷新,或 ⋯ 菜单导入本地/添加 URL")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding()
                } else {
                    ForEach(filteredChannels) { ch in
                        ChannelRow(channel: ch) {
                            store.toggleFavorite(ch)
                        }
                        .tag(ch.id)
                        .contextMenu {
                            Button(ch.isFavorite ? "取消收藏" : "收藏") {
                                store.toggleFavorite(ch)
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "搜索频道")
        }
        .onChange(of: selectedChannelID) { _, newID in
            manualSourceURL = nil
            guard let id = newID, let ch = store.channels.first(where: { $0.id == id }) else { return }
            if ch.isRtc, ch.pinHash != nil, !unlockedChannelIDs.contains(id) {
                // Deselect and show PIN sheet
                selectedChannelID = nil
                pendingPINChannel = ch
            } else if !ch.isRtc {
                store.recordWatch(id)
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let ch = selectedChannel, (ch.isRtc || activeSource != nil) {
            let src = activeSource  // RTC 时为 nil，不影响
            VStack(spacing: 0) {
                if !isRtcFullscreen {
                    HStack(alignment: .center, spacing: 12) {
                        Text(ch.name).font(.title2).bold()

                        Button {
                            store.toggleFavorite(ch)
                        } label: {
                            Image(systemName: ch.isFavorite ? "star.fill" : "star")
                                .foregroundStyle(ch.isFavorite ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)

                        if let group = ch.groupTitle {
                            Text(group)
                                .font(.caption)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15))
                                .clipShape(Capsule())
                        }

                        Spacer()

                        if let latency = src?.latencyMs {
                            Label("\(latency) ms", systemImage: "speedometer")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }

                if ch.isRtc {
                    RtcViewerPanel(roomId: ch.rtcRoomId, isFullscreen: $isRtcFullscreen)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let src = src {
                    PlayerContainerView(source: src)
                        .id(src.url)
                        .aspectRatio(16.0/9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !ch.isRtc && ch.sources.count > 1, let src = src {
                    sourcePicker(for: ch, current: src)
                }
            }
        } else {
            ContentUnavailableView {
                Label("选择一个频道", systemImage: "tv")
            } description: {
                Text(store.channels.isEmpty
                     ? "点击右上角刷新按钮拉取频道列表"
                     : "从左侧列表选择一个频道开始观看")
            }
        }
    }

    private func sourcePicker(for channel: Channel, current: StreamSource) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("可用源 (\(channel.sources.count))")
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(channel.sources) { src in
                        Button {
                            manualSourceURL = src.url
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(scoreColor(src.score))
                                    .frame(width: 6, height: 6)
                                Text(short(src.url))
                                    .lineLimit(1)
                                    .font(.caption)
                                if let l = src.latencyMs {
                                    Text("\(l)ms").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(src.url == current.url
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func scoreColor(_ score: Double) -> Color {
        if score >= 1.0 { return .green }
        if score >= 0.5 { return .yellow }
        if score > 0 { return .orange }
        return .gray
    }

    private func short(_ url: String) -> String {
        guard let host = URL(string: url)?.host else { return url }
        return host
    }
}

private extension ContentView {
    func matchesSubcategory(_ ch: Channel, tag: String) -> Bool {
        let text = "\(ch.name) \(ch.groupTitle ?? "")".lowercased()
        switch tag {
        case "儿童":
            return ["儿童", "少儿", "卡通", "动漫", "动画", "亲子", "kid"].contains { text.contains($0) }
        case "地方":
            return ["卫视", "地方", "都市", "公共", "新闻综合", "经济生活"].contains { text.contains($0) }
        case "港澳台":
            return ["香港", "澳门", "台湾", "tvb", "翡翠", "hk", "tw"].contains { text.contains($0) }
        case "纪录片":
            return ["纪录", "documentary", "discovery", "国家地理"].contains { text.contains($0) }
        case "动漫":
            return ["动漫", "动画", "anime", "二次元", "卡通"].contains { text.contains($0) }
        case "音乐":
            return ["音乐", "music", "mtv", "演唱会"].contains { text.contains($0) }
        case "赛事专区":
            return ["英超", "西甲", "欧冠", "nba", "cba", "ufc", "f1", "nfl", "mlb"].contains { text.contains($0) }
        default:
            return false
        }
    }
}

struct ChannelRow: View {
    let channel: Channel
    var onToggleFavorite: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            logo
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).lineLimit(1)
                HStack(spacing: 6) {
                    statusDot
                    Text("\(channel.sources.count) 源")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let group = channel.groupTitle {
                        Text(group)
                            .font(.caption2).foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 4)

            Button(action: onToggleFavorite) {
                Image(systemName: channel.isFavorite ? "star.fill" : "star")
                    .font(.body)
                    .foregroundStyle(channel.isFavorite ? .yellow : Color.secondary.opacity(0.6))
                    .contentShape(Rectangle())
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .help(channel.isFavorite ? "取消收藏" : "收藏")
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var logo: some View {
        if let urlStr = channel.logoURL, let url = URL(string: urlStr) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit()
                default:
                    Image(systemName: "tv").foregroundStyle(.secondary)
                }
            }
        } else {
            Image(systemName: "tv").foregroundStyle(.secondary)
        }
    }

    private var statusDot: some View {
        let score = channel.bestSource?.score ?? 0
        let color: Color = {
            if score >= 1.0 { return .green }
            if score >= 0.5 { return .yellow }
            if score > 0 { return .orange }
            return .gray
        }()
        return Circle().fill(color).frame(width: 6, height: 6)
    }
}
