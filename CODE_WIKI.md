# IPTVPlayer Code Wiki

## 1. 项目概览

`IPTVPlayer` 是一个基于 `SwiftUI` 构建的 macOS 原生 IPTV 播放器。项目目标非常聚焦：

- 聚合多个公开 m3u 直播源
- 将频道解析为统一的数据模型
- 在本地缓存频道与验证结果
- 后台验证流地址质量并为频道自动排序最优源
- 使用 `AVPlayer` 在 macOS 上直接播放选中的直播流

当前仓库是一个单目标、轻量单体应用，没有引入第三方依赖管理器，主要依赖 Apple 官方框架。

---

## 2. 仓库结构

```text
IPTVPlayer/
├── IPTVPlayer/
│   ├── Assets.xcassets/          # 图标与颜色资源
│   ├── IPTVPlayerApp.swift       # App 入口
│   ├── ContentView.swift         # 主界面与交互层
│   ├── ChannelStore.swift        # 状态中心与业务编排
│   ├── Models.swift              # 核心数据模型
│   ├── M3UParser.swift           # m3u 解析器
│   ├── SourceAggregator.swift    # 多源抓取与聚合
│   ├── StreamValidator.swift     # 流可用性验证与评分
│   ├── PlayerView.swift          # AVPlayer 播放封装
│   └── Info.plist                # ATS 网络配置
└── IPTVPlayer.xcodeproj/
    └── project.pbxproj           # Xcode 工程配置
```

这个项目没有复杂的 feature 目录拆分，而是采用“按职责拆文件”的轻量结构。对于当前体量，这种方式简单直接，阅读成本低。

---

## 3. 技术栈与系统依赖

### 3.1 开发技术

- 语言：`Swift 5`
- UI：`SwiftUI`
- 播放：`AVKit`、`AVFoundation`
- 状态管理：`ObservableObject`、`@Published`、`@StateObject`、`@EnvironmentObject`
- 并发：`Swift Concurrency`（`async/await`、`TaskGroup`、`actor`）
- 持久化：`Codable` + 本地 `JSON`
- 网络：`URLSession`

### 3.2 系统配置

- 目标平台：`macOS`
- 工程产物：macOS App
- Bundle ID：`yue.IPTVPlayer`
- 开启 App Sandbox
- `Info.plist` 中放宽了 ATS 限制：
  - `NSAllowsArbitraryLoads = true`
  - `NSAllowsArbitraryLoadsForMedia = true`

这些配置说明该应用需要访问大量第三方直播源地址，其中很多地址并不完全符合默认 ATS 要求，因此必须允许更宽松的网络访问策略。

---

## 4. 整体架构

### 4.1 架构摘要

项目整体可以理解为以下 5 层：

1. 应用层：负责启动与生命周期管理
2. 视图层：负责界面展示、交互与播放区域布局
3. 状态/业务层：负责频道刷新、导入、收藏、缓存、后台验证调度
4. 数据处理层：负责远程源聚合、m3u 解析、流质量验证
5. 基础设施层：本地持久化、系统播放器、网络请求

### 4.2 架构关系图

```text
IPTVPlayerApp
    |
    v
ContentView <-------------------------------+
    |                                       |
    | 读取/触发动作                         | 发布状态
    v                                       |
ChannelStore -------------------------------+
    |            |                |
    |            |                |
    v            v                v
SourceAggregator M3UParser   StreamValidator
    |                             |
    v                             v
URLSession                    URLSession
    |
    v
远程 m3u 源

ContentView
    |
    v
PlayerContainerView -> PlayerView -> AVPlayer / AVPlayerItem / AVURLAsset
```

### 4.3 主调用链

