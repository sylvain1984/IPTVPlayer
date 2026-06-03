//
//  IPTVPlayerApp.swift
//  IPTVPlayer
//

import SwiftUI

@main
struct IPTVPlayerApp: App {
    @StateObject private var channelStore = ChannelStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(channelStore)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    // Live channel polling starts immediately, in parallel with M3U refresh
                    channelStore.startLiveChannelPolling()
                    channelStore.scheduleDailyRefresh()
                    await channelStore.refreshIfNeeded()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("立即刷新频道") {
                    Task { await channelStore.refresh() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}
