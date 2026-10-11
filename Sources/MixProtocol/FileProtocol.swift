import Foundation

/// Nachrichten zwischen Engine-Prozess und Datei-Dienst (`minos-files`). Typen nur anhängen, Felder nur ergänzen
/// (tolerantes Codable); andere Hauptversion -> Helfer wird nicht benutzt.
public enum FileProtocol {
    public static let service = "minos-files"
    public static let major = 1
    public static let minor = 0
    /// Name des Helfers (neben dem eigenen Programm, im Bundle unter Contents/MacOS)
    public static let helperName = "minos-files"

    public enum Kind: UInt16, Sendable {
        case handshake = 1
        case decode = 10
        case quit = 19
        /// Herzschlag während eines Auftrags (Stufe + Frames), alle `beatInterval`
        case progress = 20
        /// fertig, fd der `.mtrk`-Datei hängt an der Nachricht
        case done = 21
        case failed = 22
    }

    public static let beatInterval = 0.25
}

/// Track dekodieren (bzw. aus dem Cache holen) und als `.mtrk` übergeben
public struct DecodeRequest: Codable, Sendable, Equatable {
    public var id: UInt64
    public var path: String
    public var sampleRate: Double
    /// Cache-Ordner (lokal, gehört der App)
    public var cacheDir: String

    public init(id: UInt64, path: String, sampleRate: Double, cacheDir: String) {
        self.id = id; self.path = path; self.sampleRate = sampleRate; self.cacheDir = cacheDir
    }
}

public enum DecodeStage: String, Codable, Sendable {
    /// Datei prüfen / öffnen (bei einer Cloud-Datei: wartet auf den Anbieter)
    case opening
    /// Datei liegt nur online, der Anbieter lädt sie beim Öffnen
    case fetching
    case decoding
    case writing
}

public struct DecodeProgress: Codable, Sendable, Equatable {
    public var id: UInt64
    public var stage: DecodeStage
    /// bisher dekodierte Frames
    public var frames: Int

    public init(id: UInt64, stage: DecodeStage, frames: Int) { self.id = id; self.stage = stage; self.frames = frames }
}

public struct DecodeDone: Codable, Sendable, Equatable {
    public var id: UInt64
    public var frames: Int
    public var fileSize: Int
    /// aus dem Cache (nicht neu dekodiert)
    public var cached: Bool
    /// Messwerte (ms): Öffnen bis erste Daten, Dekodieren + Analyse, Schreiben
    public var openMs: Double
    public var decodeMs: Double
    public var writeMs: Double

    public init(id: UInt64, frames: Int, fileSize: Int, cached: Bool, openMs: Double = 0, decodeMs: Double = 0, writeMs: Double = 0) {
        self.id = id; self.frames = frames; self.fileSize = fileSize; self.cached = cached
        self.openMs = openMs; self.decodeMs = decodeMs; self.writeMs = writeMs
    }
}

/// Fehler als Code (die Oberfläche übersetzt), `detail` nur fürs Protokoll
public enum FileErrorCode: String, Codable, Sendable {
    case missing, format, convert, read, cacheWrite, invalid, cancelled
}

public struct DecodeFailed: Codable, Sendable, Equatable {
    public var id: UInt64
    public var code: FileErrorCode
    public var detail: String

    public init(id: UInt64, code: FileErrorCode, detail: String) { self.id = id; self.code = code; self.detail = detail }
}
