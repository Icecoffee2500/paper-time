# Paper Time

Apple 네이티브(macOS/iPadOS/iOS 26) 논문 리더 + 필기 + 서지관리 앱. 전체 계획과 결정 사항은 `PLAN.md`가 정본이다.

## 원칙
- 우선순위: 읽기 경험 > 필기가 PDF 파일에 기록됨 > 서지 정확도 > BibTeX 내보내기.
- UI/UX는 Apple HIG를 따르고 시스템 컴포넌트만 사용한다. 커스텀 위젯·브랜드 색 강요 금지.
- 서지 파싱은 틀린 값을 조용히 저장하지 않는다. 확신 없으면 `needsReview`.
- 사용자 데이터는 조용히 덮어쓰지 않는다. 저장 전 재로드·병합, 충돌은 UI로 노출.

## 기술 제약
- 무료 Apple 개발자 계정: CloudKit/iCloud 컨테이너 entitlement 사용 불가. 라이브러리는 사용자가 고른 클라우드 폴더(iCloud Drive/Google Drive)에 파일로 저장한다(`PLAN.md` 3.1).
- LLM은 온디바이스 Foundation Models만 사용. 클라우드 LLM 코드 추가 금지.
- Overleaf 자동 연동 없음. `.bib` 내보내기 품질에 집중.

## 코드 구성
- Swift 6, SwiftUI, Swift Package로 모듈 분리: PaperCore, LibraryStore, PDFReader, InkEngine, MetadataPipeline, Bibliography, Importers.
- 테스트 코퍼스 PDF는 저장소 밖 `~/Documents/Bookends/Attachments`(58편) + `~/Documents/Bookends/vla`(3편). 정답은 `Tests/Corpus/ground_truth.json`에 둔다. PDF를 저장소에 커밋하지 않는다.

