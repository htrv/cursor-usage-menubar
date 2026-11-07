import Foundation

enum PaceStatus: String {
    case under = "ниже графика"
    case onTrack = "в графике"
    case over = "выше графика"
}

struct PaceSnapshot {
    let membership: String
    let cycleStart: Date
    let cycleEnd: Date
    let daysTotal: Int
    /// Дней от старта цикла до сегодня включительно (1…daysTotal).
    let daysElapsedIncludingToday: Int
    /// Дней после сегодня до конца цикла (0…).
    let daysRemainingAfterToday: Int
    let daysLeftIncludingToday: Int
    let elapsedFraction: Double
    let totalPercent: Double
    let autoPercent: Double
    let apiPercent: Double
    let used: Double?
    let limit: Double?
    let remaining: Double?
    let bonusTotal: Double?
    let todayTotalPct: Double
    let todayApiPct: Double
    let dailyAllowancePct: Double
    let dayFill: Double
    /// Для иконки: чуть поднимаем крохотную дугу, чтобы было видно.
    let dayFillVisual: Double
    let status: PaceStatus
    let expectedPercent: Double
    let daySeed: DaySeed
    let dayNote: String

    /// 0-based index текущего дня в цикле.
    var todayIndex: Int { max(0, daysElapsedIncludingToday - 1) }

    var daysUntilReset: Int {
        max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: cycleEnd)).day ?? 0)
    }
}

enum Pace {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ s: String) -> Date? {
        iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    static func compute(
        summary: UsageSummary,
        todayTotalPct: Double,
        todayApiPct: Double,
        daySeed: DaySeed = .firstSample
    ) throws -> PaceSnapshot {
        guard let start = parseDate(summary.billingCycleStart),
              let end = parseDate(summary.billingCycleEnd) else {
            throw AppError.parse("не разобрать даты цикла")
        }
        let plan = summary.individualUsage?.plan
        let total = plan?.totalPercentUsed ?? 0
        let auto = plan?.autoPercentUsed ?? total
        let api = plan?.apiPercentUsed ?? 0

        let now = Date()
        let span = max(end.timeIntervalSince(start), 1)
        let elapsedFraction = min(1, max(0, now.timeIntervalSince(start) / span))
        let expected = elapsedFraction * 100

        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let endDay = cal.startOfDay(for: end)
        // Число суток в цикле: [startDay, endDay) — последний день цикла = endDay - 1 день.
        let spanDays = max(1, cal.dateComponents([.day], from: startDay, to: endDay).day ?? 1)
        let today = cal.startOfDay(for: now)
        let dayIndex = max(0, min(spanDays - 1, cal.dateComponents([.day], from: startDay, to: today).day ?? 0))
        let daysElapsed = dayIndex + 1
        let daysRemainingAfter = max(0, spanDays - daysElapsed)
        let daysLeft = max(1, daysRemainingAfter + 1) // включая сегодня

        let remainingPct = max(0, 100 - total)
        let dailyAllowance = remainingPct / Double(daysLeft)
        let dayFill: Double
        if dailyAllowance <= 0.05 {
            dayFill = todayTotalPct > 0.05 ? 1 : 0
        } else {
            dayFill = min(1, max(0, todayTotalPct / dailyAllowance))
        }
        // Крохотный расход иначе не читается на 18pt кольце.
        let dayFillVisual: Double
        if todayTotalPct > 0.005 && dayFill > 0 {
            dayFillVisual = max(dayFill, 0.08)
        } else {
            dayFillVisual = dayFill
        }

        let slack = 5.0
        let status: PaceStatus
        if total > expected + slack {
            status = .over
        } else if total < expected - slack {
            status = .under
        } else {
            status = .onTrack
        }

        let dayNote: String
        switch daySeed {
        case .yesterdayLast:
            dayNote = "учёт дня от вчерашнего снимка"
        case .midnightEstimate:
            dayNote = "старт дня ≈ оценка на полночь (не было ночного снимка)"
        case .firstSample:
            dayNote = "учёт с первого опроса сегодня (ранний расход мог потеряться)"
        }

        return PaceSnapshot(
            membership: summary.membershipType ?? "?",
            cycleStart: start,
            cycleEnd: end,
            daysTotal: spanDays,
            daysElapsedIncludingToday: daysElapsed,
            daysRemainingAfterToday: daysRemainingAfter,
            daysLeftIncludingToday: daysLeft,
            elapsedFraction: elapsedFraction,
            totalPercent: total,
            autoPercent: auto,
            apiPercent: api,
            used: plan?.used,
            limit: plan?.breakdown?.total ?? plan?.limit,
            remaining: plan?.remaining,
            bonusTotal: plan?.breakdown?.total,
            todayTotalPct: todayTotalPct,
            todayApiPct: todayApiPct,
            dailyAllowancePct: dailyAllowance,
            dayFill: dayFill,
            dayFillVisual: dayFillVisual,
            status: status,
            expectedPercent: expected,
            daySeed: daySeed,
            dayNote: dayNote
        )
    }
}
