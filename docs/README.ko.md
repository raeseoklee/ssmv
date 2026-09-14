# SSMV — So Simple Markdown Viewer

[English](../README.md)

SSMV는 **macOS 13 이상**에서 사용하는 네이티브 Markdown 읽기 전용 앱입니다. Finder에서 로컬 문서를 열고, 접을 수 있는 사이드바에 여러 문서를 보관하며, PDF로 내보낼 수 있습니다. Swift와 AppKit으로 구현했고 웹뷰, 백그라운드 서버, 외부 패키지를 사용하지 않습니다.

![문서 사이드바와 Markdown 본문을 표시한 SSMV](images/ssmv.png)

## 설치

```sh
brew install --cask raeseoklee/tap/ssmv
```

또는 [GitHub Releases](https://github.com/raeseoklee/ssmv/releases)에서 Apple Silicon·Intel Universal 앱을 받아 압축을 풀고 `SSMV.app`을 응용 프로그램 폴더로 옮깁니다.

**서명 안내:** 0.1.0은 ad-hoc 서명된 앱이며, Apple Developer ID 서명 및 공증을 받지 않았습니다. macOS Gatekeeper가 처음 실행을 차단할 수 있습니다. 실행 여부를 결정하기 전에 [Apple의 확인되지 않은 개발자 앱 열기 안내](https://support.apple.com/en-gb/102445)를 확인하세요. 아래 방법으로 소스에서 직접 빌드할 수도 있습니다.

## 사용법

Finder에서 `.md`, `.markdown`, `.mdown` 파일을 우클릭하고 **다음으로 열기 → SSMV**를 선택하거나, 앱에서 **⌘O**를 누릅니다. 더블클릭으로 열려면 Finder의 **정보 가져오기 → 다음으로 열기 → SSMV → 모두 변경…**으로 기본 앱을 지정하세요. SSMV는 기본 앱 설정을 자동으로 바꾸지 않습니다.

- **⌘O**, **+** 버튼 또는 사이드바로 드래그하여 여러 문서를 추가합니다.
- 목록에서 문서를 선택하고, 필요할 때 사이드바를 접습니다.
- **−**, 우클릭 메뉴 또는 **⌘⌫**로 목록에서 제거합니다. 원본 파일은 삭제하지 않습니다.
- 문서 목록·선택·사이드바 표시·외관 설정은 재실행 후에도 유지됩니다. 파일 경로를 저장하므로 이동하거나 삭제한 문서는 다시 열어야 합니다.
- **View → System Appearance / Light / Dark**에서 외관을 선택합니다.
- **File → Export as PDF…**로 선택한 문서를 내보냅니다. 화면 테마·글자 크기와 관계없이 흰 배경의 A4 PDF로 저장하며 긴 문서는 자동으로 페이지를 나눕니다.

## 지원 범위

제목, 문단, 강조, 취소선, 목록, 인용, 코드 블록, 표, 링크를 표시합니다. 웹 링크는 기본 브라우저에서, 상대 경로 Markdown 링크는 사이드바에서 엽니다. 한글·이모지를 포함한 UTF-8 파일을 지원하며 파일 크기는 최대 16 MiB입니다.

이미지, HTML 렌더링, Mermaid, 수식, 구문 강조, 체크박스 조작, 문서 내부 앵커 이동은 지원하지 않습니다. Foundation Markdown 파서를 사용하므로 GitHub와 완전히 동일한 렌더링을 보장하지 않습니다. PDF에도 같은 제한이 적용됩니다.

파일 읽기·파싱은 백그라운드에서 처리합니다. 화면 배치는 메인 스레드에서 수행하므로 큰 문서에서는 잠시 지연될 수 있습니다. 파일 변경을 자동으로 감시하지 않으며 **⌘R**로 다시 읽습니다.

## 단축키

| 기능 | 단축키 |
| --- | --- |
| 문서 열기 | ⌘O |
| 찾기 | ⌘F |
| 복사 / 전체 선택 | ⌘C / ⌘A |
| PDF 내보내기 | ⇧⌘E |
| 사이드바 접기·펼치기 | ⌃⌘S |
| 목록에서 제거 | ⌘⌫ |
| 다시 읽기 | ⌘R |
| 글자 확대 / 축소 / 초기화 | ⌘+ / ⌘− / ⌘0 |
| 전체 화면 | ⌃⌘F |
| 창 닫기 / 앱 종료 | ⌘W / ⌘Q |

⌘는 Command, ⇧는 Shift, ⌃는 Control입니다. 앱이 정의한 단축키는 Fn을 요구하지 않습니다. macOS가 관리하는 메뉴에서는 🌐가 Fn을 뜻할 수 있습니다. **Help → Keyboard Shortcuts…**에서 기호를 확인할 수 있으며 시스템 메뉴 표기는 macOS 버전에 따라 다를 수 있습니다.

## 소스에서 빌드

macOS 13 이상과 Swift 6 이상을 포함한 Xcode 또는 Command Line Tools가 필요합니다.

```sh
git clone https://github.com/raeseoklee/ssmv.git
cd ssmv
scripts/build-app.sh
open dist/SSMV.app
```

Apple Silicon·Intel Universal 빌드는 `UNIVERSAL=1 scripts/build-app.sh`를 사용합니다. 로컬 빌드는 ad-hoc 서명됩니다. 개발 검증과 기여 방법은 [CONTRIBUTING.md](../CONTRIBUTING.md)를 확인하세요.

## 자주 묻는 질문

**편집도 가능한가요?** 읽기 전용 앱입니다. 원하는 편집기에서 수정한 뒤 SSMV에서 다시 읽으세요.

**문서를 업로드하나요?** 로컬 파일을 읽으며 문서 업로드 서비스나 사용 분석 기능이 없습니다. 웹 링크를 열면 기본 브라우저에 URL을 전달합니다.

**목록에서 제거하면 파일도 삭제되나요?** 아니요. 원본 문서는 디스크에 남습니다.

## 프로젝트

- 소스·이슈: [raeseoklee/ssmv](https://github.com/raeseoklee/ssmv)
- Homebrew tap: [raeseoklee/homebrew-tap](https://github.com/raeseoklee/homebrew-tap)
- 릴리스 기록: [CHANGELOG.md](../CHANGELOG.md)
- 라이선스: [MIT](../LICENSE). 앱 아이콘은 AI 이미지 생성 도구로 제작했으며 [생성 프롬프트](../Resources/AppIcon-prompt.txt)를 포함합니다.

- [Security](../SECURITY.md) · [Publication review](../docs/COMPLIANCE.md) · [Third-party notices](../THIRD_PARTY_NOTICES.md)
