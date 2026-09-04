# Paper Time — 기능 정리 및 구현 계획 (최종안)

작성일: 2026-09-04 (v3, 구현 착수 후 실측 반영)
대상: macOS 26 / iPadOS 26 / iOS 26, Xcode 26.6, Swift 6, SwiftUI
사용자 기기: MacBook Pro (M1 Pro), iPad Air 4세대, iPhone 12 Pro — 모두 OS 26 지원 확인됨

## 0. 한 줄 요약

**"Apple 네이티브 감성의 논문 리더. PDFKit + PencilKit로 읽고 쓰고, 필기·하이라이트를 PDF 파일 자체에 기록하며,
라이브러리 전체를 사용자가 고른 클라우드 폴더(iCloud Drive 또는 Google Drive)에 파일로 저장하고,
DOI 우선 → 온디바이스 LLM 보조의 계층형 파싱으로 정확한 BibTeX을 뽑아내는 앱."**

우선순위: ① 읽고 이해하는 경험 → ② 필기가 파일에 남는 것 → ③ 정확한 서지 → ④ BibTeX 내보내기 → ⑤ 인용 스타일 가이드.

---

## 0.1 구현 중 확인된 하드웨어 제약 (계획 수정 사항)

| 사실 | 근거 | 설계 대응 |
|---|---|---|
| **iPad Air 4와 iPhone 12 Pro는 Apple Intelligence 미지원** (A14 칩. iPad는 M1 이상, iPhone은 A17 Pro 이상 필요) | Apple 공식 지원 기기 목록 | 온디바이스 LLM 추출기는 **Mac에서만** 동작. iPad/iPhone에서는 휴리스틱 추출기가 상시 경로. 폴더 동기화 덕분에 Mac이 해석한 결과가 다른 기기로 그대로 전달됨. 설정 화면에 기기별 가용 여부를 문구로 표시 |
| **PencilKit의 `PKCanvasView`는 macOS에 없음** (컴파일 확인) | SDK 26.5 타입 검사 | 펜 필기는 **iPad/iPhone 전용**. Mac은 PDF에 기록된 잉크 주석을 PDFKit이 그대로 렌더링해 보여주고, 텍스트 하이라이트·밑줄·취소선은 Mac에서도 가능 |
| iPad Air 4는 Apple Pencil 2세대 지원 (호버·스퀴즈 없음) | 기기 사양 | 호버 미리보기와 스퀴즈 제스처는 계획에서 제외 |
| 무료 개발자 계정은 iOS 앱 서명이 7일마다 만료 | Apple Developer 정책 | Mac 앱은 제약 없음. iPad에서 상시 사용하려면 유료 가입 필요 |

## 1. 확정된 결정 사항

| 항목 | 결정 | 설계에 미치는 영향 |
|---|---|---|
| 앱 이름 | **Paper Time** | 번들 ID 제안: `com.imtaeheon.PaperTime` (역DNS 형식이면 아무거나 가능, 나중에 바꾸기 어려우므로 첫 빌드 전 확정) |
| Apple Developer Program | **미가입** (무료 계정) | CloudKit·iCloud 컨테이너 entitlement 사용 불가 → **"폴더 기반 라이브러리" 아키텍처**로 전환 (아래 3.1). 결과적으로 Google Drive 요구와도 자연스럽게 맞음 |
| LLM | **온디바이스만** (Apple Foundation Models) | 클라우드 API 코드·키 관리 없음. Apple Intelligence 미지원 기기에서는 휴리스틱 파싱으로 폴백 |
| Overleaf | **자동 연동 없음**, `.bib`를 잘 뽑는 것에 집중 | BibTeX 품질(이스케이프, 대소문자 보호, 키 규칙, 중복)에 투자 |
| iPhone | 라이브러리 + 리더(보기) + **꾹 눌러 하이라이트/밑줄/취소선** | 펜 필기는 iPad/Mac 전용. iPhone은 시스템식 텍스트 마크업만 |
| 테스트 코퍼스 | `~/Documents/Bookends/Attachments` (58편) + `vla/` (3편) = 61편 | arXiv 2편, OpenReview 학회(DOI 없음) 5편+, IEEE/CVF 학회, 교과서(Casella & Berger) 등 혼합 → 파이프라인 3단계(DOI 없는 논문) 검증에 좋은 구성 |
| 디자인 | **Apple 네이티브 앱처럼** (HIG 준수) | 커스텀 위젯 금지, 시스템 컴포넌트·Liquid Glass·SF Symbols·표준 단축키·컨텍스트 메뉴·드래그&드롭 |
| 클라우드 | **iCloud Drive 기본 + Google Drive** (MVP 둘만) | 사용자가 Files/Finder에서 폴더 선택 → 그 폴더가 라이브러리. 이미 Mac에 Google Drive 데스크톱이 설치되어 있음(`~/Library/CloudStorage/GoogleDrive-…`) |

