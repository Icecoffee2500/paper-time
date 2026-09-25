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

        var value: String { Language.prefersKorean ? ko : en }

        /// Kept as a name of its own because the demos read it, but the
        /// answer now comes from `Language`, which Settings can override.
        static var prefersKorean: Bool { Language.prefersKorean }
    }

    static func string(_ ko: String, _ en: String) -> String { Text2(ko, en).value }

    /// Shown on the first run of a version. Kept short on purpose: a list of
    /// twenty is a list nobody reads.
    static let highlights: [Highlight] = [
        Highlight(
            symbol: "sparkle.magnifyingglass",
            title: Text2("낱말이 아니라 뜻으로 찾아요", "Search by meaning, not by the word"),
            detail: Text2(
                "«모델이 왜 잊는지»라고 치면, 그 낱말이 하나도 없는 구절도 나와요 — «첫 과제의 정확도가 두 번째 과제를 배우자 급히 떨어진다» 같은 문장이요. 찾기(⌘K)의 정확히 맞는 결과 아래에 «뜻이 비슷한 구절»로 서요. 작은 모델이 이 맥에서만 돌고, 논문은 밖으로 나가지 않아요. 아래에서 질문을 바꿔 보세요.",
                "Type “why do models forget” and the passages that answer it come up even when none of those words is in them — “accuracy on the first task drops sharply once the second is trained.” They stand under the exact matches in Search Everything (⌘K), as Similar in Meaning. A small model runs on this Mac, and the papers never leave it. Try another question below."
            ),
            demo: .meaning,
            tier: .one
        ),
        Highlight(
            symbol: "textformat.superscript",
            title: Text2("수식은 짧게 쳐도 돼요 — LaTeX 단축 입력", "Math in shorthand: LaTeX Shortcuts"),
            detail: Text2(
                "노트에 수식을 적다 보면 \\frac{}{}를 치는 사이에 생각을 놓쳐요. 이제 //를 치면 분수가, x1을 치면 x_{1}이, sr을 치면 제곱이 되고, Tab을 누르면 다음 칸으로 가요. Obsidian의 Latex Suite를 그대로 따라서, 쓰던 손이 그대로 통해요. 아래에서 눌러 보세요.",
                "A thought gets lost somewhere inside \\frac{}{}. Now // is a fraction, x1 is x_{1}, sr is a square, and Tab moves on to the next field. These are Latex Suite's own snippets, and they behave as they do in Obsidian. Try it below."
            ),
            demo: .latexShortcuts,
            tier: .one
        ),
        Highlight(
            symbol: "folder",
            title: Text2("라이브러리가 열려요", "The libraries open"),
            detail: Text2(
                "폴더를 여럿 열 수 있게 되자 사이드바가 길어지기만 했어요 — 한 학기를 폴더로 나눠 두면 논문보다 폴더가 먼저 스무 개가 되니까요. 이제 라이브러리를 누르면 나머지는 물러나고 그 안의 폴더들이 들여쓰여 서요. 폴더를 누르면 또 그 안이 열리고, 목록에는 그 아래의 논문이 전부 나와요. 나가는 길은 지금 눌린 그 줄이에요. 아래에서 눌러 보세요.",
                "Opening several folders only made the sidebar longer — somebody filing a term has twenty folders before they have twenty papers. Press a library now and the others step aside while its own folders appear, indented. Press one of those and it opens in turn, with every paper beneath it in the list. The way back out is the row you are on. Press below and see."
            ),
            demo: .folderTree,
            tier: .one
        ),
        Highlight(
            symbol: "doc.questionmark",
            title: Text2("논문만이 아니라, 모든 PDF", "Not only papers"),
            detail: Text2(
                "PDF를 더하면 먼저 물어봐요 — 논문인가요, 일반 문서인가요. 앱이 짐작한 답을 미리 골라 두니 한 번만 누르면 돼요. 논문이면 예전처럼 서지를 찾아 채우고, 일반 문서면 학술지나 DOI 같은 칸은 아예 사라져요. 계약서에 학술지를 묻지 않아요. 표시도, 필기도, 노트도 그대로 되고요.",
                "Add a PDF and it asks: a paper, or a document? The app has already guessed, so it is one press. A paper gets its record looked up as before; a document loses the journal and the DOI, which it never had. Nobody asks a contract for its volume number. Marking, writing and notes work the same on both."
            ),
            demo: .kindQuestion,
            tier: .one
        ),
        Highlight(
            symbol: "bubble.and.pencil",
            title: Text2("이제 같이 만들어요", "Now we build it together"),
            detail: Text2(
                "무언가 이상하거나 아쉬우면 ⌥⌘/ 를 눌러주세요. 방금 그 화면이 이미 찍힌 채로 창이 열리니까 어디서 그랬는지 설명하지 않아도 돼요. 논문에 쓰던 그 화살표와 네모로 바로 표시하면 되고, 보이면 안 되는 곳은 가리개로 덮으면 돼요. 보내주신 건 배포 페이지의 목록에 올라가고, 고쳐지면 체크가 붙어요 — 적어주신 이름과 함께요.",
                "When something is wrong, or missing, press ⌥⌘/. The sheet opens with the screenshot already taken, so you never have to explain where you were. Mark it up with the same arrow and box you use on papers, and cover anything private. What you send lands on the list on the download page and gets a check when it is fixed — with the name you chose beside it."
            ),
            demo: .feedback,
            tier: .one
        ),
        Highlight(
            symbol: "macwindow.on.rectangle",
            title: Text2("라이브러리가 어느 데스크톱에서나 열린다", "One library, on every desktop"),
            detail: Text2(
                "표시는 PDF 파일 안에 쓰이고 라이브러리는 그냥 폴더다. 그래서 같은 폴더를 맥에서도, 윈도우에서도, 리눅스에서도 연다 — 하이라이트도 손글씨도 굽은 화살표도 그대로. 계정도 서버도 내보내기도 없고, 클라우드 폴더든 USB든 파일이 닿는 곳이면 된다. 아래에서 표시 하나가 셋에 닿는 것을 눌러 보라.",
                "The marks are written into the PDF and the library is only a folder, so the same folder opens on a Mac, on Windows and on Linux — the highlights, the handwriting, the bent arrows, all of it. No account, no server, nothing exported: a cloud folder or a memory stick will do. Press below and watch one mark reach all three."
            ),
            demo: .crossPlatform,
            tier: .one
        ),
        Highlight(
            symbol: "function",
            title: Text2("Ultracopy — 수식은 LaTeX으로, 글은 글로", "Ultracopy — the words as words, the mathematics as LaTeX"),
            detail: Text2(
                "PDF에서 수식이 든 문단을 ⌘C로 복사하면 수식이 글자 부스러기로 깨져 나온다. Ultracopy(⇧⌘C)는 같은 선택에서 글은 그대로, 수식은 그대로 쓸 수 있는 LaTeX으로 돌려준다. 아래에서 둘을 직접 눌러 비교해 보라.",
                "⌘C on a passage with an equation in it gives you the formula as a spill of characters. Ultracopy (⇧⌘C) gives the same selection back with the words as words and the mathematics as LaTeX you can paste as it is. Press both below and compare."
            ),
            action: .ultracopy,
            demo: .ultracopy,
            tier: .one
        ),
        Highlight(
            symbol: "pencil.and.outline",
            title: Text2("맥에서도 자유롭게 그린다 — 도형·화살표·카드·손글씨", "Draw freely on the Mac: shapes, arrows, cards, handwriting"),
            detail: Text2(
                "PDF 앱의 필기는 딱딱하다 — 네모 하나, 메모 아이콘 하나. 여기서는 펜을 들면(⇧⌘D) 쪽 위에 Figma의 도구 줄이 뜬다: 선택 V, 프레임 F, 도형(네모 R·동그라미 O·선 L·화살표 A), 펜(P·형광펜 H·지우개 E), 글 T — 한 글자로 바꾼다. 화살표는 가운데 손잡이를 끌면 XMind처럼 구부러지고, 상자를 두 번 누르면 그 안에 글을 쓰고, 글은 종이 위에 바로 쓴다. 프레임 안에 넣고(F), 묶고(⌘G), 줄이나 열로 정렬한다(⇧A). 오른쪽 인스펙터에 위치·크기·간격·투명도·모서리·채움·외곽선·글자 크기가 숫자로 있다. 형광펜은 아이패드처럼 글자에 맞춰지고, 지우개는 선·도형·하이라이트를 함께 지운다. 모두 ⌘Z. 그리고 전부 PDF 안에 표준 주석으로도 기록되어 아이패드·아이폰·Preview에서 같은 자리에 보인다. 아래 카드를 끌어 보라 — 화살표가 따라온다.",
                "Drawing in a PDF app is stiff: one box, one note icon. Here, take the pencil out (⇧⌘D) and Figma's tool rack floats over the page: Select V, Frame F, the shapes (rectangle R, ellipse O, line L, arrow A), the pen (P, highlighter H, eraser E), Text T — one letter each. An arrow bends when its middle handle is pulled, the way XMind's do; double-click a box to write inside it; text is typed straight onto the page. Put things in a frame (F), group them (⌘G), line them up in a row or a column (⇧A). The inspector on the right has position, size, gap, opacity, corners, fill, stroke and text size as numbers. The highlighter fits itself to the words as on the iPad; the eraser takes strokes, shapes and highlights together. All of it undoes with ⌘Z. And all of it is written into the PDF as standard annotations too, so the iPad, the iPhone and Preview show it in the same place. Drag the card below — the arrow follows."
            ),
            action: .draw,
            demo: .sketch,
            tier: .one
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
            tier: .two
        ),
        Highlight(
            symbol: "arrow.triangle.2.circlepath.icloud",
            title: Text2("맥에서 긋고, 아이패드에서 본다 — 몇 초 뒤", "Mark it on the Mac, see it on the iPad — seconds later"),
            detail: Text2(
                "서버는 없다. 라이브러리는 iCloud Drive 폴더 하나인데, 20 MB PDF가 오가기를 기다리면 열 초다. 그래서 무거운 것은 기다리지 않는다. 표시는 기기마다 자기 이름으로 쓰는 몇 KB짜리 저널 파일에, 잉크는 쪽마다 사이드카에 즉시 쓰고, iCloud Drive가 그것을 옮긴다 — 두 기기가 같은 저널을 쓰는 일이 없으니 충돌도 없다. 받는 쪽은 열린 논문의 기록 폴더를 지켜보고 3초마다 한 번 더 살핀다. PDF는 그 뒤 1.5초에 저널대로 다시 쓰여 어느 앱에서 열어도 같다. 표시마다 가장 최근 말이 이긴다: 여기서 지우고 저기서 색을 바꾸면 나중 것이 남는다. 아래에서 맥 쪽에 하이라이트를 긋고 아이패드를 보라.",
                "There is no server. The library is one iCloud Drive folder, and waiting for a 20 MB PDF to travel is ten seconds. So nothing waits for the heavy thing. Marks go at once into a journal of a few KB each device writes under its own name, ink into a sidecar per page, and iCloud Drive carries those — no two devices ever write one journal, so nothing conflicts. The receiving side watches the open paper's record and looks again every three seconds. The PDF is rewritten to the journals 1.5 s later, so any app opening it sees the same. On each mark the newest word wins: remove it here, recolour it there, and the later one stands. Make a highlight on the Mac below and watch the iPad."
            ),
            demo: .sync,
            tier: .two
        ),
        Highlight(
            symbol: "waveform",
            title: Text2("읽는 동안 슬립박스가 말을 건다", "While you read, the slip-box speaks first"),
            detail: Text2(
                "할 일은 없다. 논문을 읽으면 된다. 인스펙터의 Notes 탭을 열어 두면, 지금 보이는 쪽과 드문 낱말을 나누는 노트가 — 몇 달 전 다른 논문을 읽다 쓴 것이라도 — 맨 위에 스스로 올라온다. 노트 아래 파란 낱말이 둘이 나누는 말이다: 우연이면 지나치고, 울림이면 노트를 눌러 열어 본다. 쪽에서 문장을 선택하면 노트마다 ❝ 단추가 생기고, 누르면 그 구절이 주소를 갖고 그 노트에 들어간다 — 두 논문이 노트 하나에서 만난다. 노트를 쓰는 동안에는 편집기 아래 'Resonates with'에 아직 잇지 않은 울림이 모이고, 🔗 한 번이면 [[링크]]가 써진다. 다른 앱에서 노트는 폴더에 누워 있다가 검색해야 나온다 — 그런데 잊어버린 노트는 검색하지 않는다. 루만은 자기 상자를 대화 상대라고 불렀다; 상자가 먼저 말을 걸 때만 대화다.\n\n고르는 법은 숨기지 않는다. 네 노트를 전부 외운 읽기 친구가 새 쪽의 낱말과 노트의 낱말을 나란히 놓고 같은 것을 센다고 생각하면 된다 — 다만 기능어와 논문마다 쓰는 말(model, method, results…) 300개쯤은 세지 않고, 낱말 하나의 무게는 ln((N+1)÷(그 말이 나오는 글 수+0.5))+0.3으로 매긴다(N = 노트 수 + 이 논문에서 뽑은 40쪽; 45개 글 중 42개에 나오는 'network'는 0.38, 3개에만 나오는 'consolidation'은 2.88). 두 낱말이 붙어 겹치면 ×1.3, 긴 노트는 (1+ln 길이)로 나눈다. 겹친 말이 둘 이상이고 점수 1.0 이상, 1등의 35% 이상인 노트만 넷까지 올라온다. 아래에서 네 단계를 직접 해 보고, '어떻게 고르나?'를 눌러 보라.",
                "There is nothing to do but read. Keep the inspector's Notes tab open and the notes that share their rarer words with the pages on screen — written months ago, against another paper — come up by themselves at the top. The blue words under each are what the two share: a coincidence, and you read on; an echo, and you click the note to open it. Select a sentence on the page and every note grows a ❝ button; press it and the passage lands in that note with its address — two papers meet in one note. While you write, 'Resonates with' under the editor gathers the echoes not yet linked, and one 🔗 writes the [[link]]. In other apps a note lies in a folder until you search for it — and nobody searches for a note they have forgotten. Luhmann called his box a conversation partner; it is one only when the box speaks first.\n\nThe rule is not hidden. Think of a reading friend who knows your notes by heart, laying the page's words beside each note's and counting what they share — except that function words and the words every paper uses (model, method, results…), some 300, are not counted, and a word's weight is ln((N+1)÷(texts it appears in+0.5))+0.3, with N the notes plus 40 sampled pages of this paper ('network', in 42 of 45 texts: 0.38; 'consolidation', in 3: 2.88). Two words together count ×1.3; a long note's sum is divided by (1+ln length). Only notes sharing two words, scoring 1.0 or more and at least 35% of the strongest come up, four at most. Do the four steps below, and press 'How are they chosen?'."
            ),
            demo: .resonance,
            tier: .one
        ),
        Highlight(
            symbol: "map",
            title: Text2("노트에 집이 생긴다 — 지도", "A note gets a home: the map"),
            detail: Text2(
                "노트는 폴더가 아니라 지도에 산다. 지도는 그 자체가 노트 하나인데, 본문이 다른 노트로 가는 [[링크]]와 그것들을 배열한 소제목이라 다른 앱에서도 그냥 Markdown이다. 원칙은 미리 만들지 않는다는 것 — 한 주제의 노트가 다섯 개 이상 서로 잇거나 낱말을 나누며 쌓이고 그걸 담은 지도가 없으면, 슬립박스 맨 위에 한 줄이 뜬다: \"이 노트 6개가 한 주제예요 — consolidation · forgetting.\" 누르면 초안이 써진다: 제목은 나누는 낱말에서, 노트는 논문별 소제목 아래 링크로. 지도를 열면 소제목이 열, 노트가 카드인 보드가 되고, 옆에는 지도와 울리지만 아직 안 올린 노트가 ＋ 한 번 거리에 있다. 노트를 쓰는 동안에도 편집기 아래 'Resonates with'에 지도가 뜨면 🗺 한 번으로 그 위에 올라간다. 아래에서 네 단계를 해 보라.",
                "A note lives on a map, not in a folder. The map is itself a note — its body is [[links]] to other notes under headings, so in any other app it is plain Markdown. The rule is not to make one in advance: when five or more notes on one subject have piled up, linking to each other or sharing their rarer words, and no map holds them, one line appears at the top of the slip-box: \"6 notes are one subject — consolidation · forgetting.\" Press it and a draft is written: a title from the shared words, the notes as links under a heading per paper. Open the map and it is a board — a column per heading, a card per note — with, beside it, the notes that resonate with the map and are not yet on it, one ＋ away. Writing a note, a map that echoes it appears under the editor, and one 🗺 files the note on it. Do the four steps below."
            ),
            demo: .atlas,
            tier: .three
        ),
        Highlight(
            symbol: "doc.text",
            title: Text2("노트는 글이 되어야 한다 — 초안", "Notes are meant to become writing: the draft"),
            detail: Text2(
                "노트는 모으는 게 목적이 아니다. 연구자의 산출물은 원고이고, 슬립박스는 글쓰기로 끝나야 한다 — 그리고 그 길에서 인용이 끊어지지 않아야 한다. 초안은 노트 하나(kind: draft)다: 소제목 아래 글머리표를 쓰고, 논문을 읽다 구절을 선택하면 Notes 탭에 '초안에 넣기'가 떠서 ❝ 한 번으로 그 구절이 논문 주소를 달고 들어오고, 슬립박스의 노트는 우클릭 '초안에 넣기'로 [[링크]]가 된다. ⇧⌘E를 누르면 초안이 원고로 렌더된다: 구절 칩은 그 논문의 \\cite{키}가 되고(기본 LaTeX, pandoc [@키]도), 링크한 노트는 제 문장으로 풀리고, 인용한 논문만 담은 .bib이 함께 나온다. Overleaf에 붙이면 컴파일된다. 첫 목표는 관련연구 절 하나를 끝까지 — 아래에서 해 보라.",
                "Collecting is not the point. A researcher's output is a manuscript, and the slip-box has to end in writing — with the citations intact along the way. A draft is a note (kind: draft): bullets under headings. Reading a paper, select a passage and the Notes tab offers \"Into a draft\": one ❝ and the passage arrives carrying the paper's address; a note in the slip-box goes in as a [[link]] from its context menu. ⇧⌘E renders the draft for the manuscript: each passage chip becomes that paper's \\cite{key} (LaTeX by default, pandoc [@key] too), each linked note unfolds into its own sentences, and a .bib of exactly the papers cited comes with it. Paste into Overleaf and it compiles. The first goal is one related-work section, end to end — try it below."
            ),
            demo: .express,
            tier: .three
        ),
        Highlight(
            symbol: "magnifyingglass",
            title: Text2("한 칸에서 전부 찾는다", "One field finds all of it"),
            detail: Text2(
                "⌘K — 또는 논문 목록을 위로 끝까지 당기면 — 한 칸이 뜬다. 치면 논문·노트·지도·초안·저자·컬렉션·태그·명령을 찾고, 같은 제목이면 최근에 연 것이 먼저다. 치지 않으면 빈칸이 아니라 제안이다: '이어 읽기'(어디까지 읽었고 몇 쪽 남았는지 — 끝이 가까울수록 끌리는 법), '읽었으니'(방금 읽은 논문과 드문 낱말을 나누는 아직 안 읽은 논문, 나누는 낱말과 함께 — 아는 것을 새 쪽에서 보게 하는 호기심의 틈), '다시 보기'(몇 주 전 읽고 노트를 남긴 논문 — 잊히기 직전이 다시 볼 때다), '이번 주 새로'. 논문 안의 글자를 찾는 것은 ⌘F 쪽이다.",
                "⌘K — or pull the paper list down past its top — and one field appears. Type, and it finds papers, notes, maps, drafts, authors, collections, tags and commands, the recently opened first among equals. Type nothing, and it offers rather than waits: Continue (how far you got and how few pages are left — the last stretch pulls hardest), Because you read (unread papers that share their rarer words with the one you just read, the words named — a known thing seen from a new side), Revisit (read weeks ago, with your notes — just before it fades is the time), New this week. ⌘F is the other one: the words inside the open paper."
            ),
            action: .searchEverything,
            demo: .search,
            tier: .one
        ),
        Highlight(
            symbol: "sidebar.left",
            title: Text2("창은 내가 접는 대로 있는다", "The window folds to what you are doing"),
            detail: Text2(
                "사이드바·목록·논문·인스펙터가 각자 자기 키로 숨는다. 남은 것이 빈자리를 나눠 갖는 대신, 숨은 것 뒤에 있던 것이 드러난다. 패널 사이의 틈을 끌면 크기가 바뀐다.",
                "The sidebar, the list, the paper and the inspector each hide on their own key — revealing what was behind rather than stretching to fill the gap. Drag the space between two of them to resize."
            ),
            action: .sidebar,
            demo: .panes,
            tier: .two
        ),
        Highlight(
            symbol: "book",
            title: Text2("책처럼 펼쳐서 읽는다", "Read it like a book"),
            detail: Text2(
                "⌘3이면 1·2쪽이 마주 보며 창을 가득 채운다. ←→나 스페이스로 장을 넘기고, 트랙패드로 넘겨도 된다. 아래에는 지금 몇 쪽인지와 얼마나 읽었는지가 있고, ⇧⌘L이면 두 쪽 사이 여백에 이 논문의 목차가 떠서 절로 바로 간다. ⌘1은 연속 스크롤, ⌘2는 한 장씩 — 배치를 바꿔도 보던 쪽은 그대로다.",
                "⌘3 and pages 1 and 2 face each other across the window. ← → or the space bar turn the page, and so does a swipe. Underneath, which pages these are and how far in you are; ⇧⌘L drops the paper's own table of contents into the gutter between the pages, and a section is one click away. ⌘1 scrolls, ⌘2 shows one page — and changing layout keeps the page you were on."
            ),
            action: .layoutBook,
            demo: .book,
            tier: .two
        ),
        Highlight(
            symbol: "rectangle.center.inset.filled",
            title: Text2("논문만 남긴다", "Only the paper"),
            detail: Text2(
                "⇧⌘F 한 번에 사이드바·목록·인스펙터가 비켜서고 논문만 남는다. 열려 있던 것은 기억해 두고, 나올 때 그대로 돌려준다. 그 안에서도 ⇧⌘L로 목차를 불러 절을 옮겨 다닐 수 있다.",
                "One ⇧⌘F and the sidebar, the list and the inspector step aside, leaving the paper. What was open is remembered and given back on the way out. ⇧⌘L still brings the table of contents, so you can move between sections without leaving."
            ),
            action: .focus,
            demo: .focus,
            tier: .two
        ),
        Highlight(
            symbol: "highlighter",
            title: Text2("표시는 PDF 안에 남고, 여기서는 더 예쁘다", "Your marks go into the PDF — and look better here"),
            detail: Text2(
                "형광펜과 밑줄이 옆에 붙은 데이터베이스가 아니라 파일 자체에 기록된다. 미리보기든 아이패드든 십 년 뒤든 표시는 그대로다. 그리고 이 앱 안에서는 형광펜의 끝이 둥글고 글자가 살 만큼 연하며, 밑줄은 눈에 띄게 짙고, 마우스를 올리면 밝아진다. 수식이 든 줄에서 다른 앱은 상자가 줄 높이만큼 자라지만, 여기서는 글자의 잉크를 재서 사람이 그은 것처럼 딱 맞게 덮는다 — 파일은 그대로 두고 그리는 법만 바꾼 것이라 다른 앱에서는 볼 수 없는 생김새다. 노트의 인용구도 같은 모양이다. 아래에서 둘을 나란히 보라.",
                "Highlights and underlines are written into the file itself, not into a database beside it — Preview, an iPad, ten years from now, the marks are there. And in here a highlight has rounded ends and stays pale enough to read through, an underline is dark enough to see, and either brightens under the pointer. On a line carrying a formula, other apps grow the box to the height of the line; here the ink of the letters is measured and the band fits them the way a hand-drawn stroke does. The file is untouched; only the drawing is ours, which is why no other PDF app looks like this. A quotation in a note wears the same shape. Compare the two side by side below."
            ),
            demo: .annotations,
            tier: .one
        ),
        Highlight(
            symbol: "quote.opening",
            title: Text2("인용한 구절은 주소를 갖는다", "A passage keeps its address"),
            detail: Text2(
                "선택한 글을 노트로 보내면 인용구로 앉는다. 누르면 그 글이 있던 페이지의 정확한 자리로 돌아간다.",
                "Send the selected text to a note and it arrives as a quotation you can click to go back to the exact place on the page it came from."
            ),
            action: .linkToNote,
            demo: .passageLink,
            tier: .one
        ),
        Highlight(
            symbol: "tray.full",
            title: Text2("PDF 더미가 아니라 슬립박스", "A slip-box, not a pile of PDFs"),
            detail: Text2(
                "노트는 그것을 쓰게 만든 논문 아래가 아니라 한곳에 모여 산다. [[…]]로 서로 잇고, 이 앱 없이도 읽히는 평범한 Markdown 파일이다.",
                "Notes live together rather than under the paper that caused them, link to each other with [[…]], and are plain Markdown files you can read without this app."
            ),
            action: .newNote,
            demo: .slipBox,
            tier: .three
        ),
        Highlight(
            symbol: "point.3.filled.connected.trianglepath.dotted",
            title: Text2("내 읽기가 무엇을 이었는지 본다", "See what your reading has joined"),
            detail: Text2(
                "그래프는 인용·공저자·컬렉션으로, 그리고 내 노트가 이은 것으로 라이브러리를 그린다. 나머지 선을 끄면 남는 것이 문헌의 관계가 아니라 내 읽기다.",
                "The graph draws your library by citation, shared author, collection — and by what your own notes link. Switch the other lines off and what is left is your reading rather than the literature's."
            ),
            demo: .graph,
            tier: .three
        ),
        Highlight(
            symbol: "keyboard",
            title: Text2("어떤 키가 무슨 일을 하는지 되짚을 수 있다", "Ask what a key does, not just what a key is"),
            detail: Text2(
                "설정 → Shortcuts에서 기능 이름으로도, 키로도 찾는다. 뭘 눌렀는지 모르겠으면 \"cmd\"나 ⌘F를 쳐보면 그 키를 가진 명령이 나온다. 그리고 이 앱의 모든 키는 바꿀 수 있다.",
                "Settings → Shortcuts searches by name and by key. If something happened and you do not know what you pressed, type \"cmd\" or ⌘F and the command that owns it comes back. Every key in this app can be changed."
            ),
            action: .settings,
            tier: .three
        ),
        Highlight(
            symbol: "folder",
            title: Text2("라이브러리는 내가 고른 폴더다", "The library is a folder you chose"),
            detail: Text2(
                "논문은 놓아둔 자리에 평범한 파일로 있다. iCloud Drive나 구글 드라이브 안의 폴더를 가리키면, 동기화는 이 앱이 새로 해야 할 일이 아니라 이미 갖고 있는 것이 된다.",
                "Papers stay as ordinary files where you put them. Point it at a folder in iCloud Drive or Google Drive and syncing is something you already have rather than something this app has to do."
            ),
            tier: .two
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
            version: "0.9.9",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "찾기가 이제 뜻으로도 찾아요. 그리고 노트에 수식을 짧게 쳐도 돼요 — //는 분수가 되고, Tab을 누르면 다음 칸으로 가요.",
                "Search finds passages by what they mean now. And math goes into a note in shorthand: // becomes a fraction, and Tab moves on to the next field."
            ),
            added: [
                Entry(
                    Text2("뜻으로 찾기", "Search by Meaning"),
                    Text2(
                        "찾기(⌘K)에 «모델이 왜 잊는지»라고 치면, 그 낱말이 없는 구절도 찾아요. 논문마다 본문을 백 낱말쯤의 구절로 나눠 작은 언어 모델(all-MiniLM-L6-v2)로 벡터를 만들어 두고, 친 말과 가장 가까운 여덟 구절을 정확히 맞는 결과 아래 «뜻이 비슷한 구절»로 보여줘요. 누르면 그 구절로 가요. 준비는 라이브러리를 연 뒤 조용히 돼요 — 논문 하나가 1초쯤이고, 한 번 하면 파일이 바뀌지 않는 한 다시 안 해요. 모델은 이 맥에서만 돌아요. 설정 → 읽기에서 끌 수 있어요.",
                        "Type “why do models forget” into Search Everything (⌘K) and the passages that answer it come up even without those words in them. Each paper's text is cut into passages of about a hundred words and given a vector by a small language model (all-MiniLM-L6-v2); the eight closest to what you typed stand under the exact matches, as Similar in Meaning, and pressing one goes to that passage. The library is prepared quietly after it opens — about a second a paper, once, and not again while the file stays the same. The model runs on this Mac only. Turn it off in Settings, under Reading."
                    ),
                    demo: .meaning
                ),
                Entry(
                    Text2("저장해도 논문은 그대로", "Your paper's bytes stay as they were"),
                    Text2(
                        "표시를 저장할 때 논문 파일을 처음부터 다시 쓰지 않고, 표시만 뒤에 덧붙여요. 파일의 원래 바이트는 한 자도 바뀌지 않아요. 표시를 지우거나 같은 표시를 다시 저장해도 파일은 자라지 않고, 덧붙일 수 없는 파일이면 표시를 Paper Time 안에 두고 그렇다고 알려요.",
                        "Saving marks appends them to the PDF instead of rewriting it. Not one byte of the original changes. Removing a mark, or saving the same marks again, does not grow the file, and a file that cannot take an appended revision keeps its marks in Paper Time and says so."
                    )
                ),
                Entry(
                    Text2("빠른 검색", "Faster search"),
                    Text2(
                        "모두 찾기가 논문의 글을 한 번 읽어 두고 키를 칠 때마다 바로 답해요. 630편에 노트 1,000개가 있어도 한 글자에 20 ms 안이에요. 파일에 표시를 덧붙여도 다시 읽지 않아요.",
                        "Search Everything reads each paper's text once and answers on every keystroke. With 630 papers and 1,000 notes, a keystroke takes under 20 ms, and a paper you add marks to is not read again."
                    )
                ),
                Entry(
                    Text2("정렬선과 끌어서 복제", "Snapping and drag to duplicate"),
                    Text2(
                        "도형을 옮기면 다른 도형과 쪽의 변·가운데에 붙고, 붙은 동안 빨간 정렬선이 보여요. ⇧를 누르면 한 축으로만 움직이고, ⌥이나 ⌘를 누른 채 끌면 사본이 원래 자리에 남아요. 되돌리기 한 번이면 사본도 원래 자리도 돌아와요.",
                        "Moving a shape snaps it to the edges and centers of other shapes and of the page, with a red guide while it holds. Shift keeps the move on one axis; drag with Option or Command and a copy stays where the original was. One Undo takes back both."
                    )
                ),
                Entry(
                    Text2("논문 없는 노트의 폴더", "A folder for notes without a paper"),
                    Text2(
                        "그냥 떠오른 생각을 적은 노트는 어느 논문 폴더에도 속하지 않아서 앱 안에 살았어요. 이제 설정에서 폴더를 고르면 그 노트들이 거기로 옮겨 가요. 클라우드 폴더를 고르면 다른 기기에서도 보여요. 폴더가 잠시 안 보여도 고른 것을 잊지 않아요.",
                        "Notes that belong to no paper lived inside the app. Choose a folder in Settings and they move there; pick a cloud folder and they follow you to other devices. If the folder is away for a while, the choice is kept."
                    )
                ),
                Entry(
                    Text2("LaTeX 단축 입력", "LaTeX Shortcuts"),
                    Text2(
                        "수식 안에서 x1을 치면 x_{1}, sr은 ^{2}, //는 분수가 되고, Tab을 누르면 다음 칸으로 가요. /는 앞에 친 것을 분자로 삼고, mk는 인라인 수식을, dm은 디스플레이 수식을 열어요. Obsidian의 Latex Suite를 기본값까지 그대로 따라서, 거기서 익힌 손이 여기서도 통해요. 노트에서도, 쪽 위의 글 카드에서도 돼요. 바뀐 게 마음에 안 들면 ⌘Z 한 번에 친 그대로 돌아오고, 한글을 조합하는 동안에는 아무것도 바꾸지 않아요. 설정의 «읽기»에서 끌 수 있어요.",
                        "Inside math, x1 becomes x_{1}, sr becomes ^{2}, // becomes a fraction, and Tab moves on to the next field. A / takes what came before it as the numerator; mk opens inline math, and dm opens display math. It follows Obsidian's Latex Suite down to its defaults, so hands trained there work here, in notes and in text cards on the page. One ⌘Z gives back exactly what you typed, and nothing changes while an input method is composing. Turn it off in Settings, under Reading."
                    ),
                    demo: .latexShortcuts
                ),
            ],
            fixed: [
                Entry(
                    Text2("저장이 논문의 글자를 바꾸던 것", "Saving changed the text of TeX papers"),
                    Text2(
                        "PDF를 다시 쓸 때 글꼴이 다시 만들어져서, TeX로 만든 논문의 ff·fi 같은 합자가 «!»로 바뀌고 검색과 복사가 어긋났어요. 이제 파일을 다시 쓰지 않으니 생기지 않아요. 이미 바뀐 파일은 원본 파일이 있으면 되돌릴 수 있어요.",
                        "Rewriting a PDF re-subset its fonts, so ligatures such as ff and fi in TeX papers turned into «!» and search and copy went wrong. The file is no longer rewritten, so this cannot happen again. A file that already changed can be restored from its original."
                    )
                ),
                Entry(
                    Text2("글 카드의 수식이 선명해요", "Math in a text card is sharp"),
                    Text2(
                        "펜 도구의 글 카드에서 조판된 수식이 흐릿하게 그려졌어요. 화면 배율에 맞춰 그려요.",
                        "Typeset math in a text card drew blurry. It now renders at the screen's scale."
                    )
                ),
                Entry(
                    Text2("노트를 쓰는 동안 노트 칸이 바뀌지 않아요", "The Notes pane stays on the note you are writing"),
                    Text2(
                        "쪽을 넘기거나 표시를 누르면 쓰던 노트가 다른 노트로 바뀌었어요. 쓰는 동안은 그 노트에 머물러요. 펜을 내려놓으면 인스펙터가 펜을 들기 전 탭으로 돌아가고, 새 노트의 커서가 안내 문구와 같은 줄에 서요.",
                        "Turning a page or clicking a mark switched the note you were writing. The pane now stays on it. Putting the pen down returns the inspector to the tab you had before, and the cursor in a new note lines up with the placeholder."
                    )
                ),
                Entry(
                    Text2("윈도우·리눅스에서 표시가 사라지던 것", "Marks vanished on Windows and Linux"),
                    Text2(
                        "맥이 저장한 파일을 윈도우·리눅스에서 열면 표시가 안 보이고, 거기서 표시를 하나 더하면 논문의 링크와 다른 앱의 표시가 지워졌어요. 암호가 걸린 파일에 쓴 표시는 읽을 수 없는 글자가 됐어요. 셋 다 고쳤어요.",
                        "A file saved on the Mac showed no marks on Windows and Linux, and adding one there removed the paper's links and other apps' marks. Marks written into a password-protected file came back as garbage. All three are fixed."
                    )
                ),
                Entry(
                    Text2("글 카드에서 ⌘Z가 친 글을 되돌려요", "⌘Z in a text card undoes the typing"),
                    Text2(
                        "쪽 위의 글 카드에 글을 치다가 ⌘Z를 누르면, 친 글이 아니라 그 전에 그린 도형이 되돌아갔어요. ⌘Z가 카드가 아니라 창의 기록으로 갔거든요. 이제 카드에 치는 동안의 ⌘Z는 카드 안에서만 되돌려요.",
                        "Pressing ⌘Z while typing in a text card took back the shape drawn before it, not the typing: the key went to the window's history instead of the card's. While a card is being typed into, ⌘Z now undoes inside the card."
                    )
                ),
            ]
        ),
        Release(
            version: "0.9.8",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "논문이 많아져도 목록이 느려지지 않아요. 논문을 들여오는 동안 앱이 멈추던 것도 고쳤고요. 그리고 보충 자료를 붙일 논문을 이제 찾아서 골라요.",
                "A long list scrolls like a short one, importing no longer stops the app, and the paper you attach something to is one you can search for."
            ),
            added: [
                Entry(
                    Text2("붙일 논문을 찾아서 골라요", "Search for the paper to attach to"),
                    Text2(
                        "«다른 논문에 붙이기»가 제목 순으로 서른 편만 보여주는 메뉴였어요. 그런데 찾는 건 보충 자료의 부모 논문이고, 그건 A에 있을 확률과 Z에 있을 확률이 같아요 — 이백 편짜리 라이브러리에서는 대개 그 서른 안에 없었고, 메뉴는 없다는 말조차 못 했어요. 이제 찾기 칸이 있는 창이 열리고, **제목과 파일 이름** 양쪽으로 찾아요. 받은 파일이 «Karmanov_Efficient_Test-Time_Adaptation_CVPR_2024.pdf»면 어느 제목에도 없는 «karmanov»를 치게 되니까요. 낱말 앞머리만 쳐도 되고(«adapt»가 «adaptation»을, «강화학습»이 «강화학습의»를 찾아요) 오타도 건져요. 치는 동안 맨 위 것이 골라져 있어서 Return만 누르면 붙어요.",
                        "Attach To was a menu of the first thirty papers in title order. What it is for is a supplement's parent, and that is as likely to be at Z as at A — on a shelf of two hundred the paper was usually not among the thirty, and a menu that stops at thirty cannot say that it stopped. It is a picker now, with a field, and it searches titles and file names both: nothing in «Efficient Test-Time Adaptation of Vision-Language Models» says Karmanov, and Karmanov is what you downloaded and what you will type. Word beginnings are enough — adapt finds adaptation — and a typo still finds the paper. The top match is selected as you type, so Return attaches it."
                    )
                ),
            ],
            fixed: [
                Entry(
                    Text2("논문이 많아도 목록이 느려지지 않아요", "A long list scrolls like a short one"),
                    Text2(
                        "라이브러리가 커질수록 목록이 무거워졌어요. 세 군데였는데, 마지막 하나가 컸어요 — 목록이 **보이지도 않는 줄의 높이까지 매번 다시 재고 있었거든요.** 줄 하나를 재는 데 그 줄을 통째로 한 번 그려보는 셈이라, 600편이면 한 걸음에 86ms였어요(프레임 다섯 개). 스크롤을 오래 해도 안 나아졌고요. 이제 목록은 **보이는 줄만** 만들고 높이는 한 번 재서 기억해요. 같은 자로 600편 23ms, 270편 14ms예요. 나머지 둘은 «아래로 당겨서 찾기»가 손가락이 움직일 때마다 라이브러리 전체를 다시 짓던 것과, 목록이 논문 기록을 통째로 훑던 것이에요.",
                        "The list got heavier as the library grew. Three reasons, and the last was the big one: it was measuring the height of every row, including the ones you cannot see, on every layout pass — and measuring a row means drawing it once. At six hundred papers that was 86ms a scroll step, five frames, and scrolling for a while never made it better. The list now builds only the rows on screen and measures a height once. By the same ruler: 23ms at six hundred papers, 14ms at two hundred and seventy. The other two were the pull-to-search hint rebuilding the whole library on every tick of every scroll, and the list carrying each paper's whole record where an identifier would do."
                    )
                ),
                Entry(
                    Text2("논문을 들여오는 동안 앱이 멈추지 않아요", "Importing no longer stops the app"),
                    Text2(
                        "폴더의 PDF를 들여올 때 한 편마다 라이브러리의 모든 색인을 다시 지었고, 서지를 찾아올 때마다 또 한 번 지었어요. 육백 편짜리 폴더면 그걸 수백 번 한 거예요 — 실측으로 들여오는 중에 목록을 굴리면 한 걸음이 **60초**까지 멈췄어요. 이제 스물다섯 편씩 묶어서 들이고 서지 결과도 모아서 한 번에 반영해요. 같은 측정에서 최악의 한 걸음이 0.146초예요.",
                        "Taking a folder's PDFs in rebuilt every index in the library once per file, and again for every record a registrar answered — several hundred times for a folder of six hundred. Measured, a scroll step during an import stalled for as long as sixty seconds. Papers now go in by the handful and looked-up records are settled in batches. On the same measurement the worst step is 0.146 seconds."
                    )
                ),
                Entry(
                    Text2("«남은 PDF 더하기»가 끝나요", "Add the remaining PDFs now finishes"),
                    Text2(
                        "줄에 적힌 수가 눌러도 눌러도 그대로였어요. 이유가 둘이었는데, 하나는 못 들여온 파일까지 목록에서 지우고 있던 거예요 — 사라졌다가 폴더를 다시 읽으면 돌아왔죠. 다른 하나는 이미 있는 논문과 바이트가 같은 파일에 기록을 안 만들던 거예요. 그건 밖에서 끌어다 놓은 파일에 대한 답인데, 폴더 안에 이미 있는 파일에는 맞지 않아요. 그 파일은 누군가 거기 둔 거고, 기록을 안 주면 목록에 영영 안 나오니까요. 이제 폴더에 사본이 둘이면 목록에도 둘이고, 못 읽은 파일은 «PDF n개는 더하지 못했어요»라고 말해요 — 클라우드 파일이 아직 안 내려온 것이 가장 흔한 이유라서요.",
                        "The number on that row stayed where it was however often it was pressed. Two reasons. Files that could not be taken in were struck off the list anyway, so they vanished and came back on the next read of the folder. And a PDF whose bytes matched a paper already here was refused a record — a true answer about a file dragged in from outside, and the wrong one about a file already sitting in the folder, which somebody put there and which the list will never show without one. Two copies in the folder are two papers in the list now, and a file that could not be read says so: on a cloud drive it is usually still on its way down."
                    )
                ),
                Entry(
                    Text2("보충 자료가 제 논문을 찾아요", "A supplement finds its paper"),
                    Text2(
                        "파일 이름에서 «supplementary» 같은 말을 떼어낼 때 «supplement»만 떼고 «ary»를 남기고 있었어요. 그 부스러기를 라이브러리의 모든 제목과 비교하니 점수가 떨어져서, 영어로 대놓고 supplementary라고 적힌 파일이 부모 논문을 못 찾았어요.",
                        "Stripping supplementary wording from a file name took «supplement» out of «supplementary» and left «ary» behind. That fragment was then compared against every title in the library, which pushed the score below the threshold — so a supplement that says so in plain English was offered no parent at all."
                    )
                ),
            ]
        ),
        Release(
            version: "0.9.7",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "못 여는 파일이 왜 못 열리는지, 그 파일에 적힌 글자를 그대로 보여줘요. 그 화면에서 바로 폴더로 갈 수도 있고요.",
                "When a file will not open, the reader now shows the file's own first line — and offers to take you to the file."
            ),
            added: [],
            fixed: [
                Entry(
                    Text2("못 여는 파일이 제 이름을 말해요", "A file that will not open says what it is"),
                    Text2(
                        "논문이 안 열릴 때 파일의 첫 여덟 바이트를 16진수로 보여주고 있었어요. 스크린샷을 못 찍는 회사 컴퓨터에서 «3C 23 23 20 4E 41 53 32»를 전화로 불러 주셨는데, 그게 «<## NAS2»라는 건 손으로 풀어 본 뒤에야 알았어요. 이제 파일이 읽을 수 있는 글자로 시작하면 **그 첫 줄을 그대로** 보여줘요 — 한국어 안내문도요. 크기도 1 KB 미만이면 바이트로 적어요. 249바이트짜리 쪽지를 «0 KB»라고 하면 반올림처럼 읽히는데, 사실 그게 문제의 핵심이거든요. 그리고 그 화면에 «폴더에서 보기»가 생겼어요. 이 앱이 못 여는 파일은 회사가 등록해 둔 앱으로 열어보는 게 다음 수순이고, 거기는 폴더에서 가니까요.",
                        "When a paper would not open, the reader showed the file's first eight bytes as hex. Somebody on a company machine, where screenshots are not allowed, read them down a phone — 3C 23 23 20 4E 41 53 32 — and nobody could see that they spell «<## NAS2» until they were decoded by hand. If the file begins with readable characters, the reader now shows that first line as it stands, in whatever language it is written. The size is given in bytes below a kilobyte, too: a 249-byte note reported as 0 KB reads as a rounding error rather than as the thing that is wrong with it. And the screen now offers Show in Folder — when this app cannot open a file, the next thing to try is the reader your company registered, and that is reached from the folder."
                    )
                ),
            ]
        ),
        Release(
            version: "0.9.6",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "윈도우·리눅스에서 하이라이트가 글자를 따라가지 않던 것을 고쳤어요. 여러 줄을 칠하면 하나의 커다란 덩어리가 됐고, 칠한 자리의 글자가 아예 안 보였고, 칠하고 나면 논문이 1쪽으로 돌아갔어요. 세 가지 다 고쳤어요.",
                "On Windows and Linux, a highlight now follows the lines of the text. Marking several lines drew one long lozenge instead, the words underneath disappeared, and the paper jumped back to page one afterwards. All three are fixed."
            ),
            added: [],
            fixed: [
                Entry(
                    Text2("하이라이트가 줄을 따라가요", "A highlight follows the lines"),
                    Text2(
                        "여러 줄을 칠하면 줄마다 한 칸이 아니라 단 하나의 기다란 덩어리가 그려졌어요. 줄을 묶는 규칙이 이미 삼킨 것만큼 넓어져서, 글자보다 조금 큰 것 하나만 지나가면 — 수식이든, 제목이든, 스캔한 쪽의 글자든 — 거기서부터 끝까지 한 줄로 이어졌거든요. 실제로 재 봤더니 34줄이 5줄로, 참고문헌 8줄이 1줄로 묶였어요. 이제 줄은 처음 그 줄을 연 조각만 보고 묶여요.",
                        "Marking several lines drew one long lozenge rather than a band per line. The rule that grouped runs into lines widened as it swallowed them, so a single run a little taller than the text — a formula, a heading, a word off a scanned page — joined everything below it into one. Measured: thirty-four lines came back as five, and eight lines of a reference list as one. A line is now matched against the run that opened it and nothing else."
                    )
                ),
                Entry(
                    Text2("칠한 자리의 글자가 보여요", "The words show through"),
                    Text2(
                        "형광펜이 글자를 덮어서 칠한 줄을 읽을 수 없었어요. 곱하기로 그리고 있었는데 아래에 아무것도 없는 면 위에서 곱하면 그냥 불투명한 노란색이거든요 — 맥이 같은 자리에서 겪고 고쳐 둔 것과 같은 일이에요. 이제 표시는 제 면에 그려지고, 그 면이 쪽 위에 곱해져요.",
                        "The highlighter covered the words it marked. The colour was drawn with multiply onto a surface with nothing beneath it, which is simply opaque paint — the same thing the Mac ran into and fixed years ago. Marks now have a surface of their own that is multiplied onto the page."
                    )
                ),
                Entry(
                    Text2("글자를 고르는 자리가 글자와 맞아요", "Selecting text now matches the text"),
                    Text2(
                        "고르는 층의 글자 크기가 쪽의 배율을 못 받고 있었어요. 그래서 크기를 얼마로 요청하든 전부 같은 크기가 됐고 — 7pt도 14pt도 13px로요 — 글자는 제자리에 보이니까 아무도 몰랐지만, 고른 자리의 사각형은 전부 틀려 있었어요. 표시가 줄 간격보다 1.6배 높았던 것도, 쪽 밖으로 삐져나갔던 것도 여기서 나온 일이에요. 이제 줄마다 정확히 한 칸씩 칠해져요.",
                        "The text you select was laid out without the page's scale, so every run came out the same size — a 7pt footnote and a 14pt heading both at 13px. The words still sat in the right places, so nothing looked wrong, but every rectangle the selection produced was wrong. That is why a mark stood half again as tall as its line and why one could run off the edge of the page. Marking a paragraph now gives exactly one band per line of it."
                    )
                ),
                Entry(
                    Text2("칠하고 나서 1쪽으로 돌아가지 않아요", "Marking no longer sends you back to page one"),
                    Text2(
                        "표시를 저장하면 라이브러리 폴더의 파일이 바뀌고, 폴더가 바뀌면 창이 목록을 다시 읽어요. 그 다시 읽기가 논문이 놓인 자리를 통째로 새로 지었고, 스크롤 되는 칸은 문서에서 떼였다 붙으면 맨 위로 돌아가요. 그래서 9쪽에 표시를 하면 0.5초 뒤에 1쪽이었어요. 이제 배치가 실제로 바뀔 때만 다시 짓고, 다시 지을 때도 읽던 자리를 기억해요.",
                        "Saving a mark writes to the library folder, and a folder that changes makes the window re-read it. That re-read rebuilt the whole page area, and a scroll view taken out of the document comes back at the top — so a mark made on page nine left you on page one half a second later. The page area is now rebuilt only when the arrangement actually changes, and it puts each paper back where it was."
                    )
                ),
            ]
        ),
        Release(
            version: "0.9.5",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "윈도우·리눅스에 설정 화면이 생겼어요. 메뉴에 «설정…»은 처음부터 있었는데 그 뒤에 아무것도 없었고, 그래서 말을 바꿀 길이 아예 없었어요. 그리고 기록 하나가 늦게 도착하면 라이브러리 전체가 비어 보이던 것을 고쳤어요.",
                "The Windows and Linux build has settings. The menu has carried Settings… from the beginning with nothing behind it, which meant the language could not be changed at all. And one record arriving late no longer empties the whole library."
            ),
            added: [
                Entry(
                    Text2("설정 화면 (윈도우·리눅스)", "Settings, on Windows and Linux"),
                    Text2(
                        "메뉴의 «설정…»과 Ctrl+,는 처음부터 있었지만 눌러도 아무 일이 없었어요 — 창에 그 명령을 받는 자리가 없었고, 보여줄 화면도 없었거든요. 맥은 다른 앱이라 티가 안 났고요. 이제 도구 막대의 ⚙, 메뉴, Ctrl+, 세 갈래로 열려요. 라이브러리 폴더·쪽 배치·쪽 색조·화면 모드, 그리고 **말**이 있어요 — 말은 설정에 값은 있는데 바꿀 길이 없어서, 데스크톱이 영어면 한국어로 볼 방법이 없었어요.",
                        "Settings… and Ctrl+, have been in the menu from the beginning and did nothing: the window had no case for the command and no surface to show. On the Mac that went unnoticed, since the Mac is a different app. It opens three ways now — the ⚙ in the bar, the menu, and Ctrl+, — with the library folder, page layout, page tint, theme, and **the language**, which had a setting but no way to reach it: an English desktop meant no Korean, ever."
                    )
                ),
            ],
            fixed: [
                Entry(
                    Text2("늦게 온 기록 하나가 라이브러리를 비우지 않아요", "A record that is late costs one row, not the library"),
                    Text2(
                        "한 사람의 윈도우 라이브러리가 비어 보였어요. 폴더가 안 열린 것도, 권한 문제도 아니고 — 기록 파일 하나가 아직 내려오는 중이었는데 그게 나머지 논문을 전부 데려갔어요. 기록을 한꺼번에 읽다가 하나가 실패하면 전부 실패하는 모양이었고, 창은 아무 말도 없이 «폴더를 고르세요» 화면으로 떨어졌고요. 이제 못 읽은 기록은 그 줄 하나만 잃고, 창이 몇 개가 아직 안 왔는지 말하고 «다시 읽기»를 줘요.",
                        "Somebody's Windows library read as empty. Not a folder that would not open — one record file was still coming down, and it took every other paper with it. The records were read together, so one failure was all of them, and the window fell through to a first-run screen without a word. A record that will not read now costs its own row, and the window says how many have not arrived and offers to try again."
                    )
                ),
            ]
        ),
        Release(
            version: "0.9.3",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "폴더가 많아지면 사이드바가 먼저 무너져요. 이제 라이브러리를 누르면 그 안이 열리고, 한 번에 한 갈래만 보여요. 강의자료도 제 종류가 됐고요. 그리고 윈도우·리눅스에서 하위 폴더의 논문이 아예 안 보이던 것을 고쳤어요.",
                "A sidebar gives out before a library does. Press a library now and it opens, showing one path at a time. Course material is its own kind. And on Windows and Linux, a paper filed in a subfolder simply did not exist — that is fixed."
            ),
            added: [
                Entry(
                    Text2("라이브러리가 열려요", "The libraries open"),
                    Text2(
                        "폴더를 여럿 열 수 있게 되자 사이드바가 길어지기만 했어요. 한 학기를 폴더로 나눠 두면 논문보다 폴더가 먼저 스무 개가 되니까요. 이제 라이브러리를 누르면 나머지는 물러나고 그 안의 폴더들이 들여쓰여 서요. 폴더를 누르면 또 그 안이 열리고, 목록에는 그 아래의 논문이 전부 나와요. 나가는 길은 지금 눌린 그 줄이에요 — 한 번 더 누르면 한 단계 위로, 맨 위에서 누르면 «모두»로요.",
                        "Opening several folders only made the sidebar longer, and somebody filing a term has twenty folders before they have twenty papers. Press a library now and the others step aside while its own folders appear, indented. Press one of those and it opens in turn, with every paper beneath it in the list. The way back out is the row you are on: press it again to go up a level, and once more at the top to reach All."
                    ),
                    demo: .folderTree
                ),
                Entry(
                    Text2("강의자료", "Course material"),
                    Text2(
                        "한 학기는 슬라이드와 노트와 강의계획서 서른 개예요. 일반 문서에 넣어 두면 계약서와 매뉴얼 사이에 섞여요. 이제 네 번째 종류이고, 앱이 먼저 짐작해요 — 쪽이 가로로 넓으면(종이로 읽으라고 만든 건 가로가 아니에요) 또는 이름이 강의를 가리키면요. 인용은 하지 않아요.",
                        "A term is thirty decks, notes and a syllabus. Left as documents they sit among the contracts. It is the fourth kind now, and the app guesses it: pages wider than they are tall — nothing meant to be read on paper is — or a name that names a course. It is read, not cited."
                    ),
                    demo: .kindQuestion
                ),
                Entry(
                    Text2("어느 폴더에서 왔는지", "Which folder each came from"),
                    Text2(
                        "논문이나 강의자료를 누르면 모든 폴더의 것이 한 줄로 이어져 나왔어요. 예순 줄이 어느 학기 것인지 알 수가 없었고요. 이제 폴더마다 제 이름이 그 위에 서요.",
                        "Pressing Papers or Course gathers from every folder at once, and the rows arrived in one undivided run. Each folder's name now sits over its own papers."
                    )
                ),
            ],
            fixed: [
                Entry(
                    Text2("하위 폴더의 논문이 보여요", "A paper in a subfolder is a paper"),
                    Text2(
                        "윈도우와 리눅스는 라이브러리 폴더를 한 층만 읽고 있었어요. 하위 폴더에 넣어 둔 논문은 맥에서는 논문이고 거기서는 존재하지 않았어요 — 게다가 아무 말도 없이요. 실제 폴더로 재보니 옛 코드가 0편, 지금이 390편이에요. 클라우드 파일이 아직 안 내려왔을 때 «파일 아님»으로 건너뛰던 것도 같이 고쳤어요.",
                        "Windows and Linux read the library folder one level deep, so a paper filed in a subfolder was a paper on the Mac and did not exist there — silently. Measured on a real folder: 0 papers before, 390 now. A cloud file that has not been fetched is no longer skipped as though it were not a file."
                    )
                ),
                Entry(
                    Text2("안 열리는 PDF가 왜인지 말해요", "A PDF that will not open says why"),
                    Text2(
                        "«파일이 깨졌을 수 있어요» 한 마디로 네 가지를 덮고 있었어요. 아직 안 내려온 파일, 빈 자리표시자, PDF 이름을 단 웹 페이지, 회사가 감싼 파일이 전부 같은 말을 들었어요. 이제 갈라 말하고, 첫 여덟 바이트를 같이 보여줘요 — 스크린샷 한 장이 진단이 되게요.",
                        "One sentence covered four different things: a file still arriving, an empty placeholder, a web page wearing a .pdf name, and a file a company wrapped. They are told apart now, and the first eight bytes are shown with the sentence — so a screenshot is a diagnosis."
                    )
                ),
                Entry(
                    Text2("열린 문서", "Open Documents"),
                    Text2(
                        "선반 이름이 «열린 논문»이었는데, 0.9.0부터 논문만 있는 게 아니었어요.",
                        "The shelf was called Open Papers, and it has held more than papers since 0.9.0."
                    )
                ),
                Entry(
                    Text2("저자는 접혀서 시작해요", "The names start folded"),
                    Text2(
                        "이름 쉰 개가 사이드바에서 제일 긴 줄이었고 그래프를 아래로 밀어내고 있었어요. 펴 두면 그대로 기억해요.",
                        "Fifty names was the longest run in the sidebar and it pushed the graph off the bottom. Opened, it stays open."
                    )
                ),
            ]
        ),
        Release(
            version: "0.9.2",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "여는 데 걸리던 시간이 대부분 없어졌어요. 앱의 움직임도 한 벌로 맞췄고요 — 같은 크기의 변화는 어디서나 같은 속도예요. 그리고 책이 논문도 일반 문서도 아닌 제 종류가 됐어요. 이제 베타예요.",
                "Most of the wait at launch is gone, and the app moves as one thing now: the same size of change takes the same time everywhere. A book is also its own kind at last, neither a paper nor a document. This is the first beta."
            ),
            added: [
                Entry(
                    Text2("빨리 열려요", "It opens"),
                    Text2(
                        "라이브러리를 여는 데 2초가 걸리고 있었어요. 폴더가 클라우드에 있으면 앱이 그 안을 통째로 걸어 다니면서 파일마다 «다 왔나요»를 물었는데, 정작 기다리던 파일은 이미 와 있었어요. 폴더를 여러 개 열어 뒀으면 시작할 때 라이브러리를 폴더 수만큼 읽기도 했고요 — 셋이면 세 번, 그중 둘은 버리면서요. 노트를 읽을 때마다 옛날 노트 이사 작업이 처음부터 다시 돌기도 했어요. 전부 한 번씩만 하도록 고쳤어요.",
                        "Opening a library took two seconds. With the folder in a cloud drive the app walked all of it, asking every file whether it had arrived — to hurry along one file that was already there. With several folders open it then read the whole library once per folder, throwing away all but the last. And every read of the notes started the old note migration again from nothing. Each of those now happens once."
                    ),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("목록이 손에 붙어요", "The lists answer the hand"),
                    Text2(
                        "논문을 하나 고르면 창의 목록들을 통째로 다시 그리고 있었어요 — 선반 이백 줄과 논문 예순 줄을, 아이콘까지 새로 그려서요. 이제 바뀐 줄만 고쳐요. 선반의 숫자도 줄마다 라이브러리를 한 바퀴 도는 대신 한 번에 다 세고요. 칸 사이 구분선을 끌 때 창 전체를 다시 배치하던 것도 고쳤어요.",
                        "Choosing a paper redrew every list in the window — two hundred shelf rows and sixty paper rows, icons and all. Now only the rows that changed are touched, the shelves count themselves in one pass instead of one walk of the library per row, and dragging a divider moves the one column rather than laying out the whole window sixty times a second."
                    ),
                    devices: [.mac]
                ),
                Entry(
                    Text2("움직임이 한 벌이에요", "One set of speeds"),
                    Text2(
                        "여기저기 손으로 적은 속도가 열일곱 가지 있었어요. 그래서 포인터 밑에서 칩이 켜지는 것과 칸 하나가 통째로 들어오는 것이 같은 속도로 움직였어요. 이제 사다리가 하나예요 — 창의 얼마가 움직이는지로 고르고, 곡선은 하나예요. 시스템 설정에서 «동작 줄이기»를 켜두면 따라요: 변화는 그대로 일어나되 아무것도 미끄러지거나 튕기지 않아요.",
                        "There were seventeen hand-written durations, so a chip lighting under the pointer moved at the same speed as a whole column arriving. Now there is one ladder — chosen by how much of the window moves — and one curve. If you have asked the system for less motion, it listens: things still change, but nothing travels or overshoots."
                    ),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("환영 화면은 한 번에 하나씩", "One feature at a time"),
                    Text2(
                        "이 화면이 스무 가지를 한 줄로 세워 놓은 목록이었어요. 목록은 아무도 안 읽어요. 이제 한 번에 하나씩 보여줘요 — 큰 카드 안에 실물이 있고, 그 아래 이름과 한 문장이 있고, 좌우 화살표나 ← → 키로 넘겨요.",
                        "This screen was twenty things in a column, which is a list, and nobody reads a list of twenty. It shows one at a time now: the thing itself in a card, its name and a sentence under it, and an arrow on each side — or the arrow keys."
                    )
                ),
                Entry(
                    Text2("책은 이제 책이에요", "A book is a book now"),
                    Text2(
                        "PDF가 무엇인지 묻는 자리에 «책»이 생겼어요. 교과서를 논문이라고 하면 같은 제목의 학술지 논문에 잘못 붙어서 «권 9, 호 5, 1054–1054쪽» 같은 게 돼요. 그렇다고 일반 문서라고 하면 인용을 아예 못 하고요. 책이라고 하면 출판사·펴낸 곳·판·ISBN을 물어보고, 학술지 칸은 아예 없애요. BibTeX에는 @book으로 나가고, 인용 키도 그대로 있어요. 쪽이 아주 많고 뒤에 참고문헌이 있으면 앱이 먼저 책이라고 짐작해 둬요. 라이브러리에 책이 있으면 사이드바에 «책» 선반이 생기고요.",
                        "The question about what a PDF is has a third answer. Call a textbook a paper and it gets matched to a journal article of the same name — volume 9, issue 5, pages 1054–1054 — and call it a document and you cannot cite it at all. Called a book it is asked for a publisher, a place, an edition and an ISBN, and the journal's fields go away entirely. It exports as @book and keeps its citation key. A file hundreds of pages long with a reference list at the back is guessed to be one. A library that holds books grows a Books shelf."
                    ),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("설명서가 생겼어요", "There is a manual"),
                    Text2(
                        "배포 페이지에 설명서를 뒀어요. 폴더를 고르는 것부터 표시, 그리기, 노트, 서지, 단축키까지 — 설명마다 눌러볼 수 있는 실물이 붙어 있어요. 글로만 읽는 설명서가 아니에요.",
                        "The download page now has one: choosing the folder, marking, drawing, notes, records, the keys. Every explanation that can be shown is shown — the same working pieces, in the paragraph that is talking about them."
                    ),
                    devices: [.mac, .ipad, .iphone]
                ),
            ],
            fixed: [
                Entry(
                    Text2("쓰던 글자가 사라지지 않아요", "What you were typing stays"),
                    Text2(
                        "인스펙터에서 제목을 고치는 중에 라이브러리에 아무 변화나 생기면 — 다른 줄의 별을 눌러도 — 칸이 통째로 다시 그려지면서 쓰던 글자가 사라졌어요. 윈도우·리눅스 빌드의 일이에요.",
                        "Typing in a field of the inspector, anything at all happening in the library — a star pressed on another row was enough — rebuilt the field and took the half-written title with it. This was the Windows and Linux build."
                    )
                ),
            ]
        ),
        Release(
            version: "0.9.1",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "라이브러리를 여러 개 열어 둘 수 있어요. 사이드바 맨 위의 «라이브러리»에서 하나씩 들어가 보고, 더 이상 안 볼 폴더는 연결을 해제하면 돼요. 폴더마다 제 노트·태그·컬렉션을 제 안에 갖고 있어요.",
                "The library can read several folders at once. The Libraries section at the top of the sidebar goes into one at a time, and a folder you are done with is disconnected. Each folder keeps its own notes, tags and collections inside it."
            ),
            added: [
                Entry(
                    Text2("라이브러리를 여러 개", "Several libraries at once"),
                    Text2(
                        "사이드바 맨 위 «라이브러리»에서 «라이브러리 더하기…»로 폴더를 하나 더 열어요. 그 폴더의 PDF가 같은 목록에 함께 보이고, 이름을 누르면 그 폴더만 봐요. 파일은 아무것도 옮기지 않아요 — 폴더마다 제 .papertime을 그대로 갖고 있어서, 연결을 해제하면 그 폴더는 있던 그대로 남아요. 논문을 더하면 지금 보고 있는 폴더로 들어가요.",
                        "Add one under Libraries at the top of the sidebar. Its PDFs join the same list, and clicking its name shows only that folder. Nothing is moved: each folder keeps its own .papertime beside its own files, so disconnecting one leaves it exactly as it was. A paper added while a folder is showing goes into that folder."
                    )
                ),
                Entry(
                    Text2("노트·태그·컬렉션도 그 폴더 안에", "Notes, tags and collections live in their folder"),
                    Text2(
                        "논문에 대해 쓴 노트는 그 논문이 있는 폴더에 써요. 태그와 컬렉션도 그 이름을 입은 논문이 있는 폴더마다 적어 두고요. 그래서 폴더 하나를 다른 컴퓨터로 가져가면 표시도 필기도 노트도 태그도 그대로 딸려 가고, 여기서 연결을 해제하면 그 폴더의 것만 목록에서 빠져요. 같은 이름을 두 폴더가 쓰면 목록에는 한 줄로 보여요. 논문 없이 쓴 노트 — 그냥 떠오른 생각, 지도, 초안 — 는 갈 폴더가 없으니 앱이 제 폴더에 따로 둬요. 예전에 첫 폴더에 모여 있던 노트는 열 때 제자리로 옮겨 가요.",
                        "A note about a paper is written in the folder that paper is in. A tag or a collection is written in every folder whose papers wear it. So a folder carried to another machine arrives whole — marks, handwriting, notes, tags — and disconnecting one here takes only its own. A name two folders use shows once. A note about no paper — a loose thought, a map, a draft — has no folder to belong to, so the app keeps it in a folder of its own. Notes that used to sit in the first folder move where they belong the next time the library opens."
                    )
                ),
                Entry(
                    Text2("파일 이름을 여기서 고쳐요", "Rename the file from here"),
                    Text2(
                        "인스펙터의 «파일» 칸에 이름을 적고 Return을 누르면 디스크의 PDF 이름이 바뀌어요. 라이브러리는 사람이 이름 붙인 PDF들의 폴더니까, 앱에서 보는 이름과 Finder에서 보는 이름은 같은 이름이어야 하니까요. «.pdf»는 안 적어도 붙여 줘요. 표시·필기·노트는 논문의 번호를 따라다녀서 하나도 안 움직여요.",
                        "Type a name in the File field of the inspector and press Return: the PDF is renamed on disk. The library is a folder of PDFs under the names you gave them, so the name in the app and the name in Finder should be the same name. Leave the .pdf off and it is kept for you. Marks, handwriting and notes follow the paper's identifier, so none of them move."
                    )
                ),
                Entry(
                    Text2("선반은 세 묶음으로", "The shelves in three groups"),
                    Text2(
                        "사이드바의 선반이 세 가지를 물어요 — 무엇인지(모두·논문·문서), 얼마나 읽었는지(안 읽음·읽는 중·읽음), 내가 뭘 했는지(즐겨찾기·살펴볼 것·열린 논문). 이제 그 셋 사이에 여백이 있어요. 아홉 줄이 한 줄로 이어져 있으면 찾는 하나를 고르려고 아홉 줄을 다 읽게 되니까요.",
                        "The shelves answer three questions — what a thing is, how far through it you are, and what you did about it — and there is now air between the three. Nine rows in one run meant reading all nine to find the one you wanted."
                    )
                ),
                Entry(
                    Text2("연결 해제", "Disconnect a folder"),
                    Text2(
                        "폴더 이름을 오른쪽 클릭해서 «연결 해제»예요. 목록에서 그 폴더의 논문이 빠질 뿐, 파일도 기록도 그대로예요. 다시 열고 싶으면 «라이브러리 더하기…»로 같은 폴더를 다시 고르면 표시와 필기와 노트까지 그대로 돌아와요.",
                        "Right-click a folder's name and choose Disconnect. Its papers leave the list; the files and their records stay where they are. Add the same folder again and everything — marks, handwriting, notes about it — is back."
                    )
                ),
            ],
            fixed: []
        ),
        Release(
            version: "0.9.0",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "논문만이 아니라 모든 PDF를 위한 앱이 됐어요. 새 PDF에는 먼저 논문인지 일반 문서인지 물어보고, 답에 따라 정보 칸이 바뀌어요. 차례가 없는 문서는 쪽 그림으로 넘겨요.",
                "Not only papers now. A new PDF is asked what it is — a paper or a document — and the fields follow the answer. A document with no headings is turned by the look of its pages."
            ),
            added: [
                Entry(
                    Text2("논문인지 먼저 물어봐요", "It asks what the PDF is"),
                    Text2(
                        "새 PDF를 더하면 인스펙터가 먼저 물어요 — 논문인가요, 일반 문서인가요. 앱이 먼저 짐작해서 하나를 골라 두고요(안에 DOI나 참고문헌이 보이면 논문). 논문이라고 하면 서지를 찾아 채우고 비슷한 후보를 보여줘요. 일반 문서라고 하면 학술지·권·호·DOI·인용 키 같은 칸이 사라지고, 펴낸 곳·해·종류·파일처럼 문서에 있는 것만 남아요. 논문이 아닌 PDF는 등록기관에 묻지도 않아요 — 계약서 제목을 밖으로 보낼 일이 없어요. 한 번 답하면 그 질문은 사라져요. 잘못 눌렀으면 도구 막대의 ⋯ 메뉴나 목록의 오른쪽 클릭 메뉴에서 바꾸면 돼요.",
                        "Add a PDF and the inspector asks first: a paper, or a document? The app has already guessed one of them — a DOI or a reference list inside means a paper. Say paper and it looks the record up and offers the near matches, as before. Say document and the journal, volume, issue, DOI and citation key go away, leaving what a document actually has: where it came from, its year, its kind, its file. A PDF that is not a paper is never looked up online, so a contract's title never leaves the machine. Answered once, the question goes away. Pressed the wrong one? Change it from the ⋯ menu in the toolbar, or from the row's own menu."
                    ),
                    demo: .kindQuestion, featured: true
                ),
                Entry(
                    Text2("쪽 그림으로 넘겨요", "Turn by the look of the pages"),
                    Text2(
                        "차례(⇧⌘L)에 '쪽' 칸이 생겼어요. 모든 쪽을 작게 늘어놓고, 누르면 그 쪽으로 가요. 지금 보는 쪽에는 테두리가 있어요. 제목을 찾지 못한 PDF — 스캔한 계약서나 '1장'만 반복되는 안내서 — 는 이 칸으로 바로 열려요. 윈도우·리눅스에서도 같은 키예요.",
                        "The contents (⇧⌘L) has a Pages tab: every page, small, and a click goes there. The page you are on is ringed. A PDF whose headings could not be read — a scanned contract, a handbook whose every heading is \"Chapter 7\" — opens straight to it. Same key on Windows and Linux."
                    )
                ),
                Entry(
                    Text2("문서와 논문을 나눠서 봐요", "Papers and documents, side by side in the shelf"),
                    Text2(
                        "라이브러리에 둘 다 있으면 사이드바에 '논문'과 '문서' 줄이 생겨요. 논문만 있는 라이브러리는 예전 그대로예요. '살펴볼 것'에는 논문만 올라와요 — 등록기관이 문서에 대해 할 말은 없으니까요.",
                        "Once a library holds both, the sidebar gets a Papers row and a Documents row. A library of nothing but papers looks exactly as it did. Needs Review holds only papers now: no registrar has an opinion about a manual."
                    )
                ),
            ],
            fixed: []
        ),
        Release(
            version: "0.8.3",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "PC에서 더한 논문이 맥에서 안 보이던 것을 고쳤어요. 그리고 폴더를 앱에 끌어다 놓으면 그 폴더가 라이브러리가 돼요 — Google Drive 폴더도요.",
                "A paper added on a PC was invisible on the Mac; that is fixed. And a folder dropped on the app becomes the library — a Google Drive folder too."
            ),
            added: [
                Entry(
                    Text2("폴더를 끌어다 놓으면 열려요", "Drop a folder and it opens"),
                    Text2(
                        "Finder에서 폴더를 Paper Time 아이콘이나 창에 끌어다 놓으면 그 폴더가 라이브러리가 돼요. PDF를 끌어다 놓으면 지금 라이브러리에 들어가고요. Google Drive나 Dropbox 폴더처럼 앱이 혼자서는 못 들어가는 자리도 이렇게 건네주면 열려요 — 다음부터는 앱이 알아서 기억해요.",
                        "Drag a folder from the Finder onto Paper Time's icon or window and it becomes the library. Drag a PDF and it joins the library that is open. A folder the app cannot reach on its own — one in Google Drive or Dropbox — opens this way too, and is remembered from then on."
                    )
                ),
            ],
            fixed: [
                Entry(
                    Text2("PC에서 더한 논문이 맥에서 안 보였어요", "A paper added on a PC was invisible on the Mac"),
                    Text2(
                        "윈도우·리눅스가 쓴 기록에 날짜 한 칸이 비어 있었고, 맥은 그 기록을 읽다 실패했어요. 읽히지 않는 기록은 논문이 아니라서, PDF가 든 폴더 옆에 빈 서가가 보였어요 — 오류 하나 없이요. 이제 양쪽이 같은 칸을 쓰고, 맥은 칸이 비어 있어도 논문을 잃지 않아요. 이미 만들어진 라이브러리도 그대로 열려요.",
                        "The Windows and Linux build left one date out of a record, and the Mac failed to read it. A record that will not read is not a paper, so the Mac showed an empty shelf beside a folder full of PDFs — with no error at all. Both builds now write the field, and the Mac no longer loses a paper over a missing one. Libraries already made open as they are."
                    )
                ),
            ]
        ),
        Release(
            version: "0.8.2",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "잠긴 PDF가 빈 화면으로 남지 않아요. 암호가 걸렸으면 물어보고, 회사가 보호한 파일이면 그렇다고 말해요.",
                "A locked PDF no longer sits on a blank page. If it wants a password, Paper Time asks; if a company locked it, Paper Time says so."
            ),
            added: [
                Entry(
                    Text2("암호가 걸린 PDF를 열어요", "Open a PDF that wants a password"),
                    Text2(
                        "암호를 묻는 칸이 쪽 자리에 떠요. 넣으면 열리고, 틀리면 다시 물어요. 암호는 어디에도 저장하지 않아요 — 파일을 여는 데 한 번 쓰고 잊어요.",
                        "A field appears where the page would be. Type the password and it opens; get it wrong and it asks again. The password is stored nowhere — it opens the file once and is forgotten."
                    )
                ),
            ],
            fixed: [
                Entry(
                    Text2("잠긴 PDF가 아무 말 없이 빈 화면이었어요", "A locked PDF was a blank page with no message"),
                    Text2(
                        "암호가 걸린 파일을 누르면 쪽이 영원히 비어 있었어요. 오류도, 안내도 없이요 — 안에서는 암호를 기다리고 있었는데 물어보는 창이 없었거든요. 회사 권한 서비스(Microsoft Purview 같은)가 잠근 파일은 더 나빴어요: 윈도우·리눅스에서는 요청이 조용히 실패했고, 맥은 열린 척하며 암호문을 그렸어요. 이제 셋 다 무엇이 막고 있는지 이름을 대고 말해요.",
                        "Clicking a password-protected file left the page empty for good — no error, no notice. Inside, it was waiting for a password nobody was asking for. A file locked by a rights service such as Microsoft Purview was worse: on Windows and Linux the request failed silently, and on the Mac it pretended to open and drew the cipher. All three now name what is in the way and say it."
                    )
                ),
                Entry(
                    Text2("잠긴 PDF의 제목이 깨진 글자였어요", "A locked PDF was listed under broken letters"),
                    Text2(
                        "잠긴 파일에서 제목을 읽으면 암호문이 나와요. 목록에 \"OìáCµC˘-Ü˘°\" 같은 줄이 생겼어요. 이제 잠긴 파일은 파일 이름 그대로 목록에 들어가요.",
                        "Reading a title out of a locked file gives cipher, and the library got a row called \"OìáCµC˘-Ü˘°\". A locked file now keeps the name of the file it came from."
                    )
                ),
            ]
        ),
        Release(
            version: "0.8.1",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "다크 모드에서 패널이 창 바닥보다 밝아서 흰 글자가 잘 안 보였어요. 이제 읽는 자리가 창에서 가장 어두워요.",
                "In dark mode the panels came out paler than the ground behind them, and white text sat on light grey. The surface you read on is now the darkest thing in the window."
            ),
            added: [],
            fixed: [
                Entry(
                    Text2("다크 모드에서 패널이 너무 밝았어요", "Panels were too light in dark mode"),
                    Text2(
                        "유리의 몸통이 밝든 어둡든 흰색이라, 어두울 때 목록·논문·인스펙터가 뒤의 바닥보다 밝게 나왔어요. 다크 모드는 라이트 모드를 낮춘 것이 아니에요. 이제 패널이 창에서 가장 어둡고, 바닥이 그보다 밝아요. 작은 컨트롤만 흰 몸통을 그대로 써요 — 패널 위에 얹힌 것이라 떠 보여야 하거든요. 윈도우·리눅스도 같아요.",
                        "The glass body was white however the window was dressed, so in the dark the list, the paper and the inspector came out paler than the ground behind them. Dark mode is not light mode turned down. The panels are now the darkest thing in the window and the ground is what is lighter. Only a small control keeps a white body, because it lies on a pane and has to read as raised from it. Windows and Linux match."
                    )
                ),
            ]
        ),
        Release(
            version: "0.8.0",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2(
                "그리기가 Figma처럼 됐어요. 프레임·묶음·오토 레이아웃, 사이드바의 Tools 탭, 종이 위에 바로 쓰는 글, 카드 안의 수식. 논문을 나란히 넷까지 열고, 다크 모드에서도 논문이 잘 보여요.",
                "Drawing works the way Figma does: frames, groups and auto layout, a Tool tab in the inspector, text typed straight onto the page, formulas in a card. Up to four papers open side by side, and a paper reads well in dark mode."
            ),
            added: [
                Entry(
                    Text2("프레임·묶음·오토 레이아웃", "Frames, groups, auto layout"),
                    Text2(
                        "F로 프레임을 그리면 그 안에 있던 것들이 자식으로 들어가요. ⌘G로 묶고, ⇧⌘G로 풀어요. 프레임을 골라 ⇧A를 누르면 자식들이 줄이나 열로 정렬되고, 간격과 여백은 숫자로 정해요. 한 카드에 글을 더 쓰면 옆 카드가 비켜 앉아요. 묶음은 한 번에 잡히고, 두 번 누르면 안으로 들어가요. 프레임에는 이름이 붙고, 넘친 내용은 숨길 수 있어요. 아래에서 흐름을 바꿔 보세요.",
                        "Draw a frame with F and whatever was inside becomes its child. Group with ⌘G, ungroup with ⇧⌘G. Select a frame and press ⇧A: its children line up in a row or a column, with a gap and a padding you set as numbers. Type more into one card and its neighbours make room. A group is picked up whole; double-click to go inside it. A frame has a name, and can hide what spills past its edge. Change the flow below."
                    ),
                    action: .draw, demo: .frames, featured: true
                ),
                Entry(
                    Text2("Tools 탭", "The Tools tab"),
                    Text2(
                        "그린 것의 인스펙터가 오른쪽 사이드바의 네 번째 탭이 됐어요. Info, Marks, Notes, Tools. 펜을 들면 Tools 탭이 앞으로 와요. 위치(정렬 여섯 가지, X와 Y), 레이아웃(W와 H, 흐름, 간격, 여백), 외형(투명도, 모서리 반경), 채우기와 외곽선(색상 패널, hex, %), 글(글꼴, 크기, 정렬, 자동 너비와 자동 높이). 여러 개를 고르면 서로 맞추고, 하나면 프레임이나 쪽에 맞춰요. 탭 이름 넷은 어느 언어에서도 영어예요.",
                        "The inspector for what you draw is the fourth tab of the window's inspector: Info, Marks, Notes, Tools. Taking the pencil out brings Tools forward. Position, with six alignments and X and Y. Layout, with W and H, flow, gap and padding. Appearance, with opacity and corner radius. Fill and Stroke, with the colour panel, a hex and a percentage. Text, with font, size, alignment, auto width and auto height. Several things align to each other; one thing aligns to its frame, or to the page."
                    ),
                    action: .draw
                ),
                Entry(
                    Text2("그린 것을 누르면 펜이 나와요", "Click a drawing and the pencil comes out"),
                    Text2(
                        "읽는 중에 도형이나 카드나 손글씨를 누르면 그 자리에서 펜이 켜지고 그것이 골라져요. 끝 단추는 없어요. esc나 제목 줄의 펜으로 내려놓아요.",
                        "Reading, click a shape, a card or a stroke and the pencil is out with that thing selected. There is no Done button; Escape or the pencil on the title row puts it away."
                    ),
                    action: .draw
                ),
                Entry(
                    Text2("카드 안의 수식과 글꼴", "Formulas and fonts in a card"),
                    Text2(
                        "카드에 $E = mc^2$처럼 쓰면 노트와 같은 조판으로 수식이 그려져요. 글꼴은 Tools 탭에서 이 맥에 있는 것 중에 골라요. 수식은 맥에서 그려지고, 윈도우와 리눅스에서는 쓴 대로 보여요.",
                        "Write $E = mc^2$ in a card and it is set as mathematics, the same setting a note gets. The font is chosen in the Tool tab from what this Mac has. Formulas are drawn on the Mac; Windows and Linux show them as typed."
                    ),
                    action: .draw
                ),
                Entry(
                    Text2("글은 종이 위에 바로", "Text, typed on the page"),
                    Text2(
                        "T로 누르면 그 자리에 커서가 서고, 쓰는 대로 종이 위에 글자가 보여요. 입력 상자 같은 배경은 없어요. 글이 길어지면 카드가 옆으로 자라요. T로 끌어서 너비를 정하면 그 안에서 줄이 바뀌어요.",
                        "Press T and a caret appears where you clicked. The words show on the page as you type, in their own face and colour, with no field around them. The card grows with its words. Drag with T to set a width, and the lines wrap inside it."
                    ),
                    action: .draw
                ),
                Entry(
                    Text2("다른 쪽으로 끌어 옮기기", "Drag to another page"),
                    Text2(
                        "고른 것을 다음 쪽까지 끌고 가면 거기에 놓여요. 손글씨도 같이 가요. ⌘Z 한 번이면 두 쪽이 함께 돌아와요.",
                        "Drag a selection onto the next page and it lands there, handwriting included. One ⌘Z brings both pages back."
                    ),
                    action: .draw
                ),
                Entry(
                    Text2("도구 줄", "The tool rack"),
                    Text2(
                        "Figma의 도구 줄처럼 다섯 단추예요. 선택, 프레임, 도형, 펜, 글. 아이콘도 Figma의 선 굵기로 그렸고, 고른 도구는 파란 칸에 흰 아이콘이에요. 도형과 펜은 옆 화살표에서 종류를 골라요. 한 글자 키는 그대로예요. 프레임에 무엇을 끌어 넣으면 그 프레임의 테두리가 켜지고, 프레임 안의 것을 고르면 그 프레임 이름이 파랗게 보여요.",
                        "Five buttons, as in Figma: Select, Frame, a shape, the pen, Text. The icons are drawn in Figma's line weight, and the chosen tool is a blue square with a white icon. The shapes and the pen tools open from the chevron beside them. Every one-letter key still works. Drag something over a frame and the frame's edge lights up; select something inside a frame and the frame's name turns blue."
                    ),
                    action: .draw
                ),
                Entry(
                    Text2("논문을 나란히", "Papers side by side"),
                    Text2(
                        "사이드바에 '열린 논문'이 생겼어요. 이 세션에서 연 논문들이 순서대로 있어요. 논문을 목록에서 끌어 쪽의 왼쪽이나 오른쪽에 놓으면 반씩, 네 귀에 놓으면 넷까지 나란히 열려요. 맥이 창을 화면 가장자리에 붙이는 것과 같아요. 우클릭 메뉴의 '나란히 열기'로도 돼요. 누른 칸이 지금 읽는 논문이고, Info·Marks·Notes는 그 논문 것이에요. 칸이 여럿이면 ⌘W가 그 칸만 닫아요. 목록 줄 앞의 핀을 누르면 열어 둔 논문이 되고, 읽기 상태는 별 옆으로 옮겼어요.",
                        "The sidebar has Open Papers: the papers opened this session, in order. Drag one onto the left or right of the page for halves, or into a corner for up to four at once — the way a Mac tiles a window dragged to the edge of the screen. Open Side by Side in the context menu does the same. The pane you click is the paper you are reading; Info, Marks and Notes are about it. ⌘W closes that pane while there are several. In the list, the pin at the head of a row keeps the paper open; the reading status moved beside the star."
                    )
                ),
                Entry(
                    Text2("열린 논문 팝업과 새 창", "The Open Papers popup, and a window of its own"),
                    Text2(
                        "⇧⌘O로 열린 논문 목록이 차례처럼 쪽 위에 떠요. 누르면 그 논문, ⌘클릭이면 새 창. 줄을 창 밖으로 끌어 놓으면 거기에 새 창이 생기고, 쪽의 가장자리에 놓으면 옆에 붙어요. 선반에 남는 것은 쓴 논문이에요. 목록을 훑어보기만 한 것은 '미리보기'로 잠깐 있다가 빠져요.",
                        "⇧⌘O brings the open papers up over the page, as the contents come. Click for that paper, ⌘-click for a new window. Drag a row off the window and a window opens where you let go; drag it to the page's edge and it docks beside. What stays on the shelf is what you used; a paper only glanced at from the list sits there as a preview and leaves with the next."
                    ),
                    action: .openPapers
                ),
            ],
            fixed: [
                Entry(
                    Text2("다크 모드에서 논문이 잘 안 보였어요", "Papers were hard to read in dark mode"),
                    Text2(
                        "Glass 색은 종이의 흰색을 뒤의 패널에 곱해서 지우는데, 어두운 패널 위에서는 글자까지 함께 사라져요. 다크 모드에서는 Glass가 흰 종이로 보여요. 유리는 창의 나머지에 남아요.",
                        "The Glass tint multiplies the paper's white into the panel behind it, and over a dark panel that took the letters with it. In dark mode Glass shows a white page; the glass stays on the rest of the window."
                    )
                ),
                Entry(
                    Text2("펜을 든 채로 핀치 줌이 안 됐어요", "Pinch to zoom did nothing with the pen out"),
                    Text2(
                        "PDFKit은 스크롤 뷰의 확대로 줌하는데, 그리기 층이 핀치를 PDF 뷰에 넘기고 있었어요. 이제 스크롤 뷰로 보내요.",
                        "PDFKit zooms with its scroll view's magnification, and the drawing layer was handing the pinch to the PDF view instead. It now goes to the scroll view."
                    )
                ),
            ]
        ),
        Release(
            version: "0.7.2",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("0.7.1에서 창이 비어 보이던 것을 고쳤어요.", "The empty window in 0.7.1 is fixed."),
            added: [],
            fixed: [
                Entry(
                    Text2("창이 텅 비어서 열렸어요", "The window opened empty"),
                    Text2(
                        "0.7.1에서 창 뒤에 깔아 둔 바탕이 앱을 통째로 덮어버렸어요. 그 바탕을 AppKit 쪽에서 창의 내용 뷰에 끼워 넣었는데, 그 안의 순서는 SwiftUI가 정하는 것이라 자리가 밀렸어요 — 디버그 빌드에서는 우연히 뒤에 남아 있었고, 배포 빌드에서만 앞으로 나왔고요. 이제 바탕이 SwiftUI 안에 들어가 있어서 순서가 더는 운에 달려 있지 않아요. 배포 빌드로 직접 확인했어요.",
                        "In 0.7.1 the backdrop meant to sit behind the window covered the whole app. It was inserted into the window's content view from AppKit, but the order inside that view is SwiftUI's to decide — in a debug build it happened to stay at the back, and only the release build moved it to the front. The backdrop now lives inside the SwiftUI tree, where the order is not a matter of luck, and this was checked in a release build."
                    ),
                    devices: [.mac]
                ),
            ]
        ),
        Release(
            version: "0.7.1",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("보내주신 네 가지를 고쳤어요.", "Four things you told us about."),
            added: [
                Entry(
                    Text2("그린 것을 다른 쪽으로 옮겨요", "Move a drawing to another page"),
                    Text2(
                        "고른 도형이나 손글씨를 ⌘C로 복사하고, 다른 쪽으로 가서 ⌘V로 붙이면 돼요. 같은 자리에 그대로 내려앉고, 같은 쪽에 붙이면 원래 것을 가리지 않게 조금 비켜서 놓여요. ⌘X로 잘라내기도 되고, 다른 논문에 붙여도 돼요.",
                        "Copy a selected shape or stroke with ⌘C, go to another page, and paste it with ⌘V. It lands at the same place; pasted back onto the page it came from it steps aside so it doesn't hide the original. ⌘X cuts, and it pastes into another paper too."
                    ),
                    devices: [.mac]
                ),
            ],
            fixed: [
                Entry(
                    Text2("글을 쓰기 시작하면 창이 까매졌어요", "The window went black when you started typing"),
                    Text2(
                        "창을 일부러 투명하게 두고 칸들만 그 위에 띄워 왔는데, 뒤에 아무것도 없는 창이었어요. 글상자가 뜨는 순간 그 주변이 전부 레이어로 바뀌면서, 아무것도 없던 자리가 까맣게 칠해졌어요. 이제 창에 진짜 바탕이 깔려 있어요 — 보이는 건 전과 같은데, 칠할 것이 생겼어요.",
                        "The window was deliberately left transparent, with the panels floating on it and nothing behind them. The moment a text box appears everything around it becomes layer-backed, and a layer-backed view with nothing behind it paints black. The window has a real backdrop now — it looks the same, and there is something there to draw."
                    ),
                    devices: [.mac]
                ),
                Entry(
                    Text2("첫 화면이 거의 보이지 않았어요", "The first screen was barely there"),
                    Text2(
                        "폴더를 고르는 첫 화면에는 칸이 하나도 없어서, 투명한 창 위에 글자만 떠 있었어요. 바탕화면이 그대로 비쳐서 읽기 어려웠고요. 읽는 창이 아닌 화면들은 이제 여느 맥 창처럼 제 바탕을 가져요.",
                        "The first screen has no panels of its own, so it was words on a transparent window with the desktop showing through. Every screen that is not the reader now has the background an ordinary Mac window has."
                    ),
                    devices: [.mac]
                ),
                Entry(
                    Text2("폴더 고르기를 눌러도 창이 안 떴어요", "Choose Folder opened nothing"),
                    Text2(
                        "첫 화면에서 폴더 고르기를 눌러도 아무 일도 없었어요. SwiftUI의 파일 고르기를 그 화면에서 띄운 탓인데, 0.4.x에서 도구 막대의 ＋가 한 번만 열리던 것과 같은 자리예요. 이제 맥의 열기 창을 직접 띄워요 — 설정에서도, 메뉴에서도, 옆 목록에서도 같은 문이에요.",
                        "Nothing happened when you pressed Choose Folder on the first screen — a SwiftUI file importer presented from a view that is itself being replaced never appears, the same failure the toolbar's ＋ had in 0.4.x. It opens AppKit's own panel now, from Settings and the menu and the sidebar alike."
                    ),
                    action: .addPapers,
                    devices: [.mac]
                ),
            ]
        ),
        Release(
            version: "0.7.0",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("이제 같이 만들어요.", "Now we build it together."),
            added: [
                Entry(
                    Text2("한마디 보내기 — 화면은 이미 찍혀 있어요", "Send feedback — the screenshot is already taken"),
                    Text2(
                        "⌥⌘/ 를 누르면 방금 그 화면이 이미 찍힌 채로 창이 열려요. 어디서 그랬는지 설명하지 않아도 되고, 논문에 쓰던 그 화살표와 네모로 바로 위에 표시하면 돼요. 남에게 보이면 안 되는 곳은 가리개로 덮으면 되고요. 함께 보내는 것은 전부 목록으로 보여줘요 — 버전이나 창 크기 같은 앱 이야기뿐이고, 논문 제목도 파일 경로도 쓰신 글도 가지 않아요. 보내기 전에 이 제보가 공개 목록의 어떤 줄이 될지도 미리 보여줘요.",
                        "Press ⌥⌘/ and the sheet opens with the screenshot already taken. You never have to explain where you were, and you mark it up with the same arrow and box you use on papers. Cover anything private with Hide. Everything that travels with the report is listed for you — the app's own version and window size, never a paper title, a path, or a word you wrote. Before you send, the sheet shows you the row it becomes on the public list."
                    ),
                    action: .feedback,
                    demo: .feedback
                ),
                Entry(
                    Text2("함께 만드는 중 — 고치면 체크가 돼요", "Built together — fixed things get a check"),
                    Text2(
                        "보내주신 것은 배포 페이지의 목록에 올라가고, 고쳐지면 체크 표시가 붙어요. 누르면 GitHub의 그 자리로 가니까 지어낸 표가 아니라는 걸 바로 확인할 수 있어요. 이름을 적으면 그 이름으로 올라가고, About에도 남아요.",
                        "What you send lands on a list on the download page, and gets a check when it is fixed. Click through and you land on it in GitHub, so none of it is decoration. Leave a name and it appears there — and in About, inside the app."
                    ),
                    demo: .together
                ),
                Entry(
                    Text2("쓰는 말에 따라 한국어로, 영어로", "Korean or English, whichever you read"),
                    Text2(
                        "시스템 언어가 한국어면 앱도 배포 페이지도 한국어로, 그 밖이면 영어로 나와요. 설정에서 직접 고를 수도 있어요. 맥과 윈도우와 리눅스 모두 같아요.",
                        "A Korean system gets Korean, everything else gets English — the app and the download page both. You can also pick one in Settings. The same on macOS, Windows and Linux."
                    ),
                    demo: .twoLanguages
                ),
            ],
            fixed: []
        ),
        Release(
            version: "0.5.0",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("라이브러리가 맥 밖으로 나갔다.", "The library leaves the Mac."),
            added: [
                Entry(
                    Text2("윈도우와 리눅스에서도 연다", "It opens on Windows and Linux too"),
                    Text2(
                        "같은 라이브러리 폴더를 윈도우와 리눅스에서도 연다. 하이라이트도, 밑줄도, 손글씨도, 도형과 화살표도 그대로 — 표시가 PDF 파일 안에 쓰이고 라이브러리는 그냥 폴더이기 때문이다. 계정도 서버도 내보내기도 없고, 클라우드 폴더든 USB든 파일이 닿는 곳이면 된다. 맥에서 그린 굽은 화살표가 PC에서 같은 곡선으로 열린다.",
                        "The same library folder opens on Windows and on Linux. The highlights, the underlines, the handwriting, the shapes and arrows — all of it, because the marks are written into the PDF and the library is only a folder. No account, no server, nothing exported: a cloud folder or a memory stick will do. A bent arrow drawn on the Mac opens on a PC with the same curve."
                    ),
                    demo: .crossPlatform
                ),
                Entry(
                    Text2("칸 단추가 둘씩 양쪽으로", "The pane buttons, two and two"),
                    Text2("넷이 한 덩어리로 붙어 있던 칸 단추를 양쪽으로 갈랐다 — 왼쪽에 사이드바와 논문 목록, 오른쪽에 논문과 인스펙터. 단추가 제가 여는 칸 쪽에 선다. 켜진 칸은 네모 바탕 대신 색으로만 말한다(네모 넷이 나란히 서면 한 덩어리로 읽혔다). 목록과 논문 아이콘도 칸의 모양이 보이는 것으로 바꿨다.", "The four pane buttons were one block; now they are two and two — sidebar and paper list at the left, paper and inspector at the right, each beside the pane it opens. A pane that is on says so with colour rather than a filled square: four squares in a row read as one block. The list and paper icons now look like the panes they open."),
                    action: .sidebar,
                    devices: [.mac]
                ),
            ],
            fixed: [
                Entry(
                    Text2("＋를 눌러도 아무것도 안 떴다", "The + button did nothing"),
                    Text2("도구 막대의 ＋가 처음 한 번만 열리고 그 뒤로는 눌러도 조용했다. SwiftUI의 파일 가져오기 시트를 도구 막대에서 띄운 탓이라, 여는 창을 직접 띄우도록 바꿨다. 이제 누를 때마다 뜬다.", "The toolbar's + opened once and was silent after that — a SwiftUI file importer presented from a toolbar fires once. It opens an open panel directly now, every time."),
                    action: .addPapers,
                    devices: [.mac]
                ),
                Entry(
                    Text2("뒤로·앞으로가 아무 데도 안 갔다", "Back and forward went nowhere"),
                    Text2("화살표가 PDF 안의 링크 기록에만 묶여 있어서, 논문 속 링크를 누른 적이 없으면 갈 곳이 없었다. 이제 브라우저처럼 연 논문들의 발자취를 따라간다 — 뒤로 간 뒤 새 논문을 열면 그 앞의 발자취는 잊고, 논문 안에서 참고문헌 링크를 눌러 이동했다면 먼저 그 자리로 돌아간다. 갈 곳이 없으면 흐리게 꺼진다.", "The arrows drove PDFKit's in-document link history, which is empty until a link has been followed. They now walk the trail of papers opened, browser-style: opening a paper after going back forgets what lay ahead, and a link followed inside a paper is stepped back through first. They grey out when there is nowhere to go."),
                    action: .back,
                    devices: [.mac]
                ),
            ]
        ),
        Release(
            version: "0.4.4",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("도구 막대가 조용해졌다.", "A quieter toolbar."),
            added: [
                Entry(
                    Text2("도구 막대 둘로", "The toolbar in two groups"),
                    Text2("열한 개가 한 줄로 서 있던 도구 막대를 둘로 나눴다. 왼쪽에는 사이드바와 뒤로·앞으로, 오른쪽에는 검색·추가, 세 칸 단추(목록·논문·인스펙터), 그리고 드물게 쓰는 것(동기화·정렬·쪽 배치·색조·공유)을 담은 메뉴 하나. 아이콘은 가늘게, 켜진 칸은 연한 바탕으로.", "Eleven icons in one row became two groups: at the left the sidebar and back/forward; at the right search, add, the three pane buttons (list, paper, inspector) and one menu for what is done rarely — sync, sort, page layout, tint, share. Thinner icons; a pane that is on gets a soft square behind it."),
                    devices: [.mac]
                ),
                Entry(
                    Text2("칸 단추 넷", "Four pane buttons"),
                    Text2("도구 막대의 '칸' 메뉴 하나가 단추 넷이 되었다 — 사이드바·논문 목록·논문·인스펙터. 각각 제 칸을 켜고 끄고, 켜진 것은 채워진 아이콘. 단추는 도구 막대에 남으니 닫은 칸을 다시 열 수 있다.", "The toolbar's one panes menu became four buttons — sidebar, paper list, paper, inspector. Each shows and hides its own pane, filled when on. They stay on the toolbar, so a closed pane can be opened again."),
                    action: .inspector,
                    devices: [.mac]
                ),
            ],
            fixed: [
                Entry(
                    Text2("스타일 패널 잘림", "The style panel was cut off"),
                    Text2("그리기의 스타일 패널이 폭이 고정되어 일곱째 채움 색이 반만 보였고, 글 도구의 긴 패널은 창 아래로 빠져나갔다. 이제 내용만큼 넓고, 창이 짧으면 안에서 스크롤된다.", "The drawing mode's style panel had a fixed width that cut the seventh fill colour in half, and the text tool's tall panel ran off the bottom of the window. It is now as wide as its rows and scrolls inside a short window."),
                    devices: [.mac]
                ),
            ]
        ),
        Release(
            version: "0.4.0",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("맥이 아이패드처럼 그린다 — 그리고 아이패드가 못 하던 것까지.", "The Mac draws like the iPad — and then some."),
            added: [
                Entry(
                    Text2("맥에서 그리기", "Drawing on the Mac"),
                    Text2("맥에는 그릴 길이 없었다 — 아이패드의 잉크를 보여 주기만 했다. 이제 ⇧⌘D(또는 제목 줄의 연필)로 펜을 들면 쪽 위에 도구 줄이 뜨고, 마우스·트랙패드·태블릿 펜으로 그린다(태블릿의 압력은 굵기에). 펜 선은 아이패드와 같은 잉크 사이드카로 들어가 세 기기가 같은 선을 본다. 형광펜은 글자에 맞춰 하이라이트·밑줄이 되고, 지우개는 선·도형·하이라이트를 함께 지운다. Esc는 선택을 놓고, 도구를 내리고, 펜을 내려놓는다 — 그 순서로.",
                          "The Mac had no way to draw — it only showed the iPad's ink. Now ⇧⌘D (or the pencil on the title row) takes the pencil out, a tool rack floats over the page, and the mouse, the trackpad or a tablet pen draws (a tablet's pressure sets the width). Pen strokes go into the same ink sidecar as the iPad's, so all three devices see one line. The highlighter fits the words into a highlight or an underline; the eraser takes strokes, shapes and highlights together. Escape lets go of the selection, then the tool, then the pencil — in that order."),
                    action: .draw,
                    demo: .sketch,
                    featured: true,
                    devices: [.mac]
                ),
                Entry(
                    Text2("도형·화살표·글 카드", "Shapes, arrows, text cards"),
                    Text2("Excalidraw와 XMind에서 좋은 것만: 네모(R)·동그라미(O)·화살표(A)·선(L)·글(T), 한 글자 키. 그린 뒤에는 선택(V)으로 돌아와 옮기고, 손잡이로 크기를 바꾸고, 화살표는 가운데 손잡이로 구부린다. 상자를 두 번 누르면 안에 글을 쓰고, 빈 곳을 두 번 누르면 글 카드가 생긴다 — 배경색과 테두리를 줄 수 있어 마인드맵의 토픽 상자가 된다. 손글씨도 골라서 옮길 수 있고, 무엇이든 골라 B를 누르면 둘레에 테두리(둥근 네모)가 둘러진다. ⇧-클릭으로 여럿, 빈 곳을 끌어 사각 선택, ⌘D 복제, ⇧⌘] / ⇧⌘[ 앞뒤, 화살표 키로 한 점씩(⇧면 열 점). 왼콽 패널: 선 색 7, 채움 6+없음, 굵기 3, 점선, 모서리, 화살표 끝 5종(양 끝 따로), 글자 크기 3, 투명도. 고른 것이 있으면 그것을 바꾸고 다음 것의 기본도 된다.",
                          "The good parts of Excalidraw and XMind: rectangle (R), ellipse (O), arrow (A), line (L), text (T), one letter each. Drawn, the pointer goes back to Select (V): move, resize by the handles, bend an arrow by its middle handle. Double-click a box to write in it; double-click empty paper for a text card — give it a background and a border and it is a mind map's topic box. Handwriting is selectable and movable too, and B frames whatever is selected in a rounded box. Shift-click for several, drag empty paper for a marquee, ⌘D duplicates, ⇧⌘] / ⇧⌘[ reorder, the arrow keys nudge a point (ten with Shift). The panel on the left: 7 stroke colours, 6 fills and none, 3 widths, dash, corners, 5 arrowheads set per end, 3 text sizes, opacity. With something selected a change applies to it and becomes the default for the next."),
                    devices: [.mac]
                ),
                Entry(
                    Text2("도형은 PDF에도, 사이드카에도", "Shapes in the PDF, and beside it"),
                    Text2("도형은 쪽마다 사이드카(`sketch/pNNNN.json`)가 진실이고 iCloud Drive로 다른 기기에 간다; PDF에는 저장 때 표준 주석 사본을 쓴다 — 네모는 Square, 동그라미는 Circle, 곧은 화살표는 Line, 굽은 화살표는 Ink, 글은 FreeText — 그래서 Preview나 다른 앱에서도 같은 자리에 보인다. 사본마다 원소 자체를 실어 두어 사이드카 없는 기기가 파일에서 그대로 되살린다. 아이패드·아이폰은 같은 렌더러로 그려서 보여 준다(고치는 것은 맥에서).",
                          "Shapes live in a sidecar per page (`sketch/pNNNN.json`) that iCloud Drive carries; the PDF gets a copy on save as standard annotations — Square, Circle, Line for a straight arrow, Ink for a bent one, FreeText for words — so Preview and any other app show them in the same place. Each copy carries the element itself, so a device without the sidecar rebuilds it from the file. The iPad and the iPhone draw them with the same renderer (editing is the Mac's)."),
                    devices: [.mac, .ipad, .iphone]
                ),
            ],
            fixed: []
        ),
        Release(
            version: "0.3.0",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("Sonoma를 위해 지었다 — 아직 Sonoma에서 켜 본 것은 아니다.", "Built for Sonoma — not yet run on one."),
            added: [
                Entry(
                    Text2("macOS 14부터", "From macOS 14"),
                    Text2("최소 macOS가 26에서 14(Sonoma)로 내려갔다. 26에만 있는 것은 셋이고 없어도 앱은 그대로다: 온디바이스 모델이 제목·저자를 읽는 것(그 아래에서는 조판 규칙으로 읽는다), 도구 막대의 유리(그 아래에서는 평범한 도구 막대), 목록을 끌어내려 검색을 여는 것(⌘K와 단추는 그대로). 26이 깔린 맥에서 14를 위해 짓고 확인했고, 실제 Sonoma 맥이 이 앱을 켜 본 것은 아직 없다 — 켜 봤다면 어땠는지 알려주면 고맙다.",
                          "The minimum macOS goes from 26 to 14, Sonoma. Three things exist only on 26 and the app stands without them: the on-device model reading titles and authors (below it, layout heuristics do), the glass on the toolbar (below it, an ordinary toolbar), and pulling the list down to open the search (Command-K and the button remain). Built and checked for 14 on a Mac running 26; a Sonoma Mac has not yet opened it — if yours does, say how it went."),
                    devices: [.mac]
                ),
            ],
            fixed: []
        ),
        Release(
            version: "0.2.4",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("표 위에서도 마음대로 드래그한다.", "Drag freely over a table."),
            added: [],
            fixed: [
                Entry(
                    Text2("표 모드 끔", "Table mode, off"),
                    Text2("macOS 26의 PDFKit은 화면에 든 쪽을 Vision에 넘겨 표를 찾고, 찾으면 손잡이 달린 테두리를 치고 그 안에서는 셀만 잡게 한다 — 표 안에서 시작한 드래그가 옆 문장까지 못 간다. 그 스위치를 내렸다. 이제 표 위에서도 글처럼 선택되고 형광펜이 든다. 덤으로 배경에서 쪽을 다시 쓰던 분석이 사라져 쪽 넘김이 가볍다.",
                          "PDFKit on macOS 26 hands every visible page to Vision to look for tables, and where it finds one it draws a frame with handles and lets the mouse take cells and nothing else — a drag begun inside the table cannot reach the sentence beside it. That switch is now off. A table selects like text and takes the highlighter; and the background analysis that rewrote pages under the reader is gone with it."),
                    devices: [.mac]
                ),
            ]
        ),
        Release(
            version: "0.2.3",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("표의 셀이 노랗게 칠해진다.", "A table cell takes the highlighter."),
            added: [],
            fixed: [
                Entry(
                    Text2("표 셀 하이라이트", "Highlighting a table cell"),
                    Text2("표에서 셀을 잡은 선택은 전체로는 제 자리를 아는데, 줄로 쪼개면 PDFKit이 위치를 잃는다(빈 사각형). 형광펜은 줄 단위로 사각형을 만들어서 사각형이 0개인 표시가 됐다 — 막대 뜨고 색 눌러도 아무것도 안 나타났다. 자리를 모르는 줄은 글자 범위로 다시 묻고, 그래도 모르면 선택 전체의 상자를 쓴다.",
                          "A cell selected in a table knows where it is as a whole, but split into lines PDFKit loses the place (a null rectangle). Highlights are made a line at a time, so the mark had no rectangles: the bar came up, the colour was pressed, nothing appeared. A line without a place is asked again by its text range, and failing that the whole selection's box stands in."),
                    devices: [.mac, .ipad, .iphone]
                ),
            ]
        ),
        Release(
            version: "0.2.2",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("표에서 죽던 진짜 이유를 찾았다.", "The real reason it died in tables, found."),
            added: [],
            fixed: [
                Entry(
                    Text2("표에서 형광펜을 들면 꺼지던 것", "Quitting when the highlighter was raised over a table"),
                    Text2("표를 가로지른 선택에 대해 PDFKit이 위치를 '숫자 아님(nan)'으로 돌려줄 때가 있다. 그 자리에 표시 막대를 세우려다 AppKit이 예외를 던졌고, 그 예외가 Swift 태스크를 뚫고 지나가면서 런타임을 망가뜨려 그 다음 아무 곳에서나 죽었다. 이제 위치를 모르는 줄은 세지 않고, 아는 줄이 하나도 없으면 막대는 손 아래에 선다. 막대 자체도 숫자 아닌 자리는 거절한다.",
                          "For a selection across a table, PDFKit sometimes reports its position as not-a-number. Standing the markup bar there made AppKit throw, and that exception, unwinding through a Swift task, left the runtime broken — the app then died at the next thing it did, anywhere. Lines without a place are no longer counted; when none has one, the bar stands under the hand. The bar itself now refuses a position that is not a number."),
                    devices: [.mac]
                ),
            ]
        ),
        Release(
            version: "0.2.1",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("표 안에서도 형광펜이 통한다.", "The highlighter works inside a table too."),
            added: [],
            fixed: [
                Entry(
                    Text2("표 안의 표시", "Marking inside a table"),
                    Text2("표를 가로질러 그은 선택은 줄이 백 개가 넘는다. 형광펜이 글자에 맞게 앉으려고 줄마다 쪽을 한 번씩 그렸으니 백 번이었고, 그동안 PDFKit은 같은 쪽을 제 스레드에서 훑고 있었다 — 맥OS 26은 새로 보이는 쪽을 Vision에 넘겨 표를 찾는다. 이제 한 번만 그린다. 표 한 덩어리를 칠하는 데 78밀리초가 4밀리초가 됐고, 앱이 그 쪽을 붙들고 있는 시간도 그만큼 짧아졌다.",
                          "A selection drawn across a table is more than a hundred lines. To sit the highlight on the letters, the app drew the page once for every one of them — a hundred renderings, while PDFKit was reading the same page on a thread of its own, because macOS 26 hands a newly visible page to Vision to look for tables in it. It draws once now. Measuring a table's worth of lines went from 78 milliseconds to 4, and the app holds that page for as much less time."),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("저장할 때의 소란", "The noise of saving"),
                    Text2("저장은 파일을 디스크에서 다시 짓는다 — 다른 기기가 쓴 표시까지 같이 남기려고 아는 표시를 모두 다시 넣었다. 이미 그대로 들어 있는 표시는 이제 건드리지 않는다. 표를 칠한 논문에서 저장 한 번이 던지던 알림 2만 3천 개가 0이 됐다.",
                          "A save rebuilds the file from disk, putting back every mark the app knows about so that another device's marks survive too. Marks already in the file, exactly as they are, are now left alone: on a paper marked across a table, one round of saving went from twenty-three thousand notifications to none."),
                    devices: [.mac, .ipad, .iphone]
                ),
            ]
        ),
        Release(
            version: "0.2.0",
            date: Text2("2026년 9월", "September 2026"),
            note: Text2("두 번째 알파: 상자가 글이 되는 길, 그리고 아이패드와 아이폰.", "The second alpha: the way from the box to the manuscript, and the iPad and iPhone."),
            added: [
                Entry(
                    Text2("지도(Atlas)", "Maps (Atlas)"),
                    Text2("한 주제의 노트가 다섯 개 넘게 쌓이면 슬립박스가 지도를 제안한다. 지도는 링크가 소제목 아래 놓인 노트(kind: map)이고, 열면 카드 보드가 된다. 울리는데 안 올린 노트는 ＋ 한 번.",
                          "When more than five notes pile up on one subject, the slip-box suggests a map. A map is a note (kind: map) with links under headings; opened, it is a board of cards. Notes that resonate but are not on it are one ＋ away."),
                    demo: .atlas,
                    featured: true
,
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("기기 사이 동기화", "Sync between devices"),
                    Text2("맥에서 그은 하이라이트가 몇 초 뒤 아이패드의 열린 쪽에 나타난다 — 앱을 다시 열지 않아도. 표시는 기기마다 자기 이름의 작은 저널 파일에 즉시 쓰고, 잉크는 쪽마다 사이드카에 쓴다; 둘 다 몇 KB라 iCloud Drive가 곧 옮긴다. 20 MB PDF는 그 뒤 1.5초에 저널대로 다시 쓰여 어느 앱에서 열어도 같다 — 아무도 PDF가 오가기를 기다리지 않는다. 표시마다 가장 최근 말이 이긴다. 열린 논문의 기록 폴더는 3초마다 한 번 더 살피고 아직 안 온 것은 iCloud에 청한다.",
                          "A highlight made on the Mac appears on the iPad's open page a few seconds later — no reopening. Marks go straight into a small journal file named for the device, ink into a sidecar per page; both a few KB, which iCloud Drive carries promptly. The 20 MB PDF is rewritten to the journals 1.5 s later so any app opening it sees the same — nobody waits for the PDF to travel. On each mark the newest word wins. The open paper's record is looked at every three seconds, and what has not come yet is asked of iCloud."),
                    demo: .sync,
                    featured: true,
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("초안(Express)", "Drafts (Express)"),
                    Text2("초안은 노트(kind: draft)다. 논문의 구절은 ❝로, 노트는 [[링크]]로 넣고, ⇧⌘E면 구절이 \\cite{키}로, 노트가 제 문장으로, 인용한 논문만의 .bib과 함께 나온다. 기본 LaTeX, pandoc도.",
                          "A draft is a note (kind: draft). Passages go in with ❝, notes as [[links]]; ⇧⌘E renders passages as \\cite{key}, notes as their sentences, with a .bib of just the papers cited. LaTeX by default, pandoc too."),
                    demo: .express,
                    featured: true
,
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("검색은 묻기 전에 내놓는다", "Search that offers before it is asked"),
                    Text2("⌘K 또는 목록을 끝까지 당기면. 노트·지도·초안도 찾고 최근 연 것이 먼저. 빈칸이면 이어 읽기·읽었으니·다시 보기·이번 주 새로 — 각각 이유와 함께.",
                          "⌘K, or pull the list down past its top. Finds notes, maps and drafts too, the recently opened first. Empty, it offers Continue, Because you read, Revisit and New this week — each with its reason."),
                    action: .searchEverything
,
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("논문 안의 낱말까지 찾는다", "Search that reads the papers"),
                    Text2("제목에 없고 9쪽 한 줄에만 있는 낱말도 찾는다. ⌘K에 'unlearning'을 치면 그 낱말이 적힌 논문들이 «논문 안에서»에 문장째로 뜨고, 고르면 그 논문의 그 줄로 간다. 본문은 한 번만 읽어 캐시에 두므로 처음만 몇 초, 다음부터는 즉시. 줄 끝에서 잘려 un- 과 learning으로 나뉜 낱말도 한 낱말로 본다.",
                          "A word that is nowhere in a title and on one line of page nine is found too. Type \u{201C}unlearning\u{201D} into ⌘K and the papers that say it appear under In the Papers, each with the sentence it says it in; choose one and the reader goes to that line. The text of each paper is read once and kept, so only the first search waits; a word broken across a line end — un- then learning — still counts as one word."),
                    demo: .search,
                    featured: true,
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("인용은 논문의 구조를 데리고 온다", "A quotation brings the page's shape with it"),
                    Text2("⌘L로 노트에 넣은 구절은 세로줄이 선 인용이 되고, 논문에서의 생김새를 그대로 가지고 온다: 절 제목은 제목으로, 문단은 문단으로, 굵은 머리말은 굵게, 그리고 따로 선 수식은 제 줄에 번호(\\tag)까지 달고. 쪽수를 누르면 그 줄로 돌아가고, 인용문은 그냥 글이라 골라서 복사할 수 있다. 수식은 UltraCopy와 같은 눈으로 읽어 $…$로 들어온다 — 기호가 흩어진 산문이 아니라. 파일에는 평범한 마크다운 인용(>)으로 남는다.",
                          "A passage put into a note with ⌘L is a quotation with a rule down its side, and it brings the page's own shape: the section title is a title, paragraphs are paragraphs, a bold lead-in stays bold, and a displayed equation keeps its own line and its number (as \\tag). The page reference goes back to the line; the quoted words are ordinary text, so they can be selected and copied. The mathematics is read the way UltraCopy reads it and arrives as $…$ — not as the scattered symbols a PDF makes of it. In the file it is a plain Markdown block quote."),
                    demo: .passageLink,
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("아이패드 · 아이폰", "iPad and iPhone"),
                    Text2("아이패드는 맥과 같은 리더에 연필 — 필기는 PDF에 잉크 주석으로 남아 맥에서도 보인다. 아이폰은 읽고 찾는 데 맞춰 리더 바에 배치·검색·표시가 있다.",
                          "The iPad has the Mac's reader with a pencil — ink lands in the PDF as annotations and shows on the Mac. The phone is for reading and finding, with layout, search and marks on the reader's bar.")
,
                    devices: [.ipad, .iphone]
                ),
            ],
            fixed: [
                Entry(
                    Text2("책 모드 여백", "Book-mode margins"),
                    Text2("펼침면이 가운데에 서고, 논문마다 여백이 같으며, 여백의 도장은 지워진다.", "The spread stands centred, margins match across papers, and the stamps in the margin are painted out.")
,
                    devices: [.mac]
                ),
                Entry(
                    Text2("환영 화면 크기", "Welcome sheet size"),
                    Text2("아이폰에서 맥 창 크기로 뜨던 환영 화면이 화면에 맞는다.", "The welcome sheet, which opened at the Mac window's size on the phone, fits the screen."),
                    devices: [.iphone]
                ),
                Entry(
                    Text2("Google Drive 폴더 선택", "Choosing a Google Drive folder"),
                    Text2("iOS의 Google Drive 파일 제공자는 폴더 선택을 지원하지 않아 '로드 중'에서 멈춘다. 첫 화면이 이를 말해 주고 iCloud Drive를 권한다.", "Google Drive's Files provider on iOS does not allow a folder to be chosen and loads without end; the first screen now says so and points to iCloud Drive."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("펜 도구 바", "The pen tool strip"),
                    Text2("펜을 들면 제목 아래에 도구 줄이 나온다 — 노트 앱이 두는 자리에, 애플의 떠다니는 팔레트 대신. 되돌리기·다시하기, 펜·형광펜·지우개, 그리고 고른 도구의 빠른 색 셋과 굵기 셋. 도구를 한 번 더 누르면 그 도구의 설정(형광펜: 글자에 맞추기, 지우개: 하이라이트도 지우기, 손가락 그리기), 쓰고 있는 색·굵기를 한 번 더 누르면 그 자리에 다른 색·굵기를 넣는다. 형광펜은 글자 위에서는 맞춘 하이라이트, 글자 밑에서는 밑줄이 되고 — 끄면 그은 그대로. 펜은 언제나 손글씨. 지우개는 선을 통째로, 하이라이트도 함께. 읽기 모드에서 표시를 탭하면 색·지우기. 아이폰도 같은 줄, 손가락이 펜이다.",
                          "Take the pencil out and a strip of tools appears under the title — where a notebook keeps them, instead of Apple's floating palette. Undo and redo; pen, highlighter, eraser; then the chosen tool's three quick colours and three widths. Tap a tool again for its options (highlighter: fit to text; eraser: erase highlights too; draw with finger); tap the colour or width in use to put another in its place. The highlighter over words becomes a fitted highlight, under them an underline — off, it stays as drawn. The pen is always handwriting. The eraser takes strokes whole, highlights along with them. In reading mode a tap on a mark offers its colours and Remove. The phone has the same strip, with a finger for a pen."),
                    demo: .penTools,
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("잉크는 사이드카가 진실", "The sidecar is where ink lives"),
                    Text2("잉크는 쪽마다 사이드카 하나에 살고, PDF 속 잉크 주석은 거기서 써 낸 사본이다. 파일에는 있는데 사이드카가 없는 잉크는 열 때 사이드카로 만든다. 그래서 어느 기기에서 그렸든 세 기기 모두 같은 선을 그리고, 지우고, 다시 그린다 — 맥은 캔버스가 없어도 같은 PencilKit으로 사이드카를 그려, 아이패드의 선이 몇 KB와 함께 온다.",
                          "Ink lives in one sidecar per page; the ink annotations in the PDF are a copy written from it. Ink in the file with no sidecar gets one on opening. So whichever device drew it, all three draw, erase and redraw the same strokes — the Mac, canvas or not, renders the sidecar with the same PencilKit, and an iPad stroke arrives with its few kilobytes."),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("아이패드 펜 필기", "Writing with the pencil on the iPad"),
                    Text2("PDFKit의 쪽 뷰가 터치를 받지 않아 그 위의 캔버스에 펜이 닿지 못했고, 스크롤 뷰가 펜 선을 스크롤로 가져갔다. 이제 쓰는 동안 펜은 캔버스로, 손가락은 스크롤로 간다(손가락 쓰기를 켜면 두 손가락이 스크롤).",
                          "PDFKit's page view took no touches, so the pencil never reached the canvas above it, and the scroll view took a pencil stroke as a scroll. While drawing, the pencil now goes to the canvas and a finger scrolls (two fingers, with finger drawing on)."),
                    devices: [.ipad]
                ),
                Entry(
                    Text2("구절은 인용으로, 노트는 링크로", "A passage is a quotation; a note is a link"),
                    Text2("읽다가 고른 구절과 다른 노트로 가는 링크가 같은 몸짓으로 보였다 — 둘 다 문장 속의 물든 토막이었다. 다른 것이다. 링크는 \"이것의 더 많은 것이 저기 있다\"고 말하고, 인용은 \"이 말은 내 것이 아니다, 7쪽에서 왔다\"고 말한다. 그래서 구절은 이제 제 문단을 갖는 인용으로 들어온다: 왼쪽에 줄, 옅은 바탕, 기울인 글씨, 그리고 밑에 쪽수. 눌러서 그 줄로 돌아가는 것은 그대로다. 파일에는 평범한 마크다운 인용(>)으로 남아 다른 편집기에서도 인용으로 보인다. 문장 가운데 떨어뜨린 구절은 여전히 칩이다 — 그건 원래 토막이 맞다. 아이폰과 아이패드에서는 ⌘L이 아무 데로도 가지 않고 있었는데(노트가 그 신호를 듣는 쪽이 맥밖에 없었다) 이제 거기서도 인용이 들어온다.",
                          "A passage chosen while reading and a link to another note were the same gesture to look at — both a tinted morsel inside a sentence. They are not the same thing. A link says \"there is more of this over there\"; a quotation says \"these words are not mine, they came from page seven\". So a passage now arrives as a quotation with a paragraph of its own: a rule down its left, a pale ground, the words set in italic, the page underneath. Pressing it still goes back to that line. In the file it is an ordinary Markdown block quote, so it reads as a quotation in any other editor too. A passage dropped mid-sentence is still a chip — that one really is a morsel. On the phone and the iPad ⌘L had been going nowhere at all (only the Mac was listening for it); the quotation lands there now as well."),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("노트 링크가 줄의 나머지를 삼킴", "A note link swallowing the rest of its line"),
                    Text2("[[노트]] 뒤에 같은 줄에서 구절을 인용하면, 링크의 이름표가 [[까지 열고 들어가 노트 이름도 그 뒤의 글도 구절도 통째로 하나의 링크가 됐다. 같은 자리에서 시작하는 둘 중에는 먼저 끝나는 쪽이 뜻한 것이다.",
                          "Cite a passage on the same line as a [[note]] and the link's label opened at the note's own bracket and ran to the passage at the end — note name, words between, and passage, all one link. Where two matches begin at the same character, the one that ends sooner is the one that was meant."),
                    devices: [.mac]
                ),
                Entry(
                    Text2("설정이 아이폰·아이패드의 설정답게", "Settings that look like settings on the phone and the iPad"),
                    Text2("맥이 옆에 세워 둔 일곱 쪽을, 손으로 쓰는 화면에서는 한 두루마리에 다 이어 붙여 놓았었다. 이제 같은 일곱 쪽이 일곱 줄이 되어 하나씩 열린다 — 이름도 기호도 맥과 같고, 줄 끝에는 지금 값이 적힌다(라이브러리·폴더 이름, 읽기·현재 배치). 없던 것도 생겼다: 기록(Log)은 아이폰·아이패드에 아예 없었고, 소개(About)는 판 번호 한 줄이었는데 이제 맥과 같은 실물 크기 소개다. 단축키는 키보드를 붙일 수 있는 아이패드에만, 읽기 전용으로. 폴더 칸에 통째로 들어가 카드 높이만큼 구멍을 내던 긴 경로는 이름만 남기고 밑으로 내렸고, 이름이 안 보이던 연락처 칸에 이름을 붙였으며, 쪽 배치·색조는 이제 리더의 것을 그대로 읽어 온다 — 목록에 없던 Glass가 여기에도 생겼고 'None'이 'Paper White'가 되었다.",
                          "The Mac stands its seven pages beside the page it is showing; on a touch screen they had all been sewn into one scroll. The same seven are now seven rows opened one at a time — the same names and symbols as the Mac, each with its value at the end (Library · the folder's name, Reading · the layout in use). Two were missing outright: the Log was not on the phone or the iPad at all, and About was a version number, where now it is the Mac's full-size introduction. The keys are on the iPad, which may have a keyboard, to read rather than to change. The long path that went into the Folder row and left a hole the height of the card now sits under the section with the folder's name in the row; the contact field, which showed only its placeholder, has its name back; and the layout and tint pickers read the reader's own cases — so Glass is offered here too, and \"None\" is called Paper White, as the page calls it."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("어디서나 동기화 단추", "A sync button, on every device"),
                    Text2("표시와 잉크는 작은 파일로 오가고 iCloud가 가져올 때 온다 — 대개 몇 초, 가끔 여덟 초. 기다리는 동안 누를 것이 없었다. 이제 목록 바에 새로고침이 있고(⌘R), 책을 펴 목록이 물러난 아이패드에서는 AA 메뉴에도 있다. 누르면 iCloud에 아직 안 가져온 것을 청하고, 폴더를 다시 읽고, 열어 둔 논문에게 제 파일을 다시 보라고 이른다. 맥 메뉴의 '폴더에서 새로고침'도 같은 일을 하게 되어 ⌘R은 이제 하나다.",
                          "Marks and ink travel as small files and arrive when iCloud brings them — usually seconds, sometimes eight. There was nothing to press while waiting. There is now: a refresh on the list's bar (⌘R), and in the AA menu on the iPad when a book has sent the list away. It asks iCloud for what it has not brought, reads the folder again, and tells the open paper to look at its own files. The Mac's \"Refresh from Folder\" does the same errand now, so ⌘R means one thing."),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("당겨 내리면 무엇이 나오는지 먼저 말한다", "The pull says what it will open"),
                    Text2("논문 목록을 끝까지 당기면 서재 전체 검색이 뜬다 — 뜨기 전까지는 아무 말이 없어서, 목록이 튕겨 돌아오고 갑자기 창이 있었다. 이제 당기는 만큼 'Search Everything'이 따라 올라오고, 그 문구를 지나야 열린다. 멈출 수 있는 몸짓이 되었다. 세 기기 모두.",
                          "Pulling the paper list past its top opens the library-wide search — and nothing had said it would, so the list sprang back and a palette was suddenly there. The words \"Search Everything\" now come in with the pull, and going past them is what opens it, so the gesture is something you can stop doing. On all three."),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("검색을 열면 키보드가 먼저 올라옴", "The keyboard arriving before the search did"),
                    Text2("아이폰과 아이패드에서 검색을 열면 키보드가 곧장 올라와, 무엇을 이어 읽을지 내놓는 절반을 덮었다. 맥은 ⌘K를 누른 순간부터 타자를 칠 준비가 되어 있는 게 맞지만, 손으로 쓰는 화면에서는 먼저 보고 필요하면 칸을 누른다.",
                          "Opening the search on the phone or the iPad raised the keyboard at once, covering the half of the palette that offers what to read next. On the Mac the caret belongs in the field — ⌘K is a key you press in order to type — but on a touch screen you look first and tap the field if you want to type."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("빈 선반이 검색 실패라고 말함", "An empty shelf saying the search had failed"),
                    Text2("아직 아무것도 별을 안 단 즐겨찾기 앞에서 '맞춤법을 확인하거나 다시 검색하세요'가 떴다. 선반마다 제 이유를 말한다 — 읽는 중으로 표시한 논문이 여기 모인다, 별을 달면 여기 있다.",
                          "\"Check the spelling or try a new search\" stood in front of Favorites, which nothing had been starred into yet. Each shelf now says why it is empty — papers you set to Reading wait here; star one and it will be here."),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("돋보기가 둘, 생김새는 하나", "Two magnifiers, one shape"),
                    Text2("리더 바의 돋보기는 이 논문을 찾고, 목록 바의 돋보기는 서재 전체를 뒤지는데 둘이 똑같이 생겨서 어느 쪽을 누르는지 알 수 없었다. 서재 쪽은 이제 목록과 돋보기가 함께 있는 기호다.",
                          "The magnifier on the reader's bar finds a word in this paper; the one on the list's bar looks through the whole library. They were the same shape, so pressing one was a coin toss. The library's is now a list with a magnifier over it."),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("책장이 소리 없이 바뀜", "A spread that changed without turning"),
                    Text2("아이패드의 책 모드는 쓸면 넘어가되 한 칸이 그냥 다른 칸으로 바뀌었다 — 넘어간 것이 아니라 잘못된 것처럼 보인다. 한 쪽 모드가 쪽 넘김 컨트롤러에서 받는 그 움직임을, 책은 층(layer)의 밀어내기로 받는다. 처음에는 그림 두 장을 찍어 옮겼는데, 올 펼침면의 그림을 찍으려면 그걸 통째로 그려 놓고 시작해야 해서 움직임이 있어야 할 자리에 멈칫이 들어갔다 — 지금은 렌더 서버가 이미 그려 둔 것을 그대로 민다.",
                          "The iPad's book turned on a swipe but cut from one spread to the next with no motion, which reads as a glitch rather than a page turning. The movement the single page gets from the page-turn controller comes to the book as a push on its own layer. Two snapshots were the first attempt: taking the picture of the spread about to arrive means drawing the whole of it before the animation can begin, and the pause landed exactly where the movement should have been. The render server already has it drawn, and now it does the pushing."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("맥의 목차도 쪽 아래로", "The Mac's contents along the foot as well"),
                    Text2("목차가 기둥으로 서는 곳은 펼침면의 가운데 홈뿐이다. 이어 읽기와 한 쪽 모드에서는 쪽이 열을 가득 채우니, 그 한가운데 선 기둥은 찾아 주려던 글을 가린다. 이제 거기서는 아이패드처럼 쪽 아래를 가로지른다. (처음 고쳤을 때 맥에서만 여전히 한가운데 떴다 — 아래로 붙이라는 말은 붙일 벽이 있어야 듣는데, 손가락을 받는 투명한 층이 없는 맥에서는 겹이 판 크기로 오그라들어 붙을 데가 없었다.)",
                          "The only place a column of headings can stand is the gutter of a spread. In continuous and single-page the page fills the column, and a column down the middle of it covers the words it is meant to help you find — so there it lies along the foot, as it does on the iPad. (It kept appearing in the middle on the Mac after the first attempt: an instruction to sit at the bottom needs a bottom to sit at, and without the invisible layer that catches a dismissing touch the stack shrank to the panel and had none.)"),
                    devices: [.mac]
                ),
                Entry(
                    Text2("슬립박스에서 나올 수 없음", "No way out of the slip-box"),
                    Text2("아이패드에서 노트로 들어가면 서가를 여는 단추가 논문 목록과 함께 사라져, 다른 선반으로 갈 길이 없었다. 그 바는 목록의 것이 아니라 열의 것이다.",
                          "Walking into the notes on the iPad took the button that opens the shelves with it, and there was no way back to another shelf. That bar belongs to the column, not to the papers."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("다른 논문을 열면 표시가 안 보임", "Marks invisible after opening a second paper"),
                    Text2("쪽 위의 겹(잉크 캔버스와 둥근 표시를 그리는 층)을 쪽 번호로만 기억해, 다음 논문의 1쪽이 앞 논문 1쪽의 겹을 물려받았다. 그래서 앞 논문의 잉크가 다음 논문 위에 그려지고, 하이라이트는 PDFKit에게 숨긴 뒤 아무도 그리지 않아 사라졌다 — 표시 목록에는 남은 채로. 이제 논문 하나에 겹 한 벌이고, 그릴 것이 없는 쪽에서는 숨기지 않는다.",
                          "The layer over a page — the ink canvas and the one that draws the rounded marks — was remembered by page number alone, so page 1 of the next paper inherited page 1 of the last. The previous paper's ink was drawn over the new one, and a highlight was hidden from PDFKit with nothing left to draw it: gone from the page, still in the list of marks. One paper now has one set of layers, and a page with nothing to draw its marks keeps PDFKit's."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("책이 넘어가지 않음", "A book that would not turn"),
                    Text2("아이패드의 책 모드에는 쪽을 넘길 것이 없었다. 쪽 넘김 컨트롤러는 한 쪽씩만 보여 쓸 수 없고, 펼침면은 화면에 꽉 맞춰 스크롤할 여지도 없어 — 쓸어도 두 쪽이 몇 점 밀렸다 말았다. 이제 책에서는 쓸면 넘어간다. 확대한 펼침면은 천천히 끌면 그대로 움직인다.",
                          "Book mode on the iPad had nothing that turned a page: the page-turn controller shows one page and a spread is two, and the spread is fitted to the screen, leaving no room to scroll — a swipe moved the pages a few points and let go. A swipe now turns the book, while a deliberate drag still moves a spread that has been zoomed into."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("목차는 쪽 아래에 길게", "The contents along the foot of the page"),
                    Text2("맥에서 목차는 펼침면의 가운데 홈에 서는 좁은 기둥이다. 손으로 읽는 화면에는 내줄 홈이 없어, 쪽 아래를 가로지르는 낮고 넓은 판으로 뜬다 — 제목이 접히지 않고 한 줄에 들어간다. 목록이 담긴 만큼만 높고, 쪽 세는 줄을 덮지 않는다. 쪽 아무 데나 누르면 닫힌다.",
                          "On the Mac the contents stands in the gutter of a spread, a narrow column. A touch screen has no gutter to give, so it comes as a low, wide panel across the foot of the page — a heading fits on one line. It is as tall as its headings need and no taller, and it keeps clear of the bar that counts the pages. A touch anywhere on the paper puts it away."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("논문 안에서 찾기", "Finding a word in the paper"),
                    Text2("아이패드의 리더 바에는 서재 전체를 뒤지는 돋보기만 있고, 읽고 있는 논문에서 한 낱말을 찾을 방법이 없었다. 이제 리더 바의 돋보기는 이 논문이고(⌘F), 서재 전체는 목록 쪽의 돋보기와 AA 메뉴의 한 줄이다.",
                          "The iPad's reader bar carried a magnifier that searched the whole library and no way to find a word in the paper being read. The magnifier on the reader's bar now means this paper (⌘F); the library is the magnifier on the list and a line in the AA menu."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("서가의 불이 옮겨 앉는다", "The lit shelf moves"),
                    Text2("어느 서가에 있는지를 칠하는 바탕이 한 줄에서 꺼지고 다른 줄에서 켜졌다. 이제 그 유리 한 장이 고른 줄로 미끄러져 간다 — 음악의 아래 단추들처럼. 어디에서 왔는지가 보인다.",
                          "The wash that says which shelf you are on went out on one row and came on in another. That one piece of glass now slides to the row you chose, the way the buttons along the foot of Music do — so you can see where you came from."),
                    devices: [.mac, .ipad, .iphone]
                ),
                Entry(
                    Text2("도구 설정이 잘림", "Tool options cut off"),
                    Text2("형광펜과 지우개의 설정 팝오버가 짧아 마지막 줄(손가락 그리기)이 모서리에 잘렸다 — 닿을 수 없는 설정은 없는 설정이다.",
                          "The highlighter's and eraser's options popover was too short and its last row — draw with finger — was cut in half by the edge. A switch you cannot reach is a setting that does not exist."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("아이패드의 서가는 패널로, 인스펙터는 떠서", "The iPad's shelves as a panel, its inspector afloat"),
                    Text2("아이패드 화면은 열 셋을 둘 만큼 넓지 않다. 서가(범위·컬렉션·태그·저자)는 목록 열의 격자 단추로 Spotlight처럼 창 가운데에 떠서 나오고, 고르면 사라진다. 인스펙터는 오른쪽에서 쪽 위로 떠 들어온다 — 시트가 읽던 쪽을 가리던 대신. 목록은 시스템 토글로 숨기고 보인다. 툴바가 겹치던 것도 이렇게 풀렸다.",
                          "The iPad's screen has no room for three columns. The shelves — scopes, collections, tags, authors — come as a panel in the middle of the window, Spotlight-fashion, from the grid button on the list; pick one and it goes. The inspector floats in over the page from the right instead of a sheet that hid what you were reading. The list hides and shows with the system's own toggle. The overlapping toolbar came apart the same way."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("형광펜이 아랫줄까지 칠함", "The highlighter spilling onto the next line"),
                    Text2("형광펜은 굵어서 한 줄을 따라 그은 선의 상자가 줄보다 크고, 이웃 줄에 걸쳤다. 이제 선의 가운데 띠로 어느 줄인지 정한다 — 한 줄을 그으면 한 줄이다.",
                          "A highlighter is wide: one stroke along one line made a box taller than the line, touching its neighbours. The line is now judged by the band at the stroke's centre — one line drawn, one line marked."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("아이패드의 창이 맥처럼", "The iPad's window, like the Mac's"),
                    Text2("도구 단추 뒤의 유리 알약을 없애 맥처럼 평평하게. 쪽 표시줄은 열 너비에 맞춘 평면. 책 모드가 목록을 물리고 두 쪽을 너비에 꽉 채운다(단일 쪽에만 쪽 넘김 컨트롤러를 쓴다). 목록 열의 단추로 목록을 숨기고, 목록이 없을 때는 리더 바에 목록·AA·검색·인스펙터가 온다. 목차는 리더 바의 단추. PDF 추가가 아이패드에서 열린다. 글자를 선택하면 맥과 같은 색 막대가 뜬다 — 이름 대신 색으로.",
                          "The glass pills behind toolbar buttons are gone, flat as the Mac. The page bar is a flat strip the width of the column. Book mode steps the list aside and fills the width with two pages (the page-turn controller is kept for the single page only). A button on the list column hides the list; with the list away, the reader's bar carries list, AA, search and inspector. The table of contents is a button on the reader's bar. Adding PDFs opens on the iPad. Selecting text brings the Mac's colour bar — colours, not their names."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("아이폰에 지운 잉크가 남음", "Erased ink lingering on the phone"),
                    Text2("아이패드에서 한 쪽의 선을 모두 지우면 사이드카가 사라지고, 아이폰은 그 순간 PDF에 남은 옛 사본을 다시 그렸다 — 20 MB PDF가 다시 올 때까지 일부가 남아 보였다. 이제 오버레이 아래에서는 PDF의 잉크 사본을 언제나 숨긴다.",
                          "Erase every stroke on a page on the iPad and its sidecar goes; the phone then drew the old copy left in the PDF, so some strokes lingered until the 20 MB PDF came again. The PDF's copy of the ink is now always hidden under an overlay."),
                    devices: [.iphone, .mac]
                ),
                Entry(
                    Text2("아이패드 잉크가 맥에서 안 보임", "iPad ink invisible on the Mac"),
                    Text2("PDFKit은 잉크 경로를 주석 상자 기준으로 받는데 쪽 좌표를 넘겨, 파일의 선이 상자 밖 두 배 자리에 쓰였다. 아이폰은 사이드카를 캔버스로 그려 눈치채지 못했고 맥은 아무것도 보지 못했다. 좌표를 고쳤고, 예전 파일은 다음 저장 때 다시 쓴다.",
                          "PDFKit takes an ink path relative to the annotation's box; handed page coordinates, it wrote each stroke at twice its position, outside the box. The iPhone drew its ink from the sidecar and never noticed; the Mac saw nothing. The coordinates are fixed, and older files are rewritten on their next save."),
                    devices: [.mac, .ipad]
                ),
                Entry(
                    Text2("아이패드 하이라이트 모서리", "Highlight corners on the iPad"),
                    Text2("PDFView가 쪽을 한 번 그려 둔 뒤라 파일의 네모난 표시가 둥근 것 밑에 남았다. 이제 쪽을 그리기 전에 표시를 넘겨받고, 바뀔 때마다 다시 그리게 한다.",
                          "The PDF view had painted the page before the flat marks were hidden, so a square stayed under each rounded one. Marks are taken over before the page is painted, and the page repainted when they change."),
                    devices: [.ipad]
                ),
                Entry(
                    Text2("iCloud 라이브러리가 비어 보임", "An iCloud library that looked empty"),
                    Text2("맥에서 만든 라이브러리를 아이패드·아이폰이 논문 0편으로 열었다. iOS의 iCloud는 숨김 폴더 .papertime 아래를 통째로 숨김으로 표시해 기록 폴더가 하나도 잡히지 않았다. 이제 이름으로 가려 62편이 그대로 온다.", "A library made on the Mac opened on the iPad and iPhone with no papers. iCloud on iOS flags everything under the hidden .papertime folder as hidden, so no record folder was listed. Records are now filtered by name, and the papers come across."),
                    devices: [.ipad, .iphone]
                ),
                Entry(
                    Text2("슬립박스 순서", "Slip-box order"),
                    Text2("노트는 쓴 순서로 고정되고 논문별로 묶인다.", "Notes stay in the order written, grouped by paper.")
,
                    devices: [.mac, .ipad, .iphone]
                ),
            ]
        ),
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
                    Text2("논문·노트·지도·초안·저자·컬렉션·명령을 한 칸에서. 제목에 없는 낱말은 «논문 안에서»가 본문에서 찾아 문장째로 보여 주고, 고르면 그 줄로 간다. 목록을 끝까지 당겨도 열린다. 빈칸이면 이어 읽기·읽었으니·다시 보기·새로 온 것을 제안한다.", "Papers, notes, maps, drafts, authors, collections, commands, from one field. A word that is in none of the titles is looked for in the text — In the Papers shows the sentence it is in, and choosing it goes to that line. Pull the list down to open it. Empty, it offers: continue, because you read, revisit, new."), action: .searchEverything),
            Feature(Text2("페이지 배치", "Page layout"),
                    Text2("연속 스크롤, 한 장씩, 또는 두 장 펼침. AA 메뉴에 있고, ⌘1·⌘2·⌘3으로도 바꾼다. 책에서는 ←→로 장을 넘긴다.", "Continuous scrolling, single page, or a two-page spread. In the AA menu, and on ⌘1, ⌘2 and ⌘3. In a book, ← and → turn the page."), action: .layoutBook),
            Feature(Text2("페이지 색", "Page tint"),
                    Text2("흰 종이, 세피아, 어둡게 — 그리고 Glass는 종이의 흰색을 걷어내 글자가 창 위에 앉게 한다. AA 메뉴에 있다.", "Paper white, sepia, dimmed — or Glass, which drops the page's white so it sits on the window. In the AA menu.")),
            Feature(Text2("논문에 집중", "Focus on the paper"),
                    Text2("나머지가 비켜선다. 절을 옮길 때는 ⇧⌘L로 목차를 불러낸다.", "Everything else steps aside; ⇧⌘L brings the table of contents when you want another section."), action: .focus),
            Feature(Text2("목차", "Table of contents"),
                    Text2("PDF가 가진 목차를 페이지 위에 띄운다. 절을 누르면 그리로.", "The PDF's own outline, floated over the page. Click a section to go there."), action: .floatingList),
            Feature(Text2("쪽 그림으로 넘기기", "Turn by the look of the pages"),
                    Text2("같은 창(⇧⌘L)의 «쪽» 칸. 모든 쪽을 작게 세로로 늘어놓고, 누르면 그 쪽으로 간다. 지금 보는 쪽에는 테두리가 있다. 제목을 하나도 찾지 못한 PDF — 스캔한 계약서나 모든 제목이 «1장»인 안내서 — 는 이 칸으로 바로 열린다.",
                            "The Pages tab of the same panel (⇧⌘L): every page, small, in a column; click one to go there, and the page you are on is ringed. A PDF whose headings could not be read — a scanned contract, a handbook whose every heading is \"Chapter 7\" — opens straight to it."), action: .floatingList),
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
            Feature(Text2("프레임·묶음·오토 레이아웃", "Frames, groups, auto layout"),
                    Text2("F로 프레임, ⌘G로 묶음, ⇧A로 오토 레이아웃. 위치·크기·간격은 오른쪽 인스펙터에서 숫자로.", "F for a frame, ⌘G to group, ⇧A for auto layout. Position, size and gap as numbers in the inspector on the right."), action: .draw),
            Feature(Text2("맥에서 그리기", "Drawing on the Mac"),
                    Text2("펜을 들면 쪽 위에 도구 줄: 펜·형광펜·지우개와 네모·동그라미·화살표·선·글, 한 글자 키. 펜 선은 아이패드와 같은 잉크로.", "Take the pencil out and a tool rack floats over the page: pen, highlighter, eraser, and rectangle, ellipse, arrow, line, text, one letter each. Pen strokes are the iPad's ink."), action: .draw),
            Feature(Text2("도형·화살표·글 카드", "Shapes, arrows, text cards"),
                    Text2("구부러지는 화살표, 글이 든 상자, 배경과 테두리가 있는 카드, 손글씨 둘레의 테두리(B). 옮기고, 크기를 바꾸고, 스타일을 바꾸고, ⌘Z. PDF에는 표준 주석으로 기록된다.", "Arrows that bend, boxes with words in them, cards with a background and a border, a frame round handwriting (B). Move, resize, restyle, ⌘Z. Written into the PDF as standard annotations.")),
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
            Feature(Text2("초안과 내보내기", "Drafts and export"),
                    Text2("구절과 노트로 초안을 채우고 ⇧⌘E로 \\cite와 .bib이 붙은 LaTeX을 받는다.", "Fill a draft from passages and notes; ⇧⌘E gives LaTeX with \\cite and a .bib.")),
            Feature(Text2("공명", "Resonance"),
                    Text2("읽는 쪽과 낱말을 나누는 다른 논문의 노트가 Notes 탭 맨 위에 올라온다. 노트 아래에는 아직 잇지 않은 울림이 모인다.", "Notes from other papers that share the page's words rise to the top of the Notes tab; under a note, the echoes not yet linked are gathered.")),
            Feature(Text2("Markdown과 LaTeX", "Markdown and LaTeX"),
                    Text2("쓰는 대로 조판된다. $x^2$는 수식이 되고, 저장되는 것은 여전히 원문이다.", "Both are set as you write them. $x^2$ becomes mathematics; the source is still what is saved.")),
            Feature(Text2("LaTeX 단축 입력", "LaTeX Shortcuts"),
                    Text2("Obsidian의 Latex Suite와 같아요. 수식 안에서 //는 분수, x1은 x_{1}, sr은 제곱이 되고 Tab은 다음 칸으로 가요. 글 카드에서도 돼요.", "The same as Latex Suite in Obsidian: inside math, // is a fraction, x1 is x_{1}, sr a square, and Tab moves to the next field. Text cards too.")),
            Feature(Text2("원문 보기", "Raw"),
                    Text2("</> 버튼이 노트를 Markdown 그대로 보여준다. 링크나 수식을 손으로 고칠 때 쓴다.", "The </> button shows the note as Markdown, for fixing a link or a formula by hand.")),
        ]),
        Group(Text2("라이브러리", "The library"), symbol: "books.vertical", features: [
            Feature(Text2("라이브러리를 여러 개 열어 두기", "Several libraries at once"),
                    Text2("""
                        사이드바 맨 위 «라이브러리»에서 «라이브러리 더하기…»로 폴더를 더 연다. 열어 둔 \
                        폴더의 PDF가 한 목록에 함께 보이고, 이름을 누르면 그 폴더만 본다. 파일은 \
                        옮기지 않는다 — 폴더마다 제 .papertime을 갖고 있어서 연결을 해제해도 그 폴더는 \
                        있던 그대로다. 논문을 더하면 지금 보고 있는 폴더로 들어간다. 이름 옆 아이콘이 \
                        그 폴더가 클라우드에 있는지 이 맥에 있는지 말해 준다.
                        """,
                        """
                        Add one under Libraries at the top of the sidebar. Every folder's PDFs appear \
                        in one list, and clicking a name shows only that folder. Nothing is moved: \
                        each folder keeps its own .papertime, so disconnecting leaves it exactly as \
                        it was. A paper added while a folder is showing goes into that folder. The \
                        icon beside a name says whether the folder is in a cloud or on this Mac.
                        """)),
            Feature(Text2("노트·태그·컬렉션은 그 폴더 안에", "Notes, tags and collections live in their folder"),
                    Text2("""
                        논문에 대해 쓴 노트는 그 논문이 있는 폴더에 쓴다. 태그와 컬렉션도 그 이름을 입은 \
                        논문이 있는 폴더마다 적어 둔다. 그래서 폴더 하나를 다른 컴퓨터로 가져가면 표시도 \
                        필기도 노트도 태그도 그대로 딸려 가고, 연결을 해제하면 그 폴더의 것만 목록에서 \
                        빠진다. 같은 이름을 두 폴더가 쓰면 목록에는 한 줄로 보인다. 논문 없이 쓴 노트와 \
                        지도·초안은 갈 폴더가 없으니 앱이 제 폴더(Application Support 안 Notes)에 둔다 — \
                        폴더를 뽑아도 안 사라지는 대신, 기기 사이를 따라다니지는 않는다.
                        """,
                        """
                        A note about a paper is written in the folder that paper is in, and a tag or \
                        a collection is written in every folder whose papers wear it. So a folder \
                        carried to another machine arrives whole — marks, handwriting, notes, tags — \
                        and disconnecting one here takes only its own. A name two folders use shows \
                        once. A note about no paper, and every map and draft, goes in a folder of the \
                        app's own (Notes, in Application Support): nothing you disconnect can take \
                        it, and in exchange it does not follow you between machines.
                        """)),
            Feature(Text2("폴더 연결 해제", "Disconnect a folder"),
                    Text2("폴더 이름을 오른쪽 클릭해 «연결 해제». 목록에서 빠질 뿐 파일도 기록도 그대로고, 같은 폴더를 다시 더하면 표시와 필기와 노트까지 그대로 돌아온다.",
                            "Right-click a folder and choose Disconnect. Its papers leave the list; the files and their records stay. Add it again and the marks, the handwriting and the notes come back with it.")),
            Feature(Text2("파일 이름 고치기", "Rename the file"),
                    Text2("인스펙터의 «파일» 칸에 이름을 적고 Return. 디스크의 PDF 이름이 바뀐다. «.pdf»는 안 적어도 붙는다. 표시·필기·노트는 논문의 번호를 따라다녀서 움직이지 않는다.",
                            "Type a name in the inspector's File field and press Return: the PDF is renamed on disk. Leave the .pdf off and it is kept for you. Marks, handwriting and notes follow the paper's identifier and do not move.")),
            Feature(Text2("논문 추가", "Add papers"),
                    Text2("PDF를 끌어다 놓거나, 이 키로.", "Drag PDFs in, or use this."), action: .addPapers),
            Feature(Text2("논문인지 일반 문서인지", "A paper, or a document"),
                    Text2("""
                        PDF를 더하면 인스펙터가 한 번 묻는다 — 논문인가요, 일반 문서인가요. \
                        앱이 먼저 짐작해서 하나를 골라 두니 대개 그대로 누르면 된다(안에 DOI나 \
                        arXiv 번호가 있으면 논문, 없으면 초록과 참고문헌이 둘 다 있을 때만 논문). \
                        논문이라고 하면 예전처럼 서지를 찾아 채우고 비슷한 후보를 보여준다. \
                        일반 문서라고 하면 학술지·권·호·DOI·인용 키 칸이 사라지고 펴낸 곳·해·종류·파일만 남으며, \
                        등록기관에 묻지도 않는다 — 계약서 제목이 밖으로 나갈 일이 없다.
                        """,
                        """
                        Adding a PDF asks once, in the inspector: a paper, or a document? \
                        The app has already guessed one of them, so it is usually one press — \
                        a DOI or an arXiv identifier inside means a paper, and without one it \
                        takes an abstract and a reference list together. Say paper and the record \
                        is looked up and the near matches offered, as before. Say document and the \
                        journal, volume, issue, DOI and citation key go away, leaving where it came \
                        from, its year, its kind and its file — and nothing is asked of a registrar, \
                        so a contract's title never leaves the machine.
                        """)),
            Feature(Text2("종류를 나중에 바꾸기", "Changing that answer"),
                    Text2("잘못 눌렀으면 도구 막대의 ⋯ 메뉴에서 «종류»를, 또는 목록에서 그 줄을 오른쪽 클릭해 바꾼다. 한 번 정하는 것이라 폼에는 두지 않았다.",
                            "Pressed the wrong one? Change it under Kind in the ⋯ menu in the toolbar, or by right-clicking the row in the list. It is decided once, so it does not stand in the form.")),
            Feature(Text2("논문 선반과 문서 선반", "Papers and documents in the shelf"),
                    Text2("라이브러리에 둘 다 있으면 사이드바에 «논문»과 «문서» 줄이 생긴다. 논문만 있으면 예전 그대로다. «살펴볼 것»에는 논문만 올라온다 — 등록기관이 안내서에 대해 할 말은 없다.",
                            "Once a library holds both, the sidebar gets a Papers row and a Documents row; a library of nothing but papers looks as it did. Needs Review holds only papers: no registrar has an opinion about a manual.")),
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
            Feature(Text2("열린 논문 선반", "The Open Papers shelf"),
                    Text2("쓴 논문이 남는 선반이다. 쪽을 클릭해 들어가거나 나란히 놓으면 남고, 그냥 훑어본 것은 다음 논문을 보면 빠진다 — 편집기의 미리보기 탭과 같다. ⇧⌘O로 쪽 위에 띄우고, 한 줄을 창 밖으로 끌면 그 논문만 담은 창이 된다.",
                            "The shelf of what you have used. Click into a paper, or put it beside another, and it stays; one merely looked at leaves when the next is shown — the rule an editor's preview tab follows. ⇧⌘O floats it over the page, and a row dragged out of the window becomes a window of its own."), action: .openPapers),
            Feature(Text2("핀은 직접 꽂는 것", "The pin is yours"),
                    Text2("목록 줄 앞의 핀은 사람이 누른 것만 켜진다. 앱이 «쓰는 중»으로 남겨 두는 것은 선반에만 보이고 핀을 켜지 않는다 — 읽었다고 핀이 꽂히면 그건 핀이 아니다. 핀을 한 번 더 누르면 그 논문을 닫는다.",
                            "The pin at the head of a row lights only for what you pinned. What the app keeps because you were using it shows on the shelf and nowhere else — a pin that appears by itself is not a pin. Press it again to close the paper.")),
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
        /// Where the change landed. Everything is the Mac's unless it says
        /// otherwise; a change made on several at once carries several.
        var devices: [Device] = [.mac]
        var id: String { title.en }

        init(
            _ title: Text2, _ detail: Text2,
            action: ShortcutAction? = nil, demo: Demo? = nil, featured: Bool = false,
            devices: [Device] = [.mac]
        ) {
            self.title = title
            self.detail = detail
            self.action = action
            self.demo = demo
            self.featured = featured
            self.devices = devices
        }
    }

    enum Device: String, CaseIterable, Identifiable {
        case mac, ipad, iphone
        var id: String { rawValue }
        var label: String {
            switch self {
            case .mac: "Mac"
            case .ipad: "iPad"
            case .iphone: "iPhone"
            }
        }
        var symbol: String {
            switch self {
            case .mac: "macbook"
            case .ipad: "ipad"
            case .iphone: "iphone"
            }
        }
    }

    /// The demonstrations the app knows how to draw.
    ///
    /// The same six are used in two sizes: small, under a line of the log,
    /// and full size in About, where there is room to make them the real
    /// thing rather than a diagram of it.
    enum Demo: String, Identifiable, CaseIterable {
        /// The report sheet: a screenshot already taken, marked up with the
        /// app's own pen, and the public row it is about to become.
        case feedback
        /// The list on the download page, and a check mark that is the issue
        /// being closed rather than a picture of one.
        case together
        /// The same window, in the two languages it speaks.
        case twoLanguages
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
        /// A draft filled from passages and notes, and what comes out: LaTeX
        /// with its citations, and the .bib to go with it.
        case express
        /// A Mac and an iPad side by side; a mark made on one lands on the
        /// other a moment later, by way of the folder.
        case sync
        /// A marker stroke over words, kept as drawn or fitted to the words.
        case penTools
        /// The Mac's drawing layer beside a plain reader's box and note
        /// icon: a card with words, a bent arrow that follows it when it is
        /// dragged, a frame round handwriting, and the row of one-key tools.
        case sketch
        /// A frame with three cards in it, and the auto layout that keeps
        /// them in a column or a row — press the flow and they move.
        case frames
        /// The question every PDF is asked, and the two forms it decides
        /// between.
        case kindQuestion
        /// The sidebar's folders: press one and it opens, press it again and
        /// you come back out.
        case folderTree
        /// One folder, three desktops: a mark made on any of them is in the
        /// PDF, so the other two have it the moment the folder catches up.
        case crossPlatform
        /// A formula typed the short way through the real Latex Suite, key by
        /// key: `//` a fraction, `x1` a subscript, `sr` a square, Tab the
        /// next field — and the line as the note sets it.
        case latexShortcuts
        /// A question typed into Search Everything, and under the exact
        /// matches the passages that answer it without using its words —
        /// press another question and both sections change.
        case meaning

        var id: String { rawValue }
    }

    /// What order to meet the app in.
    ///
    /// Fifteen things that are each worth a paragraph is not a list anybody
    /// reads; it is a wall, and a wall is read by nobody. So they are told in
    /// three goes. The first answers "why not just use Preview" — the things
    /// no other reader does at all. The second is what makes the window a
    /// place to read in rather than a viewer. The third is what becomes of
    /// the reading afterwards, which is the part that turns into writing.
    /// Somebody who stops after the first tier has still seen the point.
    enum Tier: Int, CaseIterable, Identifiable {
        case one = 1, two, three
        var id: Int { rawValue }

        var name: Text2 {
            switch self {
            case .one: Text2("다른 데 없는 것", "Nowhere else")
            case .two: Text2("읽는 자리", "The place you read in")
            case .three: Text2("읽고 난 뒤", "After the reading")
            }
        }

        var promise: Text2 {
            switch self {
            case .one:
                Text2("이것들 때문에 만들었다. 다른 PDF 앱에서는 아예 되지 않는 일들.",
                      "The reasons it was built: things no other PDF reader does at all.")
            case .two:
                Text2("논문 말고는 아무것도 신경 쓰지 않게 하는 것들.",
                      "What makes the window a place to read in, and nothing else.")
            case .three:
                Text2("표시가 생각이 되고, 생각이 원고가 되는 길.",
                      "How marks become thinking, and thinking becomes a manuscript.")
            }
        }

        var symbol: String {
            switch self {
            case .one: "sparkles"
            case .two: "book.pages"
            case .three: "pencil.and.outline"
            }
        }
    }

    struct Highlight: Identifiable {
        let symbol: String
        let title: Text2
        let detail: Text2
        var action: ShortcutAction?
        /// Shown full size in About, where the point is to let somebody try
        /// the thing rather than read about it.
        var demo: Demo?
        /// Which of the three goes this one belongs to.
        var tier: Tier = .two
        /// The first tier is what somebody came for, and it is set apart —
        /// the tint on the title, the ring round the demonstration. This was
        /// a flag of its own, which meant two ways of saying one thing and a
        /// chance for them to disagree.
        var featured: Bool { tier == .one }
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
