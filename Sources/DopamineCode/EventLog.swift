import Foundation

/// Append-only log plus a small in-memory ring buffer for the menu.
///
/// The whole point of this app is that it runs for hours behind a closed lid, where
/// nothing on screen can be observed. Without a durable log there is no way to answer
/// "did it actually stay awake, and what happened at 03:40" after the fact.
final class EventLog {
    static let shared = EventLog()

    enum Level: String {
        case info = "INFO"
        case warn = "WARN"
        case error = "FOUT"
    }

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: Level
        let message: String
    }

    private let queue = DispatchQueue(label: "com.peter46jan.dopaminecode.log")
    private let fileURL: URL
    private var recent: [Entry] = []
    private let recentLimit = 60

    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent("Library/Logs/Dopamine Code", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("dopamine-code.log")

        // Carry the history over from the app's previous name, so a run from before the
        // rename can still be reviewed afterwards.
        //
        // The old directory is removed only when the move genuinely succeeded. `try?` on
        // both lines meant a failed move — the destination directory could not be created,
        // say — was followed by a recursive delete of the only copy of the history. A log
        // that exists to answer "what happened at 03:40" must not be the thing that gets
        // thrown away by its own migration.
        let legacy = home.appendingPathComponent("Library/Logs/Wakker/wakker.log")
        if FileManager.default.fileExists(atPath: legacy.path),
           !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try FileManager.default.moveItem(at: legacy, to: fileURL)
                try? FileManager.default.removeItem(at: legacy.deletingLastPathComponent())
            } catch {
                NSLog("Dopamine Code: oud logboek kon niet verhuisd worden (%@); origineel blijft staan.",
                      error.localizedDescription)
            }
        }
    }

    var logPath: String { fileURL.path }

    func log(_ level: Level, _ message: String) {
        let entry = Entry(date: Date(), level: level, message: message)
        queue.async { [self] in
            recent.append(entry)
            if recent.count > recentLimit { recent.removeFirst(recent.count - recentLimit) }
            let line = "\(stamp.string(from: entry.date)) [\(level.rawValue)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            // Create-then-append, never write-the-whole-file. The old fallback replaced the
            // entire log with this one line whenever the handle could not be opened — which
            // is right when the file is simply absent and catastrophic for any other reason.
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }

    func info(_ m: String) { log(.info, m) }
    func warn(_ m: String) { log(.warn, m) }
    func error(_ m: String) { log(.error, m) }

    func snapshot() -> [Entry] {
        queue.sync { recent }
    }

    /// Rolls the file over once it passes a megabyte. A personal tool should not quietly
    /// eat disk for years.
    ///
    /// Renames rather than truncates. The old version kept the last 2000 lines and threw the
    /// rest away with no archive and no notice — which for a log whose entire purpose is
    /// answering "what happened at 03:40" is the wrong direction to fail in. It also only
    /// ever ran from `AppModel.start()`, so an app that launches at login and runs for weeks
    /// never rotated at all, right up until the one moment it discarded most of its history.
    /// The guardian now calls this hourly as well.
    func rotateIfNeeded() {
        queue.async { [self] in
            guard let size = try? FileManager.default
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int, size > 1_048_576 else { return }
            let archive = fileURL.deletingLastPathComponent()
                .appendingPathComponent("dopamine-code.1.log")
            try? FileManager.default.removeItem(at: archive)
            do {
                try FileManager.default.moveItem(at: fileURL, to: archive)
            } catch {
                NSLog("Dopamine Code: logboek roteren mislukt (%@).", error.localizedDescription)
                return
            }
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }
}
