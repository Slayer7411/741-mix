import AVFoundation

/// Abspiel-Zustand eines Decks, wird vom Audio-Thread gelesen und geschrieben.
/// Skalare Felder werden vom UI-Thread gesetzt (auf arm64 atomar genug für Steuerwerte);
/// Puffer werden nur bei gestopptem Deck getauscht (siehe `MixEngine.load`).
public final class DeckPlayer: @unchecked Sendable {
    // Audiodaten
    var left: UnsafeMutablePointer<Float>?
    var right: UnsafeMutablePointer<Float>?
    var frames = 0

    // Transport (Positionen in Frames)
    public internal(set) var position: Double = 0
    public var playing = false
    public var reverse = false

    // Loop
    public internal(set) var loopActive = false
    public internal(set) var loopStart: Double = 0
    public internal(set) var loopEnd: Double = 0

    // Flux: Schattenposition läuft weiter, während Loop/Reverse aktiv sind
    public var flux = false
    public internal(set) var fluxPosition: Double = 0

    /// Positionswechsel vom UI, wird am Anfang des nächsten Render-Blocks übernommen (NaN = keiner)
    var pendingSeek: Double = .nan
    var pendingLoop: (active: Bool, start: Double, end: Double)?

    public internal(set) var reachedEnd = false

    func render(frameCount: Int, abl: UnsafeMutableAudioBufferListPointer) {
        guard abl.count >= 2,
              let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
              let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return }

        if !pendingSeek.isNaN {
            position = pendingSeek
            fluxPosition = pendingSeek
            pendingSeek = .nan
        }
        if let l = pendingLoop {
            loopActive = l.active; loopStart = l.start; loopEnd = l.end
            pendingLoop = nil
        }

        guard playing, let L = left, let R = right, frames > 0 else {
            outL.update(repeating: 0, count: frameCount)
            outR.update(repeating: 0, count: frameCount)
            return
        }

        let step: Double = reverse ? -1 : 1
        let fluxRunning = flux && (reverse || loopActive)
        var pos = position
        for i in 0..<frameCount {
            let p = Int(pos)
            if p >= 0 && p < frames {
                outL[i] = L[p]
                outR[i] = R[p]
            } else {
                outL[i] = 0
                outR[i] = 0
            }
            pos += step
            if loopActive, !reverse, pos >= loopEnd { pos -= (loopEnd - loopStart) }
            if loopActive, reverse, pos < loopStart { pos += (loopEnd - loopStart) }
            if pos < 0 { pos = 0 }
        }
        if fluxRunning { fluxPosition += Double(frameCount) } else { fluxPosition = pos }
        position = pos
        if pos >= Double(frames) {
            playing = false
            reachedEnd = true
        }
    }
}
