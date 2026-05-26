//
//  RtcViewerPanel.swift
//  IPTVPlayer
//
//  Uses Volcano Engine RTC Web SDK (v4.68) via WKWebView.
//  No native macOS SDK required.

import SwiftUI
import WebKit
import AppKit
import Combine

private let kAppId = "6a13b1373d860b0617f988aa"

// MARK: - Weak script-message bridge (avoids WKUserContentController retain cycle)
private final class WeakMsgHandler: NSObject, WKScriptMessageHandler {
    weak var vm: RtcWebViewModel?
    init(_ vm: RtcWebViewModel) { self.vm = vm }
    func userContentController(_ c: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard let body = message.body as? String else { return }
        Task { @MainActor [weak vm] in vm?.handle(body) }
    }
}

// MARK: - View Model
@MainActor
final class RtcWebViewModel: NSObject, ObservableObject {
    @Published var state: RtcViewerState = .idle
    let webView: WKWebView

    private let roomId: String
    private let userId: String

    init(roomId: String, userId: String = "viewer_mac_\(Int.random(in: 1000...9999))") {
        self.roomId = roomId
        self.userId = userId
        let cfg = WKWebViewConfiguration()
        cfg.mediaTypesRequiringUserActionForPlayback = []
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        cfg.userContentController.add(WeakMsgHandler(self), name: "rtcState")
    }

    func join() {
        guard state == .idle else { return }
        state = .connecting

        let token = RTCTokenGenerator.viewerToken(
            appId: kAppId,
            appKey: "221fb57fe116497b9201c3c635f1b23c",
            roomId: roomId,
            userId: userId
        )

        // Write SDK + HTML to a temp dir so loadFileURL can serve them normally
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rtcviewer", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let sdkDest = tmpDir.appendingPathComponent("vertc.min.js")
        if !FileManager.default.fileExists(atPath: sdkDest.path),
           let sdkSrc = Bundle.main.url(forResource: "vertc.min", withExtension: "js") {
            try? FileManager.default.copyItem(at: sdkSrc, to: sdkDest)
        }

        let credScript = "window.__rtc={appId:'\(kAppId)',token:'\(token)',roomId:'\(roomId)',userId:'\(userId)'};"
        let htmlURL = tmpDir.appendingPathComponent("viewer.html")
        try? Self.makeHTML(credScript: credScript).write(to: htmlURL, atomically: true, encoding: .utf8)

        let uc = webView.configuration.userContentController
        uc.removeAllUserScripts()
        webView.loadFileURL(htmlURL, allowingReadAccessTo: tmpDir)
    }

    func leave() {
        webView.evaluateJavaScript(
            "typeof leaveRoom==='function'&&leaveRoom()", completionHandler: nil
        )
        state = .idle
    }

    fileprivate func handle(_ msg: String) {
        if msg.hasPrefix("live:") {
            state = .live
        } else if msg == "connecting" {
            if state == .live { state = .connecting }
        } else if msg.hasPrefix("error:") {
            state = .error(String(msg.dropFirst(6)))
        }
    }

    // MARK: - HTML loaded from file:// so <script src="vertc.min.js"> resolves locally
    private static func makeHTML(credScript: String) -> String {
        """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>
        *{margin:0;padding:0;box-sizing:border-box}
        html,body{width:100%;height:100%;background:#000;overflow:hidden}
        #wrap{width:100%;height:100%;position:relative}
        #wrap *{position:absolute;top:0;left:0;width:100%!important;height:100%!important}
        #wrap video{object-fit:contain;background:#000}
        </style>
        <script>\(credScript)</script>
        <script src="vertc.min.js"></script>
        </head>
        <body>
        <div id="wrap"></div>
        <script>
        var engine = null;

        function notify(s) {
          try { window.webkit.messageHandlers.rtcState.postMessage(s); } catch(e) {}
        }

        async function joinRoom(appId, token, roomId, userId) {
          try {
            engine = VERTC.createEngine(appId);

            engine.on(VERTC.events.onUserPublishStream, async function(e) {
              try {
                await engine.subscribeStream(e.userId, VERTC.MediaType.AUDIO);
                await engine.subscribeStream(e.userId, VERTC.MediaType.VIDEO);
                engine.setRemoteVideoPlayer(VERTC.StreamIndex.STREAM_INDEX_MAIN, {
                  userId: e.userId,
                  renderDom: document.getElementById('wrap')
                });
                notify('live:' + e.userId);
              } catch(err) { notify('error:' + err.message); }
            });

            engine.on(VERTC.events.onUserUnpublishStream, function() {
              notify('connecting');
            });

            engine.on(VERTC.events.onError, function(e) {
              notify('error:code_' + e.errorCode);
            });

            await engine.joinRoom(token, roomId, { userId: userId }, {
              isAutoPublish: false,
              isAutoSubscribeAudio: true,
              isAutoSubscribeVideo: true
            });
          } catch(err) {
            notify('error:' + err.message);
          }
        }

        function leaveRoom() {
          if (engine) { try { engine.leaveRoom(); } catch(e) {} engine = null; }
        }

        window.addEventListener('load', function() {
          var c = window.__rtc;
          if (c) joinRoom(c.appId, c.token, c.roomId, c.userId);
        });
        </script>
        </body></html>
        """
    }
}

// MARK: - SwiftUI View
struct RtcViewerPanel: View {
    @StateObject private var vm: RtcWebViewModel
    @Binding var isFullscreen: Bool

    init(roomId: String, isFullscreen: Binding<Bool> = .constant(false)) {
        _vm = StateObject(wrappedValue: RtcWebViewModel(roomId: roomId))
        _isFullscreen = isFullscreen
    }

    var body: some View {
        ZStack {
            Color.black
            RtcWebNSView(webView: vm.webView)
            switch vm.state {
            case .connecting:
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("等待开播...").foregroundStyle(.white.opacity(0.7)).font(.callout)
                }
            case .error(let msg):
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 36)).foregroundStyle(.orange)
                    Text("连接失败").font(.headline).foregroundStyle(.white)
                    Text(msg).font(.caption).foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            default:
                EmptyView()
            }
            // Overlay controls always visible (fullscreen + live badge)
            overlayControls
        }
        .onAppear  { vm.join()  }
        .onDisappear { vm.leave() }
        .onTapGesture(count: 2) { isFullscreen.toggle() }
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                if vm.state == .live {
                    HStack(spacing: 5) {
                        Circle().fill(.red).frame(width: 6, height: 6)
                        Text("直播中").font(.caption.bold()).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.55)).clipShape(Capsule())
                }
                Spacer()
                Button {
                    isFullscreen.toggle()
                } label: {
                    Image(systemName: isFullscreen
                          ? "arrow.down.right.and.arrow.up.left"
                          : "arrow.up.left.and.arrow.down.right")
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.black.opacity(0.55))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help(isFullscreen ? "退出全屏 (Esc)" : "全屏 (⌘⌃F)")
                .keyboardShortcut(isFullscreen ? .escape : "f",
                                  modifiers: isFullscreen ? [] : [.command, .control])
            }
            .padding(12)
            Spacer()
        }
    }
}

// MARK: - NSViewRepresentable wrapper
struct RtcWebNSView: NSViewRepresentable {
    let webView: WKWebView
    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
