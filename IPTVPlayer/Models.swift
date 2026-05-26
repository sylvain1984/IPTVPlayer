//
//  Models.swift
//  IPTVPlayer
//

import Foundation

struct Channel: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var name: String
    var logoURL: String?
    var groupTitle: String?
    var sources: [StreamSource]
    var isFavorite: Bool = false
    var isRtc: Bool = false
    var pinHash: String? = nil  // nil = no PIN required

    /// RTC room ID extracted from rtc:// source URL
    nonisolated var rtcRoomId: String {
        sources.first?.url.replacingOccurrences(of: "rtc://", with: "") ?? "iptv_private"
    }

    nonisolated var bestSource: StreamSource? {
        sources.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return (lhs.latencyMs ?? Int.max) < (rhs.latencyMs ?? Int.max)
        }.first
    }
}

struct WatchRecord: Codable {
    var channelId: String
    var lastWatchedAt: Date
    var watchCount: Int = 1
}

struct StreamSource: Codable, Hashable, Identifiable, Sendable {
    nonisolated var id: String { url }
    let url: String
    var userAgent: String?
    var referer: String?
    var score: Double = 0
    var lastChecked: Date?
    var lastWorked: Date?
    var latencyMs: Int?

    init(url: String,
         userAgent: String? = nil,
         referer: String? = nil,
         score: Double = 0,
         lastChecked: Date? = nil,
         lastWorked: Date? = nil,
         latencyMs: Int? = nil) {
        self.url = url
        self.userAgent = userAgent
        self.referer = referer
        self.score = score
        self.lastChecked = lastChecked
        self.lastWorked = lastWorked
        self.latencyMs = latencyMs
    }
}
