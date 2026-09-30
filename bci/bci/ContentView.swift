//
//  ContentView.swift
//  bci
//
//  Created by Rohan Sidharth Samala on 09/09/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject var mqttManager = MQTTManager()
    @StateObject var identity = DeviceIdentity.shared
    @State var deviceIdInput: String = DeviceIdentity.shared.username

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                connectionCard
                latestCommandSection
                if !statusText.isEmpty {
                    statusRow
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("JioSaavn BCI Controller")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
            Text("Control your music with brain signals")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Connection

    private var connectionCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionColor)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(connectionTitle)
                    .font(.headline)
                Spacer()
            }
            .animation(.easeInOut(duration: 0.25), value: mqttManager.isConnected)

            // UUID-gated device ID (must match server active_device).
            VStack(alignment: .leading, spacing: 6) {
                Text("Device ID (must match server)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("e.g. sathwik", text: $deviceIdInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .disabled(mqttManager.connectionState == .connecting || mqttManager.isConnected)
                    .accessibilityLabel("Device ID")
                Text("Phone UUID: \(identity.deviceID.prefix(8))…")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Button {
                if mqttManager.isConnected || mqttManager.connectionState == .connecting {
                    mqttManager.disconnect()
                } else {
                    mqttManager.connect(username: deviceIdInput)
                }
            } label: {
                Text(connectButtonTitle)
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(mqttManager.isConnected ? Color(.systemGray) : Color.accentColor)
            .disabled(connectButtonDisabled)
            .accessibilityLabel(connectButtonTitle)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
    }

    private var connectionColor: Color {
        switch mqttManager.connectionState {
        case .online: return .green
        case .connecting, .disconnecting: return .orange
        case .offline: return .secondary
        }
    }

    private var connectionTitle: String {
        switch mqttManager.connectionState {
        case .online: return "Online"
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .offline: return "Offline / Standby"
        }
    }

    private var connectButtonTitle: String {
        switch mqttManager.connectionState {
        case .connecting: return "Connecting..."
        case .disconnecting: return "Disconnecting..."
        case .online: return "Disconnect"
        case .offline: return mqttManager.isConnected ? "Disconnect" : "Connect"
        }
    }

    private var connectButtonDisabled: Bool {
        mqttManager.connectionState == .connecting
        || mqttManager.connectionState == .disconnecting
        || (!mqttManager.isConnected && deviceIdInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Latest command

    private var latestCommandSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Latest Command")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            Group {
                if let cmd = mqttManager.parsedCommand {
                    commandCard(for: cmd)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    emptyCommandCard
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.28), value: commandIdentity)
        }
    }

    private var commandIdentity: String {
        guard let cmd = mqttManager.parsedCommand else { return "empty" }
        return "\(cmd.rawCommand ?? cmd.command.rawValue)|\(cmd.query ?? "")|\(mqttManager.searchStateLabel)"
    }

    private func commandCard(for cmd: CommandMessage) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbolName(for: cmd))
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
                .padding(.bottom, 2)

            Text(commandTitle(for: cmd))
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .lineLimit(2)

            Text(actionText(for: cmd))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(commandTitle(for: cmd)), \(actionText(for: cmd))")
    }

    private var emptyCommandCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 32, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Waiting for BCI command")
                .font(.body.weight(.medium))
                .foregroundStyle(.secondary)
            Text("Commands from Sub-Master\nwill appear here")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Status

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(statusText)
                .font(.body)
                .foregroundStyle(.primary)
                .animation(.easeInOut(duration: 0.2), value: statusText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Status, \(statusText)")
    }

    private var statusText: String {
        if mqttManager.statusMessage == "Connecting..." {
            return "Connecting..."
        }
        if mqttManager.statusMessage == "Connection refused" {
            return "Connection failed"
        }
        if !mqttManager.isConnected {
            return "Disconnected"
        }
        if let err = mqttManager.lastDecodeError, mqttManager.parsedCommand == nil {
            return err.isEmpty ? "Could not read command" : "Could not read command"
        }
        if let validation = mqttManager.validationResult, !validation.isValid {
            return "Command not recognized"
        }
        if mqttManager.parsedCommand?.command == .SEARCH {
            switch mqttManager.searchState {
            case .idle, .searching:
                return "Searching JioSaavn..."
            case .success:
                if mqttManager.searchOpenedSong != nil {
                    return "Opening JioSaavn..."
                }
                return "No playable result found"
            case .noResults:
                return "No results found"
            case .failure:
                return "Search failed"
            }
        }
        if mqttManager.parsedCommand != nil {
            if let execution = mqttManager.executionResult, !execution.isExecuted {
                return "Command failed"
            }
            return ""
        }
        return "Ready"
    }

    // MARK: - Presentation helpers (UI only)

    private func commandTitle(for cmd: CommandMessage) -> String {
        let raw = cmd.rawCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !raw.isEmpty { return raw }
        return cmd.command.rawValue
    }

    private func actionText(for cmd: CommandMessage) -> String {
        switch cmd.command {
        case .PLAY, .PAUSE:
            return "Play / Pause"
        case .NEXT:
            return "Next Song"
        case .PREVIOUS:
            return "Previous Song"
        case .SEEK:
            return "Seek"
        case .SEARCH:
            if let query = cmd.query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty {
                return query
            }
            return "Search"
        case .VOLUME_UP:
            return "Volume Up"
        case .VOLUME_DOWN:
            return "Volume Down"
        case .OPEN_LINK:
            return "Open JioSaavn"
        case .unknown:
            return "Unknown command"
        }
    }

    private func symbolName(for cmd: CommandMessage) -> String {
        switch cmd.command {
        case .NEXT:
            return "forward.fill"
        case .PREVIOUS:
            return "backward.fill"
        case .PLAY, .PAUSE:
            return "playpause.fill"
        case .VOLUME_UP:
            return "speaker.wave.3.fill"
        case .VOLUME_DOWN:
            return "speaker.wave.1.fill"
        case .SEARCH:
            return "magnifyingglass"
        case .OPEN_LINK:
            return "music.note"
        case .SEEK:
            return "gobackward"
        case .unknown:
            return "questionmark.circle"
        }
    }
}

private extension MQTTManager {
    /// Stable identity for the latest-command card animation. Reads existing state only.
    var searchStateLabel: String {
        switch searchState {
        case .idle: return "idle"
        case .searching: return "searching"
        case .success: return "success"
        case .noResults: return "noResults"
        case .failure: return "failure"
        }
    }
}

#Preview {
    ContentView()
}
