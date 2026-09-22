import SwiftUI

/// The sheet shown the first time a version is run.
///
/// Built the way the system's own are: the name and the version at the top,
/// then a short column of things each with a symbol, a line of title and a
/// sentence — and one button. No tabs, no scrolling if it can be helped, and
/// nothing to decide. Somebody who wants to start reading should be able to
/// dismiss it without feeling they have skipped something, which is why the
/// whole list is also in Settings afterwards.
struct WhatsNewView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// Shown at launch, or asked for from Settings. Only the first kind marks
    /// the version as seen.
    var marksAsSeen = true
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        VStack(spacing: 0) {
            // No scroller. One thing is shown at a time now, so there is
            // nothing below the fold to go and look for — which is the whole
            // reason the system's own version of this sheet turns pages.
            VStack(spacing: 0) {
                FeatureShowcase { header }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, horizontalSizeClass == .compact ? 18 : 30)
            .padding(.top, 26)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        // A window's worth on the Mac; on iOS the sheet is the screen, and
        // the showcase takes the width it is given.
        #if os(macOS)
        .frame(width: 680, height: 700)
        #endif
        .onAppear { if marksAsSeen { app.markReleaseNotesSeen() } }
    }

    /// The name of the thing, and nothing else.
    ///
    /// A page that shows one feature at a time does not need a paragraph
    /// introducing the set: each page introduces itself, and the words that
    /// used to be here were read once and then scrolled past for ever.
    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 24))
                .foregroundStyle(.tint)
            Text("Paper Time \(ReleaseNotes.version)")
                .font(.system(size: 26, weight: .bold))
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider().opacity(0.5)
            HStack(spacing: 14) {
                Text(ReleaseNotes.string(
                    "알파 버전이에요 — 매일 쓰면서 자주 바꾸고 있어요. 논문과 노트는 직접 고른 폴더 안에 평범한 파일로 남아요.",
                    "An alpha — used daily, changed often. Your papers and notes stay ordinary files in the folder you chose."
                ))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button(ReleaseNotes.string("읽기 시작", "Start Reading")) { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 20)
            .padding(.top, 4)
        }
    }
}

/// A shortcut drawn as a key, reading whatever the reader has it set to.
struct KeyCap: View {
    @Environment(AppModel.self) private var app
    let action: ShortcutAction

    var body: some View {
        if app.hasShortcut(action) {
            Text(app.shortcut(for: action).display)
                .font(.caption.weight(.medium))
                .monospaced()
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: Corner.row - 2, style: .continuous)
                        .fill(.quaternary.opacity(0.6))
                )
        }
    }
}

/// The whole catalogue, for when someone is looking for something rather than
/// being introduced to it.
struct FeatureLogView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ForEach(ReleaseNotes.groups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        Label(group.name.value, systemImage: group.symbol)
                            .font(.title3.weight(.semibold))
                            .labelStyle(.titleAndIcon)

                        ForEach(group.features) { feature in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(feature.title.value)
                                        .font(.callout.weight(.medium))
                                    Text(feature.detail.value)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 10)
                                if let action = feature.action {
                                    KeyCap(action: action)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
        #if os(macOS)
        .frame(width: 620, height: 640)
        #endif
    }
}
