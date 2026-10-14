import Foundation

/// Nachrichten zwischen Engine-Prozess und Datei-Dienst (`minos-files`). Typen nur anhängen, Felder nur ergänzen
/// (tolerantes Codable); andere Hauptversion -> Helfer wird nicht benutzt.
public enum FileProtocol {
    public static let service = "minos-files"
    public static let major = 1
    public static let minor = 2
    /// Name des Helfers (neben dem eigenen Programm, im Bundle unter Contents/MacOS)
    public static let helperName = "minos-files"

    public enum Kind: UInt16, Sendable {
        case handshake = 1
        case decode = 10
        /// Zustand vieler Pfade (existiert, lokal / nur online), ohne herunterzuladen
        case stat = 11
        case quit = 19
        /// Herzschlag während eines Auftrags (Stufe + Frames), alle `beatInterval`
        case progress = 20
        /// fertig, fd der `.mtrk`-Datei hängt an der Nachricht
        case done = 21
        case failed = 22
        case statResult = 23
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
    /// Pfade prüfen (`frames` = geprüfte Pfade)
    case checking
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
    /// Cloud-Datei ohne lokale Kopie: der Anbieter gab den Inhalt beim Lesen nicht heraus
    case notLocal
}

/// Lesefehler einer Cloud-Datei erkennen (Datei-Dienst und Laden im Prozess)
public enum CloudRead {
    /// liegt in einem Ordner eines Dateianbieters (~/Library/CloudStorage/…, iCloud Drive)
    public static func isCloudBacked(_ path: String) -> Bool {
        path.contains("/Library/CloudStorage/") || path.contains("/Library/Mobile Documents/")
    }

    /// nur Platzhalter auf der Platte (SF_DATALESS); stat lädt nichts herunter
    public static func isDataless(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && st.st_flags & 0x4000_0000 != 0
    }

    /// Dekodieren einer Datei im Cloud-Ordner scheiterte, weil der Inhalt nicht lokal war: Platzhalter (SF_DATALESS) vor
    /// oder nach dem Lesen. Der leere Fehler (Foundation._GenericObjCError 0) allein zählt nicht: er kam im Lasttest von
    /// lokalen mp3 (Lesen hinter dem tatsächlichen Ende, siehe TrackAudio.readFailureIsEnd)
    public static func notLocal(path: String, datalessBefore: Bool, datalessAfter: Bool) -> Bool {
        isCloudBacked(path) && (datalessBefore || datalessAfter)
    }
}

public struct DecodeFailed: Codable, Sendable, Equatable {
    public var id: UInt64
    public var code: FileErrorCode
    public var detail: String

    public init(id: UInt64, code: FileErrorCode, detail: String) { self.id = id; self.code = code; self.detail = detail }
}

/// Pfade prüfen (stat ohne Materialisieren), höchstens `FileProtocol.statChunk` je Auftrag
public struct StatRequest: Codable, Sendable, Equatable {
    public var id: UInt64
    public var paths: [String]
    public init(id: UInt64, paths: [String]) { self.id = id; self.paths = paths }
}

public enum PathState: UInt8, Codable, Sendable {
    case missing = 0
    case local = 1
    /// nur online (SF_DATALESS)
    case online = 2
    /// anderer Fehler (Rechte, E/A)
    case error = 3
}

public struct StatResult: Codable, Sendable, Equatable {
    public var id: UInt64
    public var states: [PathState]
    public init(id: UInt64, states: [PathState]) { self.id = id; self.states = states }
}

extension FileProtocol {
    public static let statChunk = 2000
}
