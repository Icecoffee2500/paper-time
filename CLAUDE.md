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
- **맥 최소 버전은 14(Sonoma), 아이패드·아이폰은 26.** `project.yml`의 `deploymentTarget.macOS`와 `Package.swift`의 `.macOS("14.0")` 둘이 한 쌍이다. 26/15 전용 API는 `#available`로 가른다 — 지금 갈라 둔 것: FoundationModels 전체(`OnDeviceHeaderExtractor`, 26), 도구 막대의 `ToolbarSpacer`·`sharedBackgroundVisibility`(26)와 `toolbarBackgroundVisibility`(15) → `RootView.decorated`의 두 가지, `onScrollGeometryChange`(15) → `View.onPull`, `Color.mix`(15) → `Color.mixed`. FoundationModels는 `OTHER_LDFLAGS`로 **약하게 링크**한다 — 강하게 걸면 Sonoma의 dyld가 앱 자체를 안 띄운다(`otool -l … | grep -B3 FoundationModels`로 `LC_LOAD_WEAK_DYLIB`인지 본다). `CustomizableToolbarContentBuilder`는 없다 — 도구 막대 내용은 `#available`로 감싼 헬퍼를 못 만들고 호출 자리에서 가른다. 이 컴퍼일이 통과한다는 것과 Sonoma에서 돈다는 것은 다르다: 실기 확인은 Sonoma VM에서 한다(이 맥에는 VMware Fusion 13이 있고, `softwareupdate --list-full-installers`에 14.8.x 설치 프로그램이 있다).
- Xcode 26.6. 앱 타겟 실행은 Xcode 또는 `xcodebuild`. 시뮬레이터 확인은 iOS Simulator 도구 사용.
- iOS 빌드: `xcodebuild -scheme PaperTime -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build`, 설치·실행은 `xcrun simctl install/launch`. 시뮬레이터를 손대지 않고 몰고 가려면 환경변수: `SIMCTL_CHILD_PAPERTIME_LIBRARY=PaperTimePapers`(앱 Documents 안 상대경로), `…_SKIP_WELCOME=1`, `…_ADOPT_LOOSE=1`(폴더의 PDF를 들여옴), `…_OPEN_FIRST=1`(첫 논문을 연다). 시뮬레이터에서 필기·지우개를 시험하려면 AA 메뉴의 Draw with Finger를 켠다; 탭을 여러 개 이어 보내면 메뉴 애니메이션에 먹히니 한 탭마다 스크린샷으로 확인한다. 캡처는 `xcrun simctl io <UDID> screenshot`.
- 필기 층(세 기기 공통): 하이라이트·밑줄은 PDF 주석이고 `MarkOverlayView`가 둥근 끝으로 그린다. 잉크는 쪽마다 사이드카 `.papertime/papers/<id>/ink/pNNNN.drawing`이 **진실**이고, PDF 속 잉크 주석은 저장 때 써 내는 사본이다(경로는 주석 bounds 기준 좌표 — PDFKit이 `/InkList`에 원점을 더한다). 파일에만 있는 잉크는 열 때 `InkConverter.drawing(fromOwnedInkOn:)`으로 사이드카를 만든다. 오버레이 아래에서는 PDF의 잉크 사본을 항상 숨긴다(`hideOwnedInk`). 아이패드·아이폰은 `PKCanvasView`가, 맥은 `InkOverlayView`(PKDrawing 렌더)가 사이드카를 그린다. 지우개는 `PageOverlay`가 직접 받는다(캔버스 위의 팬 제스처는 스트로크가 시작되면 취소된다).
- 펜 도구: `ReaderConfiguration.tool/presets`(`InkTool`, `PenColor`, `InkPresets`)가 상태, `MarkingToolbar`(iOS)가 제목 아래 도구 줄. PKToolPicker는 쓰지 않는다 — 캔버스 tool은 `configuration.currentTool`로 코디네이터가 맞춘다. 형광펜만 글자에 맞춘다(위=하이라이트, 아래=밑줄); 펜은 절대 스냅하지 않는다.
- 동기화(iCloud Drive만; 근거리 전송은 뺐다): 표시는 기기별 저널 `.papertime/papers/<id>/marks/<device>.json`에 즉시, PDF에는 1.5초 뒤 저널대로 다시 쓴다(`DocumentSession.reconcile`). `DocumentWatcher`(파일 프리젠터+kqueue)와 3초 폴링(`requestPendingDownloads`)이 도착을 알린다. CloudKit(푸시)은 무료 계정으로 쓸 수 없다.
- **쓰라고 설치하는 것은 Release다.** `~/Applications`에 Debug 빌드를 넣어 두고 있었는데, Swift의 Debug 빌드는 문자열·컬렉션이 많은 코드에서 몇 배 느리다 — 실측으로 시작할 때 메인 스레드가 멈추는 시간이 4.8초(Debug) 대 2.8초(Release)였다. 디버깅은 `build/mac`(Debug)로 하고, 사용자가 여는 사본은 `xcodebuild -configuration Release -derivedDataPath build/release CODE_SIGN_IDENTITY="-"`로 지어 넣는다.
- 느려졌다 싶으면 재지 말고 **자 대고 재라**: `--papertime-trace=1`(또는 `PAPERTIME_TRACE=1`)이면 4 ms를 넘는 단계와 메인 스레드가 50 ms 넘게 멈춘 자리를 찍고, 앱이 끝날 때 무엇에 시간이 갔는지 합계를 낸다(`Trace`, `Hitches`). 곁들여 `sample "Paper Time" 5 -file …`으로 그 순간의 스택을 보면 어디인지 나온다 — 이 방법으로 찾은 것이 "행마다 컨텍스트 메뉴를 통째로 짓고 있었다"였다.
- 실행 설정은 환경변수와 **명령줄 인자 둘 다**로 준다(`Boot`): `PAPERTIME_OPEN_TITLE=EWC`와 `--papertime-open-title=EWC`가 같다. 번들을 `open`으로 띄울 때는 환경변수를 넘길 길이 없어서 인자 쪽이 필요하다 — `open -a "…/Paper Time.app" --stderr /tmp/t.log --args --papertime-trace=1`.
- **표 분석은 꺼 두었다.** `-[PDFView setDocumentAnalysisEnabled:]`(헤더에 없는 PDFKit의 스위치, `responds(to:)`로 확인해서 KVC로 내린다)가 macOS 26의 Vision 표 분석과 셀 선택 모드를 함께 끈다 — 사용자가 표 안에서 자유롭게 드래그하고 싶어 했고, 아래 두 항목의 병리(쪽을 배경에서 다시 쓰는 것, 줄 자리가 없는 선택)도 그 분석이 근원이다. 켜져 있던 시절의 기록은 그대로 남겨 둔다. 스위치를 찾은 방법: `objc` 런타임으로 PDFKit 클래스의 메서드 이름을 훑었다(`class_copyMethodList`; 전체 클래스 목록을 돌면 이상한 클래스에 걸려 죽으니 이름을 지정해서). `dyld_info -objc`는 공유 캐시 안의 프레임워크에는 안 먹는다.
- **표가 있는 쪽은 PDFKit이 제 스레드에서 만지고 있다.** macOS 26의 PDFKit은 새로 보이는 쪽을 Vision에 넘겨 표를 찾고(`PDFPageAnalyzerV2 addTablesFromVisionDocument:…toPage:`, `PDFKit.PDFDocument.formFillingQueue`), 그 결과를 쪽에 되쓴다 — 같은 사각형을 두 번 선택하면 줄 수가 31개에서 76개로 바뀌는 것으로 확인된다. 그러니 **쪽을 오래 붙들지 마라**: 표시를 글자에 맞추려고 줄마다 `page.draw`를 부르던 코드가 표 하나에 백 번을 그렸고, 그게 표에서만 앱이 죽던 자리다(`InkStrip`은 이제 표시 하나에 한 번만 그린다). 끄는 API는 없다.
- **Swift 태스크 안에서 Objective-C 예외가 나면 그 자리에서 안 죽고 다음 아무 곳에서 죽는다.** AppKit이 예외를 삼키는 동안 스택이 `swift_job_run`을 뚫고 풀려서 동시성 런타임의 스레드 로컬이 죽은 스택 프레임을 가리키게 되고, 그 다음 `@MainActor` 메서드에 들어갈 때(`swift_task_isCurrentExecutor`)에 `swift_getObjectType`에서 죽는다 — 크래시 로그에는 `mouseMoved`, `viewDidMoveToWindow` 같은 무관한 곳이 찍히고, 옆에 `HIE:` 스레드(`SOME_OTHER_THREAD_SWALLOWED_AT_LEAST_ONE_EXCEPTION`)가 서 있다. 그 로그가 보이면 크래시 자리를 보지 말고 **`/usr/bin/log show --predicate 'processImagePath CONTAINS "Paper Time" AND messageType == error'`로 몇 초 전의 `*** Assertion failure`를 찾아라**(zsh의 `log`는 내장 명령이라 `/usr/bin/log`). 실제 사례: 표를 가로지른 선택에 PDFKit이 `bounds(for:)`를 `nan`으로 돌려줬고(`isEmpty`도 `isNull`도 `nan`을 통과시킨다 — `CGRect.isFinite`가 그래서 있다), 표시 막대를 `{nan, nan}`에 세우려다 `NSWindow.m:1070`이 던졌다. AppKit에 넘기는 좌표는 반드시 유한한지 본다.
- 배경 스레드에서 `page.addAnnotation`을 부르면 PDFKit이 `PDFViewAnnotationsDidChange`를 **그 스레드에서** 던지고, 화면의 PDFView가 그걸 받는다. 저장할 때 아는 표시를 전부 다시 넣던 시절 한 번 저장에 2만 3천 개가 갔다(`TextMarkupWriter.isAlreadyWritten`으로 멈췄다). 알림이 어느 스레드로 오는지는 `--papertime-watch-threads=1`이 메인 스레드 아닌 곳에서 온 알림을 모두 찍는다.
- 표시가 얼마나 걸리는지는 마우스 없이 잰다: `--papertime-mark-test=<쪽>,<x>,<y>,<w>,<h>`가 그 사각형을 형광펜으로 칠하고, 줄 수·사각형 수·걸린 시간을 찍고, 도로 지운다(남의 라이브러리에 자국을 남기지 않는다). 드래그는 스크립트로 못 만든다 — PDFKit의 `shouldBeginDrag:`가 제 이벤트 루프를 돌려서 합성한 이벤트로는 빠져나오지 못한다.
- 표 셀을 마우스로 잡은 선택은 **전체 `bounds(for:)`는 정상인데 `selectionsByLine()`의 줄은 `(inf, inf, 0, 0)`(null)**이다. 이 값은 PDFKit이 표를 분석한 쪽에서 마우스로 만든 선택에만 나오고, 같은 글자 범위를 `page.selection(for: NSRange)`로 만들면 멀쩡하다 — 그래서 스크립트로 재현이 안 되고 사람 손이 필요하다. `TextMarkupWriter.placement(of:on:within:)`가 줄 → 글자 범위로 재선택 → 선택 전체 순으로 묻는다. 선택이 무엇을 들고 오는지는 `--papertime-watch-selection=1`이 바뀔 때마다 stderr에 찍는다(전체 bounds, 줄별 bounds, 글자 범위, characterBounds — 마지막 것은 이 문서들에서 엉뚱한 값이라 쓰지 않는다). `--papertime-mark-test-zoom=2.5`로 확대해 놓고 `--papertime-mark-test-dry=1`이면 가서 자리만 찍고 아무것도 쓰지 않는다 — 표시를 쓰면 파일이 바뀌고 감시자가 다시 읽어 스크롤이 튀어서, 방금 찍은 자리가 틀려진다.
- **창을 찍은 그림을 믿지 마라 — 뷰 나무를 봐라.** `cacheDisplay`는 `draw(_:)`를 따라 걷기 때문에 Core Animation으로 그려지는 것을 통째로 놓친다. 그래서 글자로 가득한 인스펙터가 **까만 사각형**으로, ScrollView에 든 첫 화면이 **텅 빈 회색**으로 찍힌다 — 앱의 버그가 아니라 카메라의 버그다(`layer.render(in:)`도, 접근성 트리를 KVC로 훑는 것도 SwiftUI에서는 마찬가지로 빈손이다). 화면에 무엇이 있는지 확인해야 하면 `--papertime-window-shot=<경로>`에 **`--papertime-window-dump=1`**을 같이 준다: 창의 뷰 나무를 찍어 주고, 거기 `HostingScrollView → NSClipView → DocumentView → _FocusRingView(98×28)`가 보이면 단추는 실제로 거기 있는 것이다. `--papertime-force-setup=1`은 라이브러리를 잊지 않고 첫 화면만 보여주고, `--papertime-choose-folder=1`은 폴더 고르기 창이 정말 뜨는지 열어 보고 닫는다.
- 인용이 논문의 구조를 제대로 읽어 오는지는 창 없이 본다: `swiftc -O App/Model/MathReader.swift App/Model/MathTranscriber.swift App/Model/PDFContentScanner.swift App/Model/TeXGlyphNames.swift Scripts/quote-probe.swift -o /tmp/quote` 뒤에 `/tmp/quote <pdf> <쪽> [x y w h]`면 ⌘L이 노트에 넣을 마크다운이 그대로 찍히고, `--pieces`를 붙이면 그 전 단계(무엇을 제목·수식·산문으로 읽었는지, 본문 대비 몇 배 크기인지)가 나온다. 선택은 앱 안 세 칸 깊이에 있어서 스크립트로 만들 수 없다.
- 창을 띄우지 않고 확인하기: 노트 조판은 `PAPERTIME_DUMP_NOTE=<마크다운 그 자체>`가 런 단위로 찍는다(샌드박스라 경로는 못 읽는다). `PAPERTIME_DUMP_NOTE_IMAGE=<컨테이너 안 경로>`를 같이 주면 같은 노트를 그려 PNG로 남긴다 — 인용의 세로줄과 조판된 수식은 그려지는 것이라 속성 목록에는 나오지 않으니, 그 둘은 그림으로만 확인된다. 본문 검색 색인은 앱 없이도 돈다: `swiftc -O App/Model/PaperTextIndex.swift Scripts/search-probe.swift -o /tmp/probe && /tmp/probe unlearning ~/Documents/Bookends/Attachments`(`PaperTextIndex`가 Foundation·PDFKit 말고는 아무것도 안 쓰는 이유). 팔레트 자체는 `PAPERTIME_SHOW_SEARCH=<찾을 말>`로 그 말이 적힌 채 열리고, `PAPERTIME_SEARCH_JUMP=1`을 더하면 첫 본문 결과를 눌러 그 줄로 간다 — 키를 쏘지 않고 끝까지 보는 길.
- **그리기 층(맥의 필기).** 맥에는 PKCanvasView가 없고 PDFKit의 쪽 오버레이는 마우스를 못 받는다(클릭은 안쪽 문서 뷰로 간다). 그래서 펜을 들면(`ReaderConfiguration.mode == .draw`, ⇧⌘D) `SketchInputView`가 PDFView 위에 통째로 얹혀 마우스를 받고, 스크롤·핀치는 아래 **스크롤 뷰**로 넘긴다 — PDFView가 아니다. PDFKit은 `magnify(with:)`를 구현하지 않고 NSScrollView의 확대로 줌하므로, PDFView에 넘긴 핀치는 응답 체인을 타고 올라가 아무 일도 하지 않았다(0.7.2까지 펜을 든 채로는 핀치 줌이 안 되던 이유). 도구는 Figma의 도구 줄 모양이다: `SketchTool`(V 선택, F 프레임, 도형 묶음 R 네모·O 동그라미·L 선·A 화살표, 펜 묶음 P 펜·H 형광펜·E 지우개, T 글; 묶음은 마지막에 쓴 도구를 단추로 보이고 옆 화살표가 목록을 편다). 상태는 `ReaderConfiguration.sketch: SketchState`, 도구 줄은 `SketchToolbar.swift`, 오른쪽 인스펙터는 `SketchInspector.swift`(위치·정렬·X/Y, 레이아웃·W/H·흐름·간격·여백, 외형·투명도·모서리, 채우기·외곽선(색상 패널·hex·%), 글·크기·정렬·자동 너비/높이). 펜은 마우스 점을 `PKStroke`로 만들어 잉크 사이드카에 넣는다(태블릿 펜의 압력은 굵기에 반영) — 그래서 아이패드와 같은 선이다. 도형·화살표·글 카드·프레임·묶음은 **`SketchElement`**(InkEngine, 쪽 좌표)이고 사이드카 `.papertime/papers/<id>/sketch/pNNNN.json`이 진실, PDF에는 저장 때 표준 주석 사본을 쓴다(네모·프레임→Square, 동그라미→Circle, 곧은 선→Line(끝 모양은 /LE), 굽은 화살표·막대 끝→Ink, 글→FreeText, 상자 속 글→FreeText 하나 더, 묶음→테두리 0·숨김 Square). 사본마다 `/PTSketch`에 원소의 JSON(base64)을 실어 두어 사이드카 없는 기기가 파일에서 그대로 되살린다(`SketchWriter.elements(fromOwnedOn:)`). 사본의 `userName`은 "Paper Time Sketch" — "Paper Time"이면 `InkConverter.isOwned`가 굽은 화살표를 펜 선으로 들여온다. PDFKit으로는 `/CA`(투명도)를 못 쓴다(`setValue(forAnnotationKey:)`가 거절) — 채움은 흰 종이 위에 미리 섞은 불투명색으로 쓴다. 그리기는 `SketchRenderer`(CoreGraphics+CoreText, 쪽 좌표) 하나를 맥 `SketchOverlayView`(PageImages.swift)와 iOS `SketchOverlayView`(PageOverlay_iOS.swift, 뒤집힌 컨텍스트라 `flipsText`)가 같이 쓴다. 되돌리기는 `SketchUndo`가 세션을 타겟으로 쪽 단위 전/후 배열(과 잉크 전/후)을 등록한다. 창 없이 확인: `--papertime-draw=1 --papertime-sketch-sample=1 --papertime-sketch-shot=<컨테이너 안 png>`(테스트 라이브러리 `--papertime-library=TestLibrary`에서만 동작)가 표본 도형을 놓고 창을 PNG로 남기며, stderr에 쪽이 화면 어디에 있는지(Quartz 좌표)를 찍어 실제 포인터 드래그를 보낼 수 있다. `--papertime-sketch-script="tool=frame;drag=…;key=cmd-g;dragpage=1,…;report=1"`이 제스처를 순서대로 돌린다(`dragpage`는 다른 쪽에 놓는 드래그, `report=<쪽>`은 그 쪽의 원소를 부모·레이아웃과 함께 찍는다).
- **그리기의 나무(프레임·묶음·오토 레이아웃).** 배열은 평평하게 두고(파일이 평평한 목록이고, 렌더러와 PDF 사본이 다 그렇게 걷는다) `parent` 필드로 나무를 읽는다(`SketchTree`). **자식의 좌표도 쪽 좌표다** — 부모 상대가 아니다 — 그래서 옛 렌더러와 PDF 사본은 아무것도 몰라도 된다. 프레임(`.frame`)은 제 상자가 있는 컨테이너(채움·테두리·모서리, `clips`면 넘친 자식을 자르고, `layout`이 있으면 자식을 줄·열로 놓는다), 묶음(`.group`)은 제 상자가 없는 컨테이너(상자는 자식들의 합이고, `points`에 그 합을 캐시해 둔다 — 묶음을 모르는 쪽도 온전한 상자를 보도록). 클릭 규칙은 Figma의 것: 묶음은 통째로 잡히고(가장 바깥 묶음), 프레임은 클릭을 자식에게 흘린다; 더블클릭은 묶음 안으로 들어간다(`entered`). 모든 변경은 `SketchTree.normalized`를 지난다 — 부모 뒤에 자식이 오도록 배열을 재배열하고, 안쪽 프레임부터 레이아웃을 적용하고(`arrange`, hugs면 프레임이 자식에 맞춰 크기를 잡되 왼쪽 위 모서리는 고정), 묶음의 상자를 다시 잡는다. 놓은 자리의 프레임에 자동으로 들어가고(`adopted`: 가운데가 들어가는 가장 위 프레임), 묶음에서는 끌어내지 않는다. 다른 쪽으로 끌어 옮기기는 `finishMove`가 두 쪽의 사이드카를 한 undo 그룹으로 고친다(원소는 id를 유지하고 좌표는 목표 쪽의 것). 글 카드는 `textSizing`이 `autoWidth`(가장 긴 줄 너비, T로 클릭)거나 `autoHeight`(너비 고정·높이 따라감, T로 끌거나 손잡이로 너비를 잡으면 이것이 된다)이고, 옛 파일의 nil은 autoHeight로 읽는다. 글 입력은 Figma처럼 배경 없는 `NSTextView`가 글자만 보이고 카드(채움·테두리)는 `SketchInputView.draw`가 그 아래에 그린다. 새 스타일 필드(`strokeHidden`·`cornerRadius`·`fontSize`·`textAlign`)와 원소 필드(`parent`·`name`·`clips`·`layout`·`textSizing`)는 **값이 있을 때만 쓴다**(둘 다 `encode(to:)`를 직접 구현) — 이 빌드가 그냥 열었던 파일은 바이트까지 그대로 다시 써지고, Portable은 모르는 키를 `extra`로 들고 다닌다. Portable도 같은 나무를 편집한다(`shared/sketchTree.ts`가 `SketchTree.swift`의 포팅, `ui/sketchInput.ts`·`ui/sketchInspector.ts`·`ui/sketchToolbar.ts`; 계약은 `ui/sketchEditing.ts`). 카드의 수식은 MathJax(`renderer/sketchMath.ts`, tex→svg→이미지, 비동기 로드 뒤 다시 그림). 열린 논문·핀·나란히(`shared/split.ts`)·⇧⌘O 팝업(`ui/openPapers.ts`)·논문 창(`--papertime-paper=<id>`로 같은 렌더러를 solo로)도 있다. 어느 쪽에 기능을 더하면 다른 쪽에도 같은 커밋 안에서 더한다.
- **그리기 층의 나머지 규칙.** 도구 줄의 아이콘은 SF Symbols가 아니라 `FigmaIcon`이 직접 그린다(1.6pt 선, 둥근 이음). "끝" 단추는 없다 — 읽는 중에 그린 것(원소나 스트로크)을 클릭하면 `installMarkClickMonitor`의 `hitsDrawing`이 `mode = .draw`로 바꾸고 `updateCanvasInteraction()`을 **즉시** 불러 그 클릭이 오버레이에 떨어진다. 그린 것의 인스펙터는 떠다니지 않고 창의 인스펙터 **Tools 탭**(`InspectorTab.tool`, `SketchInspector(docked: true)`)이며 펜을 들면 그 탭이 앞으로 온다; 인스펙터 탭 이름 넷(Info·Marks·Notes·Tool)은 시스템 언어와 무관하게 영어다. 카드의 `$…$`는 `SketchTypesetter.mathProvider`가 있을 때만 수식으로 조판된다 — 맥은 `MathBridge.install()`이 `MathTypesetter`를 꽂고(iOS·Portable·PDF 사본은 쓴 그대로), 수식이 든 문단은 줄바꿈 없이 한 줄이다. 글꼴은 `SketchStyle.fontName`(패밀리 이름; `SketchTypesetter.font(points:name:)`가 그 패밀리가 실제로 있을 때만 쓴다). 모서리는 `Corner` 척도로만 쓴다: 둥근 것 안의 둥근 것은 `Corner.inner(outer, inset:)`(바깥 반경 − 간격)로 동심원을 만든다 — 같은 반경을 안팎에 주면 안쪽이 더 날카롭게 보인다. **다크 모드의 Glass 색은 흰 종이다**(`ReaderConfiguration.effectiveTint`): 곱하기 합성은 어두운 패널 위에서 글자까지 지운다. `--papertime-dark=1`이 창만 다크로 보여 주고, `--papertime-split=1`이 처음 두 논문을 나란히 놓는다.
- **논문 나란히 보기.** `LibraryModel.openPaperIDs`는 **훑어본 논문이 아니라 쓴 논문**이다 — 목록을 내려가며 보이는 것마다 쌓으면 선반이 목록과 같아진다. 클릭해 들어가거나(`link.activated` → `keepOpen`), 나란히 놓거나(`dock`), 메뉴의 "열어 두기"로 남고, 지금 보이는 것은 "미리보기"로 선반 끝에 잠깐 있다가 다음 논문을 보면 빠진다(편집기의 미리보기 탭과 같은 규칙). 칸의 ×와 선반의 ×는 논문을 닫는다(`undock` + `closeOpenPaper`). (`Scope.open`이 "열린 논문" 선반)와 `AppModel.split: SplitArrangement?`(왼쪽 열·오른쪽 열, 열마다 위·아래 — 최대 넷). 놓는 자리는 `DockZone` 여섯 개이고, 쪽 영역에 `DockDropDelegate`가 `PaperTransfer` 드롭을 받아 `DockZoneOverlay`로 자리를 미리 비춘다(가운데 40%는 자리가 아니다). 비춘 자리는 마우스 단추가 떼어지면 지운다(`NSEvent.pressedMouseButtons` 감시) — Escape로 취소한 드래그나 창 밖에서 놓은 드래그는 `dropExited`를 보내지 않아 반쪽이 파랗게 남았었다. 우클릭 메뉴 "나란히 열기"도 같은 `app.dock`. 각 칸은 제 `ReaderScreen`이고, **포커스된 칸만 창의 `ReaderLink`를 빌려 쓴다**(나머지는 `app.paneLink(for:)`) — 그래서 툴바·인스펙터·노트가 그 논문 것이 된다. 그러려고 `ReaderCoordinator.link`가 `var`이고 `updateNSView`가 매번 다시 넣으며, `ReaderScreen`은 링크 객체가 바뀌면 제 세션을 새 링크에 다시 `adopt`한다. 칸 클릭은 클릭 모니터가 `link.activated?()`로 알린다. ⇧⌘O(`.openPapers`)는 `OpenPapersPopup`을 차례 팝업처럼 쪽 위에 띄운다; 줄 뒤의 `DragOutHandle`(NSDraggingSource)이 클릭·⌘클릭·드래그를 받고, 드래그가 아무 데도 받아들여지지 않고 우리 창 밖에서 끝나면(`draggingSession(_:endedAt:operation:)`, operation 비어 있음) `WindowGroup(id: "paper", for: UUID.self)`의 새 창(`PaperWindow`)을 그 자리에 연다. 새 창은 제 `ReaderConfiguration`·`ReaderLink`를 가지고, ⇧⌘D 알림은 키 윈도우일 때만 받는다.
- **윈도우·리눅스 빌드(`Portable/`).** 맥이 아닌 데스크톱에는 PDFKit도 PencilKit도 없어서, 코드를 옮기는 길은 없고 다시 쓰는 길만 있었다. 그래서 **코드가 아니라 파일을 공유한다** — 라이브러리는 PDF 옆에 작은 JSON이고 표시·필기는 PDF 안에 있으니, 그 파일들에 합의한 두 구현은 그 자체로 호환된다(서버도, 프로토콜도, 마이그레이션도 없다). 두 번째 구현은 Electron + TypeScript다: 윈도우와 리눅스가 **똑같이** 보여야 한다는 요구를 정직하게 지키는 길은 크로미움 하나뿐이고, Qt나 GTK는 유지할 외양이 둘 더 느는 일이다. 대가는 패키지당 100 MB 남짓.
- **두 빌드 사이를 건너는 것.** 레코드(`.papertime/*.json`)는 바이트까지 같다 — Swift의 `JSONEncoder`는 콜론 앞에 공백을 두고, 키를 UTF-8 바이트 순으로 정렬하고, 빈 배열을 `[`·빈 줄·`]`로 쓰고, 닫는 괄호에서 개행 없이 끝난다. `Portable/src/shared/coding.ts`가 그걸 그대로 낸다(틀려도 눈에는 안 보이고, 대신 건드린 파일마다 클라우드 폴더에서 전체 변경으로 보여 조용한 동기화가 충돌이 된다). **날짜 모양이 둘**인 것에 주의: 레코드는 `JSONCoding`의 `.iso8601`, 스케치 사이드카와 `/PTSketch`는 기본 `JSONEncoder`의 2001-01-01 기준 초다. 게다가 `Date`는 밀리초까지만 쥐므로 맥이 쓴 `811492215.409792`를 다시 인코딩하면 `…4089999`가 된다 — **파일에 있던 숫자를 그대로 보관했다가 그대로 쓴다**(`createdAtRaw`). 도형은 `/PTSketch`가 원소 JSON을 싣고 다니므로 사이드카 없는 기기가 파일만으로 똑같이 되살린다: 실제로 사이드카를 전부 지운 PDF를 맥에 줬더니 맥이 **바이트까지 같은** `sketch/p0000.json`을 써냈다. BibTeX도 출력이 같다(Swift 내보내기와 직접 대조했다). LaTeX 이스케이프 표는 옮겨 적지 않고 `Portable/tools/generate-latex-table.mjs`가 `LaTeXEscaping.swift`에서 **생성**한다 — 손으로 옮기면 "Almudévar"가 기기마다 다르게 나온다.
- **클라우드 폴더와 Finder에서 건네받기.** 라이브러리는 어느 클라우드 폴더든 된다 — 맥에서 Google Drive는 `~/Library/CloudStorage/GoogleDrive-<메일>/`(File Provider)이고, 샌드박스 앱은 **사용자가 건네준 뒤에만** 그 안을 본다. 건네는 길은 둘: 열기 패널(`chooseLibraryFolder`)과 **Finder에서 앱에 끌어다 놓기**(`OpenWithFinder`, `CFBundleDocumentTypes`에 `public.folder`). 둘 다 Launch Services/Powerbox가 같은 권한을 주고, 보안 스코프 북마크로 다음 실행에도 열린다(실측: Drive 폴더를 떨어뜨린 뒤 인자 없이 다시 띄우니 그 폴더가 열렸다). Portable은 샌드박스가 없어 경로만 있으면 된다. 폴더를 못 읽으면 `CloudProvider`가 어느 서비스인지 말해 준다.