### 무료 개발자 계정으로 인한 제약 (알고 시작해야 하는 것)
- iPad/iPhone에 Xcode로 설치한 앱은 **7일마다 서명이 만료**되어 Xcode로 다시 설치해야 함(Mac 앱은 제한 없음). 매일 쓰는 앱이면 불편하므로 MVP가 마음에 들면 그때 가입($99/년)을 권장. TestFlight도 가입 필요.
- 가입하더라도 아래 폴더 기반 설계는 그대로 유효함(CloudKit을 추가할 이유가 없음). 즉 지금 결정이 나중에 발목을 잡지 않음.

---

## 2. 기능 목록

### 2.1 MVP (목표 8주) — "매일 쓸 수 있는 최소 버전"

**A. 라이브러리 (폴더 기반)**
- 첫 실행 온보딩: "라이브러리 폴더 선택" → iCloud Drive 또는 Google Drive 안의 폴더(없으면 `Paper Time/` 생성). 여러 기기에서 같은 폴더를 선택하면 동기화 완료.
- PDF 가져오기: 드래그&드롭(Mac), 파일 앱/공유 시트(iPad·iPhone), Mac 다운로드 폴더 감시(옵션), Safari 공유 시트에서 PDF URL 저장.
- **기존 라이브러리 이전**: Bookends/Zotero에서 내보낸 BibTeX/RIS + 첨부 폴더를 가져와 파일명·`file` 필드로 매칭. 가져온 서지는 파이프라인으로 재검증해 정확도 개선.
- 목록/그리드, 검색(제목·저자·연도·태그·본문), 태그, 컬렉션(스마트 폴더 포함), 읽음 상태, 즐겨찾기, 정렬. 논문 수 무제한.
- Mac: 3열 `NavigationSplitView`(사이드바-목록-리더) + 우측 Inspector(서지 편집). iPad: 동일, 컴팩트 시 2열. iPhone: 스택 내비게이션.

**B. PDF 리더 (핵심)**
- PDFKit: 연속 스크롤/페이지 단위, 2쪽 보기, 여백 자동 크롭, 종이 톤(세피아/다크 배경+원색 유지) 조절.
- 텍스트 선택·복사(줄바꿈·하이픈 정리 옵션), 문서 내 검색, 목차 사이드바, 썸네일 스트립.
- 내부 링크 점프 후 **뒤로/앞으로 히스토리**(Sioyek식, ⌘[ ⌘]).
- Mac 표준 단축키·메뉴바, 트랙패드 핀치줌, iPad 키보드 단축키, Apple Pencil 호버 미리보기.
- 마지막 읽은 위치 저장(라이브러리 폴더에 기록 → 기기 간 이어보기).

