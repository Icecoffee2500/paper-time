import Foundation

/// What this version of the app can do, written down once.
///
/// Two audiences out of one list. `highlights` is what a reader is shown on
/// the first run of a new version — the few things worth interrupting someone
/// for. `groups` is the whole catalogue, which is what they go back to when
/// they are looking for something and cannot remember what it was called.
///
/// Keeping both here means the release notes cannot drift away from the
/// feature list, which is the usual fate of two documents describing one app.
/// Shortcuts are named rather than spelled: every key in this app can be
/// changed, so the page reads the reader's own and not the one that shipped.
enum ReleaseNotes {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    /// A string in both languages, in the order this app cares about them.
    ///
    /// Korean first because that is who is reading it. The rest of the app's
    /// interface is still English — this page is the one place a reader is
    /// being *told* something rather than shown a control, and a paragraph is
    /// where reading in a second language actually costs you something.
    ///
    /// Carried here rather than in a string catalogue on purpose: it is one
    /// file of prose, the two versions have to be edited together to stay
    /// true, and a catalogue would put them in two places. When the rest of
    /// the interface is translated this should move there with it.
    struct Text2 {
        let ko: String
        let en: String

        init(_ ko: String, _ en: String) {
            self.ko = ko
            self.en = en
        }

        var value: String { Text2.prefersKorean ? ko : en }

        static let prefersKorean: Bool = {
            Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
        }()
    }

    static func string(_ ko: String, _ en: String) -> String { Text2(ko, en).value }

