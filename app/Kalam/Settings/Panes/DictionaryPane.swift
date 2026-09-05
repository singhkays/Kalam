import KalamTextEngine
import SwiftUI

struct DictionaryPane: View {
    @Bindable var model: SettingsModel
    @State private var phase: DictionaryEditorPhase = .browsing
    @State private var query: String = ""
    @State private var draftSpoken: String = ""
    @State private var draftTyped: String = ""
    @State private var draftMode: MatchMode = .smart
    @FocusState private var searchFocused: Bool

    private enum FieldFocus: Hashable {
        case spoken, typed
    }

    @FocusState private var focusedField: FieldFocus?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The dictionary")
                .font(SettingsType.styleDiveKicker)
                .compassTracking(SettingsType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            (
                Text("Teach Kalam the words ").font(SettingsType.styleDiveDisplay).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("it keeps getting wrong.").font(SettingsType.styleDiveDisplayItalic).compassTracking(SettingsType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text("When you say a rule’s phrase, Kalam types the replacement instead.")
                .font(SettingsType.styleLede)
                .foregroundStyle(Color.kInk2)
                .padding(.top, 10)

            if model.rules.isEmpty && phase == .browsing && query.isEmpty {
                emptyState
            } else {
                editorCard
            }
        }
        .onChange(of: phase) { _, new in
            if case .browsing = new {
                draftSpoken = ""
                draftTyped = ""
                draftMode = .smart
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No rules yet")
                .font(SettingsType.styleEmptyTitle)
            Text("Kalam types exactly what it heard.")
                .font(SettingsType.styleEmptyBody)
                .foregroundStyle(Color.kInk2)
            Button {
                beginAdd()
            } label: {
                Label("Add a replacement", systemImage: "plus")
            }
            .buttonStyle(SettingsPrimaryButtonStyle())
            .padding(.top, 16)
        }
        .padding(.top, 28)
    }

    private var filtered: [ReplacementRule] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return model.rules }
        return model.rules.filter {
            $0.spoken.lowercased().contains(q) || $0.typed.lowercased().contains(q)
        }
    }

