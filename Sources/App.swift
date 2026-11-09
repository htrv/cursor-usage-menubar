import AppKit
import SwiftUI

@main
struct CursorUsageMenubarApp: App {
    @StateObject private var store = UsageStore()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(store: store)
        } label: {
            Image(nsImage: store.icon)
                .id(store.lastRefresh?.timeIntervalSince1970 ?? 0)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuPanel: View {
    @ObservedObject var store: UsageStore
    @ObservedObject private var proxy = ProxySettings.shared
    @State private var showProxy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let err = store.errorText {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let p = store.pace {
                Text("Cursor · \(p.membership)")
                    .font(.headline)

                // Цикл подписки — над Total
                CycleHeader(pace: p)
                CycleStrip(pace: p)

                Divider()

                Text(String(format: "Total: %.1f%%  (ожид. %.1f%%)", p.totalPercent, p.expectedPercent))
                    .font(.system(.body, design: .monospaced))
                if let api = p.apiPercent {
                    Text(String(format: "Auto: %.1f%%   Other: %.1f%%", p.autoPercent, api))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else if abs(p.autoPercent - p.totalPercent) > 0.05 {
                    Text(String(format: "Auto: %.1f%%", p.autoPercent))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                if let used = p.used, let limit = p.limit {
                    Text(String(format: "Used: %.0f / %.0f", used, limit))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Divider()

                Text(String(
                    format: "Сегодня: %.2f п.п. из ~%.2f  (круг %.0f%%)",
                    p.todayTotalPct,
                    p.dailyAllowancePct,
                    p.dayFill * 100
                ))
                .font(.caption)
                Text(p.dayNote)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Темп: \(p.status.rawValue)")
                    .font(.caption)
                    .foregroundStyle(paceColor(p.status))

                Text(p.apiPercent == nil ? "Круг = день" : "Круг = день · точка = other models")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if store.errorText == nil {
                Text("Загрузка…")
                    .foregroundStyle(.secondary)
            }

            if let t = store.lastRefresh {
                HStack(spacing: 4) {
                    Text("Обновлено: \(fmtDateTime(t))")
                    if let via = store.lastVia {
                        Text("· \(via)")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            DisclosureGroup("Прокси", isExpanded: $showProxy) {
                ProxySettingsView(proxy: proxy) {
                    Task { await store.refresh() }
                }
            }
            .font(.caption)

            HStack {
                Button("Обновить") {
                    Task { await store.refresh() }
                }
                .keyboardShortcut("r")
                Spacer()
                Button("Выйти", role: .destructive) {
                    NSApp.terminate(nil)
                }
            }
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 300)
    }

    private func paceColor(_ s: PaceStatus) -> Color {
        switch s {
        case .under: return .green
        case .onTrack: return .primary
        case .over: return .red
        }
    }

    private func fmtDateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }
}

struct ProxySettingsView: View {
    @ObservedObject var proxy: ProxySettings
    var onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Режим", selection: $proxy.mode) {
                ForEach(ProxyMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            if proxy.mode == .manual {
                TextField("http://127.0.0.1:8080", text: $proxy.manualURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
            } else if proxy.mode == .auto {
                Text("Cursor http.proxy → HTTPS_PROXY/HTTP_PROXY → напрямую")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Без прокси")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button("Применить и обновить") {
                onApply()
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }
}

struct CycleHeader: View {
    let pace: PaceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Подписка с \(short(pace.cycleStart)) → \(short(pace.cycleEnd))")
                .font(.subheadline.weight(.semibold))
            Text("Прошло \(pace.daysElapsedIncludingToday) дн · осталось \(pace.daysRemainingAfterToday) дн · всего \(pace.daysTotal)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func short(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM"
        return f.string(from: d)
    }
}

/// Полоска цикла: один сегмент = один день.
struct CycleStrip: View {
    let pace: PaceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                let n = max(1, pace.daysTotal)
                let gap: CGFloat = n > 40 ? 0.5 : 1
                let totalGap = gap * CGFloat(n - 1)
                let w = max(1, (geo.size.width - totalGap) / CGFloat(n))
                HStack(spacing: gap) {
                    ForEach(0..<n, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(color(for: i))
                            .frame(width: w, height: 10)
                    }
                }
            }
            .frame(height: 10)

            HStack {
                Label("\(pace.daysElapsedIncludingToday)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("сегодня")
                    .foregroundStyle(.orange)
                Spacer()
                Label("\(pace.daysRemainingAfterToday)", systemImage: "circle.dotted")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption2)
            .labelStyle(.titleAndIcon)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Цикл \(pace.daysTotal) дней, прошло \(pace.daysElapsedIncludingToday), осталось \(pace.daysRemainingAfterToday)"
        )
    }

    private func color(for index: Int) -> Color {
        if index < pace.todayIndex {
            return Color.accentColor.opacity(0.85)
        }
        if index == pace.todayIndex {
            return Color.orange
        }
        return Color.secondary.opacity(0.22)
    }
}
