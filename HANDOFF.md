# 이어받기

새 세션에서 이 파일 하나만 읽으면 따라잡을 수 있게 쓴 문서다.
원칙과 제약은 `CLAUDE.md`, 결정 정본은 `PLAN.md`.

## 먼저 할 것

```
git log -12 --stat
```

커밋 메시지 본문에 **무엇을 잘못 보고 있었는지**를 적어뒀다. 다시 만나면 또
며칠 헤맬 종류의 사실들이라, 코드보다 그쪽을 먼저 읽는 편이 빠르다.

## 빌드 · 테스트

```sh
xcodebuild -project PaperTime.xcodeproj -scheme PaperTime -configuration Debug \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual PROVISIONING_PROFILE_SPECIFIER="" build

swift test --package-path Packages/PaperTimeKit    # 157개 통과가 정상
```

설치는 빌드 산출물(`…/Build/Products/Debug/Paper Time.app`)을 `~/Applications/`로 복사.

`CODE_SIGNING_REQUIRED=NO`를 쓰면 entitlement가 같이 날아가고, 앱은 뜨지만
샌드박스가 사용자 지정 폴더를 거부해 "Library Folder Unavailable"이 된다.
애드혹 서명(`-`)이라야 한다.

`PaperTime.xcodeproj`는 gitignore돼 있고 `project.yml`에서 xcodegen이 만든다.
`sources: App` 이 디렉터리를 통째로 훑으므로 파일을 추가할 때 등록할 곳은 없다 —
다만 **새 파일을 만들었으면 `xcodegen generate`를 먼저 돌려야** 빌드에 들어간다.
"cannot find X in scope"가 나오면 대개 이것이다.

## 테스트 자료

`~/Documents/PaperTimePapers` (61편). 저장소에는 넣지 않는다.
수식 읽기를 건드렸다면 최소한 이 넷으로 확인할 것 —
VAE(`auto-encoding variational bayes.pdf`, 단단 조판, 식 1·3·5·7·8·10),
V-JEPA 2(식 2·3·4), `5308_The_Forgetting_Retention_`(2단, 단 사이 간격 14pt),
`Fast Machine Unlearning…`(다른 앱이 남긴 하이라이트 105개).

노트는 `~/Documents/PaperTimePapers/.papertime/notes/<id>.md`. 하나당 파일 하나,
YAML 머리말 + Markdown 본문이라 다른 앱으로도 읽힌다.

**앱이 켜진 채로 노트 파일을 지우면 되살아난다.** 앱이 그 노트를 메모리에 들고
있다가 종료할 때 도로 쓴다. 노트 폴더의 외부 변경을 앱이 보고 있지 않다 —
클라우드 폴더에 라이브러리를 두는 설계라 언젠가 물릴 자리다.

## 단축키

앱의 **모든** 명령이 설정에서 바뀐다. 정의는 `App/Model/Shortcuts.swift`
(`ShortcutAction` 열거형 하나에 기본값까지), 저장은 `AppModel.paneShortcuts`
(UserDefaults, 바뀔 때마다 스스로 기록), 메뉴 적용은
`PaperTimeCommands.command(_:_:run:)`, 설정 UI는
`App/Views/ShortcutRecorder.swift`.

새 명령을 만들면 `ShortcutAction`에 case 하나만 추가하면 메뉴와 설정에 동시에
나온다. 하드코딩된 `keyboardShortcut`을 새로 쓰지 말 것.

`⌘,`(설정)만 예외다. SwiftUI의 `Settings` 씬이 자기 항목을 따로 넣기 때문에
우리 것을 더하면 메뉴에 Settings가 **두 개** 생긴다. 그래서 목록에는 보이되
바꿀 수 없는 행으로 뒀다(`ShortcutAction.isFixed`).

한 키는 한 명령에만 붙는다. 다른 창에 이미 있는 키를 주면 원래 주인은 단축키가
없는 상태(`—`)가 되고, 메뉴 항목은 남되 키만 빠진다.

단축키를 받는 필드(`ShortcutRecorder`)에는 두 개의 함정이 있었다.

- `keyDown`으로는 ⌘ 조합을 못 받는다. 창이 먼저 뷰들에게 key equivalent로
  물어보고, 아무도 안 가져가면 메뉴 막대로 넘어간다 — ⌘P와 ⌘\가 이미 사는 곳이
  거기다. `performKeyEquivalent`로 들어야 한다.