**C. 필기·하이라이트**
- PencilKit 캔버스를 각 페이지 위에 오버레이(Apple 권장 패턴). **시스템 `PKToolPicker`** 사용 → GoodNotes와 같은 도구 팔레트, 압력·기울기, 더블탭 도구 전환, 손바닥 무시, 지우개·올가미.
- 텍스트 마크업: 하이라이트(4색), 밑줄, 취소선, 텍스트 메모. iPhone은 꾹 눌러 선택 → 시스템 편집 메뉴에 "하이라이트/밑줄/취소선/복사/찾기" 추가.
- **저장 정책(요구사항 3의 핵심)**
  - 하이라이트/밑줄/취소선/메모 → 표준 `PDFAnnotation`으로 **PDF 파일에 기록**. 미리보기·Acrobat·Zotero에서 그대로 보임.
  - 펜 필기 → 스트로크별 `PDFAnnotation(.ink)`로 **PDF 파일에 기록** + 원본 `PKDrawing`을 사이드카 파일(`<paper>/ink/p0003.drawing`)로 보존. PDF Ink 주석은 압력 굵기 변화를 못 담으므로, 앱 안에서는 원본 그대로 재편집하고 파일에는 표준 주석으로 반영.
  - 저장 시점: 페이지 이탈, 앱 백그라운드, 3초 idle 디바운스. `NSFileCoordinator` + 임시파일 후 atomic replace.
  - 공유용 "평탄화 내보내기": 필기를 페이지에 구워 어떤 뷰어에서도 원본과 같게.

**D. 동기화 (폴더 기반, entitlement 불필요)**
- 라이브러리 = 폴더. Mac은 `~/Library/Mobile Documents/com~apple~CloudDocs/...` 또는 `~/Library/CloudStorage/GoogleDrive-…/...`, iOS는 파일 앱 폴더 선택 + security-scoped bookmark.
- 변경 감지: `NSFilePresenter`/`DispatchSource` + 포그라운드 진입 시 스캔. 다운로드 안 된 파일(evicted)은 아이콘 표시, 열 때 다운로드.
- 충돌 최소화 설계: 논문당 작은 JSON 여러 개(메타/상태/노트), 필기는 페이지당 파일 → 동시에 같은 파일을 건드릴 확률을 낮춤. 그래도 충돌 시 iCloud는 `NSFileVersion`, Google Drive는 "(1)" 복제본을 감지해 "A/B 버전 선택" UI. **조용히 덮어쓰지 않음.**

**E. 서지정보 파싱 (정확도 우선 계층형)**
```
1) PDF 내장 메타데이터(Info/XMP)에서 DOI·제목 후보
2) 1~2페이지 텍스트 정규식: DOI / arXiv ID / PMID
   DOI  → doi.org 콘텐츠 협상(CSL-JSON + BibTeX) : 정답급
   arXiv → arXiv API(+게재 DOI 있으면 DOI 우선; 프리프린트↔게재본 중복 병합 제안)
3) 없으면 1페이지 상단 텍스트(≤40줄)로 제목/저자/연도/venue 추출
   3a) Foundation Models @Generable 구조화 출력(온디바이스, 오프라인)
   3b) 미지원 기기 폴백: 폰트 크기 기반 휴리스틱(가장 큰 글꼴=제목, 다음 블록=저자)
   3c) Crossref query.bibliographic + OpenAlex 제목 검색 → 후보 3건
   3d) 검증: 정규화 제목 유사도 ≥0.9 + 1저자 성 + 연도 → 통과 시 DOI 확정 → 2)로
4) 실패/스캔본/OpenReview 학회 논문 → "확인 필요" 배지 + 후보 선택 UI(한 탭 확정) + 수동 편집
```
- 정본은 CSL-JSON, BibTeX은 파생. 신뢰도 필드(verified/needsReview/manual)를 항상 표시.
- 회귀 테스트: 코퍼스 61편의 정답 JSON을 만들어 파이프라인 정확도를 수치로 추적. 목표: DOI 있는 논문 98%+, 없는 학회 논문 90%+ 자동 확정, 나머지는 정직하게 "확인 필요".

