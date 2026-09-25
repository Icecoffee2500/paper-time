import SwiftUI

/// The two alerts a restore of a paper's original text puts up: first what
/// it would change, waiting for a yes; afterwards what it did, or why not.
/// A modifier of its own so the root view's body stays one the compiler can
/// type-check.
struct RestoreAlerts: ViewModifier {
    @Bindable var model: LibraryModel

    private var asks: Binding<Bool> {
        Binding(get: { model.restore != nil }, set: { if !$0 { model.cancelRestore() } })
    }

    private var tells: Binding<Bool> {
        Binding(get: { model.restoreNotice != nil }, set: { if !$0 { model.restoreNotice = nil } })
    }

    func body(content: Content) -> some View {
        content
            .alert(L("원본 글자를 되살릴까요?", "Restore the Original Text?"), isPresented: asks, presenting: model.restore) { _ in
                Button(L("되살리기", "Restore")) { Task { await model.confirmRestore() } }
                Button(L("취소", "Cancel"), role: .cancel) { model.cancelRestore() }
            } message: { flow in
                Text(LibraryModel.restoreSummary(flow.plan.preview))
            }
            .alert(L("원본 글자 되살리기", "Restore Original Text"), isPresented: tells) {
                Button(L("확인", "OK"), role: .cancel) { model.restoreNotice = nil }
            } message: {
                Text(model.restoreNotice ?? "")
            }
    }
}
