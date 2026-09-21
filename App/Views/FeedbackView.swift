import InkEngine
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The one place somebody tells us something, and the reason it is one
/// keystroke away.
///
/// Three decisions make this different from a form:
///
/// 1. The screenshot is already taken when the sheet opens. The hard part of
///    a bug report is not writing it, it is explaining where you were.
/// 2. You draw on it with the app's own pen. The tools are the ones from the
///    reader — the same arrow, the same box — because an app about marking up
///    a page should let you mark up the bug.
/// 3. The row this becomes on the public list is shown *before* the send.
///    People do not write into a void. Showing them the void has an exit is
///    most of the work.
struct FeedbackView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var tool: MarkTool = .arrow

    private var draft: FeedbackDraft { app.feedbackDraft }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if draft.crash != nil { crashNote }
                    shotSection
                    messageSection
                    whoSection
                    detailsSection
                    previewSection
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 724)
        .background(.background)
        .task {
            // Only once: reopening the sheet keeps the picture and the words
            // that were already there.
            guard draft.shot == nil else { return }
            draft.shot = FeedbackImage.captureWindow()
            draft.diagnostics = FeedbackDiagnostics.collect(app: app)
            if app.cameBackFromCrash {
                draft.kind = .bug
                draft.crash = Feedback.Crash.latestReport()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("어떤 일이 있었나요?", "What happened?"))
                .font(.title2.weight(.semibold))
            Picker("", selection: Bindable(draft).kind) {
                ForEach(Feedback.Kind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(20)
    }

    private var crashNote: some View {
        Label {
            Text(L(
                "지난번에 앱이 갑자기 닫혔어요. 그때 뭘 하고 있었는지 한 줄만 알려주시면 고칠 수 있어요.",
                "Paper Time quit unexpectedly last time. One line about what you were doing is enough to fix it."
            ))
            .font(.callout)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: Corner.popover - 4))
    }

    // MARK: - The picture, already taken

    private var shotSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("화면은 이미 찍어뒀어요", "The screenshot is already here"))
                    .font(.subheadline.weight(.medium))
                Spacer()
                if draft.includesShot, draft.shot != nil {
                    markTools
                }
                Button {
                    draft.includesShot.toggle()
                } label: {
                    Image(systemName: draft.includesShot ? "xmark.circle.fill" : "arrow.uturn.backward.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(draft.includesShot
                      ? L("화면 빼고 보내기", "Send without the screenshot")
                      : L("다시 넣기", "Put it back"))
            }

            if let shot = draft.shot, draft.includesShot {
                ShotCanvas(image: shot, marks: Bindable(draft).marks, tool: tool)
                    .frame(height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: Corner.popover - 4))
                    .overlay(RoundedRectangle(cornerRadius: Corner.popover - 4).strokeBorder(.separator))
                Text(L(
                    "위에 바로 그려도 돼요. 남에게 보이면 안 되는 곳은 가려주세요.",
                    "Draw on it. Use Hide to cover anything that shouldn't leave your machine."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if draft.includesShot {
                Text(L("화면을 찍지 못했어요.", "Couldn't take a screenshot."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(L("화면 없이 보내요.", "Sending without a screenshot."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var markTools: some View {
        HStack(spacing: 2) {
            ForEach(MarkTool.allCases) { option in
                Button {
                    tool = option
                } label: {
                    Image(systemName: option.symbol)
                        .frame(width: 24, height: 20)
                        .background(
                            tool == option ? Color.accentColor.opacity(0.16) : .clear,
                            in: RoundedRectangle(cornerRadius: Corner.control - 3)
                        )
                }
                .buttonStyle(.plain)
                .help(option.title)
            }
            Button {
                if !draft.marks.isEmpty { draft.marks.removeLast() }
            } label: {
                Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(draft.marks.isEmpty)
            .help(L("되돌리기", "Undo"))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - The message

    private var messageSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: Bindable(draft).message)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 82)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Corner.row))
                .overlay(alignment: .topLeading) {
                    if draft.message.isEmpty {
                        Text(draft.kind == .bug
                             ? L("한 줄이면 충분해요.", "One line is enough.")
                             : L("어떤 게 있으면 좋을까요?", "What would you like it to do?"))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: - Who

    private var whoSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Text(L("이름", "Name")).font(.subheadline)
                TextField(L("익명", "anonymous"), text: Bindable(draft).name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 150)
                Text(L("답장", "Reply")).font(.subheadline)
                TextField(L("메일 (안 적어도 돼요)", "Email, optional"), text: Bindable(draft).reply)
                    .textFieldStyle(.roundedBorder)
            }
            Text(L(
                "적은 이름으로 기록에 올라가요. 메일은 답장할 때만 쓰고, 공개 목록에는 올라가지 않아요.",
                "The name goes on the list. The address is used only to write back, and never appears there."
            ))
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Exactly what goes

    private var detailsSection: some View {
        DisclosureGroup(isExpanded: Bindable(draft).showsDetails) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(draft.diagnostics.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                            .frame(width: 150, alignment: .leading)
                        Text(row.1).textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                    .font(.caption)
                }
                if draft.crash != nil {
                    Text(L("· 지난번 크래시 기록", "· last crash report"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(L(
                    "논문 제목도, 파일 경로도, 쓰신 글도 보내지 않아요.",
                    "No paper titles, no file paths, nothing you wrote."
                ))
                .font(.caption.weight(.medium))
                .padding(.top, 6)
            }
            .padding(.top, 8)
        } label: {
            Text(L("함께 보내는 것 \(draft.diagnostics.rows.count)가지",
                   "What gets sent with this — \(draft.diagnostics.rows.count) things"))
                .font(.subheadline)
        }
    }

    // MARK: - The row it becomes

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L("보내면 이렇게 올라가요", "This is the row it becomes"))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text("○").foregroundStyle(.tertiary)
                Text(draft.previewTitle)
                    .lineLimit(1)
                    .foregroundStyle(draft.message.isEmpty ? .tertiary : .primary)
                Spacer(minLength: 8)
                Text(L("기다리는 중", "open")).font(.caption).foregroundStyle(.secondary)
                Text("— \(draft.creditName)").font(.caption).foregroundStyle(.tertiary)
            }
            .font(.callout)
            .padding(11)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Corner.row))
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            switch draft.state {
            case let .sent(url):
                Label(L("고마워요. 목록에 올렸어요.", "Thanks. It's on the list."), systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
                if !url.isEmpty, let link = URL(string: url) {
                    Link(L("보기", "See it"), destination: link).font(.callout)
                }
            case let .kept(folder):
                Label(
                    L("지금은 못 보냈어요. 바탕화면에 저장해뒀어요.",
                      "Couldn't send just now. Saved it to the desktop instead."),
                    systemImage: "folder.fill"
                )
                .foregroundStyle(.secondary).font(.callout)
                .help(folder.path(percentEncoded: false))
            case let .failed(message):
                Text(message).font(.callout).foregroundStyle(.secondary)
            case .sending:
                ProgressView().controlSize(.small)
                Text(L("보내는 중…", "Sending…")).font(.callout).foregroundStyle(.secondary)
            case .writing:
                EmptyView()
            }

            Spacer()

            if case .sent = draft.state {
                Button(L("닫기", "Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            } else if case .kept = draft.state {
                Button(L("닫기", "Close")) { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button(L("취소", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("보내기", "Send")) {
                    Task { await FeedbackSender.send(draft) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSend)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
    }
}

// MARK: - The three tools

enum MarkTool: String, CaseIterable, Identifiable {
    case arrow, box, hide

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .arrow: "arrow.up.left"
        case .box: "rectangle"
        case .hide: "rectangle.fill"
        }
    }

    var title: String {
        switch self {
        case .arrow: L("화살표", "Arrow")
        case .box: L("네모", "Box")
        case .hide: L("가리기", "Hide")
        }
    }

    /// The app's own pen, with the one colour a report wants.
    func element(from start: CGPoint, to end: CGPoint, width: CGFloat) -> SketchElement {
        var style = SketchStyle()
        style.width = width
        switch self {
        case .arrow:
            style.stroke = .red
            style.endHead = .triangle
            return SketchElement(kind: .arrow, points: [start, end], style: style)
        case .box:
            style.stroke = .red
            style.fill = nil
            return SketchElement(kind: .rectangle, points: [start, end], style: style)
        case .hide:
            // Opaque, not a blur: a blur can sometimes be undone, and anybody
            // covering something here means it.
            style.stroke = SketchColor(0.10, 0.10, 0.12)
            style.fill = SketchColor(0.10, 0.10, 0.12)
            return SketchElement(kind: .rectangle, points: [start, end], style: style)
        }
    }
}

// MARK: - Drawing on the shot

/// The screenshot with the marks over it, drawn by `SketchRenderer` — the same
/// renderer that draws on the pages. Marks are kept in the image's own pixel
/// coordinates so the flattened copy needs no conversion.
private struct ShotCanvas: View {
    let image: CGImage
    @Binding var marks: [SketchElement]
    let tool: MarkTool

    @State private var drawing: SketchElement?

    var body: some View {
        GeometryReader { geometry in
            let scale = min(
                geometry.size.width / CGFloat(image.width),
                geometry.size.height / CGFloat(image.height)
            )
            let drawn = CGSize(
                width: CGFloat(image.width) * scale,
                height: CGFloat(image.height) * scale
            )
            let origin = CGPoint(
                x: (geometry.size.width - drawn.width) / 2,
                y: (geometry.size.height - drawn.height) / 2
            )

            Canvas { context, _ in
                context.withCGContext { cg in
                    cg.translateBy(x: origin.x, y: origin.y)
                    cg.scaleBy(x: scale, y: scale)
                    // A Canvas hands over a context whose origin is already at
                    // the top left, and `CGContext.draw` wants the bottom. Flip
                    // for the picture and put it back for the marks, which are
                    // kept in the same top-left space the drags arrive in.
                    cg.saveGState()
                    cg.translateBy(x: 0, y: CGFloat(image.height))
                    cg.scaleBy(x: 1, y: -1)
                    cg.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                    cg.restoreGState()
                    var all = marks
                    if let drawing { all.append(drawing) }
                    SketchRenderer.draw(all, in: cg, options: .init(flipsText: true))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        let from = toImage(value.startLocation, origin: origin, scale: scale)
                        let to = toImage(value.location, origin: origin, scale: scale)
                        drawing = tool.element(
                            from: from, to: to,
                            width: FeedbackImage.strokeWidth(for: image)
                        )
                    }
                    .onEnded { _ in
                        if let drawing { marks.append(drawing) }
                        drawing = nil
                    }
            )
        }
        .background(.quaternary.opacity(0.3))
    }

    /// A point in the view, in the image's pixels. Clamped: a drag that leaves
    /// the picture should stop at its edge, not paint outside it.
    private func toImage(_ point: CGPoint, origin: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(
            x: min(max((point.x - origin.x) / scale, 0), CGFloat(image.width)),
            y: min(max((point.y - origin.y) / scale, 0), CGFloat(image.height))
        )
    }
}