```text
应用启动
-> IPTVPlayerApp 创建 ChannelStore
-> IPTVPlayerApp 在 WindowGroup 中注入 ContentView + environmentObject
-> IPTVPlayerApp 的 .task 调用 refreshIfNeeded()
-> ChannelStore.refresh()
-> SourceAggregator.fetchAll()
-> M3UParser.parse()
-> ChannelStore 合并结果并保存到 channels.json
-> ChannelStore.validateAllInBackground()
-> StreamValidator.validateChannel()
-> ContentView 展示频道列表
-> 用户选择频道
-> ContentView 根据 manualSourceURL / Channel.bestSource 计算 activeSource
-> PlayerView 创建 AVPlayer 并播放已选中的源
```

---

## 5. 启动流程

### 5.1 应用入口：`IPTVPlayerApp`

文件：`IPTVPlayer/IPTVPlayerApp.swift`

职责：

- 声明应用主入口 `@main`
- 创建全局共享的 `ChannelStore`
- 把 `ChannelStore` 通过 `environmentObject` 注入根视图
- 启动后执行首次刷新逻辑
- 注册“立即刷新频道”的菜单命令

关键行为：

- `channelStore.refreshIfNeeded()`
  - 如果本地没有缓存频道，则立即拉取
  - 如果上次刷新超过 24 小时，则重新拉取
- `channelStore.scheduleDailyRefresh()`
  - 启动一个 24 小时定时器，做周期性自动刷新

---

## 6. 核心数据模型

文件：`IPTVPlayer/Models.swift`

### 6.1 `Channel`

表示一个可展示和播放的频道。

字段说明：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | `String` | 频道唯一标识，优先取 `tvg-id`，否则取频道名 |
| `name` | `String` | 频道显示名称 |
| `logoURL` | `String?` | 频道 logo 地址 |
| `groupTitle` | `String?` | 频道分组，经过规范化处理 |
| `sources` | `[StreamSource]` | 频道对应的多个流地址 |
| `isFavorite` | `Bool` | 是否收藏 |

关键计算属性：

- `bestSource`
  - 按 `score` 降序排序
  - 分数相同则按 `latencyMs` 升序
  - 返回当前最优流地址

### 6.2 `StreamSource`

表示某个频道的一个具体流地址。

字段说明：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `url` | `String` | 流地址 |
| `userAgent` | `String?` | 播放或验证时使用的 UA |
| `referer` | `String?` | 播放或验证时使用的 Referer |
| `score` | `Double` | 可用性评分 |
| `lastChecked` | `Date?` | 最近一次验证时间 |
| `lastWorked` | `Date?` | 最近一次判定可用时间 |
| `latencyMs` | `Int?` | 验证请求测得时延 |

模型特征：

- 两个模型都实现了 `Codable`，可直接持久化到本地
- 都实现了 `Sendable`，适用于并发上下文
- `StreamSource.id` 直接复用 `url`

---

## 7. 状态中心与业务编排

文件：`IPTVPlayer/ChannelStore.swift`

`ChannelStore` 是全项目最核心的业务对象，可以视为“应用数据中心 + 业务总调度器”。

### 7.1 核心职责

- 维护频道列表与刷新状态
- 负责本地缓存的读取与保存
- 调用聚合器拉取远程播放源
- 合并新旧频道数据
- 保留旧有收藏状态与验证结果
- 启动后台流验证任务
- 支持导入本地 m3u、添加远程 URL、自定义刷新与清缓存

### 7.2 公开状态

| 属性 | 说明 |
| --- | --- |
| `channels` | 当前频道列表 |
| `isRefreshing` | 是否处于刷新中 |
| `refreshProgress` | 刷新/导入/验证状态提示 |
| `lastRefreshDate` | 上次刷新时间 |

### 7.3 持久化机制

本地文件路径：

```text
~/Library/Application Support/IPTVPlayer/channels.json
```

内部结构：

```swift
private struct StoredData: Codable {
    var channels: [Channel]
    var lastRefreshDate: Date?
}
```

作用：

- 冷启动时恢复频道和评分信息
- 避免每次打开应用都重新全量拉取
- 保留用户收藏状态

### 7.4 关键函数说明

#### `init()`

