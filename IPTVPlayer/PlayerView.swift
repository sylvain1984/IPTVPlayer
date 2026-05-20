//
//  PlayerView.swift
//  IPTVPlayer
//

import SwiftUI
import AVKit
import AVFoundation
import Combine

// MARK: - 包装层：带错误提示的播放器视图
struct PlayerContainerView: View {
    let source: StreamSource?

    // 通过 ObservableObject 桥接 AVPlayer 状态，避免在 updateNSView 里改 @State
    @StateObject private var bridge = PlayerBridge()

    var body: some View {
        ZStack {
            Color.black

            PlayerView(source: source, bridge: bridge)

            if bridge.isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("正在连接...")
                        .foregroundStyle(.white.opacity(0.7))
                        .font(.callout)
                }
            } else if let msg = bridge.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.orange)
                    Text("播放失败")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                    if let url = source?.url {
                        Text(url)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
        }
        .onChange(of: source?.url) { _, _ in
            // URL 切换时重置状态（安全：在 SwiftUI 事件里改状态）
            bridge.isLoading = true
            bridge.errorMessage = nil
        }
        .onAppear {
            if source != nil {
                bridge.isLoading = true
            }
        }
    }
}

// MARK: - 状态桥（ObservableObject，跨 NSViewRepresentable 边界安全通信）
final class PlayerBridge: ObservableObject {
    @Published var isLoading: Bool = false
    @Published var errorMessage: String? = nil
}

// MARK: - 底层 AVPlayerView 包装
struct PlayerView: NSViewRepresentable {

    let source: StreamSource?
    let bridge: PlayerBridge

    func makeCoordinator() -> Coordinator {
        Coordinator(bridge: bridge)
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // 同步 bridge 引用（每次 body 重建 PlayerView 时 bridge 可能是同一个对象，但保持最新）
        context.coordinator.bridge = bridge

        guard let source = source, let url = URL(string: source.url) else {
            nsView.player?.pause()
            context.coordinator.detach()
            nsView.player = nil
            return
        }

        // URL 未变则不重建 player（避免闪烁）
        if let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url,
           currentURL == url {
            return
        }

        var headers: [String: String] = [:]
        if let ua = source.userAgent, !ua.isEmpty { headers["User-Agent"] = ua }
        if let ref = source.referer, !ref.isEmpty { headers["Referer"] = ref }

        let options: [String: Any] = headers.isEmpty
            ? [:]
            : ["AVURLAssetHTTPHeaderFieldsKey": headers]

        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)

        context.coordinator.attach(to: item)   // 先挂上观察者

        if let player = nsView.player {
            player.replaceCurrentItem(with: item)
            player.play()
        } else {
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            nsView.player = player
            player.play()
        }
    }

    // MARK: - Coordinator（KVO 监听，回调通过 bridge 修改状态）
    final class Coordinator: NSObject {
        var bridge: PlayerBridge

        private var statusObservation: NSKeyValueObservation?
        private var errorObservation: NSKeyValueObservation?

        init(bridge: PlayerBridge) {
            self.bridge = bridge
        }

        func attach(to item: AVPlayerItem) {
            detach()

            statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
                guard let self else { return }
                DispatchQueue.main.async {
                    switch item.status {
                    case .readyToPlay:
                        self.bridge.isLoading = false
                        self.bridge.errorMessage = nil
                    case .failed:
                        self.bridge.isLoading = false
                        self.bridge.errorMessage = item.error?.localizedDescription
                            ?? "流地址无法播放，请尝试切换其他源"
                    default:
                        break
                    }
                }
            }

            errorObservation = item.observe(\.error, options: [.new]) { [weak self] item, _ in
                guard let self, let error = item.error else { return }
                DispatchQueue.main.async {
                    self.bridge.isLoading = false
                    self.bridge.errorMessage = error.localizedDescription
                }
            }
        }

        func detach() {
            statusObservation?.invalidate()
            statusObservation = nil
            errorObservation?.invalidate()
            errorObservation = nil
        }

        deinit { detach() }
    }
}
