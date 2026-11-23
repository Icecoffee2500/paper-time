#if os(macOS)
import AppKit
import InkEngine
import SwiftUI

/// Which note the format panel is formatting, and what it should show.
///
/// The panel is not the note's child: it stands beside the note, or in a
/// popover over it, and the note with the keyboard may be any of several in
/// the window. So the note's text view says when it has the keyboard and
/// when its selection moves, and the panel reads what it said.
@MainActor
@Observable
final class NoteFormatCenter {
    static let shared = NoteFormatCenter()

    @ObservationIgnored weak var textView: NoteTextView?
    /// How many panels are showing. Reading the format means reading the
    /// note back as Markdown, which nobody should pay for on every move of
    /// the caret with no panel to show it in.
    @ObservationIgnored var watchers = 0
    private(set) var state = NoteFormat.State()
    /// Whether a note is what is being worked on: it took the keyboard, and
    /// neither the page nor the drawing on it has taken it since. The
    /// inspector's Tools show this panel while it is, and the drawing's
    /// otherwise.
    private(set) var isFront = false
    /// Bumped to ask the window for the inspector, on its Tools.
    private(set) var panelRequests = 0

    func took(_ textView: NoteTextView) {
        if !isFront { isFront = true }
        read(textView)
    }

    func yielded(_ textView: NoteTextView? = nil) {
        if textView == nil || textView === self.textView, isFront { isFront = false }
    }

    func left(_ textView: NoteTextView) {
        guard textView === self.textView else { return }
        self.textView = nil
        if isFront { isFront = false }
        if state.isEditing { state = NoteFormat.State() }
    }

    func askForPanel() {
        if !isFront, textView != nil { isFront = true }
        panelRequests += 1
    }

    func read(_ textView: NoteTextView) {
        self.textView = textView
        guard watchers > 0 else { return }
        let read = textView.formatState()
        if read != state { state = read }
    }

    /// A state to draw the panel in, for a picture of it with no note.
    func preview(_ state: NoteFormat.State) { self.state = state }

    func refresh() {
        if let textView { read(textView) } else if state.isEditing { state = NoteFormat.State() }
    }

    func apply(_ name: String, _ make: @escaping (String, NSRange) -> NoteFormat.Edit?) {
        textView?.format(named: name, make)
    }

    func set(_ change: NoteFormat.Change, named name: String) {
        apply(name) { NoteFormat.set(change, in: $0, selection: $1) }
    }
}

/// The note's format, the way Pages has it: what kind of paragraph, the
/// face and its size, bold and the rest, a colour, how the line is set
/// across, and its list.
///
/// Everything here is said in the note's Markdown (`NoteFormat`): Markdown's
/// own marks where it has them, a span where it has not.
struct NoteFormatPanel: View {
    private var center: NoteFormatCenter { .shared }

    var body: some View {
        ScrollView { controls }
        .scrollIndicators(.never)
        .onAppear {
            center.watchers += 1
            if !Boot.isSet("PAPERTIME_FORMAT_SHOT") { center.refresh() }
        }
        .onDisappear { center.watchers = max(0, center.watchers - 1) }
    }

