import Foundation

// MARK: - ExecutionResult

enum ExecutionResult: Equatable {
    case executed(CommandType, detail: String)
    case rejected(ValidationResult)
    case failed(String)

    var displayString: String {
        switch self {
        case .executed(let cmd, let detail):
            if detail.isEmpty {
                return "Executed: \(cmd.rawValue)"
            }
            return "Executed: \(cmd.rawValue) — \(detail)"
        case .rejected(let validation):
            return "Rejected: \(validation.displayString)"
        case .failed(let reason):
            return "Failed: \(reason)"
        }
    }

    var isExecuted: Bool {
        if case .executed = self { return true }
        return false
    }
}

// MARK: - CommandExecutor

/// Routes validated commands to their handlers.
/// For POC, handlers log intent and delegate to JioSaavnService where appropriate.
/// Architecture is pluggable: swap JioSaavnService for real media implementation later.
final class CommandExecutor {

    private let jioSaavnService: JioSaavnService
    private let shortcutService: ShortcutService
    private weak var mqttManager: MQTTManager?

    init(jioSaavnService: JioSaavnService = JioSaavnService(), shortcutService: ShortcutService = ShortcutService(), mqttManager: MQTTManager? = nil) {
        self.jioSaavnService = jioSaavnService
        self.shortcutService = shortcutService
        self.mqttManager = mqttManager
    }

    /// Main entry point. Caller should have already validated; if validation is not .valid we reject.
    func execute(_ message: CommandMessage, validation: ValidationResult) -> ExecutionResult {
        guard validation.isValid else {
            print("[Executor] Rejected \(message.command.rawValue) — \(validation.displayString)")
            return .rejected(validation)
        }

        switch message.command {
        case .PLAY, .PAUSE:
            return runShortcut("JioSaavn Play Pause", for: message.command)

        case .NEXT:
            return handleNext()

        case .PREVIOUS:
            return handlePrevious()

        case .SEEK:
            return runShortcut("JioSaavn Search", for: .SEEK)

        case .SEARCH:
            return handleSearch(message)

        case .VOLUME_UP:
            return runShortcut("JioSaavn Volume Up", for: .VOLUME_UP)

        case .VOLUME_DOWN:
            return runShortcut("JioSaavn Volume Down", for: .VOLUME_DOWN)

        case .OPEN_LINK:
            // Existing "Open JioSaavn" shortcut, with no x-callback so the BCI app stays backgrounded.
            return runShortcut("Open JioSaavn", for: .OPEN_LINK, callback: false)

        case .unknown:
            // Should have been rejected via validation, but handle defensively
            let raw = message.rawCommand ?? "UNKNOWN"
            print("[Executor] Unknown command: \(raw)")
            return .rejected(.unsupportedCommand(raw))
        }
    }

    private func runShortcut(_ shortcut: String, for command: CommandType, callback: Bool = true) -> ExecutionResult {
        print("[COMMAND] Mapped command: \(command.rawValue)")
        print("[SHORTCUT] Launching: \(shortcut) callback=\(callback)")
        Task { @MainActor in
            _ = shortcutService.runShortcut(named: shortcut, callback: callback)
        }
        let detail = callback
            ? "Shortcut launch requested: \(shortcut)"
            : "Shortcut launch requested: \(shortcut) (no synaptimesh://return)"
        return .executed(command, detail: detail)
    }

    private func handleSearch(_ message: CommandMessage) -> ExecutionResult {
        guard let query = message.query else {
            print("[SEARCH] ERROR: Missing query field")
            return .failed("Missing query field")
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            print("[SEARCH] ERROR: Empty query")
            return .failed("Empty query")
        }

        // Direct in-app search — no Shortcut. Query comes from MQTT CommandMessage.query.
        // One-way flow: search, auto-open first valid result in JioSaavn, no user selection.
        print("[SEARCH] Query: \(trimmedQuery)")
        print("[SEARCH] Direct JioSaavnService.search(query:) — no Shortcut delegation")
        DispatchQueue.main.async { [weak self] in
            self?.mqttManager?.handleSearchStarted(query: trimmedQuery)
        }
        Task {
            do {
                let songs = try await self.jioSaavnService.search(query: trimmedQuery)
                // First valid result = first with a non-empty JioSaavn URL. Nothing hardcoded.
                let firstValid = songs.first(where: { !(($0.url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) })
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.mqttManager?.handleSearchSuccess(query: trimmedQuery, songs: songs, openedSong: firstValid)
                    if let song = firstValid {
                        print("[SEARCH] Auto-opening first valid result: \(song.title ?? "nil") url=\(song.url ?? "nil")")
                        let opened = self.jioSaavnService.openSong(song)
                        print("[SEARCH] Auto-open attempted, opened=\(opened)")
                    } else {
                        print("[SEARCH] No valid result (with URL) for '\(trimmedQuery)' — nothing opened")
                    }
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.mqttManager?.handleSearchFailure(query: trimmedQuery, error: reason)
                }
            }
        }
        return .executed(.SEARCH, detail: "Direct search started for query: \(trimmedQuery) — first valid result will auto-open in JioSaavn")
    }

    private func handleNext() -> ExecutionResult {
        return runShortcut("JioSaavn Next", for: .NEXT)
    }

    private func handlePrevious() -> ExecutionResult {
        return runShortcut("JioSaavn Previous", for: .PREVIOUS)
    }
}
