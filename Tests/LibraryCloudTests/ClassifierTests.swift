import Foundation
import Testing
@testable import LibraryCloud

private let reg = UInt16(S_IFREG) | 0o644

@Test func classifyFlags() {
    // gemessen unter Google Drive (File Provider): lokal 0x40 (UF_TRACKED), nur online 0x40000060
    #expect(CloudClassifier.classify(err: 0, flags: 0x40, mode: reg) == .local)
    #expect(CloudClassifier.classify(err: 0, flags: 0x8040, mode: reg) == .local)
    #expect(CloudClassifier.classify(err: 0, flags: 0x4000_0060, mode: reg) == .cloud)
    #expect(CloudClassifier.classify(err: 0, flags: 0x4000_0000, mode: reg) == .cloud)
    #expect(CloudClassifier.classify(err: 0, flags: 0, mode: reg) == .local)
}

@Test func classifyErrors() {
    #expect(CloudClassifier.classify(err: ENOENT, flags: 0, mode: 0) == .missing)
    #expect(CloudClassifier.classify(err: ENOTDIR, flags: 0, mode: 0) == .missing)
    // Materialisierung aus + Ordner noch nicht geladen
    #expect(CloudClassifier.classify(err: EDEADLK, flags: 0, mode: 0) == .unknown)
    #expect(CloudClassifier.classify(err: EACCES, flags: 0, mode: 0) == .unknown)
    #expect(CloudClassifier.classify(err: ETIMEDOUT, flags: 0, mode: 0) == .unknown)
    // Ordner statt Datei
    #expect(CloudClassifier.classify(err: 0, flags: 0x40, mode: UInt16(S_IFDIR) | 0o755) == .missing)
}

private let drive = "/Users/x/Library/CloudStorage/GoogleDrive-a@b.c/My Drive"

@Test func cloudPaths() {
    #expect(CloudPaths.isCloudBacked("\(drive)/Music/a.mp3"))
    #expect(CloudPaths.isCloudBacked("/Users/x/Library/Mobile Documents/com~apple~CloudDocs/a.mp3"))
    #expect(!CloudPaths.isCloudBacked("/Users/x/Music/a.mp3"))
    #expect(CloudPaths.providerRoot("\(drive)/Music/a.mp3") == "/Users/x/Library/CloudStorage/GoogleDrive-a@b.c")
    #expect(CloudPaths.providerRoot("/Users/x/Music/a.mp3") == nil)
    #expect(CloudPaths.providerName("/Users/x/Library/CloudStorage/GoogleDrive-a@b.c") == "Google Drive")
    #expect(CloudPaths.providerName("/Users/x/Library/CloudStorage/OneDrive-Personal") == "OneDrive")
    #expect(CloudPaths.commonFolder(["\(drive)/Music/DJ/a/1.mp3", "\(drive)/Music/DJ/b/2.mp3"]) == "\(drive)/Music/DJ")
    #expect(CloudPaths.commonFolder(["/a/b/c.mp3"]) == "/a/b")
    #expect(CloudPaths.commonFolder([]) == nil)
}

@Test func libraryFolderIgnoresOutliers() {
    var paths = (0..<95).map { "\(drive)/Music/DJ_Kollektion/Sub\($0 % 7)/t\($0).mp3" }
    paths += (0..<5).map { "\(drive)/Music/Other/t\($0).mp3" }
    paths.append("/Users/x/Library/CloudStorage/GoogleDrive-a@b.c/.Trash/x.mp3")
    paths.append("/Users/x/Downloads/local.flac")
    #expect(CloudPaths.libraryFolder(paths) == "\(drive)/Music/DJ_Kollektion")
    #expect(CloudPaths.libraryFolder(["/Users/x/Music/a.mp3"]) == nil)
}

@Test func watchRootsPerProvider() {
    let roots = CloudPaths.watchRoots([
        "\(drive)/Music/DJ/a.mp3", "\(drive)/Music/Other/b.mp3",
        "/Users/x/Library/CloudStorage/Dropbox/Tracks/c.mp3",
        "/Users/x/Library/CloudStorage/GoogleDrive-a@b.c/.Trash/old.mp3",
        "/Users/x/Music/local.mp3",
    ])
    #expect(roots == ["\(drive)/Music", "/Users/x/Library/CloudStorage/Dropbox/Tracks"].sorted())
}

/// Ausschnitte der echten `fileproviderctl evaluate`-Ausgabe (macOS 26.7, Google Drive)
@Test func pinParse() {
    let pinned = """
                isDownloaded = 1;
                isKeepDownloaded = 0;
                isRecursivelyDownloaded = 1;
                userInfo =             {
                    "ACTION_PIN" = 0;
                    "ACTION_UNPIN" = 1;
                };
    ACTION_PIN: SUBQUERY(fileproviderItems, $item, $item.userInfo.ACTION_PIN == 1).@count > 0 - NO
    """
    #expect(CloudPin.parse(pinned) == FolderStatus(pin: .pinned, recursivelyDownloaded: true, keepDownloaded: false))
    let open = """
                isKeepDownloaded = 0;
                isRecursivelyDownloaded = 0;
                    "ACTION_PIN" = 1;
                    "ACTION_UNPIN" = 0;
    """
    #expect(CloudPin.parse(open) == FolderStatus(pin: .notPinned, recursivelyDownloaded: false, keepDownloaded: false))
    #expect(CloudPin.parse("Error: no such item") == FolderStatus())
}
