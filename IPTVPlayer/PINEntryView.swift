import SwiftUI

struct PINEntryView: View {
    let channel: Channel
    let onUnlock: (Channel) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var shake = false
    @State private var showError = false
    @FocusState private var keyboardFocused: Bool

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("输入访问密码").font(.headline)
                Text(channel.name).font(.subheadline).foregroundStyle(.secondary)
            }

            // PIN dots
            HStack(spacing: 20) {
                ForEach(0..<4) { i in
                    Circle()
                        .fill(i < pin.count ? Color.primary : Color.secondary.opacity(0.25))
                        .frame(width: 18, height: 18)
                        .animation(.spring(duration: 0.15), value: pin.count)
                }
            }
            .offset(x: shake ? -6 : 0)
            .animation(shake ? .interpolatingSpring(stiffness: 600, damping: 10) : .default, value: shake)

            // Hidden text field — captures keyboard digit input on macOS
            TextField("", text: $pin)
                .focused($keyboardFocused)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .onChange(of: pin) { _, new in
                    let filtered = String(new.filter(\.isNumber).prefix(4))
                    if filtered != new { pin = filtered; return }
                    if filtered.count == 4 { verify() }
                }

            if showError {
                Text("密码错误，请重试")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .transition(.opacity)
            }

            // Number pad (click / tap)
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    ForEach(["1","2","3"], id: \.self) { d in PadButton(label: d, action: { append(d) }) }
                }
                GridRow {
                    ForEach(["4","5","6"], id: \.self) { d in PadButton(label: d, action: { append(d) }) }
                }
                GridRow {
                    ForEach(["7","8","9"], id: \.self) { d in PadButton(label: d, action: { append(d) }) }
                }
                GridRow {
                    PadButton(label: "⌫", action: backspace)
                    PadButton(label: "0", action: { append("0") })
                    Color.clear.frame(width: 64, height: 64)
                }
            }

            Button("取消") { dismiss() }
                .foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(32)
        .frame(width: 280)
        .onAppear { keyboardFocused = true }
    }

    private func append(_ digit: String) {
        guard pin.count < 4 else { return }
        pin += digit
        // verify triggered by onChange when count reaches 4
    }

    private func backspace() {
        guard !pin.isEmpty else { return }
        pin.removeLast()
        showError = false
    }

    private func verify() {
        if channel.pinHash == LiveChannel.hashPin(pin) {
            onUnlock(channel)
            dismiss()
        } else {
            withAnimation { shake = true; showError = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                shake = false
                pin = ""
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                withAnimation { showError = false }
            }
        }
    }
}

private struct PadButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.title2.monospacedDigit())
                .frame(width: 64, height: 64)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }
}