**F. BibTeX 내보내기 (Overleaf에 수동 업로드용)**
- 선택/컬렉션/전체 → `.bib` 생성: 공유 시트, 파일 저장, 클립보드, "컬렉션 → 고정 파일명(refs.bib) 덮어쓰기" 옵션(Overleaf에 드래그 한 번으로 교체).
- 품질 규칙: 제목 대소문자 보호(`{GAN}`, `{Transformer}`), 특수문자 LaTeX 이스케이프·유니코드 변환, 저자 `Last, First and …`, 키 규칙 `lastnameYYYYfirstword` + 중복 접미사, arXiv는 `@misc`+`eprint/archivePrefix/primaryClass`(biblatex 호환) 또는 `@article{journal={arXiv preprint …}}` 선택, 저널 약어 옵션, 필드 순서 고정(diff 친화적).
- "BibTeX 미리보기" 패널에서 바로 수정 가능.

### 2.2 v1 — "이해를 돕는 리더" (MVP 후 4~6주)
- 참고문헌 팝업: `[12]`/`(Kim et al., 2023)` 탭 → 항목 미리보기, 내 라이브러리 보유 여부, DOI 조회.
- 그림/표/수식 팝업: "Fig. 3", "Eq. (5)" 탭 → 팝오버(Sioyek). 링크 없는 PDF도 텍스트 매칭.
- 포털/분할 보기: 본문 읽으며 그림·표 고정.
- 주석 노트 내보내기: 하이라이트+필기 스냅샷+메모 → Markdown/Obsidian(Highlights).
- OCR: 스캔본은 Vision `RecognizeDocumentsRequest`(온디바이스)로 텍스트 레이어 삽입 → 검색·하이라이트 가능.
- 인용 스타일 가이드: APA/IEEE/ACM/Chicago/Nature 등 완성 인용문 즉시 표시(doi.org `text/x-bibliography; style=…` 협상, 오프라인은 내장 템플릿) + 규칙 요약 + "이 학회는 보통 이 스타일".
- 논문별 한 줄 요약/평가 필드, 읽기 진도.

### 2.3 v2 — 검증 후
- Overleaf Git/Dropbox 자동 반영(프리미엄 가입 시), Safari 확장(DOI/arXiv 페이지 저장), 인용/피인용 그래프(OpenAlex/S2), 여러 논문 하이라이트 보드, Spotlight·단축어·Handoff, Dropbox/OneDrive 등 추가 클라우드(폴더 기반이므로 사실상 자동 지원).

### 2.4 넣지 않는 것
- Word/Docs 플러그인, 자체 서버·계정, 협업 라이브러리, 챗봇식 요약 기능.

---

## 3. 아키텍처

### 3.1 폴더 기반 라이브러리 (source of truth = 파일)

```
Paper Time/                         ← 사용자가 고른 클라우드 폴더
├── library.json                    ← 스키마 버전, 라이브러리 ID, 설정(태그 색 등)
├── papers/
│   └── 8F3A…-lecun2015deep/        ← 논문 1편 = 폴더 1개 (UUID 접두 + bibKey)
│       ├── paper.pdf               ← 원본 PDF(주석이 여기에 직접 기록됨)
│       ├── meta.json               ← CSL-JSON 서지 + 신뢰도 + 파일 해시 + 태그/컬렉션 ID
│       ├── state.json              ← 읽음 상태, 별점, 마지막 페이지, 요약 노트 (자주 바뀌는 것 분리)
│       └── ink/p0003.drawing       ← 페이지별 PKDrawing 원본
├── collections.json
└── .papertime/                     ← 기기별 캐시 제외 목록(.nosync 성격), 잠금 파일 없음
```
- 각 기기는 **로컬 SwiftData(로컬 전용) 인덱스**를 두고 폴더 스캔으로 재구성. 인덱스는 지워도 무손실.
- 장점: entitlement 불필요, iCloud/Google Drive/Dropbox 무차별 지원, 파일 앱에서 PDF가 그대로 보임, 앱이 사라져도 데이터는 남음(사용자 신뢰).
- 단점·대응: 클라우드 지연 → 동기화 상태 표시; Google Drive iOS File Provider는 백그라운드 동기화가 약함 → 포그라운드 진입 시 스캔 + 열 때 다운로드; JSON 충돌 → 필드 단위 병합(updatedAt 비교).