- 初始化时自动执行 `load()`
- 让应用启动后优先使用已有缓存

#### `load()`

- 从 `channels.json` 读取持久化数据
- 解码失败时静默返回，不阻断启动

#### `save()`

- 将当前频道和刷新时间编码为 JSON 写回本地

#### `refreshIfNeeded()`

- 决定是否需要自动刷新
- 条件：
  - 没有频道缓存
  - 或者上次刷新超过 24 小时

#### `refresh()`

完整刷新主流程，步骤如下：

1. 防重入，避免并发刷新
2. 取消旧的后台验证任务
3. 调用 `aggregator.fetchAll()` 拉取默认远程源
4. 若拉取失败，保留现有频道
5. 抽取旧频道中的收藏信息与历史评分数据
6. 用新拉取结果覆盖频道集合，但尽量继承旧 source 的评分/时延信息
7. 保存刷新时间并持久化
8. UI 先结束“刷新中”状态
9. 启动后台静默验证任务

这一步体现了项目的重要设计原则：先让用户看到频道，再慢慢在后台优化源质量排序，不阻塞 UI。

#### `validateAllInBackground()`

- 以分块方式并发验证频道
- `chunkSize = 48`
- 当前固定调用 `validateChannel(ch, limit: 1)`，也就是后台默认只校验每个频道的第一个源
- 结果回写后更新 `channels`
- 最后清空进度并落盘

#### `cancelValidation()`

- 允许用户手动停止后台验证

#### `toggleFavorite(_:)`

- 切换收藏状态并立即持久化

#### `scheduleDailyRefresh()`

- 使用 `Timer` 每 24 小时自动刷新一次

#### `importLocal(url:)`

- 支持导入本地 `.m3u/.m3u8`
- 处理 macOS 沙盒下的安全作用域文件访问
- 调用 `M3UParser.parse()` 后再合并进现有频道列表

#### `addRemoteSource(_:)`

- 支持用户添加远程 m3u URL
- 支持 `http/https/file`
- 文件 URL 走本地导入逻辑
- 远程 URL 通过 `URLSession` 拉取后解析并合并

#### `mergeChannels(_:)`

- 按 `Channel.id` 合并频道
- 同频道下按 `StreamSource.url` 去重
- 保留收藏状态
- 合并完成后按频道名排序

### 7.5 并发与线程模型

- `ChannelStore` 被标记为 `@MainActor`
- 所有面向 UI 的状态更新都在主线程执行
- `validationTask` 在后台异步执行，但最终结果回写仍受主 actor 保护

这保证了 SwiftUI 绑定的数据变更是安全的。

---

## 8. m3u 解析器

文件：`IPTVPlayer/M3UParser.swift`

### 8.1 职责

- 逐行解析 m3u 内容
- 提取频道元信息
- 提取附加 HTTP 请求头
- 对频道分组做归一化
- 将结果转换为 `[Channel]`

### 8.2 支持的标签

- `#EXTM3U`
- `#EXTINF:`
- `#EXTVLCOPT:`
- `#KODIPROP:`（当前忽略）

### 8.3 解析规则

处理逻辑大致如下：

1. 读取 `#EXTINF` 时提取：
   - `tvg-id`
   - `tvg-logo`
   - `group-title`
   - 频道名称
2. 读取 `#EXTVLCOPT` 时提取：
   - `http-user-agent`
   - `http-referrer`
3. 遇到真正的 URL 行时，生成 `StreamSource`
4. 使用 `tvg-id` 或频道名作为频道主键
5. 同频道多源按 URL 去重合并

### 8.4 分组规范化

原始 `group-title` 会被压缩到 4 个固定分类：

- `体育`
- `国际`
- `娱乐`
- `新闻`

规范化函数：`normalizeGroup(_:)`

特点：

- 基于关键词模糊匹配
- 不区分大小写
- 未命中的默认归到 `娱乐`

