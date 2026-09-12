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
- iOS 빌드: `xcodebuild -scheme PaperTime -destination 'platform=iOS Simulator,id=<UDID>' -derivedDataPath build/ios CODE_SIGNING_ALLOWED=NO build`, 설치·실행은 `xcrun simctl install/launch`. 시뮬레이터를 손대지 않고 몰고 가려면 환경변수: `SIMCTL_CHILD_PAPERTIME_LIBRARY=PaperTimePapers`(앱 Documents 안 상대경로), `…_SKIP_WELCOME=1`, `…_ADOPT_LOOSE=1`(폴더의 PDF를 들여옴), `…_OPEN_FIRST=1`(첫 논문을 연다). 캡처는 `xcrun simctl io <UDID> screenshot`.
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
Scripts/make-dmg.sh 0.1.0        # 닫은 버전마다 dist/에 DMG를 남긴다(dist/는 git 밖)
# 리모트가 생기면: git push origin main --tags
```

한쪽에서 고친 것이 다른 쪽에 당장 필요하면, 그 가지를 기다리지 말고 `git merge debug/v0.1.0`으로 끌어온다. 버전을 닫기 전까지 `main`은 건드리지 않는다.

개발 현황은 `python3 Scripts/board.py`로 본다 — 가지별 상태와 커밋 그래프를 HTML로 그려서 열어준다.