- **논문과 일반 문서.** 0.9.0부터 라이브러리는 두 가지를 담는다: `PaperMeta.kind`(`DocumentKind`: `.paper`/`.document`)가 **사용자의 답**, `guessedKind`가 **앱의 짐작**이고, 둘 다 없으면 `effectiveKind`는 `.paper`다(옛 라이브러리가 그대로 보이도록). 둘 다 값이 있을 때만 파일에 쓴다. 짐작은 `DocumentGuess.of(hasIdentifier:hasAbstract:hasReferences:)` — DOI/arXiv가 보이면 논문, 없으면 초록**과** 참고문헌이 함께 있을 때만 논문이다. 참고문헌은 40쪽 이하면 전부, 그보다 길면 끝 8쪽 + 열두 곳을 본다(부록 있는 논문은 참고문헌이 가운데 있다 — 실측: 23쪽 논문의 9쪽). 맥은 들여올 때 PDFKit으로 짐작하고(`DocumentSignals.guess`), **짐작이 문서면 등록기관에 묻지 않는다**(계약서 제목을 밖으로 보내지 않는다). Portable은 pdf.js가 창에 있으므로 논문을 처음 열 때 짐작한다(`shared/documentKind.ts`, `reader.ts`의 `guessKindIfAsked`). 인스펙터는 답이 없으면 **먼저 묻고**(`kindQuestion`), 답에 따라 칸이 갈린다: 논문이면 학술지·권·호·DOI·인용 키와 후보 목록, 문서면 펴낸 곳·해·종류·파일. `살펴볼 것`과 BibTeX의 "확인 안 됨" 경고는 논문만 센다. 사이드바의 `논문`/`문서` 줄은 라이브러리에 둘 다 있을 때만 나온다.
- **쪽 그림(page grid).** 차례(⇧⌘L)에 `차례`/`쪽` 두 칸이 있고, 제목을 하나도 못 찾으면 `쪽`으로 열린다(`ContentsPopup.Mode`). 썸네일은 행이 보일 때 그리고 그 뒤로 캐시한다(`PageThumbnail`) — PDFKit 문서는 두 스레드에서 못 읽으니 메인 액터에서 그리되 `Task.yield()`로 한 번에 몰리지 않게 한다. Portable은 `ui/pages.ts`(같은 키, `IntersectionObserver`로 늦게 그림, `Reader.thumbnail`이 pdf.js로 작은 캔버스를 만든다). Portable에는 차례(제목 읽기)가 없어 `쪽`만 있다.