这使 UI 中的频道分组选择保持简单统一，但也意味着某些源站原始细分类别会被丢失。

### 8.5 关键辅助函数

- `extractAttr(from:name:)`
  - 使用正则从 `#EXTINF` 提取属性
- `stripPrefix(_:_:)`
  - 从 `#EXTVLCOPT` 中提取配置值

---

## 9. 远程源聚合器

文件：`IPTVPlayer/SourceAggregator.swift`

### 9.1 职责

- 管理默认远程源列表
- 管理可选扩展源组
- 并发拉取多个 m3u 地址
- 汇总解析结果并去重

### 9.2 为什么使用 `actor`

`SourceAggregator` 被定义为 `actor`，更贴切的理解是：

- 为“抓取与聚合”提供一个天然异步的服务边界
- 让未来如果加入源健康度、缓存或统计状态时，具备并发隔离扩展空间
- 当前实现本身没有复杂的共享可变状态，因此这里的价值更多在接口语义而不是状态保护

### 9.3 默认源

默认内置多个公开 m3u 来源，例如：

- 中国频道聚合
- 中文直播源聚合
- 国际体育源

设计倾向：

- 优先使用可访问性更高的 IPv4 源
- 默认先给用户一个可用的基础频道集合

### 9.4 可选源组

`optionalSources`

当前分组：

- `咪咕`
- `海外体育`
- `中文聚合`

这些源组在 UI 中以按钮形式展示，用户可按需一键追加。

### 9.5 核心函数

#### `fetchAll(from:)`

- 如果未传参数，则使用默认源列表
- 使用 `withTaskGroup` 并发抓取每一个远程源
- 把每个源返回的 `[Channel]` 合并为统一结果
- 合并规则：
  - 按 `Channel.id` 合并
  - `sources` 按 URL 去重
  - logo 与 group 在缺失时补齐

#### `fetchOne(_:)`

- 单独拉取一个远程 m3u
- 使用 `URLSession`
- 设置自定义 `User-Agent`
- HTTP 非 `2xx` 时视为失败
- 拉取成功后调用 `M3UParser.parse()`

---

## 10. 流验证器

文件：`IPTVPlayer/StreamValidator.swift`

### 10.1 职责

- 对流地址做轻量可达性验证
- 为每个流生成评分
- 记录最近检查时间、成功时间和时延
- 重新排序频道下的候选源

### 10.2 设计目标

验证器并不追求“绝对正确地判断是否可播放”，而是提供“尽量便宜、尽量快、尽量有参考价值”的质量排序。

代码中的策略非常务实：

- 仅拉取前 8KB，避免完整下载媒体数据
- 使用更宽松的评分逻辑
- 避免把很多暂时性网络失败直接判死
- 给用户保留手动切换源的机会

### 10.3 `validate(_:)`

验证过程：

1. 检查 URL 格式是否合法
2. 发送 `GET` 请求
3. 添加 `Range: bytes=0-8191`
4. 设置 `User-Agent`
5. 如果 source 自带 `Referer`，一起带上
6. 根据 HTTP 状态码、响应数据、错误类型计算分数

典型评分逻辑：

- `1.0`
  - 返回内容含 `#EXTM3U` / `#EXTINF`
  - 基本可判定为 HLS playlist
- `0.7`
  - 有数据返回，但不一定是 playlist
- `0.3`
  - HTTP 成功但没有足够信息
- `0.1 ~ 0.2`
  - 超时、403、404、一般性错误
- `0.05`
  - DNS/连接失败等高风险情况
- `-1`
  - URL 自身非法

### 10.4 `validateChannel(_:, limit:)`

- 默认只验证前 `limit` 个源
- 其余源暂不校验，直接拼回列表
- 最终按以下规则重排：
  - `score` 越高越靠前
  - `latencyMs` 越低越靠前

这意味着：

- 启动速度快
- 网络压力较低
- 多源频道能逐步收敛出更稳定的最佳播放源

---

## 11. 播放模块

