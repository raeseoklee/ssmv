# Codex·Claude·ChatGPT·Gemini의 결과를 SSMV에서 읽기

[English](LLM-WORKFLOWS.md) · [한국어 README](README.ko.md)

macOS용 SSMV 0.5.0 이상에서는 로컬 파일, 복사한 텍스트, `ssmv` 명령으로 각 도구의 Markdown 결과를 열 수 있습니다. SSMV용 MCP 서버나 도구별 플러그인은 필요하지 않습니다.

Windows 미리 보기 버전에서는 결과를 Markdown 파일로 저장하거나 내려받아 SSMV로 열고, 복사한 텍스트는 클립보드 가져오기로 읽을 수 있습니다. 아래 `ssmv` CLI 예시는 macOS 전용입니다. 지원하는 전달 방법은 [Windows 안내](../windows/README.ko.md)를 확인하세요.

| 작업 환경 | 결과를 여는 방법 |
| --- | --- |
| Mac에서 로컬로 실행하는 Codex | Markdown 파일로 저장한 뒤 `ssmv`로 열어 달라고 요청 |
| Mac의 Claude Code·Gemini CLI | 에이전트에게 파일을 열어 달라고 요청하거나 아래 명령 사용 |
| ChatGPT·Claude·Gemini 채팅 | Markdown을 복사해 가져오거나 파일로 내려받기 |
| 클라우드 작업·원격 호스트·컨테이너 | 결과를 Mac으로 내려받은 뒤 로컬에서 열기 |

## 준비

