import Foundation
import CoreGraphics

/// Calibrated gaps for SkyLight background input. Defaults follow the open-codex-computer-use sweep
/// (MIT; see THIRD_PARTY_NOTICES.md): focus record settle 10 ms, click recipe scale 0.2 (primer and
/// renderer settle 20 ms), key settle/release 10 ms. Every knob is an environment/config override, and
/// values are clamped: the click recipe failed at scale 0, so the floor is the smallest passing scale.
struct NativeInputTiming: Equatable, Sendable {
    var focusSettleMicros: UInt32 = 10_000
    var clickDelayScale: Double = 0.2
    var keySettleMicros: UInt32 = 10_000
    var keyReleaseMicros: UInt32 = 10_000

    static let defaults = NativeInputTiming()

    /// Native background lane switch: anything but an explicit off value keeps it on (BACKGROUND_NATIVE=0 kills it).
    static func nativeEnabled(_ raw: String?) -> Bool {
        !["0", "false", "off", "no"].contains((raw ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }
    static let minimumClickScale = 0.05

    /// `lookup` is Config.value in the app; tests pass a dictionary.
    static func parse(_ lookup: (String) -> String?) -> NativeInputTiming {
        func millis(_ key: String, _ fallback: UInt32) -> UInt32 {
            guard let raw = lookup(key)?.trimmingCharacters(in: .whitespaces), let value = Double(raw), value.isFinite else { return fallback }
            return UInt32(min(200, max(0, value)) * 1000)
        }
        var timing = NativeInputTiming()
        timing.focusSettleMicros = millis("SKY_FOCUS_SETTLE_MS", defaults.focusSettleMicros)
        timing.keySettleMicros = millis("SKY_KEY_SETTLE_MS", defaults.keySettleMicros)
        timing.keyReleaseMicros = millis("SKY_KEY_RELEASE_MS", defaults.keyReleaseMicros)
        if let raw = lookup("SKY_CLICK_DELAY_SCALE")?.trimmingCharacters(in: .whitespaces), let scale = Double(raw), scale.isFinite {
            timing.clickDelayScale = min(2, max(minimumClickScale, scale))
        }
        return timing
    }

    /// One step of the Chromium-compatible click recipe. Base delays are the inherited Cua values in
    /// microseconds; the effective delay is base × clickDelayScale (the mouse-move gap keeps its 15 ms base).
    struct ClickStep: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case move, down, up }
        let kind: Kind
        let onTarget: Bool
        let clickState: Int64
        let phase: Int64
        let delayMicros: UInt32
    }

    /// Move, an off-window primer down/up that wakes the renderer, then `count` (1 or 2) target pairs.
    func clickRecipe(count: Int) -> [ClickStep]? {
        guard (1...2).contains(count) else { return nil }
        func scaled(_ base: Double) -> UInt32 { UInt32(base * clickDelayScale) }
        var steps: [ClickStep] = [
            .init(kind: .move, onTarget: true, clickState: 0, phase: 2, delayMicros: scaled(15_000)),
            .init(kind: .down, onTarget: false, clickState: 1, phase: 1, delayMicros: scaled(1_000)),
            .init(kind: .up, onTarget: false, clickState: 1, phase: 2, delayMicros: scaled(100_000)),
        ]
        for pair in 1...count {
            steps.append(.init(kind: .down, onTarget: true, clickState: Int64(pair), phase: 3, delayMicros: scaled(1_000)))
            steps.append(.init(kind: .up, onTarget: true, clickState: Int64(pair), phase: 3, delayMicros: pair < count ? scaled(80_000) : 0))
        }
        return steps
    }

    /// Synthetic-active hold after the last mouse-up so Chromium's renderer consumes it before deactivation.
    var rendererSettleMicros: UInt32 { UInt32(100_000 * clickDelayScale) }

    /// Fixed sleep cost of one background click (focus settle in + recipe + renderer settle + focus settle out).
    func clickSleepMicros(count: Int) -> UInt32 {
        (clickRecipe(count: count) ?? []).reduce(0) { $0 + $1.delayMicros } + rendererSettleMicros + 2 * focusSettleMicros
    }
}

/// Pure geometry for the keep-alive decision (OCU WindowOcclusionKeepAlive): the window counts as
/// unoccluded when at least one sample of a grid over its bounds is not covered by a window above it.
enum NativeWindowVisibility {
    static func looksUnoccluded(bounds: CGRect, covering: [CGRect], grid: Int = 16) -> Bool {
        guard bounds.width > 0, bounds.height > 0, grid > 0 else { return false }
        for row in 0..<grid {
            for column in 0..<grid {
                let point = CGPoint(x: bounds.minX + bounds.width * (CGFloat(column) + 0.5) / CGFloat(grid),
                                    y: bounds.minY + bounds.height * (CGFloat(row) + 0.5) / CGFloat(grid))
                if !covering.contains(where: { $0.contains(point) }) { return true }
            }
        }
        return false
    }
}
