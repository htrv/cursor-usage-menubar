import Foundation

enum ProxyMode: String, CaseIterable, Identifiable, Codable {
    case auto
    case manual
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Авто"
        case .manual: return "Вручную"
        case .direct: return "Напрямую"
        }
    }
}

/// Настройки прокси в Application Support (рядом с history.json).
@MainActor
final class ProxySettings: ObservableObject {
    static let shared = ProxySettings()

    @Published var mode: ProxyMode {
        didSet { persist() }
    }
    @Published var manualURL: String {
        didSet { persist() }
    }

    private struct File: Codable {
        var proxyMode: ProxyMode
        var proxyURL: String
    }

    private let url: URL
    private var suppressPersist = false

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cursor-usage-menubar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")

        if let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(File.self, from: data) {
            suppressPersist = true
            mode = file.proxyMode
            manualURL = file.proxyURL
            suppressPersist = false
        } else {
            mode = .auto
            manualURL = "http://127.0.0.1:8080"
        }
    }

    /// Кандидаты для запроса с учётом режима UI.
    func candidates() -> [ProxyResolver.HTTPProxy?] {
        switch mode {
        case .direct:
            return [nil]
        case .manual:
            if let p = ProxyResolver.parseHTTPProxyURL(manualURL) {
                return [p, nil]
            }
            return [nil]
        case .auto:
            return ProxyResolver.autoCandidates()
        }
    }

    private func persist() {
        guard !suppressPersist else { return }
        let file = File(proxyMode: mode, proxyURL: manualURL)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