- **잠긴 PDF.** PDF 암호화에는 핸들러가 있고, 표준(`/Standard`)만 암호로 열린다. 나머지 둘 — 인증서(`Adobe.PubSec`)와 회사 권한 서비스(`MicrosoftIRMServices` 등) — 는 열쇠를 남이 들고 있어서 이 앱이 열 길이 없다(Acrobat이 여는 것은 MIP 플러그인을 갖춘 등록된 앱이기 때문이다). 판정은 `PDFLock`(PaperCore, `shared/pdfLock.ts`가 포팅): 핸들러 이름은 암호화될 수 없어 파일에 평문으로 있으므로 바이트에서 찾고, **그 이름만으로는 아무것도 아니다** — 문서가 안 열리거나 잠겨 있거나, 열렸는데 앞 세 쪽에 글자가 하나도 없을 때만 그 핸들러의 것이다(권한 관리를 다룬 논문이 있다). PDFKit은 모르는 핸들러의 파일을 **거절하지 않고** 열어서 암호문을 그린다 — `isLocked`도 `isEncrypted`도 false다. 그래서 글자 유무를 본다. 암호가 걸린 파일은 맥이 `document.unlock(withPassword:)`, Portable이 pdf.js의 `task.onPassword`로 연다(**아무도 안 물어보면 pdf.js의 약속은 영영 안 끝난다** — 0.8.1까지 빈 화면이던 이유). 잠긴 파일에서는 서지 추출을 건너뛴다(암호문이 제목이 된다). 그리고 `paper:bytes`는 절대 던지지 않는다 — 렌더러에서 unhandledrejection이 되면 화면에 아무 말도 안 남는다.

