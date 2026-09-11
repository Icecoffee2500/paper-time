import SwiftUI

/// What this app is, shown rather than described.
///
/// The log gives each feature a sentence and a demonstration the size of a
/// paragraph, because a log is read by somebody checking whether a particular
/// thing moved. This page is read by somebody deciding whether any of it is
/// for them, and for that a sentence is nearly useless: "a passage keeps its
/// address" means nothing until you have sent one and clicked it back. So the
/// demonstrations here are full size and come first, with the prose above them
/// as a caption rather than the other way round.
struct AboutView: View {
    @Environment(AppModel.self) private var app
    @State private var showsReleaseNotes = false
    @State private var showsFeatureLog = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header

                ForEach(ReleaseNotes.highlights) { highlight in
                    section(highlight)
                }

                footer
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .padding(.bottom, 34)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .sheet(isPresented: $showsReleaseNotes) {
            WhatsNewView(marksAsSeen: false)
        }
        .sheet(isPresented: $showsFeatureLog) {
            VStack(spacing: 0) {
                FeatureLogView()
                Button(ReleaseNotes.string("완료", "Done")) { showsFeatureLog = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.bottom, 16)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 12) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paper Time")
                        .font(.system(size: 24, weight: .bold))
                    Text(ReleaseNotes.string(
                        "버전 \(ReleaseNotes.version) · 알파",
                        "Version \(ReleaseNotes.version) · Alpha"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }

            Text(ReleaseNotes.string(
                "논문을 읽고, 표시하고, 그 표시를 생각으로 바꾸기 위한 앱. 아래의 것들은 설명이 아니라 실제로 눌러볼 수 있는 것들이다 — 논문만 없을 뿐, 동작은 앱의 것 그대로다.",
                "An app for reading papers, marking them, and turning those marks into thinking. What follows is not a description: each one works. Only the paper is missing."
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)
        }
    }

    private func section(_ highlight: ReleaseNotes.Highlight) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: highlight.symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                Text(highlight.title.value)
                    .font(.title3.weight(.semibold))
                if let action = highlight.action {
                    KeyCap(action: action)
                }
            }

            Text(highlight.detail.value)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 29)

            if let demo = highlight.demo {
                FeatureDemoView(demo: demo, scale: .full)
                    .padding(.leading, 29)
                    .padding(.top, 3)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider().opacity(0.5)

            HStack(spacing: 10) {
                Button(ReleaseNotes.string("환영 화면 다시 보기…", "What's New…")) {
                    showsReleaseNotes = true
                }
                Button(ReleaseNotes.string("모든 기능과 단축키…", "All Features and Keys…")) {
                    showsFeatureLog = true
                }
            }

            Text(ReleaseNotes.string(
                "논문은 이 앱 안이 아니라 내가 고른 폴더에 평범한 파일로 있다. 노트도 Markdown 파일이다. 앱을 지워도 읽던 것은 남는다.",
                "Papers are ordinary files in the folder you chose, not inside this app; notes are Markdown. Delete the app and what you were reading is still there."
            ))
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
