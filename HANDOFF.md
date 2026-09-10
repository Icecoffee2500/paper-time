# 이어받기

새 세션에서 이 파일 하나만 읽으면 따라잡을 수 있게 쓴 문서다.
원칙과 제약은 `CLAUDE.md`, 결정 정본은 `PLAN.md`.

## 먼저 할 것

```
git log -6 --stat
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
`sources: App` 이 디렉터리를 통째로 훑으므로 파일을 추가할 때 등록할 곳은 없다.
프로젝트가 꼬이면 `xcodegen generate`로 다시 만들면 된다.

## 테스트 자료

`~/Documents/PaperTimePapers` (61편). 저장소에는 넣지 않는다.
수식 읽기를 건드렸다면 최소한 이 넷으로 확인할 것 —
VAE(`auto-encoding variational bayes.pdf`, 단단 조판, 식 1·3·5·7·8·10),
V-JEPA 2(식 2·3·4), `5308_The_Forgetting_Retention_`(2단, 단 사이 간격 14pt),
`Fast Machine Unlearning…`(다른 앱이 남긴 하이라이트 105개).

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

단축키를 받는 필드(`ShortcutRecorder`)에는 두 개의 함정이 있었다. 둘 다
다시 만나기 쉬운 종류다.

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
그리고 Xcode에서 실행한 빌드가 백그라운드에 살아 있으면 그쪽 메뉴를 읽게 된다 —
`pgrep -lf "Paper Time.app/Contents/MacOS"`로 몇 개가 떠 있는지 먼저 보라.

## 지금 상태

브랜치 `reading-the-page`가 `main`보다 6커밋 앞서 있다. **원격이 없다.**

## 알려진 미해결

1. `cases` 환경(중괄호로 두 줄을 묶는 수식)은 ultracopy에서 아직 깨진다.
2. 그림 안에 비표준 폰트로 그려진 라벨은 PDFKit도 못 읽는다. 원본의 한계라
   우리가 고칠 수 있는 것이 아니다.
3. `\Pr` 같은 연산자의 극한이 2단 논문의 밀집 레이아웃에서 가끔 별도 블록으로
   떨어진다. 같은 페이지의 다른 식들은 제대로 나온다.
4. `PLAN.md` 기준 미착수: iPad 펜 필기(GoodNotes식 문지르기 지우개),
   스캔본 Vision OCR.

## 다시 실수하지 않기 위한 메모

- 수식을 눈으로 판단하지 말 것. 의심스러우면 그 영역을 PNG로 렌더해서 **실제로
  무엇이 그려졌는지** 보고 결정한다. 이번 작업의 고비는 전부 그렇게 풀렸다.
- 같은 조작이 어떨 때는 되고 어떨 때는 안 되면, 못 믿을 곳에서 정보를 읽고
  있다는 뜻이다. PDFKit의 드래그를 `NSEvent` 모니터로 가로채려 한 것이 그랬다.
  PDFKit은 드래그를 자기 추적 루프에서 처리해서 mouseUp이 오지 않을 때가 있다.
  판단 근거는 `PDFSelection` 쪽에서 가져와야 한다.
- 사용자 파일(논문 PDF·노트)을 지우거나 덮어쓰기 전에 반드시 사본을 뜬다.