### 3.2 기술 스택

| 영역 | 선택 | 메모 |
|---|---|---|
| UI | SwiftUI + UIKit/AppKit Representable | `NavigationSplitView`, `Inspector`, `.searchable`, Liquid Glass 툴바(OS 26 기본), 표준 메뉴/커맨드(`Commands`), Settings 씬(Mac) |
| PDF | PDFKit | 한계 시 Nutrient PDFXKit 교체 경로 확보 |
| 필기 | PencilKit + `PKToolPicker` | 페이지별 오버레이, 좌표 변환은 InkEngine 담당 |
| 저장 | 폴더(JSON + PDF + drawing) + 로컬 SwiftData 인덱스 | CloudKit 없음 |
| 파일 접근 | `FileManager`, `NSFileCoordinator`, security-scoped bookmark, `NSFileVersion` | iOS 폴더 접근은 `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` |
| LLM | Foundation Models(온디바이스, 4096토큰) | 입력은 1페이지 상단 40줄로 제한. `SystemLanguageModel.default.availability` 확인 후 미지원이면 휴리스틱 |
| OCR(v1) | Vision `RecognizeDocumentsRequest` | 온디바이스 |
| 서지 API | doi.org, Crossref, OpenAlex, arXiv | 전부 무료·키 불필요. 직렬 큐 + 캐시 + 오프라인 재시도. `User-Agent`에 연락 메일 포함(Crossref polite pool) |
| BibTeX | 자체 직렬화(Bibliography 패키지) | 골든 파일 테스트 |
| 배포 | Xcode 직접 설치(무료 계정) → 추후 TestFlight | iOS 7일 재서명 유의 |

### 3.3 모듈 구조 (Swift Package)

```
PaperTime/
├── App/                    # 유니버설 앱 타겟, 씬/커맨드/온보딩
├── Packages/
│   ├── PaperCore/          # 도메인 모델, JSON 스키마(Codable), 로컬 SwiftData 인덱스
│   ├── LibraryStore/       # 폴더 레이아웃, 스캔/감시, 코디네이션, 충돌 감지·병합, 북마크
│   ├── PDFReader/          # PDFView 래퍼, 검색, 목차, 히스토리, 텍스트 정리, iPhone 마크업 메뉴
│   ├── InkEngine/          # PKDrawing↔PDFAnnotation(Ink) 변환, 좌표계, 자동저장, 평탄화
│   ├── MetadataPipeline/   # DOI/arXiv 탐지, API 클라이언트, 온디바이스 추출기, 휴리스틱, 검증기
│   ├── Bibliography/       # CSL-JSON, BibTeX 직렬화/파서(가져오기), RIS 파서, 키 생성, 중복
│   └── Importers/          # Bookends/Zotero 내보내기(.bib/.ris + 첨부) 이전
└── Tests/
    ├── Corpus/ground_truth.json   # 61편 정답 서지 (PDF 자체는 저장소 밖 경로 참조)
    └── …                          # 패키지별 단위 테스트, BibTeX 골든 파일
```

### 3.4 핵심 설계 상세

