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

struct CurrentPeriodUsage: Codable {
    /// Эпоха в миллисекундах строкой, либо ISO-8601.
    let billingCycleStart: String
    let billingCycleEnd: String
    let planUsage: PlanUsage?

    struct PlanUsage: Codable {
        let autoPercentUsed: Double?
        let apiPercentUsed: Double?
        let totalPercentUsed: Double?
    }
}

extension UsageSummary {
    /// Дашборд Ultra считает included по недельному окну.
    /// `usage-summary` для этого плана отдаёт нули и календарный месяц.
    func overlaying(_ period: CurrentPeriodUsage) -> UsageSummary {
        guard let total = period.planUsage?.totalPercentUsed,
              let start = Self.cycleISO(period.billingCycleStart),
              let end = Self.cycleISO(period.billingCycleEnd) else {
            return self
        }
        let old = individualUsage?.plan
        let summaryTotal = old?.totalPercentUsed ?? 0
        let sameCycle = Self.sameInstant(billingCycleStart, start) && Self.sameInstant(billingCycleEnd, end)
        let countersMatch = sameCycle && abs(summaryTotal - total) < 1
        let api = period.planUsage?.apiPercentUsed ?? (countersMatch ? old?.apiPercentUsed : nil)
        let plan = PlanUsage(
            enabled: old?.enabled ?? true,
            used: countersMatch ? old?.used : nil,
            limit: countersMatch ? old?.limit : nil,
            remaining: countersMatch ? old?.remaining : nil,
            breakdown: countersMatch ? old?.breakdown : nil,
            autoPercentUsed: period.planUsage?.autoPercentUsed ?? total,
            apiPercentUsed: api,
            totalPercentUsed: total
        )
        return UsageSummary(
            billingCycleStart: start,
            billingCycleEnd: end,
            membershipType: membershipType,
            individualUsage: IndividualUsage(plan: plan, onDemand: individualUsage?.onDemand)
        )
    }

    private static func cycleISO(_ raw: String) -> String? {
        if let ms = Double(raw), ms > 1_000_000_000_000 {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            f.timeZone = TimeZone(secondsFromGMT: 0)
            return f.string(from: Date(timeIntervalSince1970: ms / 1000))
        }
        return Pace.parseDate(raw) == nil ? nil : raw
    }

    private static func sameInstant(_ a: String, _ b: String) -> Bool {
        guard let da = Pace.parseDate(a), let db = Pace.parseDate(b) else { return false }
        return abs(da.timeIntervalSince(db)) < 2
    }
}

enum CursorAPI {
    private static let usageURL = URL(string: "https://cursor.com/api/usage-summary")!
    private static let periodURL = URL(string: "https://cursor.com/api/dashboard/get-current-period-usage")!
    private static let eventsURL = URL(string: "https://cursor.com/api/dashboard/get-aggregated-usage-events")!

    struct FetchResult {
        let summary: UsageSummary
        let via: String
        /// Накопительный расход по моделям. nil, если этот запрос не удался: прошлый удачный снимок не затираем.
        let models: ModelUsageReport?
    }

    /// Сумма по имени модели, без разбиения по tier: одна линия в истории.
    struct ModelUsageReport: Sendable {
        let since: Date
        let models: [ModelSpend]
    }

    struct ModelSpend: Sendable {
        let model: String
        let inputTokens: Double
        let outputTokens: Double
        let cacheReadTokens: Double
        let cacheWriteTokens: Double
        let costCents: Double
    }

