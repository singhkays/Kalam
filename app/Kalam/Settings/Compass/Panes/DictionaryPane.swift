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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The dictionary")
                .font(CompassType.styleDiveKicker)
                .compassTracking(CompassType.trackDiveKicker)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            (
                Text("Teach Kalam the words ").font(CompassType.styleDiveDisplay).compassTracking(CompassType.trackDiveDisplay).foregroundStyle(Color.kInk)
                    + Text("it keeps getting wrong.").font(CompassType.styleDiveDisplayItalic).compassTracking(CompassType.trackDiveDisplay).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text("When you say a rule’s phrase, Kalam types the replacement instead.")
                .font(CompassType.styleLede)
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
                .font(CompassType.styleEmptyTitle)
            Text("Kalam types exactly what it heard.")
                .font(CompassType.styleEmptyBody)
                .foregroundStyle(Color.kInk2)
            Button {
                beginAdd()
            } label: {
                Label("Add a replacement", systemImage: "plus")
            }
            .buttonStyle(CompassPrimaryButtonStyle())
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
                        .font(CompassFont.body(13))
                        .focused($searchFocused)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.kWell)
                .overlay(
                    // Recessed well per mockup `.dict-head .search` (well bg + inset top shade).
                    RoundedRectangle(cornerRadius: CompassLayout.searchRadius)
                        .fill(
                            LinearGradient(
                                colors: [Color.black.opacity(0.07), Color.clear],
                                startPoint: .top, endPoint: .center
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: CompassLayout.searchRadius))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: CompassLayout.searchRadius)
                        .stroke(searchFocused ? Color.kGreen.opacity(0.4) : Color.kHair)
                )
                .cornerRadius(CompassLayout.searchRadius)
                .overlay(
                    // Focus ring: 3 pt halo @ 8% green (mockup `.search:focus-within`).
                    RoundedRectangle(cornerRadius: CompassLayout.searchRadius + 3)
                        .stroke(Color.kGreen.opacity(searchFocused ? 0.08 : 0), lineWidth: 6)
                )

                Text(countLabel)
                    .font(CompassFont.mono(10))
                    .tracking(1.0)
                    .foregroundStyle(Color.kInk3)

                if showPlus {
                    Button(action: beginAdd) {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.white)
                            .frame(width: 32, height: 32)
                            .background(Color.kGreen)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kGreenD))
                            .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a replacement")
                }
            }
            .padding(13)
            .overlay(alignment: .bottom) { Divider().background(Color.kHair) }

            if let notice = model.dictionaryLoadFailureNotice {
                // K-20: corrupt-store recovery notice — quiet ink-3 line (no error chrome).
                Text(notice)
                    .font(CompassFont.mono(10))
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
                    .font(CompassFont.body(13))
                    .foregroundStyle(Color.kInk2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            } else {
                ForEach(filtered) { rule in
                    switch phase {
                    case .editing(let id) where id == rule.id:
                        form(isNew: false)
                    case .confirmingDelete(let id) where id == rule.id:
                        confirmDelete(rule)
                    default:
                        ruleRow(rule)
                    }
                }
            }
        }
        .background(Color.kPanel)
        .overlay(RoundedRectangle(cornerRadius: CompassLayout.cardRadius).stroke(Color.kHair))
        .cornerRadius(CompassLayout.cardRadius)
        .padding(.top, 18)
    }

    private var countLabel: String {
        if query.isEmpty {
            let n = model.rules.count
            return n == 1 ? "1 rule" : "\(n) rules"
        }
        return "\(filtered.count) of \(model.rules.count)"
    }

    private func ruleRow(_ rule: ReplacementRule) -> some View {
        HStack(spacing: 10) {
            Text("“\(rule.spoken)”")
                .font(CompassType.styleDictSpoken)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("→")
                .foregroundStyle(Color.kGreen)
                .frame(width: 18)
            Text(rule.typed)
                .font(CompassType.styleDictTyped)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(rule.mode == .smart ? "Smart" : "Literal")
                .font(CompassFont.mono(9))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            HStack(spacing: 2) {
                Button {
                    beginEdit(rule)
                } label: {
                    Image(systemName: "pencil").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit rule \(rule.spoken)")

                Button {
                    phase = .confirmingDelete(rule.id)
                } label: {
                    Image(systemName: "trash").frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove rule \(rule.spoken)")
            }
            .foregroundStyle(Color.kInk3.opacity(0.7))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .top) { Divider().background(Color.kHair) }
    }

    private func form(isNew: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                field("When you say", text: $draftSpoken, placeholder: "siobhan")
                field("Kalam types", text: $draftTyped, placeholder: "Siobhan")
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Matching")
                        .font(CompassFont.body(13).weight(.semibold))
                    Text("Smart also matches case, plurals, and possessives.")
                        .font(CompassFont.body(11.5))
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
                    .buttonStyle(CompassSecondaryButtonStyle())
                Button(isNew ? "Save replacement" : "Save") { save(isNew: isNew) }
                    .buttonStyle(CompassPrimaryButtonStyle(disabled: !canSave))
                    .disabled(!canSave)
            }
            .padding(.top, 14)
        }
        .padding(18)
        .background(Color.kWell)
        .overlay(alignment: .top) { Divider().background(Color.kHair) }
    }

    private func confirmDelete(_ rule: ReplacementRule) -> some View {
        HStack(spacing: 12) {
            Text("Remove “\(rule.spoken)”? Kalam will type that word as heard again.")
                .font(CompassFont.body(13))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Keep") { phase = .browsing }
                .buttonStyle(CompassPrimaryButtonStyle())
            Button("Remove") {
                model.rules.removeAll { $0.id == rule.id }
                phase = .browsing
            }
            .buttonStyle(CompassSecondaryButtonStyle())
        }
        .padding(18)
        .background(Color.kWell)
        .overlay(alignment: .top) { Divider().background(Color.kHair) }
    }

    @ViewBuilder
    private var coversBlock: some View {
        let spoken = draftSpoken.trimmingCharacters(in: .whitespacesAndNewlines)
        let typed = draftTyped.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            Text("Covers")
                .font(CompassFont.body(12.5).weight(.semibold))
            if spoken.isEmpty || typed.isEmpty {
                Text("Type both sides to see the forms Smart will match.")
                    .font(CompassFont.mono(11))
                    .foregroundStyle(Color.kInk3)
} else {
    let pairs: [(String, String)] = {
        if draftMode == .literal { return [(spoken, typed)] }
        // K-30: port the live smart-cover logic verbatim (DictionaryEntry.exampleMatches)
        // — do NOT keep the stub's simplified pluralizer.
        let entry = DictionaryEntry(trigger: spoken, replacement: typed)
        return entry.exampleMatches.compactMap { line -> (String, String)? in
            guard let arrow = line.range(of: " → ") else { return (line, "") }
            return (String(line[..<arrow.lowerBound]), String(line[arrow.upperBound...]))
        }
    }()
    FlexibleChipRow(pairs: pairs)
}
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(CompassType.styleDictLabel)
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                // D.4: real words type in SF Pro, not mono (only spoken tokens read as code).
                .font(CompassType.styleDictField)
                .padding(8)
                .background(Color.kPanel)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kHair))
                .cornerRadius(8)
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

struct CompassSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CompassFont.body(12.5))
            .foregroundStyle(Color.kInk)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Color.kPanel)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kHair))
            .cornerRadius(8)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// Minimal wrap layout for cover chips.
struct FlexibleChipRow: View {
    var pairs: [(String, String)]

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 120), spacing: 6)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                (Text(pair.0).font(CompassFont.mono(11, weight: CompassType.wMedium)).foregroundStyle(Color.kInk)
                    + Text(" → \(pair.1)").font(CompassFont.mono(11)).foregroundStyle(Color.kInk2))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.kPanel)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kHair))
                    .cornerRadius(6)
            }
        }
    }
}