    /// Shown on the first run of a version. Kept short on purpose: a list of
    /// twenty is a list nobody reads.
    static let highlights: [Highlight] = [
        Highlight(
            symbol: "function",
            title: Text2("Ultracopy — 수식은 LaTeX으로, 글은 글로", "Ultracopy — the words as words, the mathematics as LaTeX"),
            detail: Text2(
                "PDF에서 수식이 든 문단을 ⌘C로 복사하면 수식이 글자 부스러기로 깨져 나온다. Ultracopy(⇧⌘C)는 같은 선택에서 글은 그대로, 수식은 그대로 쓸 수 있는 LaTeX으로 돌려준다. 아래에서 둘을 직접 눌러 비교해 보라.",
                "⌘C on a passage with an equation in it gives you the formula as a spill of characters. Ultracopy (⇧⌘C) gives the same selection back with the words as words and the mathematics as LaTeX you can paste as it is. Press both below and compare."
            ),
            action: .ultracopy,
            demo: .ultracopy,
            featured: true
        ),
        Highlight(
            symbol: "book.pages",
            title: Text2("책에서 절 사이를 오간다", "A book you move through by section"),
            detail: Text2(
                "두 쪽이 마주 보고, ←→와 스페이스와 트랙패드로 장을 넘긴다. 다른 앱은 PDF의 쪽을 그대로 나란히 놓아서 논문마다 여백이 달라지고 펼침면이 한쪽으로 몰리지만, 여기서는 쪽을 글에 맞춰 잘라 — 스캔한 교과서까지 — 좌우 여백이 같고 두 쪽 사이는 늘 같은 폭이며, 여백에 세로로 찍힌 arXiv 도장은 지워진다. 아래에는 지금 몇 쪽인지와 얼마나 읽었는지. ⇧⌘L이면 이 논문의 목차가 두 쪽 사이 여백에 떠서 — 글자는 가리지 않고 — 절을 누르는 대로 그리로 간다. 목차는 Esc나 다른 곳을 누르기 전까지 남는다. 아래에서 '다른 PDF 앱'을 눌러 비교해 보라.",
                "Two pages face each other; ← →, the space bar and a swipe turn them. Other apps set the PDF's pages side by side as they are, so the margins change from paper to paper and the spread sits off to one side; here each page is cropped to its text — a scanned textbook included — so the margins match on both sides, the gutter is always the same width, and the arXiv stamp running up the margin is painted out. Underneath, which pages these are and how far in you are. ⇧⌘L floats this paper's table of contents into the gutter between the pages, covering no words, and each section is one click; it stays until Escape or a click elsewhere. Press \"Other PDF apps\" below and compare."
            ),
            action: .floatingList,
            demo: .bookReading,
            featured: true
        ),
        Highlight(
            symbol: "waveform",
            title: Text2("읽는 동안 슬립박스가 말을 건다", "While you read, the slip-box speaks first"),
            detail: Text2(
                "할 일은 없다. 논문을 읽으면 된다. 인스펙터의 Notes 탭을 열어 두면, 지금 보이는 쪽과 드문 낱말을 나누는 노트가 — 몇 달 전 다른 논문을 읽다 쓴 것이라도 — 맨 위에 스스로 올라온다. 노트 아래 파란 낱말이 둘이 나누는 말이다: 우연이면 지나치고, 울림이면 노트를 눌러 열어 본다. 쪽에서 문장을 선택하면 노트마다 ❝ 단추가 생기고, 누르면 그 구절이 주소를 갖고 그 노트에 들어간다 — 두 논문이 노트 하나에서 만난다. 노트를 쓰는 동안에는 편집기 아래 'Resonates with'에 아직 잇지 않은 울림이 모이고, 🔗 한 번이면 [[링크]]가 써진다. 다른 앱에서 노트는 폴더에 누워 있다가 검색해야 나온다 — 그런데 잊어버린 노트는 검색하지 않는다. 루만은 자기 상자를 대화 상대라고 불렀다; 상자가 먼저 말을 걸 때만 대화다.\n\n고르는 법은 숨기지 않는다. 네 노트를 전부 외운 읽기 친구가 새 쪽의 낱말과 노트의 낱말을 나란히 놓고 같은 것을 센다고 생각하면 된다 — 다만 기능어와 논문마다 쓰는 말(model, method, results…) 300개쯤은 세지 않고, 낱말 하나의 무게는 ln((N+1)÷(그 말이 나오는 글 수+0.5))+0.3으로 매긴다(N = 노트 수 + 이 논문에서 뽑은 40쪽; 45개 글 중 42개에 나오는 'network'는 0.38, 3개에만 나오는 'consolidation'은 2.88). 두 낱말이 붙어 겹치면 ×1.3, 긴 노트는 (1+ln 길이)로 나눈다. 겹친 말이 둘 이상이고 점수 1.0 이상, 1등의 35% 이상인 노트만 넷까지 올라온다. 아래에서 네 단계를 직접 해 보고, '어떻게 고르나?'를 눌러 보라.",
                "There is nothing to do but read. Keep the inspector's Notes tab open and the notes that share their rarer words with the pages on screen — written months ago, against another paper — come up by themselves at the top. The blue words under each are what the two share: a coincidence, and you read on; an echo, and you click the note to open it. Select a sentence on the page and every note grows a ❝ button; press it and the passage lands in that note with its address — two papers meet in one note. While you write, 'Resonates with' under the editor gathers the echoes not yet linked, and one 🔗 writes the [[link]]. In other apps a note lies in a folder until you search for it — and nobody searches for a note they have forgotten. Luhmann called his box a conversation partner; it is one only when the box speaks first.\n\nThe rule is not hidden. Think of a reading friend who knows your notes by heart, laying the page's words beside each note's and counting what they share — except that function words and the words every paper uses (model, method, results…), some 300, are not counted, and a word's weight is ln((N+1)÷(texts it appears in+0.5))+0.3, with N the notes plus 40 sampled pages of this paper ('network', in 42 of 45 texts: 0.38; 'consolidation', in 3: 2.88). Two words together count ×1.3; a long note's sum is divided by (1+ln length). Only notes sharing two words, scoring 1.0 or more and at least 35% of the strongest come up, four at most. Do the four steps below, and press 'How are they chosen?'."
            ),
            demo: .resonance,
            featured: true
        ),
        Highlight(
            symbol: "map",
            title: Text2("노트에 집이 생긴다 — 지도", "A note gets a home: the map"),
            detail: Text2(
                "노트는 폴더가 아니라 지도에 산다. 지도는 그 자체가 노트 하나인데, 본문이 다른 노트로 가는 [[링크]]와 그것들을 배열한 소제목이라 다른 앱에서도 그냥 Markdown이다. 원칙은 미리 만들지 않는다는 것 — 한 주제의 노트가 다섯 개 이상 서로 잇거나 낱말을 나누며 쌓이고 그걸 담은 지도가 없으면, 슬립박스 맨 위에 한 줄이 뜬다: \"이 노트 6개가 한 주제예요 — consolidation · forgetting.\" 누르면 초안이 써진다: 제목은 나누는 낱말에서, 노트는 논문별 소제목 아래 링크로. 지도를 열면 소제목이 열, 노트가 카드인 보드가 되고, 옆에는 지도와 울리지만 아직 안 올린 노트가 ＋ 한 번 거리에 있다. 노트를 쓰는 동안에도 편집기 아래 'Resonates with'에 지도가 뜨면 🗺 한 번으로 그 위에 올라간다. 아래에서 네 단계를 해 보라.",
                "A note lives on a map, not in a folder. The map is itself a note — its body is [[links]] to other notes under headings, so in any other app it is plain Markdown. The rule is not to make one in advance: when five or more notes on one subject have piled up, linking to each other or sharing their rarer words, and no map holds them, one line appears at the top of the slip-box: \"6 notes are one subject — consolidation · forgetting.\" Press it and a draft is written: a title from the shared words, the notes as links under a heading per paper. Open the map and it is a board — a column per heading, a card per note — with, beside it, the notes that resonate with the map and are not yet on it, one ＋ away. Writing a note, a map that echoes it appears under the editor, and one 🗺 files the note on it. Do the four steps below."
            ),
            demo: .atlas,
            featured: true
        ),
        Highlight(
            symbol: "magnifyingglass",
            title: Text2("한 칸에서 전부 찾는다", "One field finds all of it"),
            detail: Text2(
                "⌘K는 논문·노트·저자·컬렉션·태그, 그리고 앱의 명령까지 같은 칸에서 찾는다. 어디에 뒀는지 기억하지 않아도 되고, 화살표와 Return만으로 끝난다. 논문 안의 글자를 찾는 것은 ⌘F 쪽이다.",
                "⌘K searches papers, notes, authors, collections, tags and the app's own commands from the same field — arrows and Return, without remembering where you filed anything. ⌘F is the other one: the words inside the open paper."
            ),
            action: .searchEverything,
            demo: .search
        ),
        Highlight(
            symbol: "sidebar.left",
            title: Text2("창은 내가 접는 대로 있는다", "The window folds to what you are doing"),
            detail: Text2(
                "사이드바·목록·논문·인스펙터가 각자 자기 키로 숨는다. 남은 것이 빈자리를 나눠 갖는 대신, 숨은 것 뒤에 있던 것이 드러난다. 패널 사이의 틈을 끌면 크기가 바뀐다.",
                "The sidebar, the list, the paper and the inspector each hide on their own key — revealing what was behind rather than stretching to fill the gap. Drag the space between two of them to resize."
            ),
            action: .sidebar,
            demo: .panes
        ),
        Highlight(
            symbol: "book",
            title: Text2("책처럼 펼쳐서 읽는다", "Read it like a book"),
            detail: Text2(
                "⌘3이면 1·2쪽이 마주 보며 창을 가득 채운다. ←→나 스페이스로 장을 넘기고, 트랙패드로 넘겨도 된다. 아래에는 지금 몇 쪽인지와 얼마나 읽었는지가 있고, ⇧⌘L이면 두 쪽 사이 여백에 이 논문의 목차가 떠서 절로 바로 간다. ⌘1은 연속 스크롤, ⌘2는 한 장씩 — 배치를 바꿔도 보던 쪽은 그대로다.",
                "⌘3 and pages 1 and 2 face each other across the window. ← → or the space bar turn the page, and so does a swipe. Underneath, which pages these are and how far in you are; ⇧⌘L drops the paper's own table of contents into the gutter between the pages, and a section is one click away. ⌘1 scrolls, ⌘2 shows one page — and changing layout keeps the page you were on."
            ),
            action: .layoutBook,
            demo: .book
        ),
        Highlight(
            symbol: "rectangle.center.inset.filled",
            title: Text2("논문만 남긴다", "Only the paper"),
            detail: Text2(
                "⇧⌘F 한 번에 사이드바·목록·인스펙터가 비켜서고 논문만 남는다. 열려 있던 것은 기억해 두고, 나올 때 그대로 돌려준다. 그 안에서도 ⇧⌘L로 목차를 불러 절을 옮겨 다닐 수 있다.",
                "One ⇧⌘F and the sidebar, the list and the inspector step aside, leaving the paper. What was open is remembered and given back on the way out. ⇧⌘L still brings the table of contents, so you can move between sections without leaving."
            ),
            action: .focus,
            demo: .focus
        ),
        Highlight(
            symbol: "highlighter",
            title: Text2("표시는 PDF 안에 남고, 여기서는 더 예쁘다", "Your marks go into the PDF — and look better here"),
            detail: Text2(
                "형광펜과 밑줄이 옆에 붙은 데이터베이스가 아니라 파일 자체에 기록된다. 미리보기든 아이패드든 십 년 뒤든 표시는 그대로다. 그리고 이 앱 안에서는 형광펜의 끝이 둥글고 글자가 살 만큼 연하며, 밑줄은 눈에 띄게 짙고, 마우스를 올리면 밝아진다. 수식이 든 줄에서 다른 앱은 상자가 줄 높이만큼 자라지만, 여기서는 글자의 잉크를 재서 사람이 그은 것처럼 딱 맞게 덮는다 — 파일은 그대로 두고 그리는 법만 바꾼 것이라 다른 앱에서는 볼 수 없는 생김새다. 노트의 인용구도 같은 모양이다. 아래에서 둘을 나란히 보라.",
                "Highlights and underlines are written into the file itself, not into a database beside it — Preview, an iPad, ten years from now, the marks are there. And in here a highlight has rounded ends and stays pale enough to read through, an underline is dark enough to see, and either brightens under the pointer. On a line carrying a formula, other apps grow the box to the height of the line; here the ink of the letters is measured and the band fits them the way a hand-drawn stroke does. The file is untouched; only the drawing is ours, which is why no other PDF app looks like this. A quotation in a note wears the same shape. Compare the two side by side below."
            ),
            demo: .annotations
        ),
        Highlight(
            symbol: "quote.opening",
            title: Text2("인용한 구절은 주소를 갖는다", "A passage keeps its address"),
            detail: Text2(
                "선택한 글을 노트로 보내면 인용구로 앉는다. 누르면 그 글이 있던 페이지의 정확한 자리로 돌아간다.",
                "Send the selected text to a note and it arrives as a quotation you can click to go back to the exact place on the page it came from."
            ),
            action: .linkToNote,
            demo: .passageLink
        ),
        Highlight(
            symbol: "tray.full",
            title: Text2("PDF 더미가 아니라 슬립박스", "A slip-box, not a pile of PDFs"),
            detail: Text2(
                "노트는 그것을 쓰게 만든 논문 아래가 아니라 한곳에 모여 산다. [[…]]로 서로 잇고, 이 앱 없이도 읽히는 평범한 Markdown 파일이다.",
                "Notes live together rather than under the paper that caused them, link to each other with [[…]], and are plain Markdown files you can read without this app."
            ),
            action: .newNote,
            demo: .slipBox
        ),
        Highlight(
            symbol: "point.3.filled.connected.trianglepath.dotted",
            title: Text2("내 읽기가 무엇을 이었는지 본다", "See what your reading has joined"),
            detail: Text2(
                "그래프는 인용·공저자·컬렉션으로, 그리고 내 노트가 이은 것으로 라이브러리를 그린다. 나머지 선을 끄면 남는 것이 문헌의 관계가 아니라 내 읽기다.",
                "The graph draws your library by citation, shared author, collection — and by what your own notes link. Switch the other lines off and what is left is your reading rather than the literature's."
            ),
            demo: .graph
        ),
        Highlight(
            symbol: "keyboard",
            title: Text2("어떤 키가 무슨 일을 하는지 되짚을 수 있다", "Ask what a key does, not just what a key is"),
            detail: Text2(
                "설정 → Shortcuts에서 기능 이름으로도, 키로도 찾는다. 뭘 눌렀는지 모르겠으면 \"cmd\"나 ⌘F를 쳐보면 그 키를 가진 명령이 나온다. 그리고 이 앱의 모든 키는 바꿀 수 있다.",
                "Settings → Shortcuts searches by name and by key. If something happened and you do not know what you pressed, type \"cmd\" or ⌘F and the command that owns it comes back. Every key in this app can be changed."
            ),
            action: .settings
        ),
        Highlight(
            symbol: "folder",
            title: Text2("라이브러리는 내가 고른 폴더다", "The library is a folder you chose"),
            detail: Text2(
                "논문은 놓아둔 자리에 평범한 파일로 있다. iCloud Drive나 구글 드라이브 안의 폴더를 가리키면, 동기화는 이 앱이 새로 해야 할 일이 아니라 이미 갖고 있는 것이 된다.",
                "Papers stay as ordinary files where you put them. Point it at a folder in iCloud Drive or Google Drive and syncing is something you already have rather than something this app has to do."
            )
        ),
    ]