**(1) 필기 이중 저장과 좌표계**
- PKCanvasView(좌상단 원점, 뷰 포인트) ↔ PDF 페이지(좌하단 원점, 포인트, 회전·크롭박스). `PDFView.convert(_:to:)`로 변환 행렬을 얻어 스트로크를 페이지 공간으로 옮긴 뒤 `PDFAnnotation(bounds:forType:.ink)` + bezier path 추가.
- 주석에 커스텀 키 `/PT_StrokeID`를 기록 → 다른 앱에서 지운 주석을 사이드카에서도 제거(역동기화).
- 형광펜은 PDF가 multiply 블렌드를 못 표현하므로 알파 0.4 Ink 주석으로 근사. 굵기는 스트로크 평균 압력.
- 페이지 표시 중에는 PDF의 Ink 주석을 숨기고(중복 렌더 방지) PKCanvas 원본을 보여줌; 앱 밖에서는 PDF 주석이 보임.

**(2) 파일 안전성**
- 모든 쓰기: 임시 파일 → `replaceItemAt` atomic. PDF 저장은 `PDFDocument.write(to:)` 후 검증(페이지 수·해시)에 실패하면 롤백.
- 저장 전 항상 최신 파일 재로드 → 다른 기기 변경 위에 덮어쓰지 않음(주석 병합: 주석 ID 기준 합집합).
- 충돌 버전 감지 시 사용자에게 두 버전 미리보기 제공.

**(3) 서지 정확도 측정 루프**
- `ground_truth.json`은 첫 주에 Bookends BibTeX 내보내기를 씨앗으로 만들고 61편을 하나씩 검수(Bookends 값이 틀린 것이 있으므로 검수 필수).
- 파이프라인 변경마다 정확도 리포트(자동 확정률, 오답률, 확인 필요율) 출력. **오답률 0이 자동 확정률보다 우선.**

**(4) 네이티브 UX 체크리스트**
- 시스템 컴포넌트만 사용(List, Toolbar, Menu, Inspector, ContextMenu, ShareLink, Form).
- SF Symbols, 시스템 색·재질, 다이내믹 타입, 다크모드, VoiceOver 레이블, 한국어/영어 로컬라이즈.
- Mac: 메뉴바 명령 전부(파일/편집/보기/이동/창), 표준 단축키(⌘F 검색, ⌘O 열기, ⌘⇧E 내보내기 등), 창 상태 복원, 드래그&드롭, Quick Look.
- iPad: 멀티 윈도우(Scene), Stage Manager, 포인터 호버 효과, 키보드 단축키(⌘로 단축키 목록), Pencil 호버·스퀴즈(Pencil Pro) 팔레트.
- iPhone: 시스템 편집 메뉴 확장(`UIEditMenuInteraction`), 한 손 조작 하단 툴바.
- 앱 아이콘·이름 외에 브랜드 색을 강요하지 않음. 첫 인상은 "Apple이 만든 것 같다".

---

## 4. 데이터 스키마 (JSON, Codable, 스키마 버전 필드 포함)

```
meta.json   { schema, id, csl: {CSL-JSON}, bibKey, confidence: verified|needsReview|manual,
              candidates: [ {csl, score, source} ], fileHash, pageCount, tags: [id], collections: [id],
              addedAt, updatedAt, deviceID }
state.json  { readingStatus, rating, lastPage, lastScroll, summaryNote, lastOpenedAt, updatedAt, deviceID }
ink/pNNNN.drawing   PKDrawing.dataRepresentation()
library.json        { schema, libraryID, tags: [{id,name,color}], settings }
collections.json    { collections: [{id,name,parentID,rule?}] }
```
로컬 SwiftData 인덱스: `PaperIndex(id, title, authorsText, year, venue, tags, status, folderURL, fullTextSnippet)` — 검색·정렬 전용, 재생성 가능.

---

## 5. 구현 로드맵 (MVP 8주)

