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

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(ReleaseNotes.highlights) { highlight in
                        row(highlight)
                    }
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 26)
            }
            // Takes the room left over, explicitly. Without this the stack
            // sized itself to the content, overran the sheet, and the footer
            // ended up printed over the last thing in the list.
            .frame(maxHeight: .infinity)
            .scrollIndicators(.never)
            footer
        }
        .frame(width: 540, height: 680)
        .onAppear { if marksAsSeen { app.markReleaseNotesSeen() } }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 40))
                .foregroundStyle(.tint)
                .padding(.bottom, 2)
            Text(ReleaseNotes.string("Paper Time에 오신 것을 환영합니다", "Welcome to Paper Time"))
                .font(.system(size: 26, weight: .bold))
            Text(ReleaseNotes.string("버전 \(ReleaseNotes.version) · 알파", "Version \(ReleaseNotes.version) · Alpha"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 34)
        .padding(.horizontal, 34)
    }

    private func row(_ highlight: ReleaseNotes.Highlight) -> some View {
        HStack(alignment: .top, spacing: 15) {
            Image(systemName: highlight.symbol)
                .font(.system(size: 21))
                .foregroundStyle(.tint)
                .frame(width: 30, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(highlight.title.value)
                        .font(.headline)
                    if let action = highlight.action {
                        KeyCap(action: action)
                    }
                }
                Text(highlight.detail.value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Text(ReleaseNotes.string("알파 버전이다 — 매일 쓰면서 자주 바꾸고 있다. 논문과 노트는 내가 고른 폴더 안의 평범한 파일로 남는다.", "An alpha — used daily, changed often. Your papers and notes stay ordinary files in the folder you chose."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(ReleaseNotes.string("읽기 시작", "Start Reading")) { dismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 26)
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
        .frame(width: 620, height: 640)
    }
}
