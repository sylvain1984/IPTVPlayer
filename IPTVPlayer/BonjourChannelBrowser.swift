import Foundation

/// 监听局域网内 LiveBroadcaster 广播的频道，通过 Bonjour TXT record 获取频道数据。
final class BonjourChannelBrowser: NSObject {
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var channels: [String: LiveChannel] = [:]

    /// 当频道列表变化时回调（始终在主线程）
    var onUpdate: (([LiveChannel]) -> Void)?

    func start() {
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: "_livebroadcaster._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
        services.values.forEach { $0.stopMonitoring() }
        services.removeAll()
        channels.removeAll()
        onUpdate?([])
    }

    private func notify() {
        let sorted = channels.values.sorted { $0.startedAt < $1.startedAt }
        onUpdate?(sorted)
    }
}

extension BonjourChannelBrowser: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services[service.name] = service
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.startMonitoring()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services[service.name]?.stopMonitoring()
        services.removeValue(forKey: service.name)
        channels.removeValue(forKey: service.name)
        notify()
    }
}

extension BonjourChannelBrowser: NetServiceDelegate {
    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        let dict = NetService.dictionary(fromTXTRecord: data)
        guard let raw = dict["ch"],
              let channel = try? JSONDecoder().decode(LiveChannel.self, from: raw) else { return }
        channels[sender.name] = channel
        notify()
    }
}