| 주 | 마일스톤 | 완료 기준 |
|---|---|---|
| 1 | 프로젝트 골격(Paper Time, 번들 ID), 패키지 분리, LibraryStore(폴더 선택·북마크·레이아웃·스캔), 온보딩 | Mac에서 iCloud Drive 폴더 선택 → PDF 넣으면 iPad에 나타남. Google Drive 폴더로도 동일 |
| 2 | PDFReader: 뷰어, 검색, 목차, 썸네일, 히스토리, Mac 메뉴/단축키, 3열 레이아웃 | 100쪽 PDF 끊김 없이, 메모리 프로파일 통과 |
| 3 | 텍스트 마크업 → PDFAnnotation 저장, iPhone 꾹 눌러 메뉴, 텍스트 메모 | 미리보기.app에서 하이라이트 보임 |
| 4 | InkEngine: 오버레이, PKToolPicker, 좌표 변환, Ink 주석 기록, 사이드카, 자동 저장, 충돌 UI | iPad 필기가 Mac 미리보기에 보이고 앱에서는 원본 재편집 |
| 5 | MetadataPipeline 1~2단계, 확인 필요 UI, Inspector 편집, ground_truth.json 작성 시작 | 코퍼스 중 DOI/arXiv 논문 자동 확정 |
| 6 | 3단계(Foundation Models + 휴리스틱 + Crossref/OpenAlex 검증), 중복 감지, 정확도 리포트 | OpenReview 논문도 후보 제시, 오답 0 |
| 7 | Bibliography: BibTeX 직렬화·미리보기·내보내기, Importers(Bookends .bib/.ris 이전) | Bookends 라이브러리 전체 이전 → Overleaf 업로드 → `\cite` 컴파일 성공 |
| 8 | 안정화, Google Drive iOS 경로 검증, 접근성·로컬라이즈, 아이콘, 1주 실사용 | 실제 논문 61편으로 일주일 사용 후 버그 목록 정리 |

---

## 6. 리스크와 대응

| 리스크 | 대응 |
|---|---|
| iOS 무료 서명 7일 만료 | MVP 만족 시 Developer Program 가입. 설계는 불변 |
| Google Drive iOS File Provider 동기화 지연·오프라인 파일 | 상태 표시, 열 때 다운로드, "오프라인 사용 가능" 안내. Mac은 데스크톱 앱 폴더로 안정적 |
| PDF Ink 주석의 압력 표현 한계 | 원본 사이드카 보존 + 평탄화 내보내기 |
| 두 기기 동시 편집 충돌 | 작은 파일 분리, 저장 전 재로드·병합, 버전 선택 UI, 절대 조용히 덮어쓰지 않음 |
| Foundation Models 미지원 iPad(M1 미만) | 휴리스틱 폴백 + Mac에서 파싱한 결과가 폴더로 동기화되므로 실사용 문제 적음 |
| OpenReview/워크숍 논문은 DOI가 아예 없음 | OpenAlex/S2에 있으면 확정, 없으면 "확인 필요"로 저자·제목만 채우고 `@inproceedings` 수동 보완 |
| PDFKit 특정 PDF 렌더 버그 | 재현 PDF 수집, 필요 시 Nutrient 교체 |

---

## 7. 시작 전 마지막 확인 (선택, 없으면 기본값으로 진행)

1. 번들 ID `com.imtaeheon.PaperTime` 그대로 갈지.
2. iPad 모델(Apple Intelligence 지원 여부 → 온디바이스 파싱이 iPad에서도 되는지 확인용). 안 되어도 Mac에서 파싱 후 동기화되므로 필수는 아님.
3. Bookends에서 `File > Export…`로 BibTeX 한 번 내보내 주면(첨부 경로 포함) 1주차에 정답 데이터 씨앗과 이전 기능 테스트에 바로 사용.

---

## 8.5 구현 현황 (2026-09-04 기준)

MVP 로드맵 1~7주차 항목이 구현되어 macOS/iOS 양쪽에서 빌드·실행되며, 패키지 테스트 98개가 통과한다.

