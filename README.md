# Paper Time

논문을 읽고, 표시하고, 그 표시를 글로 바꾸기 위한 앱.
맥·윈도우·리눅스에서 돌고, 아이패드와 아이폰에서도 같은 폴더를 봐요.

**[받는 곳 → icecoffee2500.github.io/paper-time](https://icecoffee2500.github.io/paper-time/)**

> 논문을 읽는 곳과 글을 쓰는 곳 사이에, 아무것도 없다.

읽고 → 표시하고 → 옮겨 적고 → 잇는 네 칸이 한 앱 안에 있어요. 칸과 칸 사이에
내보내기도, 붙여넣기도 없고요. 논문은 내가 고른 폴더에 평범한 PDF로 있고,
하이라이트·밑줄·손글씨는 PDF 주석으로 그 안에 남아요. 노트는 Markdown이에요.
앱을 지워도 읽던 것은 그대로 남아요.

- **파일이 진실** — 라이브러리는 폴더 하나예요. 데이터베이스도, 앱 전용 저장소도 없어요.
- **어느 데스크톱이든** — 맥·윈도우·리눅스가 같은 폴더를 열어요. 계정도 서버도 없고, 클라우드 폴더든 USB든 파일이 닿는 곳이면 돼요.
- **세 기기** — 맥·아이패드·아이폰 사이에서는 표시가 몇 초 안에 건너가요 (iCloud Drive면 충분해요).
- **Ultracopy** — 수식이 든 문단을 ⇧⌘C로 복사하면 바로 컴파일되는 LaTeX으로 나와요.
- **온디바이스만** — 클라우드 LLM을 쓰지 않아요. 논문이 어디로도 올라가지 않아요.
- **Zotero와 같이 써도 돼요** — 라이브러리가 그냥 폴더라서 Zotero의 `storage` 옆에 앉을 수 있어요.

전체 계획과 결정 사항은 [`PLAN.md`](PLAN.md), 작업 규칙은 [`CLAUDE.md`](CLAUDE.md),
말투는 [`Docs/Voice.md`](Docs/Voice.md)에 있어요.

## 한마디 보내기

앱 안에서 **⌥⌘/** 를 누르면 방금 그 화면이 이미 찍힌 채로 창이 열려요.
논문에 쓰던 그 화살표와 네모로 바로 표시하면 되고, 보이면 안 되는 곳은
가리개로 덮으면 돼요. 함께 가는 것은 전부 목록으로 보여줘요 — 버전이나 창
크기 같은 앱 이야기뿐이고, 논문 제목도 파일 경로도 쓰신 글도 가지 않아요.

보내주신 것은 [배포 페이지의 목록](https://icecoffee2500.github.io/paper-time/#together)에
올라가고, 고쳐지면 체크가 붙어요. 이름을 적으면 그 이름으로 올라가고, 앱의
정보 화면에도 남아요.

GitHub 계정이 있으면 [이슈](https://github.com/Icecoffee2500/paper-time/issues)로
바로 열어도 돼요. 둘은 같은 목록이에요.

## 어떻게 만들어졌나

맥은 Swift 6 + SwiftUI + PDFKit + PencilKit이고, 윈도우·리눅스는
[`Portable/`](Portable/)의 Electron + TypeScript예요. 애플 밖에는 PDFKit도
PencilKit도 없어서 코드를 옮기는 길이 없었고, 그래서 **코드가 아니라 파일을
공유해요** — 라이브러리는 PDF 옆의 작은 JSON이고 표시는 PDF 안에 있으니,
그 파일들에 합의한 두 구현은 그 자체로 호환돼요. 서버도, 프로토콜도,
마이그레이션도 없어요. 자세한 것은 [`Docs/Porting.md`](Docs/Porting.md)에 있어요.

## 직접 빌드하기

**맥** — Xcode 26 이상이 필요해요. 무료 Apple 개발자 계정으로도 자기 기기에 설치할 수 있어요.

```bash
cp Config/Signing.xcconfig Config/Signing.local.xcconfig   # 자기 팀 ID를 적어요
xcodegen generate
open PaperTime.xcodeproj
```

`Config/Signing.local.xcconfig`는 저장소에 들어가지 않아요.

**윈도우·리눅스** — Node 20 이상이 필요해요.

```bash
cd Portable
npm install
npm start          # 그냥 띄워보기
npm test           # 37개, 대부분 "맥과 같은가"를 물어요
npm run dist:win   # 또는 dist:linux
```

`.deb`·`.rpm`은 리눅스에서만 만들어요 — 맥의 `ar`로는 96바이트짜리 깨진
패키지가 나오는데 electron-builder는 그걸 성공으로 보고해요.

## 배포

**바로 올리지 않아요.** 먼저 지금 작업 중인 코드 그대로 구워서 `Installers/`에 두고,
직접 설치해서 확인한 다음에 올려요.

```bash
Scripts/build-installers.sh           # 셋 다 → Installers/
Scripts/build-installers.sh mac       # 디스크 이미지만
```

확인이 끝나면, 닫힌 버전마다 세 플랫폼의 파일을 만들어 릴리스에 올리고 배포 페이지의 목록을 다시 써요.

```bash
Scripts/publish-release.sh 0.7.0 "한 줄 설명"
git add Website/releases.json Website/feedback.json && git commit -m "0.7.0 on the page" && git push
```

페이지는 `Website/`에 있고, 스크립트가 그것을 `gh-pages` 가지로 옮겨요.
문장만 고쳤을 때는 `Scripts/publish-page.sh "메시지"`로 릴리스 없이 올려요.

## 라이선스

[MIT](LICENSE).
