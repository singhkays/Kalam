import SwiftUI
import KalamTextEngine

struct WordReplacementView: View {
    @EnvironmentObject var manager: CustomDictionaryManager

    @State private var search: String = ""
    @State private var showingDeleteConfirmation = false
    @State private var entryToDelete: UUID?

    private var activeRuleCount: Int {
        manager.entries.filter(\.isEnabled).count
    }

    var filteredEntries: [DictionaryEntry] {
        let s = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return manager.entries }
        return manager.entries.filter {
            $0.trigger.localizedCaseInsensitiveContains(s)
                || $0.replacement.localizedCaseInsensitiveContains(s)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if manager.entries.isEmpty {
                emptyState
            } else if filteredEntries.isEmpty {
                noResultsState
            } else {
                entryList
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 14)
        .frame(maxWidth: KalamTheme.contentMaxWidth, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
        .alert("Delete Entry?", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let id = entryToDelete {
                    delete(id: id)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Word Replacement")
                    .font(KalamTheme.pageTitleFont)
                    .foregroundColor(KalamTheme.textPrimary)

                Text("\(manager.entries.count) rules • \(activeRuleCount) active")
                    .font(KalamTheme.calloutFont)
                    .foregroundColor(KalamTheme.textSecondary)
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(KalamTheme.textTertiary)

                    TextField("Search dictionary", text: $search)
                        .textFieldStyle(.plain)
                        .font(KalamTheme.bodyFont)
                        .foregroundColor(KalamTheme.textPrimary)

                    if !search.isEmpty {
                        Button(action: { search = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(KalamTheme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(height: 32)
                .padding(.horizontal, 10)
                .background(KalamTheme.controlTint)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                )

                Button(action: addNew) {
                    Image(systemName: "plus")
                        .font(KalamTheme.sectionTitleFont)
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                        .background(KalamTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help("Add rule")

                Button(action: { manager.sortEntriesByTrigger() }) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(KalamTheme.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(KalamTheme.controlTint)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .help("Sort by spoken phrase")
            }
        }
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.book.closed")
                .font(.system(size: 64))
                .foregroundColor(KalamTheme.textSecondary)
            Text("Your Dictionary is Empty")
                .font(.title2.weight(.semibold))
                .foregroundColor(KalamTheme.textPrimary)
            Text(
                "Add replacements for common ASR mistakes to make dictation faster and more accurate."
            )
            .foregroundColor(KalamTheme.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 400)
            Button("Add First Entry") {
                addNew()
            }
            .buttonStyle(.borderedProminent)
            .tint(KalamTheme.accent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsState: some View {
        ContentUnavailableView {
            Label("No Results", systemImage: "magnifyingglass")
        } description: {
            Text("Try a different search term")
        }
    }

    private var entryList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredEntries) { entry in
                    EditableRow(
                        entry: binding(for: entry),
                        onDelete: {
                            entryToDelete = entry.id
                            showingDeleteConfirmation = true
                        }
                    )
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 14)
        }
    }

    private func binding(for entry: DictionaryEntry) -> Binding<DictionaryEntry> {
        Binding(
            get: {
                manager.entries.first(where: { $0.id == entry.id }) ?? entry
            },
            set: { newValue in
                guard let index = manager.entries.firstIndex(where: { $0.id == entry.id }) else {
                    return
                }
                manager.entries[index] = newValue
            }
        )
    }

    private func addNew() {
        let new = DictionaryEntry(trigger: "", replacement: "", userAdded: true)
        manager.addEntry(new)
    }

    private func delete(id: UUID) {
        manager.removeEntries(withIds: [id])
        entryToDelete = nil
    }
}

// MARK: - Editable Row

struct EditableRow: View {
    @Binding var entry: DictionaryEntry
    let onDelete: () -> Void

    @State private var isExpanded = false
    @State private var showAdvanced = false
    @State private var isHovered = false

    // Case handling options
    enum CaseMatchingMode: String, CaseIterable {
        case smart = "Smart Match"
        case literal = "Literal"

        static func from(entry: DictionaryEntry) -> CaseMatchingMode {
            return (entry.caseInsensitive || entry.preserveCase) ? .smart : .literal
        }
        func apply(to entry: inout DictionaryEntry) {
            switch self {
            case .smart:
                entry.caseInsensitive = true
                entry.preserveCase = true
            case .literal:
                entry.caseInsensitive = false
                entry.preserveCase = false
            }
        }
    }

    @State private var matchingMode: CaseMatchingMode = .smart

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: $entry.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.86)

                HStack(spacing: 8) {
                    Text(entry.trigger.isEmpty ? "Spoken phrase" : entry.trigger)
                        .font(KalamTheme.bodyStrongFont)
                        .foregroundColor(
                            entry.isEnabled ? KalamTheme.textPrimary : KalamTheme.textSecondary
                        )
                        .lineLimit(1)

                    Image(systemName: "arrow.right")
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textTertiary)

                    Text(entry.replacement.isEmpty ? "Replacement" : entry.replacement)
                        .font(KalamTheme.bodyStrongFont)
                        .foregroundColor(KalamTheme.accent)
                        .opacity(entry.isEnabled ? 1.0 : 0.6)
                        .lineLimit(1)
                }

                Spacer()

                Text(matchingMode.rawValue)
                    .font(KalamTheme.captionStrongFont)
                    .foregroundColor(
                        matchingMode == .smart ? KalamTheme.accent : KalamTheme.textSecondary
                    )
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        KalamTheme.controlTint.opacity(matchingMode == .smart ? 0.95 : 0.72)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                Button(action: { withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() } }) {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(KalamTheme.calloutFont)
                }
                .buttonStyle(.plain)
                .foregroundColor(KalamTheme.textSecondary)
                .frame(width: 24, height: 24)

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(KalamTheme.calloutFont)
                        .foregroundColor(KalamTheme.textSecondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .help("Delete rule")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) { isExpanded.toggle() }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    Divider().overlay(KalamTheme.strokeSubtle)
                        .padding(.horizontal, -10)

                    HStack(alignment: .top, spacing: 14) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Spoken phrase", systemImage: "mouth.fill")
                                .font(KalamTheme.captionStrongFont)
                                .foregroundColor(KalamTheme.textSecondary)

                            TextField("e.g. apple", text: $entry.trigger)
                                .textFieldStyle(.plain)
                                .font(KalamTheme.bodyFont)
                                .foregroundColor(KalamTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .frame(height: 40)
                                .background(KalamTheme.controlTint)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8).stroke(
                                        KalamTheme.strokeSubtle, lineWidth: 1))
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Label("Replacement", systemImage: "pencil")
                                .font(KalamTheme.captionStrongFont)
                                .foregroundColor(KalamTheme.textSecondary)

                            TextField("e.g. orange", text: $entry.replacement)
                                .textFieldStyle(.plain)
                                .font(KalamTheme.bodyFont)
                                .foregroundColor(KalamTheme.textPrimary)
                                .padding(.horizontal, 10)
                                .frame(height: 40)
                                .background(KalamTheme.controlTint)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8).stroke(
                                        KalamTheme.strokeSubtle, lineWidth: 1))
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("Covers:")
                                .font(KalamTheme.captionStrongFont)
                                .foregroundColor(KalamTheme.textSecondary)

