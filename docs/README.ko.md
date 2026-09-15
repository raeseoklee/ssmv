# SSMV — So Simple Markdown Viewer

[English](../README.md)

SSMV는 **macOS 13 이상**에서 Markdown 문서를 읽는 네이티브 앱입니다. Finder에서 파일을 열고, 접을 수 있는 사이드바에 여러 문서를 추가해 선택하며 읽을 수 있습니다. 문서를 PDF로 저장하는 기능도 제공합니다. Swift와 AppKit으로 만들었으며 웹뷰, 백그라운드 서버, 외부 패키지를 사용하지 않습니다.

![사이드바에서 문서를 선택해 읽는 SSMV 화면](images/ssmv.png)

## 설치

Homebrew로 설치하려면 다음 명령을 실행하세요.

```sh
brew install --cask raeseoklee/tap/ssmv
open -a SSMV
```

직접 설치하려면 [GitHub Releases](https://github.com/raeseoklee/ssmv/releases)에서 앱을 받아 압축을 풀고 `SSMV.app`을 응용 프로그램 폴더로 옮기세요. Apple Silicon과 Intel에서 모두 실행할 수 있는 Universal 앱입니다.

**0.3.0은 ad-hoc 서명 상태이며 Apple Developer ID 서명과 공증을 받지 않았습니다.** Homebrew cask는 압축 파일의 체크섬과 앱 서명을 확인한 뒤 SSMV.app의 격리 속성을 제거합니다. 이 과정에서 해당 앱의 Gatekeeper 최초 실행 검사를 건너뛰며, Apple 공증을 받는 것은 아닙니다. 직접 내려받은 앱은 처음 실행할 때 차단될 수 있습니다. 실행 여부를 결정하기 전에 [Apple의 앱 실행 안내](https://support.apple.com/en-gb/102445)를 확인하세요. 아래 안내에 따라 소스에서 직접 빌드할 수도 있습니다.

Homebrew로 설치한 뒤 SSMV를 한 번 실행하면 Finder의 **다음으로 열기** 목록에 앱을 등록합니다.
이전에 설치한 앱이 목록에 없다면 tap을 갱신한 뒤 다시 설치하세요.

```sh
brew update
brew reinstall --cask raeseoklee/tap/ssmv
open -a SSMV
```

## 업데이트

앱 실행 시 Homebrew tap의 새 버전을 백그라운드에서 확인합니다. 확인은 최대 24시간에 한 번이며, 새 버전이 있으면 앱 안에 안내가 표시됩니다. **Copy Commands**를 누르고 SSMV를 종료한 다음, 터미널에 명령을 붙여 넣어 실행하세요.

```sh
brew update
brew upgrade --cask raeseoklee/tap/ssmv
```

앱이 업데이트 파일을 직접 내려받거나 설치하지는 않습니다. 같은 버전은 한 번만 알리며, 확인에 실패해도 문서 읽기에는 영향을 주지 않습니다. GitHub의 공개 cask 파일을 읽을 뿐 문서 내용이나 파일 경로는 전송하지 않습니다.

## 사용법

Finder에서 `.md`, `.markdown`, `.mdown` 파일을 우클릭한 뒤 **다음으로 열기 → SSMV**를 선택하세요. 앱 안에서는 **⌘O**로 파일을 엽니다.

문서를 더블클릭했을 때 SSMV로 열리게 하려면 Finder에서 파일을 선택하고 **정보 가져오기 → 다음으로 열기 → SSMV → 모두 변경…**을 선택하세요. SSMV가 기본 앱 설정을 자동으로 바꾸지는 않습니다.

- **⌘O**나 **+** 버튼으로 문서를 추가합니다. 여러 파일을 사이드바로 끌어 놓을 수도 있습니다.
- 사이드바에서 읽을 문서를 선택합니다. 본문을 넓게 보고 싶을 때는 사이드바를 접을 수 있습니다.
- 파일 왼쪽 화살표를 펼치면 제목의 단계에 따라 목차가 나타납니다. 제목을 클릭하면 본문의 해당 위치로 이동합니다. **View → Show Document Outline** 메뉴나 **Documents** 오른쪽 목차 버튼으로 표시 여부를 바꿀 수 있으며, 설정은 앱을 다시 실행해도 유지됩니다. 목차는 파일당 제목 2,000개까지 표시합니다. 선택하지 않은 파일은 펼칠 때 목차를 읽습니다.
- **−** 버튼, 우클릭 메뉴 또는 **⌘⌫**로 목록에서 문서를 제거합니다. 원본 파일은 삭제되지 않습니다.
- 앱을 다시 실행해도 문서 목록, 선택한 문서, 사이드바 표시 여부, 화면 모드 설정은 유지됩니다. 파일 경로를 저장하므로 파일을 옮기면 새 위치에서 다시 열어야 합니다. 삭제한 파일은 열 수 없습니다.
- **View → System Appearance / Light / Dark**에서 시스템 설정 따르기, 라이트 모드, 다크 모드를 선택합니다.
- 전체 화면(**⌃⌘F**)에서는 파일명과 도구 막대가 숨겨집니다. 화면 맨 위로 포인터를 옮기면 다시 나타납니다.
- **File → Export as PDF…**로 선택한 문서를 저장합니다. 화면 모드나 글자 크기와 관계없이 흰 배경의 A4 PDF로 저장하며, 긴 문서는 여러 페이지로 나눕니다. 별도 창에서 진행 단계를 확인하거나 **Cancel**로 취소할 수 있으며, 내보내는 동안에도 문서를 읽거나 다른 문서를 선택할 수 있습니다.

## 지원 범위와 제한

제목, 문단, 강조, 취소선, 목록, 인용, 코드 블록, 표, 링크를 표시합니다. 웹 링크는 기본 브라우저로 열고, 상대 경로로 연결된 Markdown 문서는 사이드바에서 엽니다. 한글과 이모지가 포함된 UTF-8 파일을 지원하며 파일 크기는 최대 16 MiB입니다.

이미지, HTML 렌더링, Mermaid, 수식, 구문 강조, 체크박스 조작, 문서 내부 앵커 이동은 지원하지 않습니다. Foundation Markdown 파서를 사용하므로 GitHub와 표시 방식이 완전히 같지는 않을 수 있습니다. PDF 내보내기에도 같은 제한이 적용됩니다.

파일을 읽고 Markdown을 해석하는 작업은 백그라운드에서 처리합니다. 해석이 끝나면 본문을 조금씩 표시하고, 화면에 보이는 부분부터 배치합니다. 읽는 중에도 다른 문서를 선택할 수 있으며 동시에 해석하는 문서는 최대 2개입니다. 이미 시작한 Foundation 해석 작업은 중간에 멈출 수 없어 두 작업이 모두 진행 중이면 새 문서가 기다릴 수 있습니다.

아주 긴 문단이나 표, 멀리 떨어진 본문 검색, PDF 내보내기에는 시간이 걸릴 수 있습니다. PDF 내보내기는 본문 생성이 끝나면 사용할 수 있습니다. 파일 변경은 자동으로 반영하지 않으므로 수정한 내용을 보려면 **⌘R**로 다시 읽으세요.

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

⌘는 Command, ⇧는 Shift, ⌃는 Control입니다. SSMV에서 지정한 단축키는 Fn 키 없이 사용할 수 있습니다. macOS가 관리하는 메뉴에서는 Fn 키가 🌐로 표시될 수 있습니다. 기호 설명은 **Help → Keyboard Shortcuts…**에서 확인하세요. 시스템 메뉴의 표기는 macOS 버전에 따라 다를 수 있습니다.

## 소스에서 빌드

macOS 13 이상과 Swift 6 이상이 필요합니다. Xcode 또는 Command Line Tools를 설치한 뒤 다음 명령을 실행하세요.

```sh
git clone https://github.com/raeseoklee/ssmv.git
cd ssmv
scripts/build-app.sh
open dist/SSMV.app
```

Apple Silicon과 Intel을 모두 지원하는 Universal 앱을 빌드하려면 `UNIVERSAL=1 scripts/build-app.sh`를 사용하세요. 로컬 빌드에는 ad-hoc 서명이 적용됩니다. 개발 시 확인할 항목과 기여 방법은 [CONTRIBUTING.md](../CONTRIBUTING.md)에 정리되어 있습니다.

## 자주 묻는 질문

**문서를 편집할 수 있나요?** SSMV는 읽기 전용 앱입니다. 다른 편집기에서 문서를 수정한 뒤 SSMV에서 다시 읽으세요.

**문서가 외부로 업로드되나요?** SSMV는 로컬 파일을 읽으며 문서 업로드 서비스나 사용 분석 기능을 제공하지 않습니다. 웹 링크를 열 때는 해당 URL을 기본 브라우저에 전달합니다.

**목록에서 제거하면 파일도 삭제되나요?** 아니요. 목록에서만 빠지고 원본 파일은 그대로 남습니다.

## 프로젝트 정보

- 소스와 이슈: [raeseoklee/ssmv](https://github.com/raeseoklee/ssmv)
- Homebrew tap: [raeseoklee/homebrew-tap](https://github.com/raeseoklee/homebrew-tap)
- 변경 기록: [CHANGELOG.md](../CHANGELOG.md)
- 라이선스: [MIT](../LICENSE). 앱 아이콘은 AI 이미지 생성 도구로 만들었으며 [생성 프롬프트](../Resources/AppIcon-prompt.txt)를 함께 공개합니다.
- [보안 안내](../SECURITY.md) · [공개 전 검토](../docs/COMPLIANCE.md) · [외부 구성 요소와 출처 고지](../THIRD_PARTY_NOTICES.md)

- 대용량 문서 측정 결과: [PERFORMANCE.md](PERFORMANCE.md)
