import Foundation

/// Thin wrapper around the `mediaremote-adapter.pl` subprocess.
///
/// It is intentionally isolated behind a tiny surface area so the underlying "now playing" source
/// can be swapped without touching downstream logic.
final class AdapterProcess {
    struct Configuration: Sendable {
        var perlPath: String = "/usr/bin/perl"
        var scriptURL: URL
        var frameworkPath: String
    }

    enum Event: Sendable {
        case stdoutLine(String)
        case stderrLine(String)
        case exited(Int32?)
    }

    private let config: Configuration
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    init(config: Configuration) {
        self.config = config
    }

    func start(onEvent: @escaping @Sendable (Event) -> Void) throws {
        precondition(process == nil, "AdapterProcess.start called twice without stop()")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.perlPath)
        p.arguments = [
            config.scriptURL.path,
            // Adapter usage: mediaremote-adapter.pl FRAMEWORK_PATH [TEST_CLIENT_PATH] [FUNCTION [OPTIONS...]]
            config.frameworkPath,
            "stream",
            // Full snapshots avoid stale UI/state when diff payloads omit `playing`.
            "--no-diff",
        ]

        let out = Pipe()
        let err = Pipe()
        p.standardOutput = out
        p.standardError = err

        stdoutPipe = out
        stderrPipe = err
        process = p

        // FileHandle readabilityHandler callbacks may arrive on a non-main thread.
        attachLineReader(fileHandle: out.fileHandleForReading) { line in
            onEvent(.stdoutLine(line))
        }
        attachLineReader(fileHandle: err.fileHandleForReading) { line in
            onEvent(.stderrLine(line))
        }

        p.terminationHandler = { proc in
            onEvent(.exited(proc.terminationStatus))
        }

        try p.run()
    }

    func stop() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if let p = process, p.isRunning {
            p.terminate()
        }

        process = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func attachLineReader(fileHandle: FileHandle, onLine: @escaping @Sendable (String) -> Void) {
        var buffer = Data()

        fileHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }

            buffer.append(chunk)

            while true {
                guard let newlineRange = buffer.firstRange(of: Data([0x0A])) else { break } // \n
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                if let line = String(data: lineData, encoding: .utf8) {
                    let trimmed = line.trimmingCharacters(in: .newlines)
                    if !trimmed.isEmpty {
                        onLine(trimmed)
                    }
                }
            }
        }
    }
}