文件：`IPTVPlayer/PlayerView.swift`

### 11.1 模块组成

播放器模块由 3 个核心对象组成：

| 组件 | 作用 |
| --- | --- |
| `PlayerContainerView` | SwiftUI 外层容器，负责加载中和错误 UI |
| `PlayerBridge` | `ObservableObject` 状态桥，连接 SwiftUI 与 AVPlayer 观察回调 |
| `PlayerView` | `NSViewRepresentable`，将 `AVPlayerView` 接入 SwiftUI |

### 11.2 `PlayerContainerView`

职责：

- 显示黑色播放背景
- 嵌入实际播放器
- 根据 `bridge` 状态显示“正在连接”提示
- 显示播放失败原因与 URL
- 在切换 `source.url` 时重置加载状态

### 11.3 `PlayerBridge`

作用：

- 持有播放器状态：
  - `isLoading`
  - `errorMessage`
- 避免在 `updateNSView` 中直接改 SwiftUI 状态

这是一个典型的“跨视图系统边界的状态桥接器”。

### 11.4 `PlayerView`

职责：

- 创建 `AVPlayerView`
- 根据 `StreamSource` 构造 `AVURLAsset`
- 把 `User-Agent` / `Referer` 作为 HTTP 头注入
- 复用已有 `AVPlayer`
- 切换流时替换 `AVPlayerItem`

关键实现点：

- URL 不变时不重建 player，避免闪烁
- 支持 `Picture in Picture`
- 支持全屏按钮

### 11.5 `Coordinator`

职责：

- 监听 `AVPlayerItem.status`
- 监听 `AVPlayerItem.error`
- 将状态变化回写到 `PlayerBridge`

处理结果：

- `readyToPlay` -> 结束加载态
- `failed` -> 结束加载态并显示错误信息

---

## 12. 主界面与交互层

文件：`IPTVPlayer/ContentView.swift`

### 12.1 总体布局

使用 `NavigationSplitView`：

- 左侧：频道列表与筛选区
- 右侧：播放器与频道详情

### 12.2 核心状态

| 状态 | 说明 |
| --- | --- |
| `selectedChannelID` | 当前选中频道 |
| `searchText` | 搜索关键字 |
| `showOnlyFavorites` | 是否只显示收藏 |
| `selectedGroup` | 当前分组筛选 |
| `manualSourceURL` | 当前手动切换的源 |
| `showAddURLSheet` | 是否展示添加源弹窗 |
| `newSourceURL` | 新增远程源输入值 |
| `showFileImporter` | 是否打开文件导入器 |

### 12.3 计算属性

#### `selectedChannel`

- 根据 `selectedChannelID` 从 `store.channels` 中查找频道

#### `activeSource`

- 如果用户手动选择过某个源，优先使用该源
- 否则使用 `channel.bestSource`

#### `groups`

- 从现有频道中提取所有分组并排序

#### `filteredChannels`

按以下条件过滤频道：

- 收藏筛选
- 分组筛选
- 名称搜索

### 12.4 Sidebar 能力

侧边栏支持：

- 刷新频道
- 显示上次刷新时间
- 查看刷新进度
- 仅看收藏
- 按分组筛选
- 搜索频道
- 导入本地 `.m3u/.m3u8`
- 添加自定义远程 URL
- 一键添加预设源组
- 停止后台验证
- 清缓存并重拉

### 12.5 Detail 能力

详情区支持：

- 展示频道名
- 收藏/取消收藏
- 展示频道分组
- 展示当前源时延
- 使用播放器播放当前源
- 列出多个可选源并手动切换

### 12.6 `ChannelRow`

列表项视图，负责：

- 显示频道 logo
- 显示频道名
- 显示源数量
- 显示分组
- 根据最佳源评分显示状态圆点
- 提供收藏按钮

状态点颜色含义：

- 绿色：高质量
- 黄色：中等
- 橙色：低质量但可尝试
- 灰色：未知或不可用

---

