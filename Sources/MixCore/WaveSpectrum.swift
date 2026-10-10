import Foundation

/// Feines Spektrum je Wellenform-Block: 6 Bänder als Pegel + Höhen-Dauer (kurz = geschlossene Hats, lang = offene
/// Hats / Ride / Rauschen). 8 Bytes je Block, 300 Blöcke/s → 10 min ≈ 1,4 MB, 2-h-Set ≈ 17 MB.
public struct WaveSpectrum: Equatable, Sendable {
    public enum Band: Int, CaseIterable, Sendable {
        /// 20–60 Hz
        case sub
        /// 60–250 Hz (Kick-Körper, Bass)
        case bass
        /// 250 Hz – 1 kHz
        case lowMid
        /// 1–4 kHz
        case highMid
        /// 4–10 kHz (Hats)
        case high
        /// 10–20 kHz
        case air
    }

    public static let stride = 8
    /// Byte 6: Anteil des Fensters (~150 ms), in dem die Höhen nahe ihrer Spitze bleiben (0 = kurz, 255 = gehalten)
    public static let sustainSlot = 6

    /// je Block `stride` Bytes: Bänder (Pegel, 0,5-dB-Schritte, 255 = 0 dBFS, 0 = Stille), Höhen-Dauer, Reserve
    public var data: [UInt8]

    public init(data: [UInt8]) { self.data = data }
    public static let empty = WaveSpectrum(data: [])

    public var count: Int { data.count / Self.stride }

    @inline(__always) public func byte(_ i: Int, _ b: Band) -> UInt8 { data[i * Self.stride + b.rawValue] }
    /// Bandpegel in dBFS (Effektivwert des Bandes)
    @inline(__always) public func level(_ i: Int, _ b: Band) -> Float { Self.decibel(byte(i, b)) }
    /// 0 = kurze Höhen (geschlossene Hats), 1 = gehaltene Höhen (offene Hats, Ride, Rauschen)
    @inline(__always) public func sustain(_ i: Int) -> Float { Float(data[i * Self.stride + Self.sustainSlot]) / 255 }

    @inline(__always) public static func decibel(_ v: UInt8) -> Float { v == 0 ? -160 : (Float(v) - 255) / 2 }

    /// mittleres Quadrat → Byte (0,5 dB je Schritt, -127 dBFS … 0 dBFS)
    @inline(__always) public static func byte(meanSquare e: Float) -> UInt8 {
        guard e > 1e-13 else { return 0 }
        return UInt8(max(1, min(255, (255 + 20 * log10f(e)).rounded())))
    }

    /// Bezugspegel je Band (dB): Perzentil `p` (0…1) über die hörbaren Blöcke (Summe nicht leise) – trackeigene Verteilung
    public func reference(percentile p: Double = 0.95) -> [Float] {
        let n = count, s = Self.stride
        guard n > 0 else { return [Float](repeating: -60, count: Band.allCases.count) }
        var hist = [[Int]](repeating: [Int](repeating: 0, count: 256), count: Band.allCases.count)
        var used = 0
        data.withUnsafeBufferPointer { d in
            for i in 0..<n {
                let o = i * s
                // Block zählt, wenn irgendein Band über -70 dBFS liegt
                var top: UInt8 = 0
                for b in 0..<6 { top = max(top, d[o + b]) }
                guard top > 115 else { continue }
                used += 1
                for b in 0..<6 { hist[b][Int(d[o + b])] += 1 }
            }
        }
        guard used > 0 else { return [Float](repeating: -60, count: Band.allCases.count) }
        let target = Int(Double(used) * p)
        return hist.map { h in
            var acc = 0
            for v in 0..<256 {
                acc += h[v]
                if acc > target { return Self.decibel(UInt8(v)) }
            }
            return 0
        }
    }

    /// auf `points` Spalten verdichten (Browser-Vorschau, Übersicht): Bänder = mittlere Energie, Höhen-Dauer = Mittel
    public func reduced(to points: Int) -> WaveSpectrum {
        let n = count, s = Self.stride
        guard n > 0, points > 0 else { return .empty }
        var out = [UInt8](repeating: 0, count: points * s)
        let per = Double(n) / Double(points)
        for p in 0..<points {
            let a = min(n - 1, Int(Double(p) * per)), e = max(a + 1, min(n, Int(Double(p + 1) * per)))
            var acc = [Float](repeating: 0, count: 6)
            var sus: Float = 0
            for i in a..<e {
                for b in 0..<6 {
                    let v = data[i * s + b]
                    if v > 0 { acc[b] += powf(10, (Float(v) - 255) / 20) }
                }
                sus += Float(data[i * s + Self.sustainSlot])
            }
            let c = Float(e - a)
            for b in 0..<6 { out[p * s + b] = Self.byte(meanSquare: acc[b] / c) }
            out[p * s + Self.sustainSlot] = UInt8(min(255, (sus / c).rounded()))
        }
        return WaveSpectrum(data: out)
    }
}
