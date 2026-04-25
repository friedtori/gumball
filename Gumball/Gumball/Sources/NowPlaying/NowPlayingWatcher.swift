import Foundation
import os

protocol NowPlayingSource: Sendable {
    func events() -> AsyncStream<NowPlayingEvent>
    func stop()
}

/// Watches system Now Playing by spawning the `mediaremote-adapter` subprocess and parsing JSON lines.
final class NowPlayingWatcher: NowPlayingSource, @unchecked Sendable {
    private let log = Logger(subsystem: "com.gumball.Gumball", category: "NowPlaying")
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()

    private var streamContinuation: AsyncStream<NowPlayingEvent>.Continuation?
    private var runTask: Task<Void, Never>?
    private var shouldRun = ManagedAtomicFlag()

    private var lastEmitted: NowPlayingEvent?

    init() {}

    func events() -> AsyncStream<NowPlayingEvent> {
        AsyncStream { continuation in
            self.streamContinuation = continuation
            self.shouldRun.set(true)
            self.runTask = Task.detached(priority: .background) { [weak self] in
                await self?.runLoop()
            }
            continuation.onTermination = { [weak self] _ in
                self?.stop()
            }
        }
    }

    func stop() {
        shouldRun.set(false)
        runTask?.cancel()
        runTask = nil
        streamContinuation?.finish()
        streamContinuation = nil
    }

    private func runLoop() async {
        var attempt = 0

        while shouldRun.get(), !Task.isCancelled {
            do {
                try await runOnce()
                attempt = 0
            } catch {
                attempt += 1
                let delay = backoffDelaySeconds(attempt: attempt)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func runOnce() async throws {
        guard let (scriptURL, frameworkPath) = resolveBundledAdapter() else {
            throw AdapterResolutionError.missingBundleResources
        }

        log.info("Starting adapter: \(scriptURL.path, privacy: .public)")

        let proc = AdapterProcess(config: .init(scriptURL: scriptURL, frameworkPath: frameworkPath))

        // Bridge callback-style events into async, then return when the process exits.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            do {
                try proc.start { [weak self] evt in
                    guard let self else { return }
                    switch evt {
                    case .stdoutLine(let line):
                        self.handleStdoutLine(line)
                    case .stderrLine(let line):
                        // Non-fatal logs by spec; surface them for debugging.
                        self.log.debug("adapter stderr: \(line, privacy: .public)")
                    case .exited:
                        proc.stop()
                        self.log.error("Adapter exited; will respawn with backoff.")
                        cont.resume(throwing: AdapterResolutionError.processExited)
                    }
                }
            } catch {
                proc.stop()
                cont.resume(throwing: error)
            }
        }
    }

    private func handleStdoutLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        // `stream` output is an envelope: {"type":"data","diff":false,"payload":{...}}
        // We only care about the nested payload.
        guard let envelope = try? decoder.decode(AdapterStreamEnvelope.self, from: data) else { return }
        guard let payload = envelope.payload else { return }

        let event = NowPlayingEvent(adapter: payload)

        // Debounce identical events (including playing state + elapsed/duration + metadata).
        if event == lastEmitted { return }
        lastEmitted = event

        streamContinuation?.yield(event)
    }

    private func resolveBundledAdapter() -> (scriptURL: URL, frameworkPath: String)? {
        // Expected bundled layout (based on upstream repo contents you copied):
        // Resources/mediaremote-adapter/bin/mediaremote-adapter.pl
        // Resources/mediaremote-adapter/build/MediaRemoteAdapter.framework
        //
        // In v0.1 we just locate the script and a framework directory and pass the framework path through.
        guard let script = Bundle.main.url(forResource: "mediaremote-adapter", withExtension: "pl", subdirectory: "mediaremote-adapter/bin") else {
            return nil
        }

        guard let frameworkURL = Bundle.main.url(forResource: "MediaRemoteAdapter", withExtension: "framework", subdirectory: "mediaremote-adapter/build") else {
            return nil
        }

        return (script, frameworkURL.path)
    }

    private func backoffDelaySeconds(attempt: Int) -> Double {
        // Exponential backoff with a sane cap for a long-running watcher.
        // 1, 2, 4, 8, ... up to 60s
        let capped = min(attempt, 6) // 2^6 = 64
        return min(pow(2.0, Double(capped - 1)), 60.0)
    }

    enum AdapterResolutionError: Error {
        case missingBundleResources
        case processExited
    }
}

// MARK: - Tiny atomic flag (no external deps)

private struct AdapterStreamEnvelope: Decodable, Sendable {
    var type: String?
    var diff: Bool?
    var payload: NowPlayingEvent.AdapterPayload?
}

/// Minimal atomic bool suitable for simple run/stop signaling.
/// (Deliberately avoids pulling in swift-atomics at this stage.)
final class ManagedAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        let v = value
        lock.unlock()
        return v
    }
}