## 13. 核心业务流程详解

### 13.1 首次启动流程

```text
ChannelStore.init()
-> load()
-> 若无缓存，IPTVPlayerApp 调用 refreshIfNeeded()
-> refresh()
-> fetchAll()
-> parse()
-> 保存 channels.json
-> 后台 validateAllInBackground()
```

### 13.2 刷新流程

```text
用户点击刷新
-> ContentView 调用 store.refresh()
-> ChannelStore 拉取默认源
-> 合并新老数据
-> 更新刷新时间
-> 保存缓存
-> 启动后台验证
```

### 13.3 导入本地文件流程

```text
用户选择本地 m3u 文件
-> fileImporter 返回 URL
-> store.importLocal(url:)
-> M3UParser.parse()
-> mergeChannels()
-> save()
```

### 13.4 添加远程源流程

```text
用户输入 URL
-> store.addRemoteSource()
-> URLSession 拉取文本
-> M3UParser.parse()
-> mergeChannels()
-> save()
```

### 13.5 播放流程

```text
用户选中频道
-> ContentView 计算 activeSource
-> PlayerContainerView(source:)
-> PlayerView 构建 AVURLAsset
-> AVPlayerItem
-> AVPlayer.play()
-> Coordinator 监听状态并更新加载/错误 UI
```

---

## 14. 依赖关系

### 14.1 文件级依赖

| 文件 | 直接依赖 |
| --- | --- |
| `IPTVPlayerApp.swift` | `ContentView`, `ChannelStore`, `SwiftUI` |
| `ContentView.swift` | `ChannelStore`, `Channel`, `StreamSource`, `PlayerContainerView`, `SourceAggregator`, `UniformTypeIdentifiers` |
| `ChannelStore.swift` | `Channel`, `StreamSource`, `SourceAggregator`, `StreamValidator`, `M3UParser`, `Combine`, `Foundation`, `SwiftUI` |
| `Models.swift` | `Foundation` |
| `M3UParser.swift` | `Channel`, `StreamSource`, `Foundation` |
| `SourceAggregator.swift` | `M3UParser`, `Channel`, `Foundation` |
| `StreamValidator.swift` | `Channel`, `StreamSource`, `Foundation` |
| `PlayerView.swift` | `StreamSource`, `SwiftUI`, `AVKit`, `AVFoundation`, `Combine` |

### 14.2 模块关系总结

- `ContentView` 不直接处理网络逻辑，所有业务动作都委托给 `ChannelStore`
- `ChannelStore` 是唯一业务中枢
- `SourceAggregator` 和 `StreamValidator` 是两个异步服务组件
- `M3UParser` 是纯解析工具
- `PlayerView` 独立处理播放器生命周期，不污染业务层

---

## 15. 关键设计决策

### 15.1 为什么先展示，再后台验证

如果等待所有流验证完成后再展示频道：

- 启动会更慢
- 用户感知差
- 网络差时体验更糟

当前实现先展示频道，再静默优化排序，更符合播放器场景。

### 15.2 为什么保留低分源而不是直接删除

很多 IPTV 源存在以下情况：

- `URLSession` 请求失败，但 `AVPlayer` 仍能播
- 临时性超时
- 对 `User-Agent` / `Referer` 有特殊要求

因此项目采用“降权而非删除”的策略，让用户还能手动尝试。

### 15.3 为什么使用本地 JSON 而不是数据库

当前数据结构简单：

- 频道列表
- 多个流源
- 少量状态字段

直接使用 `Codable + JSON`：

- 实现简单
- 可读性高
- 足够满足当前规模

---

## 16. 运行与构建

### 16.1 使用 Xcode 运行

1. 使用 Xcode 打开 `IPTVPlayer.xcodeproj`
2. 选择 Scheme：`IPTVPlayer`
3. 选择本机 macOS 目标
4. 点击 Run

### 16.2 使用命令行构建

在仓库根目录执行：

