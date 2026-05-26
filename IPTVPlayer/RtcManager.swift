// RtcViewerState — shared state enum for the RTC viewer panel.
// The full RTC implementation uses WKWebView + Volcano Engine Web SDK (see RtcViewerPanel.swift).

enum RtcViewerState: Equatable {
    case idle, connecting, live
    case error(String)
    static func == (l: Self, r: Self) -> Bool {
        switch (l, r) {
        case (.idle, .idle), (.connecting, .connecting), (.live, .live): return true
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}