    static func fetchUsage() async throws -> FetchResult {
        let auth = try TokenProvider.load()
        var lastError: Error?
        let candidates = await MainActor.run { ProxySettings.shared.candidates() }

        for proxy in candidates {
            do {
                let summary = try await fetchOnce(auth: auth, proxy: proxy)
                let merged = try await overlayPeriod(summary, auth: auth, proxy: proxy)
                let models = try? await fetchModels(auth: auth, proxy: proxy)
                let via = proxy.map { $0.description } ?? "напрямую"
                return FetchResult(summary: merged, via: via, models: models)
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

    /// Если сводка врёт нулями, ошибка недельного эндпоинта важнее, чем «0%».
    private static func overlayPeriod(
        _ summary: UsageSummary,
        auth: TokenProvider.Auth,
        proxy: ProxyResolver.HTTPProxy?
    ) async throws -> UsageSummary {
        do {
            let period = try await fetchPeriod(auth: auth, proxy: proxy)
            return summary.overlaying(period)
        } catch {
            let total = summary.individualUsage?.plan?.totalPercentUsed ?? 0
            if total < 0.05 { throw error }
            return summary
        }
    }

    private static func fetchOnce(auth: TokenProvider.Auth, proxy: ProxyResolver.HTTPProxy?) async throws -> UsageSummary {
        var request = URLRequest(url: usageURL)
        request.setValue(auth.sessionCookie, forHTTPHeaderField: "Cookie")
        applyCommon(&request, proxy: proxy)
        let data = try await perform(request, proxy: proxy)
        do {
            return try JSONDecoder().decode(UsageSummary.self, from: data)
        } catch {
            throw AppError.parse("JSON: \(error.localizedDescription)")
        }
    }

    private static func fetchPeriod(auth: TokenProvider.Auth, proxy: ProxyResolver.HTTPProxy?) async throws -> CurrentPeriodUsage {
        var request = URLRequest(url: periodURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue(auth.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        applyCommon(&request, proxy: proxy)
        let data = try await perform(request, proxy: proxy)
        do {
            return try JSONDecoder().decode(CurrentPeriodUsage.self, from: data)
        } catch {
            throw AppError.parse("period JSON: \(error.localizedDescription)")
        }
    }

    private static func fetchModels(auth: TokenProvider.Auth, proxy: ProxyResolver.HTTPProxy?) async throws -> ModelUsageReport {
        var request = URLRequest(url: eventsURL)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"teamId\":0}".utf8)
        request.setValue(auth.sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        applyCommon(&request, proxy: proxy)
        let data = try await perform(request, proxy: proxy)
        let decoded = try JSONDecoder().decode(AggregatedUsageEvents.self, from: data)
        return decoded.report()
    }

    private static func applyCommon(_ request: inout URLRequest, proxy: ProxyResolver.HTTPProxy?) {
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) CursorUsageMenubar/1.0",
            forHTTPHeaderField: "User-Agent"
        )
        // Прямое соединение в фильтрующих сетях часто зависает на TLS — короткий таймаут, чтобы быстрее перейти к прокси.
        request.timeoutInterval = proxy == nil ? 8 : 15
    }

    private static func perform(_ request: URLRequest, proxy: ProxyResolver.HTTPProxy?) async throws -> Data {
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
        return data
    }
}

private struct AggregatedUsageEvents: Decodable {
    let aggregations: [Row]
    let startDate: String?

    struct Row: Decodable {
        let modelIntent: String
        let inputTokens: Double
        let outputTokens: Double
        let cacheReadTokens: Double
        let cacheWriteTokens: Double
        let totalCents: Double

        enum CodingKeys: String, CodingKey {
            case modelIntent, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, totalCents
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modelIntent = (try? c.decode(String.self, forKey: .modelIntent)) ?? "unknown"
            inputTokens = Self.num(c, .inputTokens)
            outputTokens = Self.num(c, .outputTokens)
            cacheReadTokens = Self.num(c, .cacheReadTokens)
            cacheWriteTokens = Self.num(c, .cacheWriteTokens)
            totalCents = Self.num(c, .totalCents)
        }

        private static func num(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) -> Double {
            if let value = try? c.decode(Double.self, forKey: key) { return value }
            if let text = try? c.decode(String.self, forKey: key) { return Double(text) ?? 0 }
            return 0
        }
    }

    func report() -> CursorAPI.ModelUsageReport {
        var folded: [String: (Double, Double, Double, Double, Double)] = [:]
        for row in aggregations {
            let prev = folded[row.modelIntent] ?? (0, 0, 0, 0, 0)
            folded[row.modelIntent] = (
                prev.0 + row.inputTokens,
                prev.1 + row.outputTokens,
                prev.2 + row.cacheReadTokens,
                prev.3 + row.cacheWriteTokens,
                prev.4 + row.totalCents
            )
        }
        let models = folded.map { name, v in
            CursorAPI.ModelSpend(
                model: name,
                inputTokens: v.0,
                outputTokens: v.1,
                cacheReadTokens: v.2,
                cacheWriteTokens: v.3,
                costCents: v.4
            )
        }.sorted { $0.costCents > $1.costCents }
        let since: Date = {
            guard let raw = startDate, let ms = Double(raw), ms > 1_000_000_000_000 else { return Date(timeIntervalSince1970: 0) }
            return Date(timeIntervalSince1970: ms / 1000)
        }()
        return CursorAPI.ModelUsageReport(since: since, models: models)
    }
}
