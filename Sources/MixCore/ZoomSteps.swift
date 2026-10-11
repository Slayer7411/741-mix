import Foundation

/// Zoom-Stufen der Oberfläche (1 = 100 %), wie im Webbrowser.
public enum ZoomSteps {
    public static let levels: [Double] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    public static var range: ClosedRange<Double> { levels.first!...levels.last! }

    /// nächste Stufe über `z`; `limit` = größter Zoom, der noch passt (zwischen zwei Stufen -> genau `limit`)
    public static func larger(than z: Double, limit: Double = .infinity) -> Double {
        let next = levels.first { $0 > z + 0.001 } ?? levels.last!
        return max(z, min(next, limit))
    }

    /// nächste Stufe unter `z`
    public static func smaller(than z: Double) -> Double {
        levels.last { $0 < z - 0.001 } ?? levels.first!
    }

    /// gespeicherter Wert -> gültiger Zoom (Bereich, ganze Prozent)
    public static func clamp(_ z: Double) -> Double {
        guard z.isFinite else { return 1 }
        return (min(range.upperBound, max(range.lowerBound, z)) * 100).rounded() / 100
    }

    /// „125 %“
    public static func percent(_ z: Double) -> String { "\(Int((z * 100).rounded())) %" }
}
