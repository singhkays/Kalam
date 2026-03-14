import SwiftUI

struct CommandCopyRow: View {
    enum CopyButtonPlacement {
        case prominent
        case insideDisclosure
    }

    let buttonTitle: String
    let copiedTitle: String
    let commandText: String
    let disclosureTitle: String
    let helpText: String?
    let isCopied: Bool
    let buttonPlacement: CopyButtonPlacement
    let copyAction: () -> Void

    @State private var isExpanded = false

    private var currentButtonTitle: String {
        isCopied ? copiedTitle : buttonTitle
    }

    private var currentButtonIcon: String {
        isCopied ? "checkmark" : "doc.on.doc"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if buttonPlacement == .prominent {
                copyButton(prominent: true)
            }

            if let helpText {
                Text(helpText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                        .frame(width: 16)

                    Text(disclosureTitle)
                        .font(.subheadline.bold())
                        .foregroundStyle(.primary)

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: OnboardingStyleMetrics.minimumDisclosureTapTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if buttonPlacement == .insideDisclosure {
                        copyButton(prominent: false)
                    }

                    Text(commandText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                        )
                        .textSelection(.enabled)
                }
                .padding(.top, 2)
            }
        }
    }

    private func copyButton(prominent: Bool) -> some View {
        Button(action: copyAction) {
            Label(currentButtonTitle, systemImage: currentButtonIcon)
        }
        .buttonStyle(OnboardingGlassButtonStyle())
        .accessibilityLabel(currentButtonTitle)
        .accessibilityInputLabels([
            Text(buttonTitle),
            Text(copiedTitle)
        ])
    }
}
