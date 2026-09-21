# 여기 있는 것

배포하기 전에 **직접 설치해서 확인하는** 파일들이에요.
`Scripts/build-installers.sh`가 지금 작업 중인 코드 그대로 구워서 여기 둬요.

| 파일 | 어디에 |
|---|---|
| `Paper Time <버전>.dmg` | 맥 — 열어서 Applications로 끌어 놓기 |
| `Paper Time Setup <버전>.exe` | 윈도우 — 두 번 눌러 설치 (관리자 권한 필요 없어요) |
| `Paper Time-<버전>-win.zip` | 윈도우 — 설치 없이 풀어서 실행 (64비트) |
| `Paper Time-<버전>-arm64-win.zip` | 윈도우 ARM — 설치 없이 |
| `Paper Time-<버전>-x86_64.AppImage` | 리눅스 — `chmod +x` 하고 실행 |
| `Paper Time-<버전>-arm64.AppImage` | 리눅스 ARM |
| `paper-time-<버전>.tar.gz` | 리눅스 — 풀어서 실행 |

이 폴더는 git에 들어가지 않아요. 몇백 MB짜리 빌드 결과물이고,
남는 사본은 GitHub 릴리스 쪽이니까요.

## 새로 굽기

```bash
Scripts/build-installers.sh           # 셋 다
Scripts/build-installers.sh mac       # 디스크 이미지만
Scripts/build-installers.sh portable  # 윈도우·리눅스만
```

## 그 다음에야 배포

```bash
Scripts/publish-release.sh <버전> "한 줄" "one line"
```

배포가 끝나면 방금 올린 버전만 남고 지난 버전은 지워져요 — 남는 사본은 릴리스 쪽이에요.