- `charactersIgnoringModifiers`는 입력 소스를 거친다. **한글 입력 상태에서 J를
  누르면 "ㅓ"가 돌아오고**, "ㅓ"에 걸린 메뉴 단축키는 한글 상태에서만 작동한다.
  `TISCopyCurrentASCIICapableKeyboardLayoutInputSource` + `UCKeyTranslate`로
  물리 키를 읽어야 한다. Carbon이 `EventModifiers`를 따로 정의하므로 SwiftUI 쪽은
  `SwiftUI.EventModifiers`로 명시해야 한다.

`⌘P`는 원래 시스템 Print 항목이 가져가므로 `CommandGroup(replacing: .printItem) {}`
로 비워뒀다. Print를 다시 넣을 일이 생기면 그 충돌부터 풀어야 한다.

**메뉴 단축키가 이상해 보이면 `defaults read com.imtaeheon.PaperTime paneShortcuts`
부터 확인할 것.** 저장된 값이 기본값을 덮는 것이지 코드가 틀린 게 아닐 때가 있다.
그리고 빌드 산출물이 백그라운드에 살아 있으면 그쪽 메뉴를 읽게 된다 —
`pgrep -lf "Paper Time.app/Contents/MacOS"`로 몇 개가 떠 있는지 먼저 보라.
(Spotlight에서 "Paper Time"이 두 개로 보이면 대개 DerivedData의 Debug/Release
산출물이지 설치본이 아니다.)

## 창의 생김새

`App/Views/LiquidGlass.swift`, `App/Views/Reader/WindowToolbarBand.swift`,
`App/Views/RootView.swift`의 `Column`.

창은 **바탕 위에 뜬 둥근 패널 네 장**이다 — 사이드바, 목록, 페이지, 인스펙터.
패널 사이의 틈이 곧 크기를 조절하는 드래그 스트립이다. 실선은 어디에도 없다:
평면 배경끼리 직각으로 맞대면 둥근 창 안에 직선이 그어지는데, 그건 앱의 나머지가
쓰지 않는 유일한 모양이다.

**유리는 눈이 통과해서 보는 곳에만 있다.** 바탕·툴바·페이지 위에 뜬 바는 유리고,
읽는 면(패널)은 거의 불투명하다(`Glass.pane.body = 0.82`). 절반쯤 투명했을 때는
논문과 노트를 벽지 색 위에서 읽게 됐다.

이 파일들에서 시도했다가 되돌린 것이 있고, 이유가 주석에 남아 있다 —
정반사 림(스트로크로 그리면 유리가 아니라 흰 외곽선으로 읽힌다), 상단 sheen
(높이의 비율이라 긴 컬럼에선 위쪽 3분의 1이 하얘진다). 다시 넣고 싶어지면
그 주석부터 읽을 것.

몇 가지 알아둘 것:

- **material을 겹치면 같은 데스크톱을 두 번 블러한다.** 패널과 바탕이 둘 다
  material이면 패널은 뿌옇고 틈은 맑아서, 그 경계가 둥근 코너를 따라 T자로
  번진다. 창에 블러는 한 겹만.
- **창을 비-불투명으로 만들지 않으면 유리가 유리가 아니다** (`translucentWindow()`).
  그러지 않으면 material이 데스크톱이 아니라 창 자신의 불투명 회색을 블러한다.
- **`.inset` 리스트와 `.grouped` 폼은 자기 불투명 배경을 그린다.**
  `.scrollContentBackground(.hidden)`이 필요하다. `.sidebar` 리스트는 안 그린다.
- **툴바 밴드**: material 툴바 배경을 선언하면 창이 full-size content view가
  되고, SwiftUI는 top safe area를 0으로 보고한다. 창의 위쪽에 붙인 것은 툴바
  **뒤에** 그려진다. AppKit의 `contentView.safeAreaInsets.top`이 유일한 출처고,
  그 값은 툴바 설치 전 32 / 후 52로 **바뀐다** — 너무 일찍 물으면 틀린 답을 얻는다.
  그리고 창 부위마다 시작 y가 다르다(사이드바 헤더 52, 리더와 인스펙터 0).

