import Foundation

/// Result of running an external process.
struct ShellResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String

    var ok: Bool { status == 0 }
    var combined: String { (stdout + "\n" + stderr).trimmingCharacters(in: .whitespacesAndNewlines) }
}

enum Shell {
    /// Runs a binary with an argv array. Never goes through a shell, never inherits stdin.
    ///
    /// stdin is nulled deliberately: `sudo -n` must fail fast instead of blocking on a
    /// password prompt it can never receive from a menu bar app.
    ///
    /// **This blocks the calling thread.** Use `runAsync` from anything that runs on the
    /// main actor — a spawn plus its wait is tens to hundreds of milliseconds on a good
    /// day, and `sysadminctl` and `pmset -g therm` can take seconds when the machine is
    /// busy. The main queue is what drives the guardian timer.
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 15) -> ShellResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        proc.standardInput = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        proc.environment = env

        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err

        // Wait on a signal rather than polling. The old loop woke fifty times a second for
        // the whole run of the child; with the display re-assert firing every thirty
        // seconds for a multi-hour lid-closed session that is a lot of pointless wakeups on
        // a machine whose entire job right now is to sit still and stay awake.
        let exited = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in exited.signal() }

        do {
            try proc.run()
        } catch {
            return ShellResult(status: -1, stdout: "", stderr: "kon \(path) niet starten: \(error.localizedDescription)")
        }

        // Drain both pipes concurrently. Reading them serially deadlocks as soon as one
        // fills its 64 KB buffer while we are blocked on the other.
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        for (pipe, sink) in [(out, { outData = $0 }), (err, { errData = $0 })] as [(Pipe, (Data) -> Void)] {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                sink(pipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            _ = group.wait(timeout: .now() + 2)
            return ShellResult(status: -2, stdout: "", stderr: "\(path) reageerde niet binnen \(Int(timeout))s")
        }
        proc.waitUntilExit()   // returns at once; makes terminationStatus definitively valid
        _ = group.wait(timeout: .now() + 5)

        return ShellResult(
            status: proc.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// `run` on a background thread, for callers that live on the main actor.
    ///
    /// Every subprocess this app spawns is either diagnostic or a side effect nobody is
    /// waiting on, so none of them has any business standing in front of the guardian tick.
    static func runAsync(_ path: String, _ args: [String], timeout: TimeInterval = 15) async -> ShellResult {
        await Task.detached(priority: .userInitiated) {
            run(path, args, timeout: timeout)
        }.value
    }

    /// Runs a command as root through an AppleScript authorisation prompt.
    ///
    /// This is the fallback for when the sudoers grant is missing or has been removed.
    /// It is `AuthorizationExecuteWithPrivileges` under the hood and needs no code
    /// signature, no entitlement and no TCC approval.
    static func runAsAdmin(_ command: String, prompt: String) -> ShellResult {
        let escapedCommand = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let escapedPrompt = prompt
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = "do shell script \"\(escapedCommand)\" with prompt \"\(escapedPrompt)\" with administrator privileges"
        return run("/usr/bin/osascript", ["-e", script], timeout: 180)
    }

    /// AppleScript reports a user-cancelled auth sheet as error -128, but `osascript`
    /// itself exits with 1. Branching on the exit code alone turns "user pressed Cancel"
    /// into a spurious failure toast, so match the message instead.
    static func wasCancelled(_ result: ShellResult) -> Bool {
        let s = result.stderr
        return s.contains("-128") || s.contains("User canceled") || s.contains("User cancelled")
    }
}