    private var canSave: Bool {
        !draftSpoken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftTyped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showPlus: Bool {
        query.isEmpty && phase == .browsing
    }

    private var editorCard: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.kInk3)
                    TextField("Search rules…", text: $query)
                        .textFieldStyle(.plain)
                        .font(SettingsFont.body(13))
                        .focused($searchFocused)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.kPaper)
                // Single focus mark (the halo below): the edge stays hair in
                // both states — edge-plus-halo read as a doubled outline.
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsLayout.searchRadius)
                        .stroke(Color.kHair2)
                )
                .cornerRadius(SettingsLayout.searchRadius)
                .overlay(
                    // Focus ring: 3 pt halo @ 8% green (mockup `.search:focus-within`).
                    RoundedRectangle(cornerRadius: SettingsLayout.searchRadius + 3)
                        .stroke(Color.kGreen.opacity(searchFocused ? 0.08 : 0), lineWidth: 6)
                )

                Text(countLabel)
                    .font(SettingsFont.mono(10))
                    .foregroundStyle(Color.kInk3)

                if showPlus {
                    Button(action: beginAdd) {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Color.kGreen)
                            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.radiusButton).stroke(Color.kGreenD))
                            .cornerRadius(SettingsLayout.radiusButton)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a replacement")
                }
            }
            .padding(13)
            // House grammar: headers cast shadow, never borders — the wash
            // lives in the header's own padding so it shows regardless of
            // what follows (rules, notice, form).
            .overlay(alignment: .bottom) { HeaderWash() }

            if let notice = model.dictionaryLoadFailureNotice {
                // dictionary data-loss edge cases: corrupt-store recovery notice — quiet ink-3 line (no error chrome).
                Text(notice)
                    .font(SettingsFont.mono(10))
                    .foregroundStyle(Color.kInk3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) { Divider().background(Color.kHair) }
            }

            if case .adding = phase {
                form(isNew: true)
            }

            if filtered.isEmpty && !query.isEmpty {
                Text("No rules match “\(query)”.")
                    .font(SettingsFont.body(13))
                    .foregroundStyle(Color.kInk2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            } else {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { index, rule in
                    switch phase {
                    case .editing(let id) where id == rule.id:
                        form(isNew: false)
                    case .confirmingDelete(let id) where id == rule.id:
                        confirmDelete(rule)
                    default:
                        // First row carries no divider when it directly follows
                        // the search header (pure browsing) — the header wash
                        // owns that boundary. Paint-only: no layout shift.
                        // Every other state keeps dividers (form/notice need
                        // separation from the rules below them).
                        ruleRow(
                            rule,
                            hideTopDivider: phase == .browsing
                                && model.dictionaryLoadFailureNotice == nil && index == 0
                        )
                    }
                }
            }
        }
        .background(Color.kPanel)
        .clipShape(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: SettingsLayout.cardRadius, style: .continuous).stroke(Color.kHair))
        .padding(.top, 18)
    }

    private var countLabel: String {
        if query.isEmpty {
            let n = model.rules.count
            return n == 1 ? "1 rule" : "\(n) rules"
        }
        return "\(filtered.count) of \(model.rules.count)"
    }

    private func ruleRow(_ rule: ReplacementRule, hideTopDivider: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text("“\(rule.spoken)”")
                .font(SettingsType.styleDictSpoken)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("→")
                .foregroundStyle(Color.kInk3)
                .frame(width: 18)
            Text(rule.typed)
                .font(SettingsType.styleDictTyped)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(rule.mode == .smart ? "Smart" : "Literal")
                .font(SettingsFont.mono(9))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            HStack(spacing: 2) {
                Button {
                    beginEdit(rule)
                } label: {
                    Image(systemName: "pencil").frame(width: 24, height: 24)
                }
                .buttonStyle(DictionaryRowActionStyle())
                .accessibilityLabel("Edit rule \(rule.spoken)")

                Button {
                    phase = .confirmingDelete(rule.id)
                } label: {
                    Image(systemName: "trash").frame(width: 24, height: 24)
                }
                .buttonStyle(DictionaryRowActionStyle())
                .accessibilityLabel("Remove rule \(rule.spoken)")
            }
            .foregroundStyle(Color.kDact)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .top) {
            if !hideTopDivider {
                Divider().background(Color.kHair)
            }
        }
    }

    private func form(isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                field("When you say", text: $draftSpoken, placeholder: "siobhan", id: .spoken)
                field("Kalam types", text: $draftTyped, placeholder: "Siobhan", id: .typed)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matching")
                        .font(SettingsFont.body(13).weight(.semibold))
                    Text("Smart also matches case, plurals, and possessives.")
                        .font(SettingsFont.body(11.5))
                        .foregroundStyle(Color.kInk2)
                }
                Spacer()
                PaperSegment(
                    selection: $draftMode,
                    options: [(.smart, "Smart"), (.literal, "Literal")]
                )
            }
            .padding(.top, 14)

            coversBlock
                .padding(.top, 14)

            HStack {
                Spacer()
                Button("Cancel") { phase = .browsing }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                Button(isNew ? "Save replacement" : "Save") { save(isNew: isNew) }
                    .buttonStyle(SettingsPrimaryButtonStyle(disabled: !canSave))
                    .disabled(!canSave)
            }
            .padding(.top, 14)
        }
        .padding(18)
        .background(Color.kPaper)
        .overlay(alignment: .top) { Divider().background(Color.kHair2) }
    }

    private func confirmDelete(_ rule: ReplacementRule) -> some View {
        HStack(spacing: 12) {
            Text("Remove “\(rule.spoken)”? Kalam will type that word as heard again.")
                .font(SettingsFont.body(13))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Keep") { phase = .browsing }
                .buttonStyle(SettingsPrimaryButtonStyle())
            Button("Remove") {
                model.rules.removeAll { $0.id == rule.id }
                phase = .browsing
            }
            .buttonStyle(SettingsSecondaryButtonStyle())
        }
        .padding(18)
        .background(Color.kPaper)
        .overlay(alignment: .top) { Divider().background(Color.kHair2) }
    }

    @ViewBuilder
    private var coversBlock: some View {
        let spoken = draftSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = draftTyped.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            Text("Covers")
                .font(SettingsFont.body(13).weight(.semibold))
            if spoken.isEmpty || typed.isEmpty {
                Text("Type both sides to see the forms Smart will match.")
                    .font(SettingsFont.body(12))
                    .foregroundStyle(Color.kInk3)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let groups: [CoverGroup] = {
                    if draftMode == .literal {
                        return [CoverGroup(why: "Exact", pairs: [(spoken, typed)])]
                    }
                    return LiveSmartCovers.groups(spoken: spoken, typed: typed)
                }()
                CoverGroupsView(groups: groups)
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String, id: FieldFocus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(SettingsType.styleDictLabel)
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                // D.4: real words type in SF Pro, not mono (only spoken tokens read as code).
                .font(SettingsType.styleDictField)
                .focused($focusedField, equals: id)
                .padding(8)
                .background(Color.kPanel)
                .overlay(RoundedRectangle(cornerRadius: SettingsLayout.radiusButton).stroke(Color.kHair))
                .cornerRadius(SettingsLayout.radiusButton)
                // Same single-halo focus mark as search (edge stays hair).
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsLayout.radiusButton + 3)
                        .stroke(Color.kGreen.opacity(focusedField == id ? 0.08 : 0), lineWidth: 6)
                )
        }
        .frame(maxWidth: .infinity)
    }

    private func beginAdd() {
        draftSpoken = ""
        draftTyped = ""
        draftMode = .smart
        phase = .adding
    }

    private func beginEdit(_ rule: ReplacementRule) {
        draftSpoken = rule.spoken
        draftTyped = rule.typed
        draftMode = rule.mode
        phase = .editing(rule.id)
    }

    private func save(isNew: Bool) {
        let spoken = String(draftSpoken.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            .replacingOccurrences(of: "\n", with: " ")
        let typed = String(draftTyped.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            .replacingOccurrences(of: "\n", with: " ")
        guard !spoken.isEmpty, !typed.isEmpty else { return }

        switch phase {
        case .adding:
            model.rules.append(.init(spoken: spoken, typed: typed, mode: draftMode))
        case .editing(let id):
            if let idx = model.rules.firstIndex(where: { $0.id == id }) {
                model.rules[idx].spoken = spoken
                model.rules[idx].typed = typed
                model.rules[idx].mode = draftMode
            }
        default:
            break
        }
        phase = .browsing
    }
}

struct SettingsSecondaryButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(SettingsFont.body(12.5))
            .foregroundStyle(Color.kInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(configuration.isPressed || hovering ? Color.kWell : Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: SettingsLayout.radiusButton).stroke(Color.kHair))
            .cornerRadius(SettingsLayout.radiusButton)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }
}

