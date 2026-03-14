import SwiftUI

// MARK: - Premium Toggle Style
struct KalamToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            RoundedRectangle(cornerRadius: 12)
                .fill(configuration.isOn ? KalamTheme.accent : Color(nsColor: .controlBackgroundColor))
                .frame(width: 36, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(configuration.isOn ? .clear : KalamTheme.strokeSubtle, lineWidth: 1)
                )
                .overlay(
                    Circle()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.15), radius: 2, x: 0, y: 1)
                        .padding(2)
                        .offset(x: configuration.isOn ? 8 : -8)
                )
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isOn)
                .onTapGesture {
                    configuration.isOn.toggle()
                }
        }
    }
}

// MARK: - Premium Checkbox Style
struct KalamCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(configuration.isOn ? KalamTheme.accent : Color(nsColor: .controlBackgroundColor))
                    .frame(width: 15, height: 15)
                    .padding(.top, 2)

                RoundedRectangle(cornerRadius: 4)
                    .stroke(configuration.isOn ? .clear : KalamTheme.strokeSubtle, lineWidth: 1)
                    .frame(width: 15, height: 15)
                    .padding(.top, 2)

                if configuration.isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                configuration.isOn.toggle()
            }

            configuration.label
        }
    }
}

// MARK: - Premium Segmented Control
// NOTE: SelectionValue only requires Hashable — title is provided via the label closure.
struct KalamSegmentedControl<SelectionValue: Hashable, Label: View>: View {
    @Binding var selection: SelectionValue
    let options: [SelectionValue]
    @ViewBuilder let content: (SelectionValue) -> Label

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let isSelected = selection == option
                Button(action: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
                        selection = option
                    }
                }) {
                    content(option)
                        .font(KalamTheme.captionStrongFont)
                        .foregroundColor(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color(nsColor: .controlBackgroundColor))
                                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                                        .matchedGeometryEffect(id: "segment", in: namespace)
                                } else {
                                    Color.clear
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(KalamTheme.strokeSubtle.opacity(0.5), lineWidth: 1)
        )
    }
}

// MARK: - Premium Menu Picker
struct KalamMenuPicker<SelectionValue: Hashable>: View {
    @Binding var selection: SelectionValue
    let options: [SelectionValue]
    let titleProvider: (SelectionValue) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        Text(titleProvider(option))
                        if selection == option {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(titleProvider(selection))
                    .font(KalamTheme.bodyStrongFont)
                Image(systemName: "chevron.up.chevron.down")
                    .font(KalamTheme.captionFont)
            }
            .foregroundColor(KalamTheme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(KalamTheme.strokeSubtle, lineWidth: 1)
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}