    /// What changed, version by version.
    ///
    /// The title is the keyword — what the thing is called, so the line can be
    /// scanned — and the sentence under it is what it does, kept folded away
    /// until asked for. A changelog is read by someone looking for whether the
    /// thing they care about moved; making them read a paragraph to find out
    /// is what makes changelogs go unread.
    static let releases: [Release] = [
        Release(
            version: "0.1.0",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("첫 알파.", "The first alpha."),
            added: [
                Entry(
                    Text2("Ultracopy", "Ultracopy"),
                    Text2("⌘C는 수식을 글자 부스러기로 깨뜨린다. ⇧⌘C는 같은 문단에서 글은 그대로, 수식은 바로 쓸 수 있는 LaTeX으로 돌려준다.",
                          "⌘C spills an equation into loose characters. ⇧⌘C gives the same passage back with the words as words and the mathematics as LaTeX."),
                    action: .ultracopy,
                    demo: .ultracopy,
                    featured: true
                ),
                Entry(
                    Text2("책 읽기", "Reading as a book"),
                    Text2("마주 보는 두 쪽, ←→·스페이스·트랙패드로 넘기기, 아래에 쪽 번호와 진행도, 그리고 ⇧⌘L로 두 쪽 사이 여백에 뜨는 목차 — 절을 누르면 그리로 가고 목차는 남는다.",
                          "Two facing pages, turned by ← →, space or a swipe; page numbers and progress underneath; and ⇧⌘L floating the table of contents into the gutter — a section is one click, and the list stays."),
                    action: .floatingList,
                    demo: .bookReading,
                    featured: true
                ),
                Entry(
                    Text2("공명", "Resonance"),
                    Text2("읽기만 하면 된다: 보이는 쪽과 드문 낱말을 나누는 노트가 — 다른 논문에서 쓴 것이라도 — Notes 탭 맨 위에 올라온다. 파란 낱말이 나누는 말. 문장을 선택하면 ❝로 그 노트에 떨어뜨리고, 노트 아래 'Resonates with'에서 🔗 한 번이면 링크가 써진다. 아래 네 단계를 직접 해 보라.",
                          "Just read: notes that share the page's rarer words — from other papers — come up at the top of the Notes tab, the shared words in blue. Select a sentence and ❝ drops it into a note; under a note, 'Resonates with' and one 🔗 writes the link. Do the four steps below."),
                    demo: .resonance,
                    featured: true
                ),
                Entry(
                    Text2("지도(Atlas)", "Maps (Atlas)"),
                    Text2("한 주제의 노트가 다섯 개 넘게 쌓이면 슬립박스가 지도를 제안한다. 지도는 링크가 소제목 아래 놓인 노트(kind: map)이고, 열면 카드 보드가 된다. 울리는데 안 올린 노트는 ＋ 한 번.",
                          "When more than five notes pile up on one subject, the slip-box suggests a map. A map is a note (kind: map) with links under headings; opened, it is a board of cards. Notes that resonate but are not on it are one ＋ away."),
                    demo: .atlas,
                    featured: true
                ),
                Entry(
                    Text2("검색", "Search"),
                    Text2("⌘K는 논문·노트·저자를 한 칸에서 찾고, ⌘F는 열린 논문 안을 찾는다.",
                          "⌘K finds papers, notes and authors from one field; ⌘F searches inside the open paper."),
                    action: .searchEverything,
                    demo: .search
                ),
                Entry(
                    Text2("4-패널 창", "Four-pane window"),
                    Text2("사이드바·목록·논문·인스펙터가 각자 자기 키로 숨는다. 패널 사이의 틈을 끌면 크기가 바뀐다.",
                          "Sidebar, list, paper and inspector, each hiding on its own key. The gap between two of them resizes them."),
                    action: .sidebar,
                    demo: .panes
                ),
                Entry(
                    Text2("PDF 주석", "PDF annotations"),
                    Text2("형광펜과 밑줄이 파일 자체에 기록된다. 미리보기·아이패드·다른 어떤 PDF 앱에서 열어도 그대로 보인다.",
                          "Highlights and underlines are written into the file. They show up in Preview, on an iPad, in any PDF reader."),
                    action: .highlight,
                    demo: .annotations
                ),
                Entry(
                    Text2("둥근 표시", "Rounded marks"),
                    Text2("형광펜은 끝이 둥글고 글자가 살 만큼 연하다. 수식이 든 줄에서도 상자가 줄 높이만큼 자라지 않고 글자에 딱 맞는다 — 사람이 그은 것처럼. 밑줄·취소선은 짙다. 마우스를 올리면 밝아지고 얇은 테두리가 생긴다. 노트의 인용구 칩도 같은 모양 — 파일은 그대로 두고 이 앱이 그리는 법만 바꾼 것이라 다른 PDF 앱에는 없는 생김새다.",
                          "Highlights have rounded ends and stay pale enough to read through, and on a line with a formula the band fits the letters rather than growing to the line's height — like a stroke drawn by hand. Underlines and strikes are dark. Under the pointer a mark brightens and gains a thin edge. Quotation chips in notes wear the same shape. The file is untouched — only the drawing is ours, which is why no other PDF app looks like this."),
                    demo: .annotations
                ),
                Entry(
                    Text2("책 모드", "Book mode"),
                    Text2("⌘3이면 1·2쪽이 마주 보며 창을 채우고 ←→·스페이스·트랙패드로 넘긴다. 어떤 논문이든 — 스캔한 교과서까지 — 쪽은 글에 맞춰 잘려 좌우 여백이 같고 가운데 여백은 늘 같은 폭이며, 여백에 세로로 찍힌 arXiv 도장은 지워진다. 아래에 쪽 번호와 진행도. ⌘1 연속 스크롤, ⌘2 한 장씩. 배치를 바꿔도 보던 쪽은 그대로다.",
                          "⌘3 fills the window with pages 1 and 2 facing; ← →, space and a swipe turn them. Whatever the paper — a scanned textbook included — each page is cropped to its text, so the margins match on both sides and the gutter is always the same width, and the arXiv stamp running up the margin is painted out. Page numbers and progress underneath. ⌘1 continuous, ⌘2 single page. Changing layout keeps the page you were on."),
                    action: .layoutBook,
                    demo: .book
                ),
                Entry(
                    Text2("목차 팝업", "Table of contents"),
                    Text2("⇧⌘L이면 목차가 페이지 위에 좁고 길게 뜬다 — 책 모드에서는 두 쪽 사이 여백에, 글자를 가리지 않게. PDF에 목차가 없거나 망가져 있으면 쪽에서 제목을 읽어낸다: 크기와 굵기, 번호, 문단 머리의 굵은 글까지. 제목 속 수식은 논문에 찍힌 그대로 그림으로 들어간다. 절을 누르면 그리로 가고, Esc나 다른 곳을 누르기 전까지 남는다. 단추는 없다. 키 하나다.",
                          "⇧⌘L floats the table of contents over the page, narrow and tall — in a book, in the gutter between the pages, covering no words. When the PDF has no outline, or a broken one, the headings are read off the pages: by size and weight, by number, down to the bold words a paragraph opens with. Mathematics in a heading comes in as a picture of itself, as the paper set it. Click a section to go there; it stays until Escape or a click elsewhere. No button; one key."),
                    action: .floatingList
                ),
                Entry(
                    Text2("논문에 집중", "Focus on the paper"),
                    Text2("⇧⌘F 한 번에 나머지 패널이 비켜서고 논문만 남는다. 목록은 구석의 단추로 불러내고, 나올 때 열려 있던 것을 그대로 돌려준다.",
                          "One ⇧⌘F and the other panes step aside, leaving the paper. The list waits behind a button in the corner; what was open comes back on the way out."),
                    action: .focus,
                    demo: .focus
                ),
                Entry(
                    Text2("인용구 링크", "Passage links"),
                    Text2("선택한 글을 노트로 보내면 둥근 인용구로 앉고, 누르면 그 글이 있던 페이지의 정확한 자리로 돌아간다.",
                          "Send a selection to a note and it lands as a rounded quotation. Click it to jump back to the exact spot on the page."),
                    action: .linkToNote,
                    demo: .passageLink
                ),
                Entry(
                    Text2("슬립박스", "Slip-box"),
                    Text2("노트는 한 폴더에 모여 살고 [[링크]]로 서로 잇는다. 나를 가리키는 노트는 아래에 모인다. 전부 평범한 Markdown 파일이다.",
                          "Notes live in one folder, joined by [[links]], with backlinks collected underneath. Plain Markdown files throughout."),
                    action: .newNote,
                    demo: .slipBox
                ),
                Entry(
                    Text2("인라인 LaTeX", "Inline LaTeX"),
                    Text2("노트에 $x^2$처럼 쓰면 쓰는 대로 조판된다. 저장되는 것은 여전히 원문이라 다른 편집기에서도 열린다.",
                          "Write $x^2$ in a note and it is set as you type. What is saved is still the source.")
                ),
                Entry(
                    Text2("연결 그래프", "Connection graph"),
                    Text2("인용·공저자·컬렉션, 그리고 내 노트가 이은 것으로 라이브러리를 그린다. 범례에서 선을 끄면 그게 곧 질문이 된다.",
                          "Draws the library by citation, author, collection and your own notes. Switching a line off in the legend is how you ask a question."),
                    demo: .graph
                ),
                Entry(
                    Text2("서지 자동 인식", "Metadata extraction"),
                    Text2("제목·저자·연도를 논문에서 읽어낸다. 확신이 없으면 조용히 저장하지 않고 Needs Review로 남긴다.",
                          "Title, authors and year are read from the paper. What it is unsure of is left as Needs Review rather than saved quietly."),
                    action: .resolveMetadata
                ),
                Entry(
                    Text2("BibTeX 내보내기", "BibTeX export"),
                    Text2("선택한 논문만, 또는 라이브러리 전체를 .bib로. 인용 키는 따로 복사할 수 있다.",
                          "The selection or the whole library as .bib. Citation keys can be copied on their own."),
                    action: .exportBibTeX
                ),
                Entry(
                    Text2("단축키 편집·검색", "Editable, searchable shortcuts"),
                    Text2("모든 키를 바꿀 수 있고, 기능 이름으로도 키로도 찾을 수 있다. 뭘 눌렀는지 모를 때 \"cmd\"를 쳐보면 된다.",
                          "Every key can be changed, and found by name or by key — type \"cmd\" when you do not know what you pressed.")
                ),
                Entry(
                    Text2("폴더가 곧 라이브러리", "The folder is the library"),
                    Text2("논문은 내가 고른 폴더에 평범한 파일로 있다. iCloud Drive나 구글 드라이브 안에 두면 동기화는 이미 해결돼 있다.",
                          "Papers stay as ordinary files in a folder you chose. Put it in iCloud Drive or Google Drive and syncing is already solved.")
                ),
            ],
            fixed: []
        ),
    ]