struct DictionaryRowActionStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed || hovering ? Color.kWell : Color.clear, in: Circle())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .onHover { hovering = $0 }
    }
}

struct CoverGroup: Identifiable {
    let id = UUID()
    var why: String
    var pairs: [(String, String)]
}

/// Port of the live smart-cover logic (settings redesign mandate: `DictionaryEntry.exampleMatches`
/// verbatim — do NOT reimplement the pluralizer), bucketed into the v1.2
/// definition-list vocabulary (Case / Plural / Possessive).
enum LiveSmartCovers {
    static func groups(spoken: String, typed: String) -> [CoverGroup] {
        let entry = DictionaryEntry(trigger: spoken, replacement: typed)
        let base = spoken.lowercased()
        var casePairs: [(String, String)] = []
        var pluralPairs: [(String, String)] = []
        var possessivePairs: [(String, String)] = []
        for line in entry.exampleMatches {
            guard let arrow = line.range(of: " → ") else { continue }
            let heard = String(line[..<arrow.lowerBound])
            let written = String(line[arrow.upperBound...])
            let pair = (heard, written)
            if heard.hasSuffix("’s") || heard.hasSuffix("'s") {
                possessivePairs.append(pair)
            } else if heard == base + "s" {
                pluralPairs.append(pair)
            } else {
                casePairs.append(pair)
            }
        }
        var groups: [CoverGroup] = []
        if !casePairs.isEmpty { groups.append(CoverGroup(why: "Case", pairs: casePairs)) }
        if !pluralPairs.isEmpty { groups.append(CoverGroup(why: "Plural", pairs: pluralPairs)) }
        if !possessivePairs.isEmpty { groups.append(CoverGroup(why: "Possessive", pairs: possessivePairs)) }
        return groups
    }
}

/// Definition list: Pro label + token mappings. No third (mono-caps) voice.
struct CoverGroupsView: View {
    var groups: [CoverGroup]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups) { group in
                HStack(alignment: .firstTextBaseline, spacing: 14) {
                    Text(group.why)
                        .font(SettingsFont.body(12.5))
                        .foregroundStyle(Color.kInk3)
                        .frame(width: 88, alignment: .leading)
                    FlowPairs(pairs: group.pairs)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

struct FlowPairs: View {
    var pairs: [(String, String)]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
                if i > 0 {
                    Text("  ·  ")
                        .font(SettingsFont.body(12))
                        .foregroundStyle(Color.kHair)
                }
                (Text(pair.0).font(SettingsFont.mono(12)).foregroundStyle(Color.kInk)
                    + Text(" → ").foregroundStyle(Color.kInk3)
                    + Text(pair.1).foregroundStyle(Color.kInk2))
                    .font(SettingsFont.body(12.5))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
