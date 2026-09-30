import Foundation
import CocoaMQTT
import Combine

enum ConnectionState: Equatable {
    case offline
    case connecting
    case online
    case disconnecting
}

class MQTTManager: ObservableObject {
    @Published var isConnected = false
    @Published var connectionState: ConnectionState = .offline
    @Published var lastCommand = "No command received"
    @Published var statusMessage = "Disconnected"

    // Pipeline published state
    @Published var rawMessage: String?
    @Published var parsedCommand: CommandMessage?
    @Published var validationResult: ValidationResult?
    @Published var executionResult: ExecutionResult?
    @Published var commandHistory: [CommandHistoryEntry] = []
    @Published var lastDecodeError: String?

    // Direct in-app SEARCH state (no Shortcut). Query always comes from MQTT.
    // One-way flow: SEARCH auto-opens the first valid result; no user selection.
    @Published var searchState: SearchState = .idle
    @Published var searchResults: [JioSaavnSong] = []
    @Published var searchQuery: String?
    @Published var searchError: String?
    @Published var searchOpenedSong: JioSaavnSong?

    private var mqtt: CocoaMQTT?
    private let validator = CommandValidator()
    private lazy var executor: CommandExecutor = CommandExecutor(mqttManager: self)
    private let jsonDecoder = JSONDecoder()
    private let identity = DeviceIdentity.shared

    // Broker settings (host/port fixed; topics are per-user dynamic)
    private let host = "broker.emqx.io"
    private let port: UInt16 = 1883

    /// Active command topic for this session (nil until connected).
    private var activeCommandTopic: String?
    private var activeUsername: String = ""

    // Legacy global topic — subscribed only as fallback so old servers
    // still reach this client; messages there are accepted only when no
    // username is set (transition period).
    private let legacyTopic = "bci/rohan/commands/ios"

    var deviceID: String { identity.deviceID }
    var username: String { identity.normalizedUsername }

    // MARK: - Connect / Disconnect (UUID-gated, mirrors Android)

    /// Connect with the typed device ID. Publishes bci/devices/register
    /// {device_id, username, device_type: ios} then subscribes to
    /// bci/<username>/commands/ios (+ status/ack/media).
    func connect(username rawName: String? = nil) {
        if let rawName {
            identity.saveUsername(rawName)
        }
        guard identity.isUsernameValid else {
            statusMessage = "Enter Device ID first"
            return
        }
        // Prevent multiple connection attempts
        if let mqtt = mqtt, mqtt.connState == .connected || mqtt.connState == .connecting {
            print("Already connected or connecting")
            return
        }

        // Clean up old instance
        mqtt?.disconnect()
        mqtt = nil

        let user = identity.normalizedUsername
        let cmdTopic = "bci/\(user)/commands/ios"
        activeCommandTopic = cmdTopic
        activeUsername = user

        // Stable client ID per phone (not random each launch).
        let short = String(identity.deviceID.prefix(6))
        let client = CocoaMQTT(clientID: "iOS-\(short)", host: host, port: port)
        client.keepAlive = 60
        client.autoReconnect = true
        client.autoReconnectTimeInterval = 5
        client.delegate = self
        client.logLevel = .debug

        self.mqtt = client
        connectionState = .connecting
        statusMessage = "Connecting..."
        isConnected = false

        _ = client.connect()
    }

    func disconnect() {
        guard mqtt != nil else {
            connectionState = .offline
            statusMessage = "Disconnected"
            return
        }
        connectionState = .disconnecting
        statusMessage = "Disconnecting..."
        publishOffline()
        // Unsubscribe per-user topics before dropping the client.
        if let cmd = activeCommandTopic { mqtt?.unsubscribe(cmd) }
        if !activeUsername.isEmpty {
            mqtt?.unsubscribe("bci/\(activeUsername)/status")
            mqtt?.unsubscribe("bci/\(activeUsername)/ack")
            mqtt?.unsubscribe("bci/\(activeUsername)/media")
        }
        mqtt?.autoReconnect = false
        mqtt?.disconnect()
        mqtt = nil
        activeCommandTopic = nil
        isConnected = false
        connectionState = .offline
        statusMessage = "Disconnected"
    }

    // MARK: - Presence / ACK (per-user topics)

    private func publishOnline() {
        guard let mqtt, !activeUsername.isEmpty else { return }
        // 1. Device registration (stable UUID + configurable username).
        if let data = try? JSONSerialization.data(
            withJSONObject: identity.registrationPayload()),
           let json = String(data: data, encoding: .utf8) {
            mqtt.publish(DeviceIdentity.discoveryTopic, withString: json,
                         qos: .qos1, retained: true)
            print("[MQTT] Published register: \(json)")
        }
        // 2. ONLINE presence on per-user status.
        mqtt.publish("bci/\(activeUsername)/status",
                     withString: "{\"status\":\"ONLINE\"}", qos: .qos1, retained: true)
    }

