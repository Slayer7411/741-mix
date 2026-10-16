import AVFoundation
import Foundation

/// Ergebnis einer async-Arbeit, die der Hintergrund-Thread abwartet
final class SyncBox<T: Sendable>: @unchecked Sendable {
    var result: Result<T, Error>?
}

/// Metadaten für m4a (Apple Lossless, AAC): Schlüssel der Atom-Standard über einen Durchreich-Export (keine Neukodierung).
/// BPM als `tmpo`, Tonart und Remixer als Freiform-Felder (Namensraum „itlk“), Cover als `covr`
public enum MediaTags {
    /// AVFoundation ist async: auf dem Hintergrund-Thread warten
    static func sync<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = SyncBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = Result<T, Error>.success(try await body()) } catch { box.result = Result<T, Error>.failure(error) }
            done.signal()
        }
        done.wait()
        return try box.result!.get()
    }

    static func item(_ id: AVMetadataIdentifier, _ value: NSCopying & NSObjectProtocol) -> AVMutableMetadataItem {
        let it = AVMutableMetadataItem()
        it.identifier = id
        it.value = value
        return it
    }

    /// Freiform-Feld (Namensraum „itlk“), UTF-8
    static func freeform(_ key: String, _ value: String) -> AVMutableMetadataItem {
        let it = AVMutableMetadataItem()
        it.keySpace = AVMetadataKeySpace(rawValue: "itlk")
        it.key = "com.apple.iTunes." + key as NSString
        it.value = value as NSString
        it.dataType = "com.apple.metadata.datatype.UTF-8"
        return it
    }

    /// Felder als Metadaten-Einträge (leere Felder fehlen)
    public static func items(_ t: ExportTags, cover: Data?) -> [AVMetadataItem] {
        var out: [AVMetadataItem] = []
        func s(_ id: AVMetadataIdentifier, _ v: String) { if !v.isEmpty { out.append(item(id, v as NSString)) } }
        s(.iTunesMetadataSongName, t.title)
        s(.iTunesMetadataArtist, t.artist)
        s(.iTunesMetadataAlbum, t.album)
        s(.iTunesMetadataUserComment, t.comment)
        s(.iTunesMetadataUserGenre, t.genre)
        s(.iTunesMetadataPublisher, t.label)
        if let y = t.year { s(.iTunesMetadataReleaseDate, String(y)) }
        if !t.remixer.isEmpty { out.append(freeform("REMIXER", t.remixer)) }
        if !t.key.isEmpty { out.append(freeform("initialkey", t.key)) }
        if let b = t.bpm, b > 0 {
            let it = item(.iTunesMetadataBeatsPerMin, NSNumber(value: Int(b.rounded())))
            it.dataType = "com.apple.metadata.datatype.int16-signed-be"   // tmpo: 16 Bit
            out.append(it)
        }
        if let c = cover, !c.isEmpty { out.append(item(.iTunesMetadataCoverArt, c as NSData)) }
        return out
    }

    /// `src` (m4a) nach `dst` kopieren, Metadaten ersetzen. Durchreichen: die Audiodaten bleiben unverändert
    public static func export(_ src: URL, to dst: URL, tags: ExportTags, cover: Data?) throws {
        let items = items(tags, cover: cover)
        try sync { @Sendable in
            guard let s = AVAssetExportSession(asset: AVURLAsset(url: src), presetName: AVAssetExportPresetPassthrough) else {
                throw AudioCutWriter.CutError.format
            }
            s.metadata = items
            try await s.export(to: dst, as: .m4a)
        }
    }

    /// Metadaten einer Datei: Kennung (Atom-Schlüssel bzw. Freiform) -> Text oder Zahl
    public static func read(_ url: URL) throws -> [String: String] {
        try sync { @Sendable in
            var out: [String: String] = [:]
            for it in try await AVURLAsset(url: url).load(.metadata) {
                guard let key = it.identifier?.rawValue ?? (it.keySpace == .iTunes ? (it.key as? String).map { "com.apple.iTunes:" + $0 } : nil) else { continue }
                if let s = try await it.load(.stringValue) { out[key] = s }
                else if let n = try await it.load(.numberValue) { out[key] = n.stringValue }
            }
            return out
        }
    }

    /// eingebettetes Cover einer Datei (m4a, mp3, aiff mit Metadaten)
    public static func embeddedCover(_ url: URL) throws -> Data? {
        try sync { @Sendable in
            for it in try await AVURLAsset(url: url).load(.metadata) where it.identifier == .commonIdentifierArtwork || it.identifier == .iTunesMetadataCoverArt {
                if let d = try await it.load(.dataValue) { return d }
            }
            return nil
        }
    }
}
