import SwiftUI

@MainActor
final class WordReplacementsEditorModel: ObservableObject {
    @Published var rules: [WordReplacement] {
        didSet {
            guard rules != oldValue else { return }
            settingsStore.updateWordReplacements(rules)
        }
    }

    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        self.rules = settingsStore.preferences.wordReplacements
    }

    var hasIncompleteRule: Bool {
        rules.contains { isIncomplete($0) }
    }

    func addRule() -> UUID {
        let rule = WordReplacement(id: UUID(), trigger: "", replacement: "")
        rules.append(rule)
        return rule.id
    }

    func deleteRule(id: UUID) {
        rules.removeAll { $0.id == id }
    }

    /// Drops in-progress rules whose trigger is empty or whitespace-only.
    /// A rule with a non-empty trigger but empty replacement is valid
    /// (it deletes the matched word) and is kept.
    func pruneIncompleteRules() {
        guard hasIncompleteRule else { return }
        rules.removeAll { isIncomplete($0) }
    }

    private func isIncomplete(_ rule: WordReplacement) -> Bool {
        rule.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct WordReplacementsView: View {
    @ObservedObject var model: WordReplacementsEditorModel
    @FocusState private var focusedTrigger: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if model.rules.isEmpty {
                emptyState
            } else {
                ruleList
            }

            Divider()

            footer
        }
        .frame(minWidth: 380, minHeight: 260)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Word Replacements")
                .font(.system(size: 13, weight: .semibold))

            Text("Fix words the transcription gets wrong. Matching is case-insensitive and whole-word.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)

            Text("No rules yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)

            Text("Add a rule to replace a word or phrase the transcription\ngets wrong with the text you actually want.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var ruleList: some View {
        VStack(alignment: .leading, spacing: 0) {
            columnHeader

            Divider()

            ScrollView {
                VStack(spacing: 8) {
                    ForEach($model.rules) { $rule in
                        ruleRow($rule)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var columnHeader: some View {
        HStack(spacing: 8) {
            Text("Replace")
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "arrow.right")
                .opacity(0)
                .frame(width: 12)

            Text("With")
                .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear
                .frame(width: 22, height: 1)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func ruleRow(_ rule: Binding<WordReplacement>) -> some View {
        HStack(spacing: 8) {
            TextField("misheard word or phrase", text: rule.trigger)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)
                .focused($focusedTrigger, equals: rule.wrappedValue.id)

            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 12)

            TextField("replacement", text: rule.replacement)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Button {
                model.deleteRule(id: rule.wrappedValue.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Delete rule")
        }
    }

    private var footer: some View {
        HStack {
            Button {
                focusedTrigger = model.addRule()
            } label: {
                Label("Add Rule", systemImage: "plus")
                    .font(.system(size: 12))
            }
            .disabled(model.hasIncompleteRule)
            .help(
                model.hasIncompleteRule
                    ? "Fill in the empty rule before adding another"
                    : "Add a new replacement rule"
            )

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