    private func publishOffline() {
        guard let mqtt, !activeUsername.isEmpty else { return }
        mqtt.publish("bci/\(activeUsername)/status",
                     withString: "{\"status\":\"OFFLINE\"}", qos: .qos1, retained: true)
    }

    /// ACK back to server on bci/<username>/ack so dashboard shows EXECUTED.
    func publishAck(command: String) {
        guard let mqtt, !activeUsername.isEmpty else { return }
        let payload = "{\"status\":\"EXECUTED\",\"command\":\"\(command)\"}"
        mqtt.publish("bci/\(activeUsername)/ack", withString: payload, qos: .qos1)
    }

    // MARK: - Direct SEARCH helpers (in-app, no Shortcut)

    func resetSearchState() {
        searchState = .idle
        searchResults = []
        searchQuery = nil
        searchError = nil
        searchOpenedSong = nil
    }

    func handleSearchStarted(query: String) {
        searchQuery = query
        searchResults = []
        searchError = nil
        searchOpenedSong = nil
        searchState = .searching
    }

    func handleSearchSuccess(query: String, songs: [JioSaavnSong], openedSong: JioSaavnSong? = nil) {
        searchQuery = query
        searchResults = songs
        searchError = nil
        searchOpenedSong = openedSong
        searchState = songs.isEmpty ? .noResults : .success
        print("[SEARCH] Success: \(songs.count) result(s) for '\(query)' auto-opened=\(openedSong?.title ?? "none")")
    }

    func handleSearchFailure(query: String, error: String) {
        searchQuery = query
        searchResults = []
        searchError = error
        searchOpenedSong = nil
        searchState = .failure
        print("[SEARCH] Failure for '\(query)': \(error)")
    }

    /// Open a song's actual JioSaavn URL. Used for the auto-opened first valid
    /// result (no user selection). No hardcoded URL/ID.
    func openSongInJioSaavn(_ song: JioSaavnSong) {
        let opened = JioSaavnService().openSong(song)
        print("[SEARCH] openSongInJioSaavn title=\(song.title ?? "nil") opened=\(opened) url=\(song.url ?? "nil")")
    }
}

extension MQTTManager: CocoaMQTTDelegate {

    func mqtt(_ mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        if ack == .accept {
            DispatchQueue.main.async {
                self.isConnected = true
                self.connectionState = .online
                self.statusMessage = "Online"
            }
            // Per-user command channel (UUID-gated) + legacy fallback.
            if let cmd = activeCommandTopic {
                mqtt.subscribe(cmd, qos: .qos1)
                print("Subscribed to \(cmd)")
            }
            mqtt.subscribe(legacyTopic, qos: .qos1)
            if !activeUsername.isEmpty {
                mqtt.subscribe("bci/\(activeUsername)/status", qos: .qos1)
                mqtt.subscribe("bci/\(activeUsername)/ack", qos: .qos1)
                mqtt.subscribe("bci/\(activeUsername)/media", qos: .qos1)
            }
            publishOnline()
            print("Successfully connected; device=\(identity.deviceID) user=\(activeUsername)")
        } else {
            DispatchQueue.main.async {
                self.connectionState = .offline
                self.statusMessage = "Connection refused"
            }
        }
    }

