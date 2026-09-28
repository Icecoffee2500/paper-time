#if os(macOS)
import SwiftUI

/// The sheet that says a new version is out, and what is in it.
///
/// Shown by itself at launch, when nobody is reading yet; asked for from the
/// line at the bottom of the window otherwise. What changed comes from the
/// page's list, so it is the new version's own notes — this copy has never
/// heard of them.
struct UpdateSheet: View {
    @Bindable var center: UpdateCenter

    var body: some View {
        if let offer = center.offer {
            VStack(spacing: 0) {
                header(offer)
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
                    .padding(.bottom, 14)
                Divider().opacity(0.5)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        ForEach(offer.steps) { step in
                            StepNotes(step: step, titled: offer.steps.count > 1)
                        }
                    }
                    .padding(.horizontal, 26)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 160, maxHeight: 380)
                Divider().opacity(0.5)
                footer
                    .padding(.horizontal, 26)
                    .padding(.vertical, 16)
            }
            .frame(width: 560)
        }
    }

    private func header(_ offer: UpdateOffer) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("새 버전이 나왔어요", "A New Version Is Available"))
                    .font(.title2.weight(.bold))
                Text(L(
                    "Paper Time \(offer.version) · 지금 쓰는 버전은 \(ReleaseNotes.version)",
                    "Paper Time \(offer.version) · You have \(ReleaseNotes.version)"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(L("이 버전 건너뛰기", "Skip This Version")) { center.skip() }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            UpdateStatus(center: center)
            Button(L("나중에", "Later")) { center.later() }
                .keyboardShortcut(.cancelAction)
            Button(center.stage == .manual ? L("받기", "Download") : L("지금 설치", "Install Now")) {
                center.installNow()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(center.stage == .installing || center.wantsInstall)
        }
        .controlSize(.large)
    }
}

/// One version's notes: the sentence, then what is new and what was fixed.
private struct StepNotes: View {
    let step: UpdateOffer.Step
    let titled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if titled {
                Text(step.version).font(.headline)
            }
            if let note = step.notes?.note {
                Text(note.value)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            list(L("새로 생긴 것", "New"), symbol: "plus.circle.fill", items: step.notes?.added ?? [])
            list(L("고친 것", "Fixed"), symbol: "wrench.adjustable.fill", items: step.notes?.fixed ?? [])
            if step.notes == nil {
                Text(L("이 버전의 설명은 배포 페이지에 있어요.", "The download page describes this version."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func list(_ title: String, symbol: String, items: [UpdateFeed.Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title.value)
                            .font(.callout.weight(.medium))
                        if let detail = item.detail {
                            Text(detail.value)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.leading, 22)
                }
            }
        }
    }
}

/// How far the download has got, once somebody is waiting for it.
private struct UpdateStatus: View {
    let center: UpdateCenter

    var body: some View {
        switch center.stage {
        case .installing:
            ProgressView().controlSize(.small)
            Text(L("설치하는 중", "Installing")).font(.callout).foregroundStyle(.secondary)
        case .downloading(let fraction) where center.wantsInstall:
            if let fraction { ProgressView(value: fraction).frame(width: 80) } else { ProgressView().controlSize(.small) }
            Text(L("받는 중", "Downloading")).font(.callout).foregroundStyle(.secondary)
        case .preparing where center.wantsInstall:
            ProgressView().controlSize(.small)
            Text(L("받는 중", "Downloading")).font(.callout).foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }
}

/// The line at the bottom of the window, for an update found while the app
/// was in use. It says the version and nothing more; what changed is one
/// click away.
struct UpdateBar: View {
    @Bindable var center: UpdateCenter

    var body: some View {
        if let offer = center.offer {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                Text(L("\(offer.version) 버전이 나왔어요", "Paper Time \(offer.version) is available"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Button(L("무엇이 바뀌었나요", "What's New")) { center.showChanges() }
                    .buttonStyle(.link)
                Button(center.stage == .manual ? L("받기", "Download") : L("지금 설치", "Install Now")) {
                    center.installNow()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(center.stage == .installing || center.wantsInstall)
                UpdateStatus(center: center)
                Button {
                    center.hideBar()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L("닫기", "Close"))
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .liquidGlass()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Checking for updates, in Settings › About.
struct UpdateSettings: View {
    @Bindable var center: UpdateCenter = .shared
    @AppStorage(UpdateCenter.enabledKey) private var enabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L("새 버전 확인", "Check for Updates"), isOn: $enabled)
            Text(L(
                "하루에 한 번 배포 페이지에 새 버전이 있는지 물어봐요. 논문이나 노트에 대한 것은 아무것도 보내지 않아요.",
                "Once a day, Paper Time asks the download page for a new version. It sends nothing about your papers or notes."
            ))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button(L("지금 확인", "Check Now")) {
                    Task { await center.check(atLaunch: false, userInitiated: true) }
                }
                .disabled(center.isChecking)
                if center.isChecking {
                    ProgressView().controlSize(.small)
                } else if center.lastCheckFailed {
                    Text(L("확인하지 못했어요. 인터넷 연결을 확인해 주세요.", "Couldn't check. Check your internet connection."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let offer = center.offer {
                    Text(L("\(offer.version) 버전이 나왔어요.", "Paper Time \(offer.version) is available."))
                        .font(.footnote).foregroundStyle(.secondary)
                } else if center.lastCheck != nil {
                    Text(L("최신 버전이에요.", "You have the latest version."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
#endif