    /// The controls themselves, without the scroll view they stand in — a
    /// picture of the panel is drawn from these (a renderer draws nothing
    /// inside a scroll view).
    var controls: some View {
        let state = center.state
        return VStack(alignment: .leading, spacing: 14) {
                Text(L("글", "Text"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)

                paragraphMenu(state)
                rule

                Text(L("글꼴", "Font"))
                    .font(.system(size: 12.5, weight: .semibold))
                familyMenu(state)
                HStack(spacing: 8) {
                    styleButtons(state)
                    sizeControl(state)
                }

                // The five colours, as the highlighter's are offered — a
                // letter in the ink for the words, a dot for the band. The
                // system's colour panel stood here, and beside the row of
                // dots under it it was another app's control.
                HStack(spacing: 7) {
                    Text(L("글자 색", "Text Color")).font(.system(size: 12.5))
                    Spacer()
                    ForEach(NoteSpanStyle.inks, id: \.name) { ink in
                        let on = state.style.color == ink.hex
                        Button {
                            center.set(.color(on ? nil : ink.hex), named: L("글자 색", "Text Color"))
                        } label: {
                            Text("A")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color(nsColor: NoteHighlight.ink(ink.name)))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.75 : 0), lineWidth: 1.5).padding(-3))
                                .contentShape(Circle().inset(by: -4))
                        }
                        .buttonStyle(.plain)
                        .help(on ? L("글자 색 지우기", "Remove Text Color") : L("글자 색", "Text Color"))
                    }
                }
                HStack(spacing: 7) {
                    Text(L("형광펜", "Highlight")).font(.system(size: 12.5))
                    Spacer()
                    ForEach(["yellow", "green", "blue", "pink", "purple"], id: \.self) { name in
                        let on = state.style.highlight == name
                        Button {
                            center.set(.highlight(on ? nil : name), named: L("하이라이트", "Highlight"))
                        } label: {
                            Circle()
                                .fill(Self.swatch(name))
                                .frame(width: 16, height: 16)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(on ? 0.75 : 0), lineWidth: 1.5).padding(-3))
                                .contentShape(Circle().inset(by: -4))
                        }
                        .buttonStyle(.plain)
                        .help(on ? L("하이라이트 지우기", "Remove Highlight") : L("하이라이트", "Highlight"))
                    }
                }
                rule

                alignmentButtons(state)
                HStack(spacing: 1) {
                    segment("decrease.indent", on: false, help: L("내어쓰기", "Outdent")) {
                        center.textView?.shiftForPanel(by: -1)
                    }
                    segment("increase.indent", on: false, help: L("들여쓰기", "Indent")) {
                        center.textView?.shiftForPanel(by: 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
                .disabled(state.list == .none)
                rule

                HStack {
                    Text(L("목록", "Bullets & Lists")).font(.system(size: 12.5, weight: .semibold))
                    Spacer()
                    Menu {
                        ForEach(NoteFormat.List.allCases) { kind in
                            Button {
                                center.apply(L("목록", "List")) { NoteFormat.set(kind, in: $0, selection: $1) }
                            } label: {
                                if kind == state.list { Label(kind.name, systemImage: "checkmark") } else { Text(kind.name) }
                            }
                        }
                    } label: {
                        field(state.list.name)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .frame(width: 124)
                }
            }
        .padding(14)
        .disabled(!state.isEditing || state.isCode)
        .opacity(state.isEditing ? 1 : 0.5)
    }

    /// The dot a highlight is chosen by: the colour the bar over a selection
    /// shows for it.
    private static func swatch(_ name: String) -> Color {
        let tone = HighlightTone.swatch(NoteHighlight.color(name))
        return Color(red: tone.red, green: tone.green, blue: tone.blue)
    }

    private var rule: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1)
    }

    /// A control's ground: the soft grey Pages sets its fields on.
    private func field(_ text: String, weight: Font.Weight = .regular, size: CGFloat = 12.5) -> some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: size, weight: weight)).lineLimit(1)
            Spacer(minLength: 2)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: Corner.control, style: .continuous).fill(Color.primary.opacity(0.07)))
        .contentShape(Rectangle())
    }

    /// The paragraph's kind, named in its own weight — the first thing in
    /// the panel, as it is in Pages.
    private func paragraphMenu(_ state: NoteFormat.State) -> some View {
        Menu {
            ForEach(NoteFormat.Paragraph.allCases) { kind in
                Button {
                    center.apply(L("문단 스타일", "Paragraph Style")) { NoteFormat.set(kind, in: $0, selection: $1) }
                } label: {
                    if kind == state.paragraph { Label(kind.name, systemImage: "checkmark") } else { Text(kind.name) }
                }
            }
        } label: {
            HStack {
                Text(state.paragraph.name)
                    .font(.system(size: 15, weight: state.paragraph.headingLevel == nil ? .regular : .bold))
                Spacer()
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private static let families: [String] = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") }

    private func familyMenu(_ state: NoteFormat.State) -> some View {
        Menu {
            Button {
                center.set(.family(nil), named: L("글꼴", "Font"))
            } label: {
                if state.style.family == nil { Label(L("노트 기본", "Note Default"), systemImage: "checkmark") }
                else { Text(L("노트 기본", "Note Default")) }
            }
            Divider()
            ForEach(Self.families, id: \.self) { family in
                Button {
                    center.set(.family(family), named: L("글꼴", "Font"))
                } label: {
                    if family == state.style.family { Label(family, systemImage: "checkmark") } else { Text(family) }
                }
            }
        } label: {
            field(state.style.family ?? L("노트 기본", "Note Default"))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private func styleButtons(_ state: NoteFormat.State) -> some View {
        HStack(spacing: 1) {
            segment("bold", on: state.style.bold, help: L("굵게", "Bold")) {
                center.set(.bold(!state.style.bold), named: L("굵게", "Bold"))
            }
            segment("italic", on: state.style.italic, help: L("기울임", "Italic")) {
                center.set(.italic(!state.style.italic), named: L("기울임", "Italic"))
            }
            segment("underline", on: state.style.underline, help: L("밑줄", "Underline")) {
                center.set(.underline(!state.style.underline), named: L("밑줄", "Underline"))
            }
            segment("strikethrough", on: state.style.strike, help: L("취소선", "Strikethrough")) {
                center.set(.strike(!state.style.strike), named: L("취소선", "Strikethrough"))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
    }

    /// The size, with a step either way and the usual sizes under a press.
    private func sizeControl(_ state: NoteFormat.State) -> some View {
        func set(_ size: Double) {
            let bounded = min(max(size, 6), 200)
            center.set(.size(bounded == state.ownSize ? nil : bounded), named: L("글자 크기", "Size"))
        }
        let shown = state.size == state.size.rounded() ? String(Int(state.size)) : String(format: "%.1f", state.size)
        return HStack(spacing: 2) {
            Menu {
                ForEach([10, 12, 14, 16, 18, 20, 24, 28, 32, 40, 48, 64], id: \.self) { size in
                    Button("\(size) pt") { set(Double(size)) }
                }
            } label: {
                Text("\(shown) pt")
                    .font(.system(size: 12.5)).monospacedDigit()
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: Corner.control, style: .continuous).fill(Color.primary.opacity(0.07)))
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            VStack(spacing: 0) {
                Button { set((state.size + 1).rounded(.down)) } label: {
                    Image(systemName: "chevron.up").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 13)
                        .contentShape(Rectangle())
                }
                Button { set((state.size - 1).rounded(.up)) } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 13)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .frame(width: 84)
    }

    private func alignmentButtons(_ state: NoteFormat.State) -> some View {
        HStack(spacing: 1) {
            ForEach(NoteAlignment.allCases, id: \.self) { alignment in
                let symbol = switch alignment {
                case .left: "text.alignleft"
                case .center: "text.aligncenter"
                case .right: "text.alignright"
                case .justify: "text.justify"
                }
                let name = switch alignment {
                case .left: L("왼쪽 맞춤", "Align Left")
                case .center: L("가운데 맞춤", "Center")
                case .right: L("오른쪽 맞춤", "Align Right")
                case .justify: L("양쪽 맞춤", "Justify")
                }
                segment(symbol, on: state.alignment == alignment, help: name) {
                    center.apply(L("정렬", "Alignment")) { NoteFormat.set(alignment, in: $0, selection: $1) }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Corner.control, style: .continuous))
        .disabled(state.list != .none || state.paragraph == .quote)
    }

    /// One cell of a row of buttons: lit in the accent while it is on.
    private func segment(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
                .background(on ? Color.accentColor : Color.primary.opacity(0.07))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
#endif