- **건너지 못하는 것: PencilKit의 `.drawing`.** 매직 넘버 뒤에 애플의 점 압축이 들어간 비공개 protobuf라 읽지 않는다. 필기는 PDF의 잉크 주석으로 건넌다(맥이 저장할 때 쓴다) — 잃는 것은 점마다의 압력인데, 그건 맥도 파일에서는 잃는 것이고 그래서 양쪽 다 제 사이드카를 따로 둔다. `.drawing`은 있는데 PDF에 잉크가 없는 쪽(맥에서 그리고 저장을 안 한 쪽)은 **아무 말 없이 빈 쪽을 보여주지 않고** 그렇다고 알린다. 반대로 그런 쪽에 여기서 그리면 맥의 파일을 `….drawing.superseded-<언제>`로 **이름만 바꾼다** — 사이드카 둘이 한 쪽을 주장하면 두 기기가 서로 다른 걸 보여주고(맥은 제 사이드카를 파일보다 먼저 읽는다), 지우지 않는 건 그 안의 압력이 사용자의 작업이기 때문이다.
- **일부러 다르게 둔 것은 창 단추 하나뿐이다.** 맥은 신호등을 왼쪽에, 윈도우·리눅스는 최소화·최대화·닫기를 오른쪽에 제 방식으로 그린다 — 그 단추는 데스크톱의 것이지 Paper Time의 것이 아니고, 윈도우에 초록 신호등은 버그로 읽힌다. 도구 막대의 양 끝 사이는 셋 다 같다. 글꼴은 **번들한 Pretendard**다("시스템 글꼴"은 기기마다 다른 글꼴이라 메모 너비가 달라진다). 아이콘은 `Portable/src/renderer/icons.ts`에 직접 그렸다 — SF Symbols는 애플 플랫폼 전용 라이선스다.
- **창 없이 확인하기(포터블).** 시스템에 이벤트를 쏘지 않는다: `--papertime-probe=<steps.json>`이 `eval`·`click`·`drag`·`key`·`menu`(메뉴 명령 — 단축키는 메인 프로세스의 가속기라 합성 키로는 안 눌린다)·`shot` 단계를 **페이지 안에서** 실행하고, `--papertime-shot=<png>`이 창을 찍는다(`rect`를 주면 그 영역만 — 나중에 자르는 건 엉뚱한 데를 보기 좋은 방법이다). `--papertime-library=<경로>`로 남의 라이브러리를 건드리지 않고 연다. `--papertime-chrome=win32`면 맥에서 윈도우 크롬을 그려 본다. 검사는 `cd Portable && npm test`(37개 — 대부분 "맥과 같은가"를 묻는다).
- **패키징.** `npm run dist:win`(NSIS + zip), `npm run dist:linux`(AppImage + tar.gz, x64·arm64)은 어느 OS에서든 된다. **`.deb`·`.rpm`은 맥에서 만들면 안 된다** — fpm이 GNU `ar`을 부르는데 맥의 `ar`은 Mach-O 아카이브를 만들고, 그 결과 96바이트짜리 패키지가 나오는데 electron-builder는 성공으로 보고한다. `tools/package.mjs`가 만들어진 것들의 크기를 재서 그런 게 나오면 실패시키고, `dist:linux-packages`는 리눅스가 아니면 아예 거절한다.
- 플랫폼 분기: AppKit 전용 파일은 `#if os(macOS)`로 통째로 감싸고 UIKit 쌍을 옆에 둔다(`MarkOverlayView`, `MarginMaskView`, `PageOverlay`). 색은 `PlatformColorShims.swift`가 AppKit 이름을 UIKit에 준다.