## 빌드/실행
- Xcode 26.6. 앱 타겟 실행은 Xcode 또는 `xcodebuild`. 시뮬레이터 확인은 iOS Simulator 도구 사용.
- iOS 빌드: `xcodebuild -scheme PaperTime -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build`, 설치·실행은 `xcrun simctl install/launch`. 시뮬레이터를 손대지 않고 몰고 가려면 환경변수: `SIMCTL_CHILD_PAPERTIME_LIBRARY=PaperTimePapers`(앱 Documents 안 상대경로), `…_SKIP_WELCOME=1`, `…_ADOPT_LOOSE=1`(폴더의 PDF를 들여옴), `…_OPEN_FIRST=1`(첫 논문을 연다). 시뮬레이터에서 필기·지우개를 시험하려면 AA 메뉴의 Draw with Finger를 켠다; 탭을 여러 개 이어 보내면 메뉴 애니메이션에 먹히니 한 탭마다 스크린샷으로 확인한다. 캡처는 `xcrun simctl io <UDID> screenshot`.
- 필기 층(세 기기 공통): 하이라이트·밑줄은 PDF 주석이고 `MarkOverlayView`가 둥근 끝으로 그린다. 잉크는 쪽마다 사이드카 `.papertime/papers/<id>/ink/pNNNN.drawing`이 **진실**이고, PDF 속 잉크 주석은 저장 때 써 내는 사본이다(경로는 주석 bounds 기준 좌표 — PDFKit이 `/InkList`에 원점을 더한다). 파일에만 있는 잉크는 열 때 `InkConverter.drawing(fromOwnedInkOn:)`으로 사이드카를 만든다. 오버레이 아래에서는 PDF의 잉크 사본을 항상 숨긴다(`hideOwnedInk`). 아이패드·아이폰은 `PKCanvasView`가, 맥은 `InkOverlayView`(PKDrawing 렌더)가 사이드카를 그린다. 지우개는 `PageOverlay`가 직접 받는다(캔버스 위의 팬 제스처는 스트로크가 시작되면 취소된다).
- 펜 도구: `ReaderConfiguration.tool/presets`(`InkTool`, `PenColor`, `InkPresets`)가 상태, `MarkingToolbar`(iOS)가 제목 아래 도구 줄. PKToolPicker는 쓰지 않는다 — 캔버스 tool은 `configuration.currentTool`로 코디네이터가 맞춘다. 형광펜만 글자에 맞춘다(위=하이라이트, 아래=밑줄); 펜은 절대 스냅하지 않는다.
- 동기화(iCloud Drive만; 근거리 전송은 뺐다): 표시는 기기별 저널 `.papertime/papers/<id>/marks/<device>.json`에 즉시, PDF에는 1.5초 뒤 저널대로 다시 쓴다(`DocumentSession.reconcile`). `DocumentWatcher`(파일 프리젠터+kqueue)와 3초 폴링(`requestPendingDownloads`)이 도착을 알린다. CloudKit(푸시)은 무료 계정으로 쓸 수 없다.
- **쓰라고 설치하는 것은 Release다.** `~/Applications`에 Debug 빌드를 넣어 두고 있었는데, Swift의 Debug 빌드는 문자열·컬렉션이 많은 코드에서 몇 배 느리다 — 실측으로 시작할 때 메인 스레드가 멈추는 시간이 4.8초(Debug) 대 2.8초(Release)였다. 디버깅은 `build/mac`(Debug)로 하고, 사용자가 여는 사본은 `xcodebuild -configuration Release -derivedDataPath build/release CODE_SIGN_IDENTITY="-"`로 지어 넣는다.
- 느려졌다 싶으면 재지 말고 **자 대고 재라**: `--papertime-trace=1`(또는 `PAPERTIME_TRACE=1`)이면 4 ms를 넘는 단계와 메인 스레드가 50 ms 넘게 멈춘 자리를 찍고, 앱이 끝날 때 무엇에 시간이 갔는지 합계를 낸다(`Trace`, `Hitches`). 곁들여 `sample "Paper Time" 5 -file …`으로 그 순간의 스택을 보면 어디인지 나온다 — 이 방법으로 찾은 것이 "행마다 컨텍스트 메뉴를 통째로 짓고 있었다"였다.
- 실행 설정은 환경변수와 **명령줄 인자 둘 다**로 준다(`Boot`): `PAPERTIME_OPEN_TITLE=EWC`와 `--papertime-open-title=EWC`가 같다. 번들을 `open`으로 띄울 때는 환경변수를 넘길 길이 없어서 인자 쪽이 필요하다 — `open -a "…/Paper Time.app" --stderr /tmp/t.log --args --papertime-trace=1`.
- 창을 띄우지 않고 확인하기: 노트 조판은 `PAPERTIME_DUMP_NOTE=<마크다운 그 자체>`가 런 단위로 찍는다(샌드박스라 경로는 못 읽는다). `PAPERTIME_DUMP_NOTE_IMAGE=<컨테이너 안 경로>`를 같이 주면 같은 노트를 그려 PNG로 남긴다 — 인용의 세로줄과 조판된 수식은 그려지는 것이라 속성 목록에는 나오지 않으니, 그 둘은 그림으로만 확인된다. 본문 검색 색인은 앱 없이도 돈다: `swiftc -O App/Model/PaperTextIndex.swift Scripts/search-probe.swift -o /tmp/probe && /tmp/probe unlearning ~/Documents/Bookends/Attachments`(`PaperTextIndex`가 Foundation·PDFKit 말고는 아무것도 안 쓰는 이유). 팔레트 자체는 `PAPERTIME_SHOW_SEARCH=<찾을 말>`로 그 말이 적힌 채 열리고, `PAPERTIME_SEARCH_JUMP=1`을 더하면 첫 본문 결과를 눌러 그 줄로 간다 — 키를 쏘지 않고 끝까지 보는 길.
- 플랫폼 분기: AppKit 전용 파일은 `#if os(macOS)`로 통째로 감싸고 UIKit 쌍을 옆에 둔다(`MarkOverlayView`, `MarginMaskView`, `PageOverlay`). 색은 `PlatformColorShims.swift`가 AppKit 이름을 UIKit에 준다.

## 기능 소개(스니펫) 규칙
새 기능이 **중요한 기능**이면 — 즉 한 문장으로는 무엇인지 와닿지 않거나, 사용자가 모르면 영영 안 쓰게 될 기능이면 — 코드만 쓰고 끝내지 않는다. 다음을 **같은 커밋에서** 함께 한다.

1. `ReleaseNotes.Demo`에 케이스를 하나 더하고, `App/Views/FeatureDemos.swift`에 그 데모를 만든다.
   - 녹화 영상이 아니라 **동작하는 SwiftUI**로 만든다. 영상은 번들을 불리고, UI를 고치는 순간 낡고, 만져볼 수 없다.
   - `DemoScale`을 받아 `.compact`(로그용)와 `.full`(About·환영 화면용) 두 크기로 자란다. 두 벌을 따로 만들지 않는다.
   - 단축키는 `app.shortcut(for:)`로 읽는다. 사용자가 키를 바꾸면 데모도 따라 바뀌어야 한다.
   - 실제 UI와 같은 형태로 만든다 — 같은 카드, 같은 행 높이, 같은 분류 캡션. 그림이 아니라 축소판이어야 한다.
