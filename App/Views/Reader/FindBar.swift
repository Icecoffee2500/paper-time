import PDFKit
import PDFReader
import SwiftUI

/// A Preview-style find bar: floats over the reader, searches `document`
/// through `finder`, and reports the selection to scroll to via `onNavigate`.
///
/// `DocumentFinder.search(_:in:)` takes the document as a parameter rather
/// than storing it, so this bar needs its own reference to hand over on every
/// keystroke — the spec for this file didn't list one, but there is no other
/// way to satisfy that signature, so `document` is added here.
struct FindBar: View {
    let finder: DocumentFinder
    let document: PDFDocument
    @Binding var isPresented: Bool
    var onNavigate: (PDFSelection?) -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            // A small spinner stands in for the magnifying glass while a
            // longer document is being scanned; the summary text below it
            // stays put either way so the bar doesn't jump around as it types.
            if finder.isSearching {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
            }

            TextField(L("이 논문에서 찾기", "Find in Document"), text: queryBinding)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .frame(minWidth: 140)
                .onSubmit { navigate(to: finder.next) }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    navigate(to: finder.previous)
                    return .handled
                }

            Text(finder.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()

            Divider().frame(height: 16)

            Button {
                navigate(to: finder.previous)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(finder.matchCount == 0)
            .accessibilityLabel(L("이전 결과", "Previous Match"))

            Button {
                navigate(to: finder.next)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(finder.matchCount == 0)
            .accessibilityLabel(L("다음 결과", "Next Match"))

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(L("찾기 막대 닫기", "Close Find Bar"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .liquidGlass(.floating)
        .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
        .fixedSize()
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onAppear { isFocused = true }
    }

    /// Hand-rolled rather than `@Bindable`, so `finder` can stay the plain
    /// `let` this view was specified with — the object is a class, so its
    /// `query` is still mutable through it. The setter updates `finder.query`
    /// synchronously so the field never lags behind a keystroke while the
    /// debounced search Task is still spinning up.
    private var queryBinding: Binding<String> {
        Binding(
            get: { finder.query },
            set: { newValue in
                // A text field re-commits its value on submit, so Return would
                // otherwise start a fresh search for text that has not changed.
                guard newValue != finder.query else { return }
                finder.query = newValue
                Task { await finder.search(newValue, in: document) }
            }
        )
    }

    private func navigate(to step: () -> Void) {
        step()
        onNavigate(finder.currentSelection)
    }

    private func dismiss() {
        finder.clear()
        isPresented = false
    }
}
