import Foundation

/// The "run a CLI to completion with a timeout, capture stdout" pattern shared by the
/// transcription engines (afconvert, whisper-cli, sherpa-onnx-offline). Call it OFF the
/// main thread — it blocks until the process exits or the timeout fires.
enum Subprocess {
    /// Returns (exit status, stdout), or nil if it couldn't launch or timed out. stderr is
    /// captured and discarded so a chatty tool can't fill the pipe and wedge.
    static func run(_ executable: String, _ args: [String], timeout: TimeInterval) -> (status: Int32, stdout: Data)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }

        var data = Data()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) != .success {
            // Timed out. SIGTERM first; a tool that ignores it would otherwise be left as an
            // orphan and the reader above would stay blocked forever. Escalate to SIGKILL, then
            // wait briefly so the pipe closes, the reader unblocks, and the worker thread is reclaimed.
            if p.isRunning { p.terminate() }
            if done.wait(timeout: .now() + 1) != .success {
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
                _ = done.wait(timeout: .now() + 2)
            }
            return nil
        }
        return (p.terminationStatus, data)
    }

    /// First path in `candidates` that is an executable file.
    static func firstExecutable(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
