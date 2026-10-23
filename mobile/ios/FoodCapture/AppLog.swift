import Foundation
#if os(iOS)
import UIKit
#endif

/// Captures everything the app prints — Swift, Rust (`eprintln!`), and anything else writing to
/// stdout/stderr — into `Application Support/food.log`, while still mirroring to the Xcode
/// console. Settings exposes the file through ShareLink.
enum AppLog {
    private(set) static var url: URL?
    private static var logHandle: FileHandle?
    private static var pipes: [Pipe] = []
    private static let writeLock = NSLock()
    private static let maxBytes = 2_000_000

    static func start() {
        guard logHandle == nil else { return }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("food.log")
        url = file

        if let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size]
            as? NSNumber, size.intValue > maxBytes {
            try? FileManager.default.removeItem(at: file)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            FileManager.default.createFile(atPath: file.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: file) else { return }
        handle.seekToEndOfFile()
        logHandle = handle

        write(header(appSupport: dir) + "\n")
        redirect(1)
        redirect(2)
    }

    private static func header(appSupport: URL) -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let config = Settings.providerConfig()
        let override = ProcessInfo.processInfo.environment["FOOD_DB_PATH"]
        let db = override?.hasPrefix("/") == true
            ? override!
            : appSupport.appendingPathComponent("food.db").path
        #if os(iOS)
        let device = "\(UIDevice.current.model) \(UIDevice.current.systemName) "
            + "\(UIDevice.current.systemVersion)"
        #else
        let device = "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        #endif
        return """

        ==== FoodCapture \(version) (\(build)) ====
        \(ISO8601DateFormatter().string(from: Date()))
        device: \(device)
        db: \(db)
        provider: base=\(config.baseURL) models=\(config.models.joined(separator: ",")) \
        api_key=\(config.apiKey.isEmpty ? "missing" : "set") \
        embed=\(config.embeddingsConfigured ? config.embedModel : "off") \
        jev=\(config.jevEnabled ? "on" : "off")
        """
    }

    private static func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        writeLock.lock()
        logHandle?.write(data)
        writeLock.unlock()
    }

    /// Point `fd` at a pipe; a reader thread copies each chunk to the log file and to the
    /// original descriptor, so the Xcode console still shows output.
    private static func redirect(_ fd: Int32) {
        let console = dup(fd)
        guard console >= 0 else { return }
        let pipe = Pipe()
        pipes.append(pipe)
        setvbuf(fd == 1 ? stdout : stderr, nil, _IONBF, 0)
        dup2(pipe.fileHandleForWriting.fileDescriptor, fd)
        let reader = pipe.fileHandleForReading
        Thread {
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                writeLock.lock()
                logHandle?.write(data)
                writeLock.unlock()
                data.withUnsafeBytes { raw in
                    if let base = raw.baseAddress {
                        _ = Darwin.write(console, base, raw.count)
                    }
                }
            }
        }.start()
    }
}
