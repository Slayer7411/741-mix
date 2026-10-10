import CoreServices
import Foundation

/// FSEvents auf Datei-Ebene für die Library-Ordner. Auslagern („Speicher optimieren“) und fertige Downloads
/// ändern st_flags -> Ereignis mit ItemInodeMetaMod/ItemXattrMod; gemessen: Auslagern einer Datei unter Google
/// Drive meldet 0x00019000 (IsFile | XattrMod | InodeMetaMod).
public final class CloudWatcher: @unchecked Sendable {
    public typealias Handler = @Sendable (_ paths: [String], _ rescanAll: Bool) -> Void

    public let roots: [String]
    private let latency: Double
    private let queue: DispatchQueue
    private let handler: Handler
    private var stream: FSEventStreamRef?

    public init(roots: [String], latency: Double = 1.0, queue: DispatchQueue, handler: @escaping Handler) {
        self.roots = roots
        self.latency = latency
        self.queue = queue
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    public func start() -> Bool {
        guard stream == nil, !roots.isEmpty else { return stream != nil }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<CloudWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var changed: [String] = []
            var all = false
            for i in 0..<min(n, list.count) {
                let f = Int(flags[i])
                if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 { all = true }
                changed.append(list[i])
            }
            me.handler(changed, all)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes
                                             | kFSEventStreamCreateFlagWatchRoot)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          latency, flags) else { return false }
        FSEventStreamSetDispatchQueue(s, queue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return false
        }
        stream = s
        return true
    }

    public func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