## 창의 움직임

- **커브는 하나뿐이다** (`AppModel.paneMotion`). 토글이 `withAnimation`으로 열고
  뷰가 `.animation(value:)`로 또 거는 일이 있었다 — 같은 폭을 두 커브로 보간했다.
  포커스 모드가 토글을 호출하면 트랜잭션이 **중첩**되니, 상태를 직접 세팅한다.
- **닫히는 컬럼은 쥐어짜지 말고 가린다.** 폭을 애니메이트하면 안의 `List`
  (`NSTableView`)나 `PDFView`가 매 프레임 다시 배치된다. 안쪽 프레임을 자기 폭으로
  고정하고 바깥 프레임만 접으면 배치가 한 번으로 끝난다.
  그리고 폭 0을 받은 `PDFView`/`Form`은 **아무것도 그리지 않아서**, 패널만 남은
  한 프레임이 흰 유리판으로 번쩍인다. 그게 "흰 배경이 한 번 보였다 사라지는"
  증상의 정체였다.
- `ColumnDivider`는 **자기가 어느 쪽 컬럼을 조절하는지** 알아야 한다
  (`resizes:`). 사이드바·목록은 divider의 왼쪽, 인스펙터는 오른쪽이라 부호가 반대다.

**프레임 드롭을 추측으로 고치지 말 것.** 이번에 그림자·바탕 material·둥근 클립·
창 투명도·Release 빌드를 전부 의심했다가 하나씩 반증했다. 재는 법은
`CADisplayLink`로 프레임 간격을 찍는 것이고, 그렇게 재보니 남은 비용은 폭이
실제로 변하는 리더의 `PDFView` 재배치(약 5분의 1)뿐이었다.

## 노트

본문은 **시스템 페이스**(SF) 16pt, 한글은 Pretendard를 cascade로 얹는다. 세리프
(STIX Two Text)였는데, 수식과 가족을 맞추려던 선택이 문장 쪽 비용을 매 줄 치르게
했다. 수식은 여전히 수식 페이스(STIX Two Math)로 짜되 **본문의 point size가 아니라
x-height에 맞춘다**(`NoteTypography.mathSize(forBody:)`) — 같은 포인트에서 두 폰트의
x-height가 달라서 수식이 작고 아래로 처져 보였다.

**갈 수 있는 것은 어디서나 둥근 틴트 안의 글자다** — 본문의 인용구(⌘L), 노트 아래의
연결, 그리고 페이지 위. 파란 하이퍼링크가 아니다.

⌘L 칩(`App/Views/Notes/NoteChip.swift`)에서 짚어야 했던 세 가지:

- **붙이지 않고 그린다.** `NSTextAttachment`은 인용 전체를 글리프 하나로 만들어
  줄바꿈과 단어 단위 선택을 없앤다. 커스텀 `NSTextLayoutFragment`가 런 뒤에 칠한다.
- **`.link`가 아니다.** `NSTextView`는 링크 런을 **런이 뭐라 하든 자기 링크색으로**
  칠한다. 칩은 목적지를 자기 속성에 들고 클릭을 직접 받는다.
- **파서도 알아야 한다.** `NoteMarkdown.link(for:)`는 삽입 경로일 뿐이라,
  노트를 다시 열 때 도는 파서 쪽도 같이 고쳐야 한다.

목록 미리보기(`Zettel.preview`)는 **표기법을 빼고 산문만** 남긴다. 수식은 노트 안의
객체지 문장이 아니라서 요약에 넣지 않는다.

## 그래프

`App/Views/Graph/`. 논문은 인용·노트 링크·공저자·같은 컬렉션으로 이어진다.
범례는 곧 필터다 — 선 하나를 끄면 그 종류의 연결이 사라지므로, 인용을 끄면
**내 노트가 이은 것만** 남는다. 그게 이 뷰의 주된 쓸모다.
패널의 "How to use it"은 아무것도 선택되지 않았을 때만 나온다.

## 배포용 dmg 만들기

```sh
./Tools/make-dmg.sh
```

Release로 빌드하고, 디버그용 entitlement(`get-task-allow`)를 떼기 위해 우리가
선언한 entitlements로 다시 서명한 뒤, `Paper Time <버전>.dmg`를 만든다.
버전은 `project.yml`의 `MARKETING_VERSION`에서 읽는다.
`.dmg-build/`(265MB)는 **다음 실행 시작할 때** 지워지므로 만든 뒤 계속 남는다.