## 말투
앱과 배포 페이지의 **한국어는 토스의 말투(해요체), 영어는 애플의 말투**다. 정본은 `Docs/Voice.md`이고, 문자열을 새로 쓰거나 고칠 때마다 그 문서의 마지막 절(고칠 때 확인하는 것)을 지나야 한다. 요약하면: 한국어는 해요체로 쓰고 피동형과 한자어를 피하며 한 문장에 한 가지만 담는다(단추는 "보내기"처럼 명사형, "보내요"가 아니다). 영어는 능동태 현재형 짧은 평서문이고 *powerful·seamless·simply·easy* 같은 말을 쓰지 않으며 메뉴와 단추는 Title Case, 문장은 sentence case다. **둘은 번역 관계가 아니다** — 한 쪽을 직역하면 둘 다 어색해진다. 두 언어는 `L(ko, en)`(맥)과 `L(ko, en)`(`Portable/src/shared/lang.ts`)로 소스에 나란히 두고, 배포 페이지는 `data-l="ko"`/`data-l="en"` 쌍으로 마크업에 나란히 둔다 — 어느 쪽도 카탈로그로 빼지 않는 이유는 같다. 떨어뜨려 두면 한 쪽이 조용히 썩는다. 어느 말로 보일지는 시스템 언어가 정하고(한국어면 한국어, 그 밖이면 영어), 사용자가 뒤집을 수 있다.

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

