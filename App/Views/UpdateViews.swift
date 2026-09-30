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
                    "Paper Time \(offer.version) · 지금 쓰는 버전은 \(center.current)",
                    "Paper Time \(offer.version) · You have \(center.current)"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpdateProgress(center: center)
            HStack(spacing: 10) {
                Button(L("이 버전 건너뛰기", "Skip This Version")) { center.skip() }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L("나중에", "Later")) { center.later() }
                    .keyboardShortcut(.cancelAction)
                Button(center.primaryTitle) { center.installNow() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(center.isInstallAsked)
            }
            .controlSize(.large)
        }
    }
}

extension UpdateCenter {
    /// What the notice's main button says.
    var primaryTitle: String {
        switch stage {
        case .manual: L("받기", "Download")
        case .blocked: L("다시 시도", "Try Again")
        default: L("지금 설치", "Install Now")
        }
    }

    /// Install Now has been pressed, and is being carried out.
    var isInstallAsked: Bool { stage == .installing || wantsInstall }
}

/// Where the update has got to: what is happening, how far, and a bar that
/// moves. It is there from the first byte, not only once Install Now is
/// pressed — the download starts by itself, and a person reading the notes
/// should be able to see it come.
private struct UpdateProgress: View {
    let center: UpdateCenter

    var body: some View {
        switch center.stage {
        case .preparing:
            meter(L("내려받는 중", "Downloading"), detail: nil, fraction: nil)
        case let .downloading(received, total):
            meter(L("내려받는 중", "Downloading"), detail: UpdateMeasure.bytes(received, of: total), fraction: center.stage.fraction)
        case .unpacking:
            // Sparkle unpacks as soon as the download is in, asked or not;
            // it is installing only once somebody has asked for it.
            meter(
                center.wantsInstall ? L("설치하는 중", "Installing") : L("설치 준비 중", "Preparing to install"),
                detail: center.stage.fraction.map(UpdateMeasure.percent),
                fraction: center.stage.fraction
            )
        case .ready:
            line(
                L("설치할 준비가 됐어요. 설치하면 Paper Time이 잠깐 닫혔다가 다시 열려요.",
                  "Ready to install. Paper Time closes for a moment and opens again."),
                symbol: "checkmark.circle.fill", tint: .green
            )
        case .installing:
            meter(L("설치하는 중", "Installing"), detail: L("곧 다시 열려요", "Opening again"), fraction: nil)
        case .blocked:
            line(
                L("Paper Time이 닫히지 않아서 설치를 마치지 못했어요. 열려 있는 창을 닫고 다시 시도해 주세요.",
                  "Paper Time didn't close, so the update isn't installed yet. Close any open dialogs and try again."),
                symbol: "exclamationmark.triangle.fill", tint: .orange
            )
        case .manual:
            line(
                L("이 업데이트는 스스로 설치하지 못해요. 받아서 직접 설치해 주세요.",
                  "This update can't install itself. Download it and install it yourself."),
                symbol: "arrow.down.circle", tint: .secondary
            )
        }
    }

    private func meter(_ title: String, detail: String?, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.callout.weight(.medium))
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Group {
                if let fraction { ProgressView(value: fraction) } else { ProgressView() }
            }
            .progressViewStyle(.linear)
            if center.wantsInstall, center.stage != .installing {
                Text(L("다 받으면 바로 설치하고 다시 열어요.", "Installs and opens again as soon as it's ready."))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func line(_ text: String, symbol: String, tint: Color) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
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

/// The line at the bottom of the window, for an update found while the app
/// was in use — and for the moment after Install Now, when the sheet has
/// gone and the app is about to close. It says the version and where the
/// update has got to; what changed is one click away.
struct UpdateBar: View {
    @Bindable var center: UpdateCenter

    var body: some View {
        if let offer = center.offer {
            HStack(spacing: 12) {
                Image(systemName: center.stage == .blocked ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(center.stage == .blocked ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                Text(title(offer.version))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                meter
                if center.stage != .installing, center.stage != .blocked {
                    Button(L("무엇이 바뀌었나요", "What's New")) { center.showChanges() }
                        .buttonStyle(.link)
                }
                if center.stage != .installing {
                    Button(center.primaryTitle) { center.installNow() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(center.isInstallAsked)
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
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
            .liquidGlass()
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func title(_ version: String) -> String {
        switch center.stage {
        case .preparing, .downloading:
            L("\(version) 버전을 내려받는 중", "Downloading Paper Time \(version)")
        case .unpacking:
            center.wantsInstall
                ? L("\(version) 버전을 설치하는 중", "Installing Paper Time \(version)")
                : L("\(version) 버전 설치 준비 중", "Preparing to install Paper Time \(version)")
        case .ready:
            L("\(version) 버전을 설치할 준비가 됐어요", "Paper Time \(version) is ready to install")
        case .installing:
            L("설치하는 중", "Installing")
        case .blocked:
            L("설치를 마치지 못했어요", "The update isn't installed yet")
        case .manual:
            L("\(version) 버전이 나왔어요", "Paper Time \(version) is available")
        }
    }

    /// The second half of the line, when the first needs one.
    private var note: String? {
        switch center.stage {
        case .installing: L("곧 다시 열려요", "Paper Time opens again in a moment")
        case .blocked: L("열려 있는 창을 닫고 다시 시도해 주세요", "Close any open dialogs and try again")
        default: nil
        }
    }

    /// A short bar and how far along it is, while something is coming.
    @ViewBuilder
    private var meter: some View {
        switch center.stage {
        case .preparing, .downloading, .unpacking:
            if let fraction = center.stage.fraction {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                Text(UpdateMeasure.percent(fraction))
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().progressViewStyle(.linear).frame(width: 90)
            }
        case .installing:
            ProgressView().controlSize(.small)
        default:
            EmptyView()
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