                            Text(
                                entry.exampleMatches.isEmpty
                                    ? "Start typing to see examples"
                                    : entry.exampleMatches.joined(separator: ", ")
                            )
                            .font(KalamTheme.captionFont)
                            .foregroundColor(KalamTheme.textSecondary)
                            .opacity(entry.exampleMatches.isEmpty ? 0.5 : 1.0)
                        }
                        .lineLimit(3)
                    }

                    HStack {
                        HStack(spacing: 8) {
                            Picker("Matching", selection: $matchingMode) {
                                ForEach(CaseMatchingMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 170)
                            .onChange(of: matchingMode) { _, newValue in
                                newValue.apply(to: &entry)
                            }

                            Button {
                                showAdvanced.toggle()
                            } label: {
                                Image(systemName: "info.circle")
                                    .font(KalamTheme.calloutFont)
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(KalamTheme.textSecondary)
                            .popover(isPresented: $showAdvanced, arrowEdge: .top) {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text("Smart Match")
                                        .font(.headline)

                                    Text(
                                        "Automatically handles capitalization, plurals, and possessives of your spoken words."
                                    )
                                    .font(KalamTheme.calloutFont)
                                    .foregroundColor(KalamTheme.textSecondary)
                                }
                                .padding()
                                .frame(width: 220)
                            }
                        }

                        Spacer()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
                .transition(.opacity)
            }
        }
        .background(backgroundFill)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .stroke(borderColor, lineWidth: isExpanded ? 1.4 : 1)
        )
        .shadow(color: isExpanded ? Color.black.opacity(0.14) : .clear, radius: 5, y: 2)
        .onHover { hover in
            isHovered = hover
        }
        .onAppear {
            matchingMode = CaseMatchingMode.from(entry: entry)
        }
        .onChange(of: entry.caseInsensitive) { _, _ in
            matchingMode = CaseMatchingMode.from(entry: entry)
        }
        .onChange(of: entry.preserveCase) { _, _ in
            matchingMode = CaseMatchingMode.from(entry: entry)
        }
    }

    private var backgroundFill: some View {
        ZStack {
            KalamTheme.controlTint.opacity(isHovered ? 0.95 : 0.72)
            if isExpanded {
                KalamTheme.accent.opacity(0.08)
            }
        }
    }

    private var borderColor: Color {
        if isExpanded {
            return KalamTheme.accent.opacity(0.50)
        }
        if isHovered {
            return KalamTheme.strokeStrong
        }
        return KalamTheme.strokeSubtle
    }
}