| 로드맵 | 상태 | 비고 |
|---|---|---|
| 1주 폴더 라이브러리·온보딩 | 완료 | 폴더 선택, 북마크, 스캔, 원자적 저장, 충돌 병합, 클라우드 감지 |
| 2주 리더 | 완료 | PDFView 래퍼, 연속/단면/2쪽, 종이 톤, 페이지 위치 복원, Mac 메뉴·단축키 |
| 3주 텍스트 마크업 | 완료 | 표준 PDF 주석으로 기록, iOS 꾹 눌러 메뉴, 노트 목록(외부 앱 주석도 표시) |
| 4주 필기 | 완료 | 페이지별 PencilKit 오버레이, 좌표 변환(테스트 포함), Ink 주석 + 사이드카, 지연 저장, 평탄화 |
| 5~6주 서지 파이프라인 | 완료 | 식별자 우선 → 내장 제목 → 타이포그래피 → 온디바이스 모델, 단방향 검증 |
| 7주 BibTeX·이전 | 완료 | 대소문자 보호·이스케이프·키 규칙·미리보기, Bookends/Zotero 이전, 인용 스타일 7종 |
| 8주 안정화 | 진행 중 | iPad 시뮬레이터 실사용 확인 완료, 실기기 검증 남음 |

미구현(v1 이후로 이월): 참고문헌·그림 팝업, 포털/분할 보기, 주석 Markdown 내보내기, 스캔본 OCR.

### 실기기에서 확인이 필요한 것
- Apple Pencil 실제 필기감과 지연(시뮬레이터로는 검증 불가)
- Google Drive iOS File Provider의 실제 동기화 지연과 오프라인 파일 동작
- 두 기기 동시 편집 시 충돌 UI

## 8. 참고 자료

- PDFKit/PencilKit: [Apryse PDFKit annotations](https://apryse.com/blog/ios/how-to-add-annotations-using-swift-and-pdfkit), [PDFKit Ink Annotations Tutorial](https://medium.com/better-programming/ios-pdfkit-ink-annotations-tutorial-4ba19b474dce), [Apple PDFAnnotationEditor sample](https://github.com/AppTyrant/PDFAnnotationEditor), [PencilKit→PDF 발표자료](https://speakerdeck.com/ras0q/handwritten-annotations-to-pdf-with-pencilkit)
- Vision 문서 인식(WWDC25): [Read documents using the Vision framework](https://developer.apple.com/videos/play/wwdc2025/272/)
- Foundation Models: [Meet the Foundation Models framework](https://developer.apple.com/videos/play/wwdc2025/286/), [TN3193 컨텍스트 윈도우 관리](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window)
- 서지 API: [Crossref REST API](https://www.crossref.org/documentation/retrieve-metadata/rest-api/), [query.bibliographic](https://community.crossref.org/t/rest-api-works-query-bibliographic/3203), [DOI Content Negotiation](https://citation.doi.org/docs.html), [OpenAlex title search](https://help.openalex.org/hc/en-us/articles/41193820492951-How-do-I-use-the-title-search-API), [Semantic Scholar API](https://www.semanticscholar.org/product/api/tutorial), [PDF 추출 도구 벤치마크](https://gipplab.uni-goettingen.de/wp-content/papercite-data/pdf/meuschke2023.pdf)
- Developer Program: [CloudKit은 유료 멤버십 필요](https://teamtreehouse.com/community/cloudkit-only-for-paid-developer-account), [Membership Details](https://developer.apple.com/programs/whats-included/)
- 경쟁 앱: [Highlights](https://highlightsapp.net/), [Highlights 리뷰](https://www.macstories.net/reviews/highlights-for-iphone-and-ipad-an-excellent-companion-for-researchers/), [Sioyek](https://sioyek.info/), [Zotero vs Paperpile](https://paperguide.ai/blog/zotero-vs-paperpile/)
- Overleaf: [premium features](https://www.overleaf.com/learn/how-to/Overleaf_premium_features)
- PDF SDK 대안: [Nutrient PDFXKit](https://github.com/PSPDFKit/PDFXKit)