플랫폼은 그 위에 따로 셋이다 — `mac`(스위프트 앱), `windows`, `linux`. 뒤의 둘은 같은 커밋에서 갈라져 나왔고 공유 파일(`Portable/`)이 동일하므로, 서로 합치는 일은 바뀐 것만 따라가는 fast-forward다. 자세한 것은 `Docs/Porting.md`.

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

**고친 것을 바로 배포하지 않는다.** 먼저 `Scripts/build-installers.sh`로 작업 중인 코드 그대로 구워서 `Installers/`에 두고, **사용자가 직접 설치해서 확인한 뒤에** `Scripts/publish-release.sh`로 올린다. 순서를 지키는 이유는 0.7.1에서 겪었다 — 창 뒤에 깔려던 바탕이 앱을 통째로 덮었는데, 디버그 빌드에서는 우연히 뒤에 남아 있어서 배포 빌드에서만 드러났다. 확인은 **Release 빌드**로, 그것도 **설치된 사본**으로 해야 한다. `Installers/`는 git에 들어가지 않고(수백 MB), 남는 사본은 릴리스 쪽이다. 그래서 배포가 끝나면 `publish-release.sh`가 `Installers/`와 `Portable/dist/`에서 방금 올린 버전이 아닌 것을 지운다 — 올리기 전이 아니라 올린 뒤에 지우니, 업로드가 실패하면 아무것도 잃지 않는다. 배포 스크립트는 electron-builder가 돌고 있으면 시작을 거부한다 — 다 써지지 않은 패키지를 올리면 GitHub이 릴리스 전체를 되돌린다.

