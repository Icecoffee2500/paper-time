import SwiftUI

/// A row of choices drawn as capsules.
///
/// The same shape as the filter chips in the marks list, because they are the
/// same kind of thing: a small set of options, one of them on. The system's
/// segmented control has a corner of its own that matches nothing else in the
/// app, and one corner language is worth more than one stock control.
struct CapsulePicker<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    @Binding var selection: Value
    /// Fills the width, dividing it evenly — for a set of tabs.
    var fills = true

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                let isOn = option.value == selection
                Button {
                    withAnimation(Motion.tap) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.subheadline)
                        .foregroundStyle(isOn ? Color.white : .primary)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .frame(maxWidth: fills ? .infinity : nil)
                        .background {
                            Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor)
                                                : AnyShapeStyle(.quaternary))
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
