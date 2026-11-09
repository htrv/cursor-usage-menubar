import Foundation

enum DaySeed: String, Codable {
    case yesterdayLast
    case midnightEstimate
    case firstSample
}

/// Persists per-day baselines so we can compute today's spend delta.
struct HistoryStore {
    struct Snapshot: Codable {
        let at: Date
        let dayKey: String
        let totalPercentUsed: Double
        let apiPercentUsed: Double
        let used: Double?
    }

    struct DayBaseline: Codable {
        let dayKey: String
        let totalPercentUsed: Double
        let apiPercentUsed: Double
        let used: Double?
        let seededFrom: DaySeed
        let createdAt: Date
        /// Секунды unix начала цикла. Другое окно — другой смысл процента, вчерашний снимок не база.
        let cycleStart: String?
    }

    struct RecordResult {
        let todayTotal: Double
        let todayApi: Double
        let seededFrom: DaySeed
        let baselineCreatedAt: Date
    }

    private struct File: Codable {
        var baseline: DayBaseline?
        var last: Snapshot?
    }

    private let url: URL
    private let cal = Calendar.current
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("cursor-usage-menubar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
    }

    func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Returns today's deltas relative to day baseline.
    mutating func record(
        totalPercent: Double,
        apiPercent: Double,
        used: Double?,
        cycleStart: Date,
        cycleEnd: Date
    ) -> RecordResult {
        let key = dayKey()
        let cycleKey = String(Int(cycleStart.timeIntervalSince1970.rounded()))
        var file = load()

        let cycleChanged = file.baseline?.cycleStart != cycleKey
        if file.baseline?.dayKey != key || cycleChanged {
            file.baseline = makeBaseline(
                key: key,
                totalPercent: totalPercent,
                apiPercent: apiPercent,
                used: used,
                previous: cycleChanged ? nil : file.last,
                cycleStart: cycleStart,
                cycleEnd: cycleEnd,
                cycleKey: cycleKey
            )
        } else if file.baseline?.seededFrom == .firstSample,
                  let last = file.last,
                  last.dayKey == key {
            // Старый firstSample (запуск днём) — один раз пересчитать оценку на полночь,
            // если с тех пор почти не двигались (иначе baseline уже «живой»).
            let stale = abs(totalPercent - (file.baseline?.totalPercentUsed ?? totalPercent)) < 0.02
            if stale {
                file.baseline = makeBaseline(
                    key: key,
                    totalPercent: totalPercent,
                    apiPercent: apiPercent,
                    used: used,
                    previous: nil, // force midnight estimate path when no other-day last
                    cycleStart: cycleStart,
                    cycleEnd: cycleEnd,
                    cycleKey: cycleKey,
                    forceMidnight: true
                )
            }
        }

        let base = file.baseline!
        let todayTotal = max(0, totalPercent - base.totalPercentUsed)
        let todayApi = max(0, apiPercent - base.apiPercentUsed)
        file.last = Snapshot(
            at: Date(),
            dayKey: key,
            totalPercentUsed: totalPercent,
            apiPercentUsed: apiPercent,
            used: used
        )
        save(file)
        return RecordResult(
            todayTotal: todayTotal,
            todayApi: todayApi,
            seededFrom: base.seededFrom,
            baselineCreatedAt: base.createdAt
        )
    }

    private func makeBaseline(
        key: String,
        totalPercent: Double,
        apiPercent: Double,
        used: Double?,
        previous: Snapshot?,
        cycleStart: Date,
        cycleEnd: Date,
        cycleKey: String,
        forceMidnight: Bool = false
    ) -> DayBaseline {
        if !forceMidnight, let prev = previous, prev.dayKey != key {
            return DayBaseline(
                dayKey: key,
                totalPercentUsed: prev.totalPercentUsed,
                apiPercentUsed: prev.apiPercentUsed,
                used: prev.used,
                seededFrom: .yesterdayLast,
                createdAt: Date(),
                cycleStart: cycleKey
            )
        }

        // Нет вчерашнего снимка — оценка % на локальную полночь по линейному времени цикла.
        // Иначе firstSample = «всё до запуска потеряно».
        if let est = midnightEstimate(
            totalPercent: totalPercent,
            apiPercent: apiPercent,
            cycleStart: cycleStart,
            cycleEnd: cycleEnd
        ) {
            return DayBaseline(
                dayKey: key,
                totalPercentUsed: est.total,
                apiPercentUsed: est.api,
                used: used,
                seededFrom: .midnightEstimate,
                createdAt: Date(),
                cycleStart: cycleKey
            )
        }

        return DayBaseline(
            dayKey: key,
            totalPercentUsed: totalPercent,
            apiPercentUsed: apiPercent,
            used: used,
            seededFrom: .firstSample,
            createdAt: Date(),
            cycleStart: cycleKey
        )
    }

    /// total(midnight) ≈ total(now) * elapsed(midnight) / elapsed(now)
    private func midnightEstimate(
        totalPercent: Double,
        apiPercent: Double,
        cycleStart: Date,
        cycleEnd: Date
    ) -> (total: Double, api: Double)? {
        let now = Date()
        let midnight = cal.startOfDay(for: now)
        let span = cycleEnd.timeIntervalSince(cycleStart)
        guard span > 1 else { return nil }

        let elapsedNow = now.timeIntervalSince(cycleStart)
        let elapsedMid = midnight.timeIntervalSince(cycleStart)
        guard elapsedNow > 60, elapsedMid > 0, elapsedMid < elapsedNow else { return nil }

        let ratio = elapsedMid / elapsedNow
        // Не даём baseline выше текущего (иначе «сегодня» отрицательное).
        let t = min(totalPercent, max(0, totalPercent * ratio))
        let a = min(apiPercent, max(0, apiPercent * ratio))
        // Если оценка почти = сейчас (запуск сразу после полуночи) — нет смысла.
        if totalPercent - t < 0.01 { return nil }
        return (t, a)
    }

    private func load() -> File {
        guard let data = try? Data(contentsOf: url),
              let f = try? decoder.decode(File.self, from: data) else {
            return File()
        }
        return f
    }

    private func save(_ file: File) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        if let data = try? enc.encode(file) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
