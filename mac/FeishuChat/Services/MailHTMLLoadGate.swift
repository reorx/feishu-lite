import Foundation

/// Shared by the production WK bridge and tests: no load before protection installs.
@MainActor @Observable final class MailHTMLLoadGate {
    enum State: Equatable { case idle, preparing, loaded, failed, stopped }
    private(set) var state: State = .idle
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private let prepare: () async throws -> Void
    @ObservationIgnored private let load: (String) -> Void
    init(prepare: @escaping () async throws -> Void, load: @escaping (String) -> Void) {
        self.prepare = prepare; self.load = load
    }
    func start(document: String) async {
        guard state == .idle else { return }
        revision += 1
        let ticket = revision
        state = .preparing
        do {
            try await prepare()
            guard ticket == revision, !Task.isCancelled else { return }
            load(document)
            state = .loaded
        } catch {
            guard ticket == revision, !Task.isCancelled else { return }
            state = .failed
        }
    }
    func stop() { revision += 1; state = .stopped }
}