    /// Everything, by where you are when you want it.
    static let groups: [Group] = [
        Group(Text2("읽기", "Reading"), symbol: "doc.text", features: [
            Feature(Text2("논문 안에서 찾기", "Find in the paper"),
                    Text2("열려 있는 PDF를 검색하고 결과를 하나씩 넘긴다.", "Search the open PDF and step through the matches."), action: .findInDocument),
            Feature(Text2("전체 검색", "Search everything"),
                    Text2("논문·노트·저자를 한 칸에서 찾는다.", "Papers, notes and authors, from one field."), action: .searchEverything),
            Feature(Text2("페이지 배치", "Page layout"),
                    Text2("연속 스크롤, 한 장씩, 또는 두 장 펼침. AA 메뉴에 있고, ⌘1·⌘2·⌘3으로도 바꾼다. 책에서는 ←→로 장을 넘긴다.", "Continuous scrolling, single page, or a two-page spread. In the AA menu, and on ⌘1, ⌘2 and ⌘3. In a book, ← and → turn the page."), action: .layoutBook),
            Feature(Text2("페이지 색", "Page tint"),
                    Text2("흰 종이, 세피아, 어둡게 — 그리고 Glass는 종이의 흰색을 걷어내 글자가 창 위에 앉게 한다. AA 메뉴에 있다.", "Paper white, sepia, dimmed — or Glass, which drops the page's white so it sits on the window. In the AA menu.")),
            Feature(Text2("논문에 집중", "Focus on the paper"),
                    Text2("나머지가 비켜선다. 절을 옮길 때는 ⇧⌘L로 목차를 불러낸다.", "Everything else steps aside; ⇧⌘L brings the table of contents when you want another section."), action: .focus),
            Feature(Text2("목차", "Table of contents"),
                    Text2("PDF가 가진 목차를 페이지 위에 띄운다. 절을 누르면 그리로.", "The PDF's own outline, floated over the page. Click a section to go there."), action: .floatingList),
            Feature(Text2("이동", "Move about"),
                    Text2("다음·이전 페이지, 다음·이전 논문, 그리고 지나온 자리로 뒤로·앞으로.", "Next and previous page, next and previous paper, and back and forward through where you have been."), action: .nextPage),
        ]),
        Group(Text2("표시하기", "Marking"), symbol: "highlighter", features: [
            Feature(Text2("선택한 곳에 형광펜", "Highlight the selection"),
                    Text2("마지막에 쓴 색으로, PDF 안에 기록된다.", "Written into the PDF, in the colour you last used."), action: .highlight),
            Feature(Text2("선택한 곳에 밑줄", "Underline the selection"),
                    Text2("같은 방식으로, 글자 아래 선으로.", "The same, as a line under the words."), action: .underline),
            Feature(Text2("Ultracopy", "Ultracopy"),
                    Text2("선택한 부분을 수식은 LaTeX으로 바꿔 복사한다.", "Copy the selection with its formulas as LaTeX."), action: .ultracopy),
            Feature(Text2("표시 목록", "The marks list"),
                    Text2("논문 안의 모든 표시를 종류별로. 인스펙터의 Marks 탭에 있고, 누르면 그 자리로 간다.", "Every mark in the paper, filtered by kind, in the inspector's Marks tab. Click one to go to it.")),
            Feature(Text2("다른 앱이 남긴 필기", "Ink from other apps"),
                    Text2("다른 앱이 PDF에 남긴 손글씨를 그대로 보여주고, 그 위에 그리기 전까지 건드리지 않는다.", "Freehand drawing another app left in the PDF is shown and left alone until you draw over it.")),
        ]),
        Group(Text2("노트", "Notes"), symbol: "note.text", features: [
            Feature(Text2("새 노트", "A new note"),
                    Text2("노트 하나에 생각 하나. 어느 논문을 읽던 중이었는지 기억한다.", "One thought per note. It remembers which paper you were reading."), action: .newNote),
            Feature(Text2("선택한 구절을 노트로", "Link the selection to a note"),
                    Text2("인용구로 들어가고, 누르면 그 페이지로 돌아간다.", "The passage arrives as a quotation you can click to return to the page."), action: .linkToNote),
            Feature(Text2("노트끼리 잇기", "Link notes to each other"),
                    Text2("[[ 를 치면 다른 노트를 부른다. 나를 가리키는 노트는 읽고 있는 노트 아래에 모인다.", "Type [[ to reach for another note. What links back is listed under the one you are reading.")),
            Feature(Text2("태그", "Tags"),
                    Text2("#이렇게 쓴다. 슬립박스가 모아준다.", "Write #like-this. The slip-box collects them.")),
            Feature(Text2("지도", "Maps"),
                    Text2("노트 다섯 개가 한 주제로 쌓이면 지도를 제안한다. 지도는 링크와 소제목으로 된 노트이고, 열면 보드다.", "Five notes on one subject and a map is suggested. A map is a note of links under headings; opened, it is a board.")),
            Feature(Text2("공명", "Resonance"),
                    Text2("읽는 쪽과 낱말을 나누는 다른 논문의 노트가 Notes 탭 맨 위에 올라온다. 노트 아래에는 아직 잇지 않은 울림이 모인다.", "Notes from other papers that share the page's words rise to the top of the Notes tab; under a note, the echoes not yet linked are gathered.")),
            Feature(Text2("Markdown과 LaTeX", "Markdown and LaTeX"),
                    Text2("쓰는 대로 조판된다. $x^2$는 수식이 되고, 저장되는 것은 여전히 원문이다.", "Both are set as you write them. $x^2$ becomes mathematics; the source is still what is saved.")),
            Feature(Text2("원문 보기", "Raw"),
                    Text2("</> 버튼이 노트를 Markdown 그대로 보여준다. 링크나 수식을 손으로 고칠 때 쓴다.", "The </> button shows the note as Markdown, for fixing a link or a formula by hand.")),
        ]),
        Group(Text2("라이브러리", "The library"), symbol: "books.vertical", features: [
            Feature(Text2("논문 추가", "Add papers"),
                    Text2("PDF를 끌어다 놓거나, 이 키로.", "Drag PDFs in, or use this."), action: .addPapers),
            Feature(Text2("서지 정보", "Metadata"),
                    Text2("제목·저자·연도를 논문에서 읽는다. 확신이 없는 것은 조용히 저장하지 않고 Needs Review로 남긴다.", "Title, authors and year are read from the paper. What it is unsure of is marked Needs Review rather than saved quietly.")),
            Feature(Text2("빠진 서지 정보 채우기", "Resolve missing metadata"),
                    Text2("아직 확신이 없는 것들을 다시 살펴본다.", "Looks again at everything still unsure."), action: .resolveMetadata),
            Feature(Text2("컬렉션과 태그", "Collections and tags"),
                    Text2("사이드바에서 손으로 정리한다.", "Filed by hand, in the sidebar.")),
            Feature(Text2("BibTeX 내보내기", "Export BibTeX"),
                    Text2("선택한 것만, 또는 라이브러리 전체.", "The selection or the whole library."), action: .exportBibTeX),
            Feature(Text2("인용 키 복사", "Copy the citation key"),
                    Text2("쓰고 있는 논문에 붙여 넣기 위한 것.", "For pasting into a paper you are writing."), action: .copyCitationKey),
            Feature(Text2("폴더에서 새로 읽기", "Refresh from the folder"),
                    Text2("밖에서 폴더에 넣은 것을 찾아온다.", "Picks up anything added to the folder from outside."), action: .refreshFolder),
        ]),
        Group(Text2("그래프", "The graph"), symbol: "point.3.filled.connected.trianglepath.dotted", features: [
            Feature(Text2("네 가지 연결", "Four kinds of connection"),
                    Text2("한 논문이 다른 논문을 인용했거나, 내 노트가 둘을 이었거나, 저자가 겹치거나, 같은 컬렉션에 있거나.", "One paper citing another, your notes linking them, a shared author, or the same collection.")),
            Feature(Text2("범례가 곧 필터", "The legend is the filter"),
                    Text2("한 종류를 끄면 질문이 된다. 인용을 감추면 남는 것이 내 노트가 이은 것이다.", "Switch a kind off to ask a question. Hide citations and what is left is what your own notes have joined.")),
            Feature(Text2("선택에 집중", "Focus on a selection"),
                    Text2("논문을 하나 고른 다음 켜면, 관계없는 것이 모두 사라진다.", "Click a paper, then turn it on: everything unrelated drops away.")),
            Feature(Text2("계속 움직인다", "It keeps moving"),
                    Text2("논문을 끌면 나머지가 자리를 내주고, 곧 다시 가라앉는다.", "Drag a paper and the rest gives way, then settles.")),
        ]),
        Group(Text2("창", "The window"), symbol: "sidebar.left", features: [
            Feature(Text2("네 개의 패널", "Four panes"),
                    Text2("사이드바, 목록, 논문, 인스펙터. 각자 자기 키로 숨고, 패널 사이의 틈을 끌면 크기가 바뀐다.", "The sidebar, the list, the paper and the inspector. Each hides on its own key; the gap between two of them resizes them."), action: .sidebar),
            Feature(Text2("모든 키를 바꿀 수 있다", "Every key can be changed"),
                    Text2("이 앱의 모든 명령이 설정에 있고, ⌘, 자신만 빼면 고정된 것이 없다.", "Every command in this app is in Settings, and none of them is fixed except ⌘, itself.")),
            Feature(Text2("단축키를 이름으로도 키로도 찾기", "Search shortcuts by name or by key"),
                    Text2("설정 → Shortcuts. 기능 이름을 알면 키를 찾고, 키만 알면 그걸 가진 기능을 찾는다 — 뒤쪽이 보통 불가능한 쪽이다. ⌘F처럼 기호로 쳐도 되고 \"cmd\"처럼 말로 쳐도 된다.",
                            "Settings → Shortcuts. Knowing the name finds the key; knowing the key finds what owns it — and the second is the one that is usually impossible. Type it as it is drawn (⌘F) or as it is spoken (\"cmd\").")),
            Feature(Text2("설정은 왼쪽에서 고른다", "Settings has pages"),
                    Text2("라이브러리·서지·BibTeX·읽기·단축키·정보. 한 화면을 끝없이 내리는 대신 찾는 곳으로 바로 간다.", "Library, Metadata, BibTeX, Reading, Shortcuts and About — rather than one scroll with all of it in.")),
        ]),
    ]

