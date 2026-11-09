import Foundation

/// Пишет textfile для node_exporter на этом Маке. Prometheus забирает его через scrape :9100.
///
/// Метки у числовых рядов только `membership` (и `model` у расхода по моделям).
/// Темп и способ отсчёта суток — отдельные ряды: иначе смена pace/day_seed
/// рвёт историю процента на несколько серий.
enum PromExport {
    private static let dir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/node_exporter/textfile", isDirectory: true)
    }()

    /// Последний удачный разбор моделей. Сбой этого запроса не должен вырезать
    /// ряды из файла: Prometheus пометит их stale и в истории появятся дыры.
    private static var lastModels: CursorAPI.ModelUsageReport?

    static func write(snapshot: PaceSnapshot, models: CursorAPI.ModelUsageReport?) {
        if let models { lastModels = models }
        let membership = esc(snapshot.membership)
        let id = "{membership=\"\(membership)\"}"
        var lines: [String] = []
        var declared: Set<String> = []
        func gauge(_ name: String, _ help: String, _ labels: String, _ value: Double) {
            if declared.insert(name).inserted {
                lines.append("# HELP \(name) \(help)")
                lines.append("# TYPE \(name) gauge")
            }
            lines.append("\(name)\(labels) \(num(value))")
        }
        gauge("cursor_usage_up", "1 if the last Cursor usage fetch succeeded.", id, 1)
        gauge("cursor_usage_total_percent", "Included usage spent in the current weekly window, percent. Resets when the window rolls.", id, snapshot.totalPercent)
        gauge("cursor_usage_expected_percent", "Even pace for the current weekly window, percent.", id, snapshot.expectedPercent)
        gauge("cursor_usage_auto_percent", "Auto-bucket percent. Equals total when the plan has one shared pool.", id, snapshot.autoPercent)
        if let api = snapshot.apiPercent {
            gauge("cursor_usage_api_percent", "Named-model percent. Emitted only when the API reports a separate pool.", id, api)
        }
        gauge("cursor_usage_today_percent", "Percentage points of the weekly pool spent since local midnight.", id, snapshot.todayTotalPct)
        gauge("cursor_usage_daily_allowance_percent", "Remaining weekly percent divided by days left including today.", id, snapshot.dailyAllowancePct)
        gauge("cursor_usage_day_fill_ratio", "Today spend divided by today's allowance. 1 means the day budget is used up.", id, snapshot.dayFill)
        gauge("cursor_usage_days_total", "Days in the current included-usage window.", id, Double(snapshot.daysTotal))
        gauge("cursor_usage_days_elapsed", "Days from the window start through today.", id, Double(snapshot.daysElapsedIncludingToday))
        gauge("cursor_usage_days_remaining", "Days after today until the window ends.", id, Double(snapshot.daysRemainingAfterToday))
        gauge("cursor_usage_cycle_start_seconds", "Start of the included-usage window, unix seconds.", id, snapshot.cycleStart.timeIntervalSince1970)
        gauge("cursor_usage_cycle_end_seconds", "End of the included-usage window, unix seconds.", id, snapshot.cycleEnd.timeIntervalSince1970)
        gauge("cursor_usage_pace", "0 below even pace, 1 on pace, 2 above. Label-free so the history stays one series.", id, paceCode(snapshot.status))
        gauge("cursor_usage_day_seed", "0 yesterday snapshot, 1 linear midnight estimate, 2 first sample of the window.", id, daySeedCode(snapshot.daySeed))
        if let used = snapshot.used {
            gauge("cursor_usage_used", "Plan units used. Absent when the live API does not report a counter.", id, used)
        }
        if let limit = snapshot.limit {
            gauge("cursor_usage_limit", "Plan unit cap. Absent when the live API does not report a counter.", id, limit)
        }
        if let report = lastModels {
            gauge("cursor_usage_models_since_seconds", "Start of the cumulative model totals Cursor returned, unix seconds. Not the weekly window.", id, report.since.timeIntervalSince1970)
            for row in report.models {
                let labels = "{membership=\"\(membership)\",model=\"\(esc(row.model))\"}"
                gauge("cursor_usage_model_cost_cents", "Cumulative included-usage valuation in cents for one model since models_since. Sum of tiers.", labels, row.costCents)
                gauge("cursor_usage_model_input_tokens", "Cumulative input tokens for one model since models_since.", labels, row.inputTokens)
                gauge("cursor_usage_model_output_tokens", "Cumulative output tokens for one model since models_since.", labels, row.outputTokens)
                gauge("cursor_usage_model_cache_read_tokens", "Cumulative cache-read tokens for one model since models_since.", labels, row.cacheReadTokens)
                gauge("cursor_usage_model_cache_write_tokens", "Cumulative cache-write tokens for one model since models_since.", labels, row.cacheWriteTokens)
            }
        }
        gauge("cursor_usage_collected_at_seconds", "When this sample was written, unix seconds.", id, Date().timeIntervalSince1970)
        save(lines.joined(separator: "\n") + "\n")
    }

    static func writeFailure(_ message: String) {
        let note = message.replacingOccurrences(of: "\n", with: " ")
        let body = """
        # HELP cursor_usage_up 1 if the last Cursor usage fetch succeeded.
        # TYPE cursor_usage_up gauge
        # ERROR \(note)
        cursor_usage_up{membership="unknown"} 0
        # HELP cursor_usage_collected_at_seconds When this sample was written, unix seconds.
        # TYPE cursor_usage_collected_at_seconds gauge
        cursor_usage_collected_at_seconds{membership="unknown"} \(num(Date().timeIntervalSince1970))

        """
        save(body)
    }

    private static func save(_ body: String) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("cursor_usage.prom")
        let tmp = dir.appendingPathComponent("cursor_usage.prom.tmp")
        do {
            try body.write(to: tmp, atomically: true, encoding: .utf8)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            try? body.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private static func daySeedCode(_ seed: DaySeed) -> Double {
        switch seed {
        case .yesterdayLast: return 0
        case .midnightEstimate: return 1
        case .firstSample: return 2
        }
    }

    private static func paceCode(_ status: PaceStatus) -> Double {
        switch status {
        case .under: return 0
        case .onTrack: return 1
        case .over: return 2
        }
    }

    private static func esc(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func num(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
