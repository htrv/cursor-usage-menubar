import AppKit
import Foundation

@MainActor
final class UsageStore: ObservableObject {
    @Published var pace: PaceSnapshot?
    @Published var errorText: String?
    @Published var lastRefresh: Date?
    @Published var lastVia: String?
    @Published var icon: NSImage

    private var history = HistoryStore()
    private var timer: Timer?
    private var didStart = false

    init() {
        icon = IconRenderer.image(dayFill: 0, apiPercent: nil, overPace: false)
        // Не ждать открытия меню — иначе history/иконка пустые.
        Task { @MainActor in
            self.start()
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        Task { await refresh() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func refresh() async {
        do {
            let result = try await CursorAPI.fetchUsage()
            let summary = result.summary
            let plan = summary.individualUsage?.plan
            let total = plan?.totalPercentUsed ?? 0
            let api = plan?.apiPercentUsed ?? 0
            guard let cycleStart = Pace.parseDate(summary.billingCycleStart),
                  let cycleEnd = Pace.parseDate(summary.billingCycleEnd) else {
                throw AppError.parse("не разобрать даты цикла")
            }
            let deltas = history.record(
                totalPercent: total,
                apiPercent: api,
                used: plan?.used,
                cycleStart: cycleStart,
                cycleEnd: cycleEnd
            )
            let snap = try Pace.compute(
                summary: summary,
                todayTotalPct: deltas.todayTotal,
                todayApiPct: deltas.todayApi,
                daySeed: deltas.seededFrom
            )
            pace = snap
            errorText = nil
            lastVia = result.via
            lastRefresh = Date()
            icon = IconRenderer.image(
                dayFill: snap.dayFillVisual,
                apiPercent: snap.apiPercent,
                overPace: snap.status == .over
            )
            PromExport.write(snapshot: snap, models: result.models)
        } catch {
            errorText = error.localizedDescription
            icon = IconRenderer.image(dayFill: 0, apiPercent: nil, overPace: true)
            PromExport.writeFailure(error.localizedDescription)
        }
    }
}