2. `ReleaseNotes.releases`의 해당 버전 `added`에 항목을 더하고 `demo:`를 건다. 제목은 키워드, 설명은 한 문장.
3. 헤드라인급이면 `ReleaseNotes.highlights`에도 더한다. 그러면 **About과 환영 화면 양쪽에 자동으로** 실물 크기로 나온다(`FeatureShowcase` 하나를 둘이 같이 쓴다).
4. 필요하면 `ReleaseNotes.groups`(모든 기능 목록)에도 한 줄 더한다.
5. 한글을 먼저 쓴다. `Text2(ko, en)` / `ReleaseNotes.string(ko, en)`.
6. 다른 앱과 다른 점이 핵심이면 데모 안에서 **나란히 비교**한다(주석의 "다른 PDF 앱 / Paper Time", 책의 자르기 전·후 토글처럼). 한 문장으로 "더 예쁘다"보다 두 그림이 낫다.
7. 창을 띄우지 않고 확인한다: `PAPERTIME_RENDER_DEMOS=<쓸 수 있는 폴더>`(샌드박스 안, 예: `~/Library/Containers/com.imtaeheon.PaperTime/Data/tmp/demos`)로 앱을 실행하면 모든 데모를 두 크기로 PNG로 그리고 끝난다. `ImageRenderer`라 ScrollView 내용과 ProgressView는 비어 보이는데, 그건 렌더러의 한계다.

## 브랜치 규칙
버전마다 가지를 셋으로 나눈다. `v0.1.0`과 `v0.1.0/dev`는 git이 동시에 가질 수 없는 이름이라(ref 충돌) 접두사를 앞에 둔다.

| 가지 | 무엇을 하는 곳 |
|---|---|
| `main` | 닫힌 버전만 들어온다. 직접 작업하지 않는다. |
| `v0.1.0` | 이번 버전. `main`에서 갈라져 나온다. |
| `dev/v0.1.0` | **새 기능**은 여기서. |
| `debug/v0.1.0` | **오류 수정**은 여기서. |
| `ipad/v0.1.0`, `iphone/v0.1.0` | 기기별 이식은 버전 밑에 기기 가지로. |

흐름:

```bash
# 버전을 연다
git switch main && git switch -c v0.1.0
git branch dev/v0.1.0 v0.1.0 && git branch debug/v0.1.0 v0.1.0

# 개발 중 — 기능은 dev, 수정은 debug
git switch dev/v0.1.0     # 새 기능
git switch debug/v0.1.0   # 오류 수정

# 안정화되면 둘 다 버전 가지로 합치고, 버전을 닫는다
git switch v0.1.0
git merge --no-ff dev/v0.1.0 debug/v0.1.0
git switch main && git merge --no-ff v0.1.0 && git tag 0.1.0   # 태그는 v 없이 — 브랜치 v0.1.0과 이름이 겹친다
Scripts/publish-release.sh 0.1.0  # DMG를 만들어 릴리스에 올리고 배포 페이지를 다시 쓴다
git push origin main --tags
```

배포 페이지는 `Website/`에 있고 `gh-pages` 가지에서 서비스된다 —
<https://icecoffee2500.github.io/paper-time/>. `Scripts/publish-release.sh <tag>`가
`Scripts/make-dmg.sh`를 불러 DMG를 만들고, GitHub 릴리스에 올리고,
`Website/releases.json`을 다시 써서 `gh-pages`로 옮긴다. 그 json은 소스 쪽에도
같이 커밋한다. `Docs/`는 이 프로젝트가 스스로 두는 메모이지 배포 페이지가 아니다
(대소문자를 가리지 않는 디스크에서 `docs/`로 보여도 git은 가린다).

한쪽에서 고친 것이 다른 쪽에 당장 필요하면, 그 가지를 기다리지 말고 `git merge debug/v0.1.0`으로 끌어온다. 버전을 닫기 전까지 `main`은 건드리지 않는다.

개발 현황은 `python3 Scripts/board.py`로 본다 — 가지별 상태와 커밋 그래프를 HTML로 그려서 열어준다.