[Homebrew 설치 안내](README.ko.md#설치)에 따라 SSMV를 설치하거나 업데이트하고, 터미널에서 `ssmv --version`으로 확인하세요. 아래 CLI 예시를 쓰려면 해당 AI 도구도 설치하고 로그인해야 합니다. 요약할 프로젝트 폴더에서 실행하세요. 각 서비스의 사용량과 권한 정책은 그대로 적용됩니다. SSMV는 결과를 읽는 앱이며 모델 이용 권한을 제공하지 않습니다.

## Codex

로컬 Codex 작업에서 다음과 같이 요청하세요.

> 결과를 이 작업 폴더의 새 파일 `review.md`에 Markdown으로 저장해줘. 코드 예제에만 코드 블록을 사용하고, 문서 전체를 코드 블록으로 감싸지 마. 저장한 뒤 이 Mac에서 `ssmv "review.md"`를 실행해 열어줘. 로컬 앱을 실행할 수 없으면 파일 경로를 알려줘.

Codex CLI에서는 최종 응답을 파일로 저장하고, 완료 후 SSMV로 열 수 있습니다.

```sh
codex exec "이 프로젝트를 Markdown으로 요약해줘. 문서 전체를 코드 블록으로 감싸지 말고 본문만 반환해줘. 프로젝트 파일은 수정하지 마." \
  -o codex-summary.md && ssmv "codex-summary.md"
```

`-o`는 최종 응답을 파일로 저장하는 옵션입니다. [Codex 공식 문서](https://developers.openai.com/codex/noninteractive/)를 참고하세요. 클라우드 Codex 작업은 Mac에 명시적으로 연결된 환경이 아니라면 아래의 파일 내려받기 방법을 이용하세요.

## Claude Code

파일과 명령 실행 도구를 사용할 수 있는 로컬 Claude Code에서도 같은 방식으로 저장과 열기를 요청할 수 있습니다. 한 번의 명령으로 처리하려면 다음 예시를 쓰세요.

```sh
claude -p "이 프로젝트를 Markdown으로 요약해줘. 문서 전체를 코드 블록으로 감싸지 말고 본문만 반환해줘. 프로젝트 파일은 수정하지 마." \
  --output-format text > claude-summary.md && ssmv "claude-summary.md"
```

출력 형식은 JSON이나 스트리밍 이벤트 대신 텍스트로 지정합니다. [Claude Code 공식 문서](https://code.claude.com/docs/en/headless)를 참고하세요. Claude 채팅에서는 아래의 클립보드·파일 내려받기 방법을 이용하세요.

## Gemini CLI

로컬 Gemini CLI에서도 파일 저장과 열기를 요청하거나 다음 명령을 실행하세요.

```sh
gemini -p "이 프로젝트를 Markdown으로 요약해줘. 문서 전체를 코드 블록으로 감싸지 말고 본문만 반환해줘. 프로젝트 파일은 수정하지 마." \
  --output-format text > gemini-summary.md && ssmv "gemini-summary.md"
```

`-p`는 대화형 화면 없이 요청을 실행하는 옵션입니다. [Gemini CLI 공식 문서](https://geminicli.com/docs/cli/headless/)를 참고하세요. Gemini 채팅에서는 다음 방법을 이용하세요.

## ChatGPT·Claude·Gemini 채팅

채팅에서 Mac의 명령을 실행할 수 없다면 다음 순서로 가져오세요.

1. “문서를 복사할 수 있는 하나의 코드 블록 안에 Markdown으로 작성해줘. 필요한 곳에 제목, 목록, 표를 사용해줘”라고 요청합니다. 문서 안에 코드 블록이 들어간다면, 파일을 만들 수 있는 채팅에서는 내려받을 `.md` 파일로 요청하세요.
2. 바깥쪽 코드 블록 표시는 빼고 Markdown 내용만 복사합니다.
3. SSMV에서 **File → Open Clipboard as Markdown**을 선택합니다.
4. 별도 파일로 보관하려면 **File → Save a Copy…**를 선택합니다. PDF로도 내보낼 수 있습니다.

내려받을 Markdown 파일이 제공된다면 Mac에 저장한 뒤 Finder의 **다음으로 열기 → SSMV**를 선택하거나 `ssmv "/path/to/result.md"`를 실행하세요. 클라우드의 다운로드 링크가 공개 Markdown 주소인 것은 아닙니다. 로그인이 필요한 첨부 파일은 채팅에서 먼저 내려받으세요. SSMV의 URL 열기에는 공개 HTTPS Markdown 주소나 지원하는 GitHub 파일 링크를 입력합니다.

## 반복해서 사용하기

필요한 프로젝트의 로컬 에이전트 지침에 다음 내용을 추가할 수 있습니다.

> 내가 Markdown 결과를 SSMV로 보여 달라고 하면 새 `.md` 파일로 저장하고, 파일 경로를 따옴표로 감싸 `ssmv`로 열어줘. 명령을 찾지 못하면 같은 경로로 `open -a SSMV`를 사용해줘. 앱 실행이 차단되거나 원격 작업이라면 내가 로컬에서 열 수 있도록 파일을 제공해줘.

예시 명령은 현재 폴더에 파일을 씁니다. 이전 결과를 보관하려면 아직 쓰지 않은 파일명을 지정하세요. `&&` 뒤의 SSMV 명령은 생성 명령이 성공했을 때만 실행됩니다. 반복 작업에는 이 파일 방식을 권장합니다. 이미 만든 결과를 앱이 보관하는 사본으로 가져오려면 다음과 같이 실행하세요.

```sh
ssmv - --title "프로젝트 요약" < codex-summary.md
```

SSMV는 입력이 끝난 뒤 문서를 표시하며 생성 중인 토큰을 실시간으로 보여주지는 않습니다. 입력은 비어 있지 않은 UTF-8 텍스트여야 하며 최대 16 MiB입니다. `2>&1`로 진단 메시지를 Markdown에 섞지 마세요. CLI의 종료 코드 0은 SSMV에 요청을 전달했다는 뜻이며, 이후 화면 표시 오류는 앱에 나타납니다. 로컬 파일이 바뀌면 **⌘R**로 다시 읽으세요. 가져온 사본은 원본 변경을 따라가거나 답변을 다시 생성하지 않습니다.

`ssmv`를 찾지 못하면 cask를 업데이트하고 터미널을 다시 열거나 `open -a SSMV "/path/to/result.md"`를 사용하세요. 에이전트 환경에서 앱 실행이 차단되면 터미널에서 직접 실행하면 됩니다. 이를 위해 에이전트의 샌드박스 설정을 바꿀 필요는 없습니다.

명령 옵션은 2026-09-16에 공식 문서와 로컬에 설치된 CLI 도움말로 확인했습니다.