    struct Release: Identifiable {
        let version: String
        let date: Text2
        let note: Text2
        let added: [Entry]
        /// Taken out. Empty in the first release, which took nothing out.
        var removed: [Entry] = []
        let fixed: [Entry]
        var id: String { version }
    }

    /// One line of a changelog: a keyword to scan, and what it means when you
    /// stop to look.
    struct Entry: Identifiable {
        let title: Text2
        let detail: Text2
        var action: ShortcutAction?
        /// A small working model of the feature, shown under the sentence.
        ///
        /// Only on the entries where a sentence genuinely does not land —
        /// what "the passage comes back as a chip" means is one drag and one
        /// keystroke, and a paragraph about it is worse than three seconds of
        /// it happening.
        var demo: Demo?
        /// Marked out in the log the way it is in the introduction.
        var featured = false
        var id: String { title.en }

        init(
            _ title: Text2, _ detail: Text2,
            action: ShortcutAction? = nil, demo: Demo? = nil, featured: Bool = false
        ) {
            self.title = title
            self.detail = detail
            self.action = action
            self.demo = demo
            self.featured = featured
        }
    }

    /// The demonstrations the app knows how to draw.
    ///
    /// The same six are used in two sizes: small, under a line of the log,
    /// and full size in About, where there is room to make them the real
    /// thing rather than a diagram of it.
    enum Demo: String, Identifiable, CaseIterable {
        /// A mark on the page and its row in the inspector, either one
        /// reaching the other.
        case annotations
        /// Four panes, each hiding on its own key.
        case panes
        /// A selection leaving the page and landing in a note as a quotation.
        case passageLink
        /// What a copied passage looks like on the clipboard.
        case ultracopy
        /// Notes linking to each other, and what links back.
        case slipBox
        /// The library drawn by four kinds of connection, with the legend
        /// switching them off.
        case graph
        /// One field over the window that finds papers, notes, authors,
        /// collections, tags and commands.
        case search
        /// Two pages across, turned with the arrows.
        case book
        /// The spread with its page numbers, its progress, and the contents
        /// floating in the gutter.
        case bookReading
        /// The window with everything but the paper gone.
        case focus
        /// A page being read, and beside it the notes from other papers that
        /// echo it, named with the words they share.
        case resonance
        /// Notes piling up on one subject, the squeeze noticed, and the map
        /// they become — a board of cards, with the door open.
        case atlas

        var id: String { rawValue }
    }

    struct Highlight: Identifiable {
        let symbol: String
        let title: Text2
        let detail: Text2
        var action: ShortcutAction?
        /// Shown full size in About, where the point is to let somebody try
        /// the thing rather than read about it.
        var demo: Demo?
        /// The ones to see first. One or two a version — more than that is
        /// a list, and a list is what this is trying not to be.
        var featured = false
        var id: String { title.en }
    }

    struct Group: Identifiable {
        let name: Text2
        let symbol: String
        let features: [Feature]
        var id: String { name.en }

        init(_ name: Text2, symbol: String, features: [Feature]) {
            self.name = name
            self.symbol = symbol
            self.features = features
        }
    }

    struct Feature: Identifiable {
        let title: Text2
        let detail: Text2
        var action: ShortcutAction?
        var id: String { title.en }

        init(_ title: Text2, _ detail: Text2, action: ShortcutAction? = nil) {
            self.title = title
            self.detail = detail
            self.action = action
        }
    }
}