배포 페이지는 `Website/`에 있고 `gh-pages` 가지에서 서비스된다 —
<https://icecoffee2500.github.io/paper-time/>. `Scripts/publish-release.sh <tag>`가
`Scripts/make-dmg.sh`를 불러 DMG를 만들고, GitHub 릴리스에 올리고,
`Website/releases.json`을 다시 써서 `gh-pages`로 옮긴다. 그 json은 소스 쪽에도
같이 커밋한다. `Docs/`는 이 프로젝트가 스스로 두는 메모이지 배포 페이지가 아니다
(대소문자를 가리지 않는 디스크에서 `docs/`로 보여도 git은 가린다).

배포 페이지의 **다운로드 수**는 GitHub가 릴리스 자산(DMG)마다 세는 `download_count`다 — 첫 DMG를 올린 날부터 세고 있어서 페이지에 보이기 전의 것도 들어 있다. `publish-release.sh`가 그때의 값을 `releases.json`의 `downloads`에 박아 두고(API가 막혔을 때의 대비), 페이지(`demos.js`의 `fetchDownloadCounts`)는 열릴 때 `api.github.com/repos/…/releases`를 직접 불러 산 값으로 바꾼다(인증 없이 IP당 시간에 60번 — 랜딩 페이지에는 넉넉하다). **그 숫자에는 확인하느라 내려받은 것도 다 들어간다** — 배포 확인은 릴리스 자산을 `curl`로 받지 말고 `dist/`에 만들어진 같은 DMG로 하라(`gh release view <tag> --json assets`의 `digest`로 같은 파일인지 대조할 수 있다). 2026-09-17 기준 10회 중 7회가 그렇게 내가 받은 것이었다.

