import SwiftUI

struct ContentsNav: View {
    var current: Destination
    @Bindable var model: SettingsModel
    var onSelect: (Destination) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Destination.journey) { dest in
                row(dest)
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(Color.kHair)
                .frame(height: 1)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            row(.updates, maintenance: true)
        }
        .padding(CompassLayout.contentsPad)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.kPaper)
    }

    private func row(_ dest: Destination, maintenance: Bool = false) -> some View {
        let on = current == dest
        return Button {
            onSelect(dest)
        } label: {
            HStack(alignment: .top, spacing: 0) {
                Text(dest.contentsIndex)
                    .font(CompassFont.mono(10))
                    .foregroundStyle(on ? Color.kGreen : Color.kInk3)
                    .frame(width: 18, alignment: .leading)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 1) {
                    Text(dest.title)
                        .font(CompassFont.body(13).weight(on ? .semibold : (maintenance ? .medium : .semibold)))
                        .foregroundStyle(on ? Color.kInk : Color.kInk2)
                    Text(dest.subtitle)
                        .font(CompassFont.body(10.5))
                        .foregroundStyle(Color.kInk3)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(on ? Color.kGreen : Color.kInk3)
                            .frame(width: 6, height: 6)
                        Text(model.contentsState(for: dest))
                            .font(CompassFont.mono(10))
                            .tracking(0.4)
                            // mixed case for ⌘ and short states
                            .foregroundStyle(on ? Color.kGreen : Color.kInk3)
                    }
                    .padding(.top, 6)
                }
                .padding(.leading, 8)
                Spacer(minLength: 0)
            }
            .padding(CompassLayout.contentsRowPad)
            .padding(.leading, 8)
            .background(on ? Color.kGreenT : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: CompassLayout.contentsRowRadius)
                    .stroke(on ? Color.kGreen.opacity(0.22) : Color.clear)
            )
            .cornerRadius(CompassLayout.contentsRowRadius)
            .opacity(maintenance && !on ? 0.8 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityLabel("\(dest.title), \(model.contentsState(for: dest))")
    }
}