    func mqtt(_ mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16) {
        // UUID-gated isolation: only act on our own per-user command topic.
        // Legacy global accepted only when no username set (transition).
        let topic = message.topic
        if let expected = activeCommandTopic, !expected.isEmpty {
            guard topic == expected else {
                print("[MQTT] Ignored message on \(topic) (expecting \(expected)) — different ID")
                return
            }
        } else if topic != legacyTopic {
            print("[MQTT] Ignored message on \(topic) — no active device ID")
            return
        }
        guard let payload = message.string else { return }

        print("[MQTT] Received command: \(payload)")
        print("===== RAW MESSAGE =====")
        print(payload)
        print("=======================")

        // Always store raw on main
        DispatchQueue.main.async {
            self.rawMessage = payload
            self.lastCommand = payload
            self.statusMessage = "Message received"
        }

        // Pipeline: JSON -> CommandMessage -> Validation -> Execution
        guard let data = payload.data(using: .utf8) else {
            let v = ValidationResult.invalidJSON("Payload not UTF-8")
            let e = ExecutionResult.rejected(v)
            print("[Decode] FAILED: not UTF-8")
            print("[Validation] \(v.displayString)")
            print("[Execution] \(e.displayString)")
            DispatchQueue.main.async {
                self.parsedCommand = nil
                self.validationResult = v
                self.executionResult = e
                self.lastDecodeError = "Payload not UTF-8"
                self.appendHistory(rawCommand: "—", confidence: nil, validation: v, execution: e, timestamp: nil)
            }
            return
        }

        do {
            let decoded = try jsonDecoder.decode(CommandMessage.self, from: data)
            print("[COMMAND] Decoded command: \(decoded.command.rawValue) raw=\(decoded.rawCommand ?? decoded.command.rawValue)")
            print("[Decode] SUCCESS: command=\(decoded.command.rawValue) raw=\(decoded.rawCommand ?? decoded.command.rawValue) confidence=\(String(describing: decoded.confidence)) timestamp=\(String(describing: decoded.timestamp)) url=\(String(describing: decoded.url))")
            let validation = validator.validate(decoded)
            print("[Validation] \(validation.displayString)")
            let execution = executor.execute(decoded, validation: validation)
            print("[Execution] \(execution.displayString)")
            if case .executed(let cmd, _) = execution {
                self.publishAck(command: cmd.rawValue)
                if cmd == .OPEN_LINK {
                    print("[OPEN_LINK] URL open attempted for \(decoded.url ?? "nil")")
                }
            }

            DispatchQueue.main.async {
                self.parsedCommand = decoded
                self.validationResult = validation
                self.executionResult = execution
                self.lastDecodeError = nil
                self.appendHistory(
                    rawCommand: decoded.rawCommand ?? decoded.command.rawValue,
                    confidence: decoded.confidence,
                    validation: validation,
                    execution: execution,
                    timestamp: decoded.timestamp
                )
            }
        } catch {
            // Accept direct MQTT command tokens in addition to the existing JSON payload.
            let rawCommand = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            if let command = CommandType.resolveAlias(rawCommand) {
                let decoded = CommandMessage(
                    command: command,
                    rawCommand: rawCommand,
                    confidence: 1.0,
                    timestamp: Date().timeIntervalSince1970
                )
                let validation = validator.validate(decoded)
                let execution = executor.execute(decoded, validation: validation)
                print("[Decode] DIRECT MQTT command=\(rawCommand)")
                print("[Validation] \(validation.displayString)")
                print("[Execution] \(execution.displayString)")
                if case .executed(let cmd, _) = execution {
                    self.publishAck(command: cmd.rawValue)
                }
                DispatchQueue.main.async {
                    self.parsedCommand = decoded
                    self.validationResult = validation
                    self.executionResult = execution
                    self.lastDecodeError = nil
                    self.appendHistory(
                        rawCommand: rawCommand,
                        confidence: decoded.confidence,
                        validation: validation,
                        execution: execution,
                        timestamp: decoded.timestamp
                    )
                }
                return
            }
            let v = ValidationResult.invalidJSON(error.localizedDescription)
            let e = ExecutionResult.rejected(v)
            print("[Decode] FAILED: \(error)")
            print("[Validation] \(v.displayString)")
            print("[Execution] \(e.displayString)")
            DispatchQueue.main.async {
                self.parsedCommand = nil
                self.validationResult = v
                self.executionResult = e
                self.lastDecodeError = error.localizedDescription
                // For invalid JSON, show raw payload snippet as command
                let snippet = String(payload.prefix(30))
                self.appendHistory(rawCommand: snippet.isEmpty ? "Invalid JSON" : snippet, confidence: nil, validation: v, execution: e, timestamp: nil)
            }
        }
    }

    // MARK: - History (cap 20)

    private func appendHistory(rawCommand: String, confidence: Double?, validation: ValidationResult, execution: ExecutionResult, timestamp: TimeInterval?) {
        let entry = CommandHistoryEntry(
            date: Date(),
            command: rawCommand,
            confidence: confidence,
            validationDisplay: validation.displayString,
            executionDisplay: execution.displayString,
            isValid: validation.isValid
        )
        commandHistory.insert(entry, at: 0)
        if commandHistory.count > 20 {
            commandHistory = Array(commandHistory.prefix(20))
        }
    }

    func mqttDidDisconnect(_ mqtt: CocoaMQTT, withError err: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            if self.connectionState == .online {
                self.connectionState = .offline
            }
            self.statusMessage = "Disconnected"
        }
        if let err = err {
            print("Disconnected with error: \(err.localizedDescription)")
        }
    }

    // Required empty methods
    func mqtt(_ mqtt: CocoaMQTT, didSubscribeTopics success: NSDictionary, failed: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didUnsubscribeTopics topics: [String]) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {}
    func mqtt(_ mqtt: CocoaMQTT, didPublishAck id: UInt16) {}
    func mqttDidPing(_ mqtt: CocoaMQTT) {}
    func mqttDidReceivePong(_ mqtt: CocoaMQTT) {}
}