페이지만 바꾼 것(문장, 카드, 스크립트)은 릴리스 없이 `Scripts/publish-page.sh "메시지"`로 gh-pages에 올린다 — `publish-release.sh`도 마지막에 이걸 부른다. 그런 커밋은 `releases.json`과 마찬가지로 `main`에 직접 둔다(앱 버전이 아니라 페이지의 일이다). 링크를 붙였을 때 메신저가 펼치는 카드(`og:image`)와 파비콘은 `Scripts/page-images.swift`가 앱 아이콘에서 그린다 — `swiftc -O Scripts/page-images.swift -o /tmp/page-images && /tmp/page-images`. 카드는 JPEG다(바탕이 그라디언트라 PNG는 1.5 MB, JPEG는 170 KB). `og:image`가 없으면 카카오톡 같은 곳은 페이지의 첫 `<img>`를 집어 간다 — 그게 설치 안내의 보안 대화상자 스크린샷이었다.

한쪽에서 고친 것이 다른 쪽에 당장 필요하면, 그 가지를 기다리지 말고 `git merge debug/v0.1.0`으로 끌어온다. 버전을 닫기 전까지 `main`은 건드리지 않는다.

개발 현황은 `python3 Scripts/board.py`로 본다 — 가지별 상태와 커밋 그래프를 HTML로 그려서 열어준다.
