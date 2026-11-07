import Foundation

struct UsageSummary: Codable {
    let billingCycleStart: String
    let billingCycleEnd: String
    let membershipType: String?
    let individualUsage: IndividualUsage?

    struct IndividualUsage: Codable {
        let plan: PlanUsage?
        let onDemand: OnDemandUsage?
    }

    struct PlanUsage: Codable {
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let remaining: Double?
        let breakdown: Breakdown?
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }

    struct Breakdown: Codable {
        let included: Double?
        let bonus: Double?
        let total: Double?
    }

    struct OnDemandUsage: Codable {
        let enabled: Bool?
        let used: Double?
        let limit: Double?
        let remaining: Double?
    }
}

enum CursorAPI {
    private static let usageURL = URL(string: "https://cursor.com/api/usage-summary")!

    struct FetchResult {
        let summary: UsageSummary
        let via: String
    }

    static func fetchUsage() async throws -> FetchResult {
        let auth = try TokenProvider.load()
        var lastError: Error?
        let candidates = await MainActor.run { ProxySettings.shared.candidates() }

        for proxy in candidates {
            do {
                let summary = try await fetchOnce(auth: auth, proxy: proxy)
                let via = proxy.map { $0.description } ?? "напрямую"
                return FetchResult(summary: summary, via: via)
            } catch let err as AppError {
                // До сервера дошли — прокси/direct ок, дальше не перебирать.
                if case .network(let msg) = err, msg.hasPrefix("HTTP ") {
                    throw err
                }
                lastError = err
            } catch {
                lastError = error
            }
        }
        throw lastError ?? AppError.network("не достучаться до cursor.com")
    }

    private static func fetchOnce(auth: TokenProvider.Auth, proxy: ProxyResolver.HTTPProxy?) async throws -> UsageSummary {
        var request = URLRequest(url: usageURL)
        request.setValue(auth.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) CursorUsageMenubar/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        // Прямое соединение в фильтрующих сетях часто зависает на TLS — короткий таймаут, чтобы быстрее перейти к прокси.
        request.timeoutInterval = proxy == nil ? 8 : 15

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = request.timeoutInterval
        config.timeoutIntervalForResource = request.timeoutInterval + 5
        config.waitsForConnectivity = false
        if let proxy {
            config.connectionProxyDictionary = proxy.connectionProxyDictionary
        }

        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            let via = proxy.map { "через \($0)" } ?? "напрямую"
            throw AppError.network("\(via): \(error.localizedDescription)")
        }

        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("пустой ответ")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw AppError.network("HTTP \(http.statusCode): \(body.prefix(200))")
        }
        do {
            return try JSONDecoder().decode(UsageSummary.self, from: data)
        } catch {
            throw AppError.parse("JSON: \(error.localizedDescription)")
        }
    }
}
