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
                    await channelStore.refreshIfNeeded()
                    channelStore.scheduleDailyRefresh()
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
