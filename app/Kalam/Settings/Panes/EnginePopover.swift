import SwiftUI

// MARK: - EnginePopover — F popover, card-stable
//
// Production popover for EnginePane GetTheModel card (Promoted F).
// Renders as an absolutely-positioned overlay anchored to the Hide button:
//   VStack { title (mono 10 tracking 0.9 uppercase kInk3)
//            monowell well (kWell + kHair border radius 8 padding 10 11 mono 11/1.55)
//            dismiss hint }
// Container: background kPanel, stroke kHair radius 12,
//            shadow 0 10 16 @0.14 + 0 1 2 @0.08, padding 14.
// Notch: 12x12 square rotated 45°, background kPanel, border-left/top kHair,
//        positioned top:-6 right:135 (centered on Hide).
// Reusable for both Install (brew install huggingface-cli) and Download
// (hf download …) via the generic Content or the String convenience.
// Card-stable: parent uses .overlay(alignment: .bottomTrailing) + offset, so the
// card never grows — popover floats above the card chrome.

struct EnginePopover<Content: View>: View {
    let title: String
    let content: Content
    @Binding var isPresented: Bool

    // MARK: Generic content
    init(title: String, isPresented: Binding<Bool>, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isPresented = isPresented
        self.content = content()
    }

    // MARK: String convenience — monowell well
    init(title: String, command: String, isPresented: Binding<Bool>) where Content == EnginePopoverWell {
        self.title = title
        self._isPresented = isPresented
        self.content = EnginePopoverWell(command: command)
    }

    // Non-binding convenience for overlay `if show { EnginePopover(...) }` usage.
    // GetTheModelCard uses `if showPopover { EnginePopover(title:..., command: ...) }`
    // without passing a binding — parent controls presentation.
    init(title: String, command: String) where Content == EnginePopoverWell {
        self.title = title
        self._isPresented = .constant(true)
        self.content = EnginePopoverWell(command: command)
    }

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self._isPresented = .constant(true)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(SettingsFont.mono(10))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Color.kInk3)
                .padding(.bottom, 8)

            content

            Text("Click outside or press Esc to dismiss.")
                .font(SettingsFont.body(11))
                .foregroundStyle(Color.kInk3)
                .padding(.top, 10)
        }
        .padding(14)
        .background(Color.kPanel)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.kHair, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 16, x: 0, y: 10)
        .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
        .background(EnginePopoverNotch(), alignment: .topTrailing)
    }
}

// MARK: - Monowell well (kWell + kHair, radius 8, padding 10 11, mono 11/1.55)

struct EnginePopoverWell: View {
    let command: String

    var body: some View {
        Text(command)
            .font(SettingsFont.mono(11))
            .foregroundStyle(Color.kInk)
            .lineSpacing(11 * 0.55) // 11pt *1.55 line height → ~6pt extra leading
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 10)
            .padding(.horizontal, 11)
            .background(Color.kWell)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.kHair, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .textSelection(.enabled)
            .accessibilityLabel(command)
    }
}

// MARK: - Notch — 12×12 rotated 45° (right:135 top:-6, centered on Hide)

struct EnginePopoverNotch: View {
    var body: some View {
        Rectangle()
            .fill(Color.kPanel)
            .frame(width: 12, height: 12)
            // left + top hairline — after 45° rotation these become the
            // diamond's top edges, matching CSS `border-left`/`border-top: 1px solid kHair`.
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.kHair)
                            .frame(height: 1)
                        Spacer()
                    }
                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(Color.kHair)
                            .frame(width: 1)
                        Spacer()
                    }
                }
            }
            .rotationEffect(.degrees(45))
            .offset(x: -135, y: -6)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

#Preview {
    ZStack(alignment: .topTrailing) {
        Color.kPaper.ignoresSafeArea()
        VStack(alignment: .trailing, spacing: 12) {
            // Install variant — brew
            EnginePopover(title: "Install command — Hugging Face CLI", command: "brew install huggingface-cli", isPresented: .constant(true))
                .frame(width: 560)
            // Download variant — v2
            EnginePopover(title: "Download command — Parakeet TDT v2", command: "hf download nvidia/parakeet-tdt-0.6b-v2 --local-dir ~/Kalam/models/parakeet-tdt-0.6b-v2", isPresented: .constant(true))
                .frame(width: 560)
            // Generic content variant — v3
            EnginePopover(title: "Download command — Parakeet TDT v3", isPresented: .constant(true)) {
                EnginePopoverWell(command: "hf download nvidia/parakeet-tdt-0.6b-v3 --local-dir ~/Kalam/models/parakeet-tdt-0.6b-v3")
            }
            .frame(width: 560)
        }
        .padding(28)
    }
    .frame(width: 720, height: 640)
}
