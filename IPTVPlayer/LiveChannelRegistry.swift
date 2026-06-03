import Foundation
import CryptoKit

enum AppConfig {
    static let rtcAppId = value(for: "RTC_APP_ID")
    static let rtcTokenURL = value(for: "RTC_TOKEN_URL")
    static let liveRegistryURL = value(for: "LIVE_REGISTRY_URL")

    private static func value(for key: String) -> String {
        if let env = ProcessInfo.processInfo.environment[key], !env.isEmpty {
            return env
        }
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              !value.hasPrefix("$(")
        else { return "" }
        return value
    }
}

struct RTCTokenCredentials {
    let appId: String
    let token: String
}

enum RTCTokenService {
    private struct RequestBody: Encodable {
        let roomId: String
        let userId: String
        let role: String
    }

    private struct ResponseBody: Decodable {
        let token: String
        let appId: String?
    }

    static func fetch(roomId: String, userId: String, role: String) async throws -> RTCTokenCredentials {
        guard let url = URL(string: AppConfig.rtcTokenURL), !AppConfig.rtcTokenURL.isEmpty else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(RequestBody(roomId: roomId, userId: userId, role: role))

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let body = try JSONDecoder().decode(ResponseBody.self, from: data)
        let appId = body.appId?.isEmpty == false ? body.appId! : AppConfig.rtcAppId
        guard !appId.isEmpty, !body.token.isEmpty else {
            throw URLError(.userAuthenticationRequired)
        }
        return RTCTokenCredentials(appId: appId, token: body.token)
    }
}

struct LiveChannel: Identifiable, Decodable {
    var id: String
    var name: String
    var roomId: String
    var pinHash: String?
    var hostId: String?
    var startedAt: Double

    init(id: String, name: String, roomId: String, pinHash: String?, hostId: String?, startedAt: Double) {
        self.id = id
        self.name = name
        self.roomId = roomId
        self.pinHash = pinHash
        self.hostId = hostId
        self.startedAt = startedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, roomId, pinHash, hostId, startedAt
        case roomID, room, channelName, title, pin_hash, host_id, startAt, timestamp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name)
            ?? c.decodeIfPresent(String.self, forKey: .channelName)
            ?? c.decodeIfPresent(String.self, forKey: .title)
            ?? "专属直播"
        roomId = try c.decodeIfPresent(String.self, forKey: .roomId)
            ?? c.decodeIfPresent(String.self, forKey: .roomID)
            ?? c.decodeIfPresent(String.self, forKey: .room)
            ?? "iptv_private"
        pinHash = try c.decodeIfPresent(String.self, forKey: .pinHash)
            ?? c.decodeIfPresent(String.self, forKey: .pin_hash)
        hostId = try c.decodeIfPresent(String.self, forKey: .hostId)
            ?? c.decodeIfPresent(String.self, forKey: .host_id)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt)
            ?? c.decodeIfPresent(Double.self, forKey: .startAt)
            ?? c.decodeIfPresent(Double.self, forKey: .timestamp)
            ?? Date().timeIntervalSince1970
    }

    static func hashPin(_ pin: String) -> String {
        let normalized = pin.compactMap { $0.wholeNumberValue }.map(String.init).joined()
        let data = Data(("iptv_pin_\(normalized)").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func verify(pin: String) -> Bool {
        guard let pinHash else { return true }
        return pinHash == LiveChannel.hashPin(pin)
    }

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
    static var isConfigured: Bool { !AppConfig.liveRegistryURL.isEmpty }

    private static func normalizeTimestamp(_ ts: Double) -> Double {
        // 兼容秒(10位)和毫秒(13位)时间戳
        ts > 10_000_000_000 ? (ts / 1000.0) : ts
    }

    private static func asString(_ any: Any?) -> String? {
        switch any {
        case let s as String:
            return s
        case let n as NSNumber:
            return n.stringValue
        default:
            return nil
        }
    }

    private static func asDouble(_ any: Any?) -> Double? {
        switch any {
        case let d as Double:
            return d
        case let i as Int:
            return Double(i)
        case let n as NSNumber:
            return n.doubleValue
        case let s as String:
            return Double(s)
        default:
            return nil
        }
    }

    private static func parseLiveChannel(_ any: Any) -> LiveChannel? {
        guard let obj = any as? [String: Any] else { return nil }
        let roomId = asString(obj["roomId"] ?? obj["roomID"] ?? obj["room"]) ?? "iptv_private"
        let name = asString(obj["name"] ?? obj["channelName"] ?? obj["title"]) ?? "专属直播"
        let id = asString(obj["id"]) ?? UUID().uuidString
        let pinHash = asString(obj["pinHash"] ?? obj["pin_hash"])
        let hostId = asString(obj["hostId"] ?? obj["host_id"])
        let startedAt = normalizeTimestamp(asDouble(obj["startedAt"] ?? obj["startAt"] ?? obj["timestamp"]) ?? Date().timeIntervalSince1970)
        return LiveChannel(id: id, name: name, roomId: roomId, pinHash: pinHash, hostId: hostId, startedAt: startedAt)
    }

    static func fetchAll() async -> [LiveChannel] {
        guard isConfigured,
              let url = URL(string: "\(AppConfig.liveRegistryURL)/live/channels"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        let now = Date().timeIntervalSince1970
        return arr.compactMap(parseLiveChannel)
            .filter { (now - $0.startedAt) >= 0 && (now - $0.startedAt) <= 90 }
            .sorted { $0.startedAt < $1.startedAt }
    }
}
