import Foundation
import CryptoKit

// 同 LiveBroadcaster/LiveChannelRegistry.swift — 保持两端 URL 一致
private let kRegistryURL = "https://YOUR_PROJECT_ID-default-rtdb.firebaseio.com/live_channels"

struct LiveChannel: Identifiable, Codable {
    var id: String
    var name: String
    var roomId: String
    var pinHash: String
    var hostId: String
    var startedAt: Double

    static func hashPin(_ pin: String) -> String {
        let data = Data(("iptv_pin_\(pin)").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func verify(pin: String) -> Bool { pinHash == LiveChannel.hashPin(pin) }

    func toChannel() -> Channel {
        Channel(
            id: "live_\(id)",
            name: name,
            logoURL: nil,
            groupTitle: "专属直播",
            sources: [StreamSource(url: "rtc://\(roomId)")],
            isFavorite: false,
            isRtc: true,
            pinHash: pinHash
        )
    }
}

enum LiveChannelRegistry {
    private static var isConfigured: Bool { !kRegistryURL.contains("YOUR_PROJECT_ID") }

    static func fetchAll() async -> [LiveChannel] {
        guard isConfigured,
              let url = URL(string: "\(kRegistryURL).json"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              data != Data("null".utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        return dict.values.compactMap { val -> LiveChannel? in
            guard let d = try? JSONSerialization.data(withJSONObject: val) else { return nil }
            return try? JSONDecoder().decode(LiveChannel.self, from: d)
        }.sorted { $0.startedAt < $1.startedAt }
    }
}