**서명은 애드혹이다.** 무료 개발자 계정으로는 Developer ID를 받을 수 없고,
공증(notarization)은 Developer ID가 있어야 한다. 그래서 다른 Mac에서는
Gatekeeper가 거부한다(`spctl: rejected`).

받는 쪽에서 뜨는 메시지는 **"Apple could not verify …is free of malware"**이고,
해결은 둘 중 하나다:

1. 앱을 응용 프로그램 폴더로 옮기고 한 번 열어 경고를 띄운 뒤,
   **시스템 설정 → 개인정보 보호 및 보안 → 보안 → 그래도 열기**.
   (버튼은 한 번 막히고 나서야 나타난다.)
2. ```sh
   xattr -dr com.apple.quarantine "/Applications/Paper Time.app"
   ```

**우클릭 → 열기는 macOS 15부터 통하지 않는다.** 예전 이 문서에 그렇게 적혀
있었는데 틀린 안내다. zip으로 보내도 같다 — 격리 표시는 전송 방식이 아니라
"다운로드됨"에 붙는다. 예외는 `scp`/`rsync`뿐.

앱은 arm64 전용이고 `LSMinimumSystemVersion`이 **26.0**이다. Sonoma(14)에서는
실행 자체가 안 된다. 낮추려면 macOS 26 전용 API 세 개(`.buttonStyle(.glass)`,
`ToolbarSpacer`, `sharedBackgroundVisibility`)와 15 전용 두 개
(`toolbarBackgroundVisibility`, `onGeometryChange`)를 전부 갈아야 하고,
universal 빌드로도 바꿔야 한다.

## 지금 상태

브랜치 `reading-the-page`가 `main`보다 앞서 있다. **원격이 없다.**

## 알려진 미해결

1. `cases` 환경(중괄호로 두 줄을 묶는 수식)은 ultracopy에서 아직 깨진다.
2. 그림 안에 비표준 폰트로 그려진 라벨은 PDFKit도 못 읽는다. 원본의 한계다.
3. `\Pr` 같은 연산자의 극한이 2단 논문의 밀집 레이아웃에서 가끔 별도 블록으로
   떨어진다. 같은 페이지의 다른 식들은 제대로 나온다.
4. 인라인 코드 뒤에 오는 마크다운 링크가 원문 그대로 렌더된다 — 노트 파서 버그.
5. 노트 폴더의 외부 삭제·수정을 앱이 보고 있지 않다(위 "테스트 자료" 참고).
6. 페인 애니메이션에서 프레임의 약 3분의 1이 늦게 도착한다. 리더의 `PDFView`
   재배치가 남은 원인이고, 애니메이션이 하는 일 자체를 바꾸지 않으면 못 없앤다.
7. `PLAN.md` 기준 미착수: iPad 펜 필기(GoodNotes식 문지르기 지우개),
   스캔본 Vision OCR.

## 다시 실수하지 않기 위한 메모

- 수식을 눈으로 판단하지 말 것. 의심스러우면 그 영역을 PNG로 렌더해서 **실제로
  무엇이 그려졌는지** 보고 결정한다.
- 같은 조작이 어떨 때는 되고 어떨 때는 안 되면, 못 믿을 곳에서 정보를 읽고
  있다는 뜻이다. PDFKit의 드래그를 `NSEvent` 모니터로 가로채려 한 것이 그랬다.
  판단 근거는 `PDFSelection` 쪽에서 가져와야 한다.
- **증상이 나타나는 범위를 먼저 보라.** "논문과 인스펙터만 흰색으로 번쩍인다"에서
  그 둘이 마침 처리를 안 한 둘이었다는 것이 답이었다.
- **UI 자동화로 SwiftUI `List` 행은 선택되지 않는다.** 합성 클릭도, 대부분의 AX
  경로도 안 먹는다. 사이드바는 `set selected of (item N of rows of outline 1 of
  scroll area 1 of group 1 of window 1) to true`가 통한다.
- 사용자 파일(논문 PDF·노트)을 지우거나 덮어쓰기 전에 반드시 사본을 뜬다.
