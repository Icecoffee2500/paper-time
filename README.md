# Paper Time

논문을 읽고, 표시하고, 그 표시를 생각으로 바꾸기 위한 macOS · iPadOS · iOS 앱.

**[받는 곳 → icecoffee2500.github.io/paper-time](https://icecoffee2500.github.io/paper-time/)**

읽기, 필기, 서지관리를 한 앱에서 한다. 논문은 내가 고른 폴더에 평범한 PDF로 있고,
하이라이트·밑줄·잉크는 PDF 주석으로 그 안에 남는다. 노트는 Markdown이다.
앱을 지워도 읽던 것은 그대로 남는다.

- **파일이 진실** — 라이브러리는 폴더 하나다. 데이터베이스도, 앱 전용 저장소도 없다.
- **세 기기** — 맥·아이패드·아이폰이 같은 폴더를 보고, 표시는 몇 초 안에 건너간다 (iCloud Drive면 충분).
- **온디바이스만** — 클라우드 LLM을 쓰지 않는다. 논문이 어디로도 올라가지 않는다.
- **BibTeX** — 서지를 확신 있을 때만 저장하고, 확신이 없으면 `needsReview`로 남긴다.

전체 계획과 결정 사항은 [`PLAN.md`](PLAN.md), 작업 규칙은 [`CLAUDE.md`](CLAUDE.md)에 있다.

## 직접 빌드하기

Xcode 26 이상이 필요하다. 무료 Apple 개발자 계정으로도 자기 기기에 설치할 수 있다.

```bash
cp Config/Signing.xcconfig Config/Signing.local.xcconfig   # 자기 팀 ID를 적는다
xcodegen generate
open PaperTime.xcodeproj
```

`Config/Signing.local.xcconfig`는 저장소에 들어가지 않는다.

## 배포

닫힌 버전마다 디스크 이미지를 만들어 릴리스에 올리고, 배포 페이지의 목록을 다시 쓴다.

```bash
Scripts/publish-release.sh 0.1.0
git add Website/releases.json && git commit -m "0.1.0 on the page" && git push
```

페이지는 `Website/`에 있고, 스크립트가 그것을 `gh-pages` 가지로 옮긴다.

## 라이선스

아직 정하지 않았다. 그때까지는 모든 권리를 저자가 가진다.
