import AppKit

enum IconRenderer {
    /// 18pt logical → draw at 2x for retina.
    static func image(dayFill: Double, apiPercent: Double, overPace: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            draw(in: rect, dayFill: dayFill, apiPercent: apiPercent, overPace: overPace)
            return true
        }
        img.isTemplate = false
        return img
    }

    private static func draw(in rect: NSRect, dayFill: Double, apiPercent: Double, overPace: Bool) {
        let fill = min(1, max(0, dayFill))
        let api = min(1, max(0, apiPercent / 100))

        let inset: CGFloat = overPace ? 1.5 : 1.0
        let ringRect = rect.insetBy(dx: inset, dy: inset)
        let lineW: CGFloat = 2.2

        // Optional outer pace warning
        if overPace {
            let warn = NSBezierPath(ovalIn: rect.insetBy(dx: 0.4, dy: 0.4))
            NSColor.systemRed.withAlphaComponent(0.55).setStroke()
            warn.lineWidth = 1.0
            warn.stroke()
        }

        // Track
        let track = NSBezierPath(ovalIn: ringRect)
        track.lineWidth = lineW
        NSColor.secondaryLabelColor.withAlphaComponent(0.35).setStroke()
        track.stroke()

        // Day fill arc (starts at 12 o'clock, clockwise)
        if fill > 0.001 {
            let center = NSPoint(x: ringRect.midX, y: ringRect.midY)
            let radius = min(ringRect.width, ringRect.height) / 2
            let startAngle: CGFloat = 90
            let endAngle = startAngle - CGFloat(fill) * 360
            let arc = NSBezierPath()
            arc.appendArc(
                withCenter: center,
                radius: radius,
                startAngle: startAngle,
                endAngle: endAngle,
                clockwise: true
            )
            dayColor(fill).setStroke()
            arc.lineWidth = lineW
            arc.lineCapStyle = .round
            arc.stroke()
        }

        // Inner solid dot — other models (api %)
        let dotR = min(ringRect.width, ringRect.height) * 0.22
        let dotRect = NSRect(
            x: ringRect.midX - dotR,
            y: ringRect.midY - dotR,
            width: dotR * 2,
            height: dotR * 2
        )
        let dot = NSBezierPath(ovalIn: dotRect)
        apiColor(api).setFill()
        dot.fill()

        // Tiny highlight for readability on dark menu bar
        NSColor.white.withAlphaComponent(0.18).setStroke()
        dot.lineWidth = 0.6
        dot.stroke()
    }

    private static func dayColor(_ fill: Double) -> NSColor {
        if fill < 0.70 { return NSColor.systemGreen }
        if fill < 0.90 { return NSColor.systemYellow }
        return NSColor.systemRed
    }

    /// Green → yellow → red by api fraction 0…1
    private static func apiColor(_ t: Double) -> NSColor {
        let t = min(1, max(0, t))
        // Hue: 0.33 green → 0.12 yellow → 0.0 red
        let hue: CGFloat
        if t < 0.5 {
            hue = 0.33 - CGFloat(t / 0.5) * (0.33 - 0.12)
        } else {
            hue = 0.12 - CGFloat((t - 0.5) / 0.5) * 0.12
        }
        return NSColor(hue: hue, saturation: 0.85, brightness: 0.95, alpha: 1)
    }
}
