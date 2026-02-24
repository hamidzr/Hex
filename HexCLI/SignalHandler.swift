import Foundation

class SignalHandler {
    static let shared = SignalHandler()
    private var shouldStop = false
    private var shouldSkipTranscription = false
    private var silent = false
    private let queue = DispatchQueue(label: "signal-handler")

    private var sigintSource: DispatchSourceSignal?
    private var sighupSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    private init() {
        setupSignalHandlers()
    }

    func setSilent(_ silent: Bool) {
        queue.sync {
            self.silent = silent
        }
    }

    private func setupSignalHandlers() {
        let signalQueue = DispatchQueue(label: "signal-queue")

        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigintSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let isSilent = self.queue.sync { self.silent }
            if !isSilent {
                print("\nReceived SIGINT, stopping without transcription...")
            }
            self.stopWithoutTranscription()
        }
        sigintSource?.resume()

        sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: signalQueue)
        sighupSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let isSilent = self.queue.sync { self.silent }
            if !isSilent {
                print("\nReceived SIGHUP, stopping recording and transcribing...")
            }
            self.stop()
        }
        sighupSource?.resume()

        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigtermSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            let isSilent = self.queue.sync { self.silent }
            if !isSilent {
                print("\nReceived SIGTERM, stopping...")
            }
            self.stop()
        }
        sigtermSource?.resume()

        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
    }

    func stop() {
        queue.sync { shouldStop = true }
    }

    func stopWithoutTranscription() {
        queue.sync {
            shouldStop = true
            shouldSkipTranscription = true
        }
    }

    func reset() {
        queue.sync {
            shouldStop = false
            shouldSkipTranscription = false
        }
    }

    func checkShouldStop() -> Bool {
        queue.sync { shouldStop }
    }

    func checkShouldSkipTranscription() -> Bool {
        queue.sync { shouldSkipTranscription }
    }

    deinit {
        sigintSource?.cancel()
        sighupSource?.cancel()
        sigtermSource?.cancel()
    }
}