```bash
xcodebuild -project IPTVPlayer.xcodeproj -scheme IPTVPlayer -configuration Debug -sdk macosx build
```

当前仓库已验证该命令可以成功构建。

### 16.3 首次运行后的行为

- 读取本地缓存
- 如果缓存为空或已过期，自动拉取默认源
- 后台验证部分源的可用性
- 用户可以手动继续补充源

### 16.4 运行前提

- 需要 macOS 开发环境
- 需要可用的网络连接
- 远程 m3u 源站必须可访问

---

## 17. 外部数据与网络交互

### 17.1 远程依赖

应用依赖多个公开 m3u 源地址，风险包括：

- 源站失效
- 响应慢
- 内容格式变化
- 单个频道 URL 过期

### 17.2 网络交互点

| 场景 | 发起方 | 说明 |
| --- | --- | --- |
| 默认源拉取 | `SourceAggregator` | 拉取多个公开 m3u 文件 |
| 用户添加远程源 | `ChannelStore` | 拉取自定义 m3u 地址 |
| 流验证 | `StreamValidator` | 发起轻量 Range 请求 |
| 实际播放 | `AVPlayer` | 直接请求媒体流 |
| 频道 logo | `AsyncImage` | 加载 logo 图片 |

---

## 18. 可维护性与扩展点

### 18.1 适合扩展的方向

- 增加更多频道分组维度，而不是压缩为 4 类
- 为 `SourceAggregator` 增加源优先级和健康度统计
- 为 `StreamValidator` 引入更细粒度的评分策略
- 持久化用户最近播放记录
- 增加频道排序方式
- 增加源编辑、删除和手动屏蔽能力
- 将业务层进一步模块化，便于后续规模增长

### 18.2 当前实现的限制

- 仓库没有自动化测试
- 默认源列表硬编码在代码中
- 分组规范化较粗糙
- 频道唯一 ID 依赖 `tvg-id` 或频道名，可能出现冲突
- 本地持久化模型与 UI 状态耦合在一起
- 没有专门的错误上报与日志系统

---

## 19. 新同学阅读顺序

建议按以下顺序阅读代码：

1. `IPTVPlayerApp.swift`
2. `ContentView.swift`
3. `ChannelStore.swift`
4. `Models.swift`
5. `SourceAggregator.swift`
6. `M3UParser.swift`
7. `StreamValidator.swift`
8. `PlayerView.swift`

推荐理由：

- 先理解应用如何启动
- 再理解 UI 如何驱动业务
- 然后理解数据从哪里来、如何被处理、如何被播放

---

## 20. 关键符号速查

### 应用入口

- `IPTVPlayerApp`

### 核心业务对象

- `ChannelStore`
- `SourceAggregator`
- `StreamValidator`
- `M3UParser`

### 核心数据模型

- `Channel`
- `StreamSource`

### UI 与播放

- `ContentView`
- `ChannelRow`
- `PlayerContainerView`
- `PlayerBridge`
- `PlayerView`

### 关键方法

- `ChannelStore.refreshIfNeeded()`
- `ChannelStore.refresh()`
- `ChannelStore.validateAllInBackground()`
- `ChannelStore.importLocal(url:)`
- `ChannelStore.addRemoteSource(_:)`
- `ChannelStore.mergeChannels(_:)`
- `M3UParser.parse(_:)`
- `M3UParser.normalizeGroup(_:)`
- `SourceAggregator.fetchAll(from:)`
- `StreamValidator.validate(_:)`
- `StreamValidator.validateChannel(_:, limit:)`

---

## 21. 一句话总结

这是一个以 `ChannelStore` 为业务中枢、以 `SourceAggregator + M3UParser + StreamValidator` 为数据处理管线、以 `SwiftUI + AVPlayer` 为交互和播放层的 macOS IPTV 单体应用。它的核心价值不在复杂架构，而在用尽量少的原生代码，把“聚合源 -> 选优 -> 播放”这条链路做完整。
