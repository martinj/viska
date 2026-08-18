import AppKit
import SwiftUI

struct MenuContentView: View {
    static let contentWidth: CGFloat = 320
    private static let maximumVisibleHistoryRows = 4
    private static let auxiliaryMessageHeight: CGFloat = 28

    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var dictationStore: DictationStore
    let openWordReplacements: () -> Void
    let openDictationActions: () -> Void

    static func contentSize(
        forHistoryCount historyCount: Int,
        showsStatusDetail: Bool = false,
        showsHotkeyError: Bool = false
    ) -> NSSize {
        NSSize(
            width: contentWidth,
            height: contentHeight(
                forHistoryCount: historyCount,
                showsStatusDetail: showsStatusDetail,
                showsHotkeyError: showsHotkeyError
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "mic.badge.xmark")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.primary)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Viska")
                        .font(.system(size: 14, weight: .semibold))

                    Text("Global hotkey dictation")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                statusBadge
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)

            // Status detail
            if shouldShowStatusDetail {
                Text(dictationStore.state.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            if let hotkeyErrorMessage = dictationStore.hotkeyErrorMessage {
                Label(hotkeyErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
            }

            // Settings sections
            VStack(alignment: .leading, spacing: 14) {
                // Permission setup section
                VStack(alignment: .leading, spacing: 7) {
                    Text("Permissions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    permissionRow(
                        title: "Microphone",
                        systemImage: "mic.fill",
                        status: dictationStore.microphonePermissionStatus
                    ) {
                        Task {
                            await dictationStore.requestMicrophonePermission()
                        }
                    }

                    permissionRow(
                        title: "Text insertion",
                        systemImage: "text.cursor",
                        status: dictationStore.accessibilityPermissionStatus
                    ) {
                        dictationStore.requestAccessibilityPermission()
                    }
                }

                // Recording mode section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recording Mode")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    Picker("Recording mode", selection: recordingModeBinding) {
                        ForEach(RecordingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Hotkey section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Shortcut")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    HotkeyRecorderView(currentHotkey: settingsStore.preferences.hotkey) { descriptor in
                        dictationStore.updateHotkey(descriptor)
                    }
                }

                // Word replacements section
                VStack(alignment: .leading, spacing: 6) {
                    Text("Word Replacements")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    WordReplacementsMenuRow(
                        label: ruleCountLabel,
                        action: openWordReplacements
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictation Actions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    SettingsMenuRow(
                        systemImage: "wand.and.sparkles",
                        label: Self.actionCountLabel(settingsStore.preferences.dictationActions.count),
                        help: "Edit dictation actions",
                        action: openDictationActions
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    if dictationStore.transcriptionHistory.isEmpty {
                        Text("No transcriptions yet")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .frame(height: 28, alignment: .center)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(dictationStore.transcriptionHistory) { item in
                                    TranscriptionHistoryRow(
                                        item: item,
                                        actions: settingsStore.preferences.dictationActions,
                                        actionFeedback: dictationStore.recentActionFeedback(for: item.id),
                                        canApplyAction: dictationStore.canApplyActionToRecent,
                                        applyAction: { actionID in
                                            dictationStore.applyDictationAction(
                                                id: actionID,
                                                toTranscriptID: item.id
                                            )
                                        },
                                        copy: { dictationStore.copyTranscript(id: item.id) }
                                    )

                                    if item.id != dictationStore.transcriptionHistory.last?.id {
                                        Divider()
                                            .padding(.leading, 6)
                                    }
                                }
                            }
                        }
                        .frame(
                            maxHeight: Self.historyViewportHeight(
                                forHistoryCount: dictationStore.transcriptionHistory.count
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)

            Spacer(minLength: 0)

            Divider()
                .padding(.horizontal, 12)

            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit")
                        .font(.system(size: 12))
                    Spacer()
                    Text("⌘Q")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(
            width: Self.contentWidth,
            height: Self.contentHeight(
                forHistoryCount: dictationStore.transcriptionHistory.count,
                showsStatusDetail: shouldShowStatusDetail,
                showsHotkeyError: dictationStore.hotkeyErrorMessage != nil
            ),
            alignment: .topLeading
        )
    }

    private var ruleCountLabel: String {
        let count = settingsStore.preferences.wordReplacements
            .filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count

        switch count {
        case 0:
            return "No rules yet"
        case 1:
            return "1 rule"
        default:
            return "\(count) rules"
        }
    }

    static func actionCountLabel(_ count: Int) -> String {
        switch count {
        case 0: "No actions yet"
        case 1: "1 action"
        default: "\(count) actions"
        }
    }

    private static func contentHeight(
        forHistoryCount historyCount: Int,
        showsStatusDetail: Bool,
        showsHotkeyError: Bool
    ) -> CGFloat {
        let clampedCount = min(max(historyCount, 0), maximumVisibleHistoryRows)
        let auxiliaryHeight = (showsStatusDetail ? auxiliaryMessageHeight : 0)
            + (showsHotkeyError ? auxiliaryMessageHeight : 0)
        // Two 58-point management sections. Keep the empty-state constant in sync.
        guard clampedCount > 0 else { return 506 + auxiliaryHeight }

        let baseHeight: CGFloat = 442
        let recentLabelHeight: CGFloat = 14
        let recentSpacing: CGFloat = 6
        let rowHeight: CGFloat = 52
        let dividerHeight: CGFloat = 1
        let historyHeight = recentLabelHeight
            + recentSpacing
            + (CGFloat(clampedCount) * rowHeight)
            + (CGFloat(max(clampedCount - 1, 0)) * dividerHeight)

        return baseHeight + historyHeight + auxiliaryHeight
    }

    private static func historyViewportHeight(forHistoryCount historyCount: Int) -> CGFloat {
        let visibleRowCount = min(max(historyCount, 0), maximumVisibleHistoryRows)
        let rowHeight: CGFloat = 52
        let dividerHeight: CGFloat = 1

        return (CGFloat(visibleRowCount) * rowHeight)
            + (CGFloat(max(visibleRowCount - 1, 0)) * dividerHeight)
    }

    private func permissionRow(
        title: String,
        systemImage: String,
        status: PermissionStatus,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(permissionColor(for: status))
                .frame(width: 18, height: 18)

            Text(title)
                .font(.system(size: 12))

            Spacer()

            Text(permissionLabel(for: status))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(permissionColor(for: status))

            if let actionTitle = permissionActionTitle(for: status) {
                PermissionActionButton(
                    title: actionTitle,
                    systemImage: permissionActionIcon(for: status),
                    color: permissionColor(for: status),
                    action: action
                )
            }
        }
        .frame(height: 24)
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(dictationStore.state.statusTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.1), in: Capsule())
    }

    private var recordingModeBinding: Binding<RecordingMode> {
        Binding(
            get: { settingsStore.preferences.recordingMode },
            set: { settingsStore.updateRecordingMode($0) }
        )
    }

    private var statusSymbolName: String {
        switch dictationStore.state {
        case .unavailable, .failed:
            "exclamationmark.triangle.fill"
        case .idle:
            "checkmark.circle.fill"
        case .recording:
            "mic.circle.fill"
        case .transcribing, .processing:
            "waveform.and.magnifyingglass"
        case .inserting:
            "text.cursor"
        }
    }

    private var statusColor: Color {
        switch dictationStore.state {
        case .unavailable, .failed:
            .orange
        case .idle:
            .green
        case .recording:
            .red
        case .transcribing, .processing, .inserting:
            .blue
        }
    }

    private var shouldShowStatusDetail: Bool {
        Self.showsStatusDetail(for: dictationStore.state)
    }

    static func showsStatusDetail(for state: DictationState) -> Bool {
        switch state {
        case .unavailable, .failed:
            true
        case .idle, .recording, .transcribing, .processing, .inserting:
            false
        }
    }

    private func permissionLabel(for status: PermissionStatus) -> String {
        switch status {
        case .granted:
            "Allowed"
        case .notDetermined:
            "Needed"
        case .denied:
            "Needed"
        case .restricted:
            "Blocked"
        }
    }

    private func permissionActionTitle(for status: PermissionStatus) -> String? {
        switch status {
        case .granted, .restricted:
            nil
        case .notDetermined:
            "Allow"
        case .denied:
            "Open"
        }
    }

    private func permissionActionIcon(for status: PermissionStatus) -> String {
        switch status {
        case .notDetermined:
            "checkmark"
        case .denied:
            "arrow.up.forward.app"
        case .granted, .restricted:
            "checkmark"
        }
    }

    private func permissionColor(for status: PermissionStatus) -> Color {
        switch status {
        case .granted:
            .green
        case .notDetermined, .denied:
            .orange
        case .restricted:
            .red
        }
    }
}

private struct TranscriptionHistoryRow: View {
    let item: TranscriptionHistoryItem
    let actions: [DictationAction]
    let actionFeedback: RecentActionFeedback.Phase?
    let canApplyAction: Bool
    let applyAction: (DictationAction.ID) -> Void
    let copy: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                Text(relativeTimestamp(for: item.createdAt))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Text(item.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                recentActionMenu

                Button(action: copy) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Copy transcript")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .frame(height: 52)
        .onHover { isHovered = $0 }
    }

    private var recentActionMenu: some View {
        ZStack {
            Menu {
                Section("Apply Action") {
                    ForEach(actions) { action in
                        Button {
                            applyAction(action.id)
                        } label: {
                            Label(action.name, systemImage: "wand.and.sparkles")
                        }
                    }
                }

                Divider()

                Text("Copies the result")
            } label: {
                Image(systemName: "wand.and.sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(actions.isEmpty ? .tertiary : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(actions.isEmpty || !canApplyAction)
            .opacity(actionFeedback == nil ? 1 : 0)

            if actionFeedback != nil {
                recentActionFeedbackLabel
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .help(recentActionHelp)
        .animation(.easeOut(duration: 0.12), value: actionFeedback)
    }

    @ViewBuilder
    private var recentActionFeedbackLabel: some View {
        switch actionFeedback {
        case .processing:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.small)
                .frame(width: 16, height: 16)
        case .copied:
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 24, height: 24)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 24, height: 24)
        case nil:
            EmptyView()
        }
    }

    private var recentActionHelp: String {
        switch actionFeedback {
        case .processing(let actionName):
            "Processing with \(actionName)…"
        case .copied:
            "Copied transformed text"
        case .failed(let message):
            message
        case nil where actions.isEmpty:
            "Create a Dictation Action first"
        case nil:
            "Apply a Dictation Action and copy the result"
        }
    }

    private func relativeTimestamp(for date: Date) -> String {
        let elapsedSeconds = max(0, Int(Date().timeIntervalSince(date)))

        switch elapsedSeconds {
        case ..<60:
            return "just now"
        case ..<3_600:
            let minutes = elapsedSeconds / 60
            return "\(minutes)m ago"
        case ..<86_400:
            let hours = elapsedSeconds / 3_600
            return "\(hours)h ago"
        default:
            let days = elapsedSeconds / 86_400
            return "\(days)d ago"
        }
    }
}

private struct SettingsMenuRow: View {
    let systemImage: String
    let label: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)

                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)

                Spacer()

                Text("Edit…")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
        .onHover { isHovered = $0 }
    }
}

private struct WordReplacementsMenuRow: View {
    let label: String
    let action: () -> Void

    var body: some View {
        SettingsMenuRow(
            systemImage: "arrow.left.arrow.right",
            label: label,
            help: "Edit word replacements",
            action: action
        )
    }
}

private struct PermissionActionButton: View {
    let title: String
    let systemImage: String
    let color: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(color)
                .frame(width: 62, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(isHovered ? 0.18 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(color.opacity(isHovered ? 0.48 : 0.30), lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(title)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}
