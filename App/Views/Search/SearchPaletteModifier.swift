import SwiftUI

/// Presents the search palette over the window.
///
/// An overlay rather than a sheet: Spotlight appears above what you were
/// looking at without displacing it, and dismissing it should leave you exactly
/// where you were.
private struct SearchPaletteModifier: ViewModifier {
    let model: LibraryModel
    let link: ReaderLink
    @Binding var isPresented: Bool
    let perform: (SearchResult.Action) -> Void

    func body(content: Content) -> some View {
        content
            .overlay {
                if isPresented {
                    SearchPalette(model: model, link: link, isPresented: $isPresented,
                                  perform: perform)
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                        .zIndex(1)
                }
            }
            .animation(Motion.tap, value: isPresented)
    }
}

extension View {
    func searchPalette(
        model: LibraryModel,
        link: ReaderLink,
        isPresented: Binding<Bool>,
        perform: @escaping (SearchResult.Action) -> Void
    ) -> some View {
        modifier(
            SearchPaletteModifier(model: model, link: link,
                                  isPresented: isPresented, perform: perform)
        )
    }
}
