import SwiftUI

struct DictionaryPane: View {
    @Bindable var model: SettingsModel
    @State private var phase: DictionaryEditorPhase = .browsing
    @State private var query: String = ""
    @State private var draftSpoken: String = ""
    @State private var draftTyped: String = ""
    @State private var draftMode: MatchMode = .smart

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("The dictionary")
                .font(CompassFont.mono(9.5))
                .tracking(2.4)
                .textCase(.uppercase)
                .foregroundStyle(Color.kGreen)

            (
                Text("Teach Kalam the words ").font(CompassFont.display(CompassType.diveDisplay)).foregroundStyle(Color.kInk)
                    + Text("it keeps getting wrong.").font(CompassFont.display(CompassType.diveDisplay).italic()).foregroundStyle(Color.kInk2)
            )
            .padding(.top, 9)

            Text("When you say a rule’s phrase, Kalam types the replacement instead.")
                .font(CompassFont.body(CompassType.diveLede))
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
                .font(CompassFont.body(15).weight(.semibold))
            Text("Kalam types exactly what it heard.")
                .font(CompassFont.body(13))
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
                        .foregroundStyle(Color.kInk3)
                    TextField("Search rules…", text: $query)
                        .textFieldStyle(.plain)
                        .font(CompassFont.body(13))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Color.kWell)
                .overlay(RoundedRectangle(cornerRadius: CompassLayout.searchRadius).stroke(Color.kHair))
                .cornerRadius(CompassLayout.searchRadius)

                Text(countLabel)
                    .font(CompassFont.mono(10))
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
                .font(CompassFont.mono(13))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("→")
                .foregroundStyle(Color.kGreen)
                .frame(width: 18)
            Text(rule.typed)
                .font(CompassFont.body(13.5))
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
                        // PORT live smartCovers() — placeholder only for stub compile:
                        return LiveSmartCovers.port(spoken: spoken, typed: typed)
                    }()
                    FlexibleChipRow(pairs: pairs)
                }
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(CompassFont.mono(9))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(CompassFont.mono(13))
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

/// Stub: replace body with a call to the live app's smartCovers().
enum LiveSmartCovers {
    static func port(spoken: String, typed: String) -> [(String, String)] {
        // TODO: call existing app function verbatim — do not keep this simplified copy in production.
        var out: [(String, String)] = []
        let pairs = [
            (spoken, typed),
            (spoken.lowercased(), typed.lowercased()),
            (
                spoken.prefix(1).uppercased() + spoken.dropFirst().lowercased(),
                typed.prefix(1).uppercased() + typed.dropFirst().lowercased()
            ),
            (spoken.uppercased(), typed.uppercased()),
        ]
        out.append(contentsOf: pairs)
        return out
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
                (Text(pair.0).fontWeight(.medium).foregroundStyle(Color.kInk)
                    + Text(" → \(pair.1)").foregroundStyle(Color.kInk2))
                    .font(CompassFont.mono(11))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.kPanel)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kHair))
                    .cornerRadius(6)
            }
        }
    }
}
