# Windows용 SSMV

[English](README.md) · [프로젝트 소개](../docs/README.ko.md)

C++20, C++/WinRT, WinUI 3로 개발 중인 Windows 버전입니다. 아직 정식 배포판이
아니며 macOS 버전의 모든 기능을 제공하지는 않습니다. 문서는 Windows 기본
텍스트 컨트롤로 표시합니다.

![로컬 문서를 표시하는 Windows 개발 빌드](../docs/images/ssmv-windows-0a2d059.png)

Windows CI에서 x64 앱을 실행해 캡처한 화면입니다.

## 빌드

Windows에 Visual Studio 2022의 **C++를 사용한 데스크톱 개발**과 Windows SDK
10.0.19041 이상을 설치하세요. ARM64 빌드에는 해당 C++ 빌드 도구도 필요합니다.
Windows App SDK의 WinUI 구성 요소와 C++/WinRT는 지정된 버전을 NuGet으로
받습니다. 사용하지 않는 AI·ML 구성 요소는 포함하지 않습니다.

```powershell
./windows/scripts/build.ps1
./windows/scripts/build.ps1 -Platform ARM64
```

Visual Studio에서 `SSMV.vcxproj`를 열어도 됩니다. 결과는 저장소 루트의
`dist/windows/<아키텍처>/Release/`에 생성됩니다. 실행 파일 하나만 옮기지 말고
폴더 전체를 함께 보관하세요. 해당 아키텍처의 Microsoft Visual C++ 재배포
패키지가 필요합니다. 앱 서명과 설치 프로그램은 아직 준비되지 않았습니다.

## 첫 구현 범위

- 파일 선택, 실행 인수, 드래그앤드롭으로 로컬 Markdown 문서 열기
- 접을 수 있는 사이드바에서 문서 전환, 목차 탐색, 이름순 정렬
- 문서 개별 제거와 확인 후 목록 전체 비우기
- 제목, 문단, 목록, 인용, 구분선, 코드 블록 표시
- 시스템 설정에 따른 테마와 라이트·다크 모드

UTF-8 문서를 최대 16 MiB까지 받습니다. 목록에서 제거해도 원본 파일은
삭제하지 않습니다. 용량 제한은 처리 속도를 보장하는 수치가 아닙니다. 본문은 최대 2,000개
블록씩 나눠 이전·다음 부분으로 이동합니다. 목차도 펼쳤을 때 최대 200개씩
표시합니다. 제목을 선택하면 해당 부분만 표시하며 앞부분 전체를 그리지 않습니다.
분석한 문서 데이터는 메모리에 유지됩니다. 연속 스크롤 최적화는 후속 작업입니다.

문장 안의 서식, 표, 이미지, PDF 내보내기, URL 열기, LLM·CLI 연동, 목록 복원,
설치 시 파일 연결, 업데이트 확인은 후속 이식 항목입니다.

## 검증

```sh
cmake -S windows -B windows/.build/core
cmake --build windows/.build/core --config Release
ctest --test-dir windows/.build/core -C Release --output-on-failure
```

코어 테스트는 macOS에서도 실행할 수 있습니다. GitHub Actions는 Windows
x64·ARM64 앱을 빌드합니다. x64에서는 앱 실행, 파일 인수로 문서 열기,
화면 캡처, 창을 닫은 뒤 정상 종료까지 자동으로 확인합니다.
이 검사만으로 모든 화면 동작을 보장할 수는 없습니다.
배포 전에는 Windows에서 파일 선택 취소, 탐색기·바탕화면 드롭, 한글 경로,
키보드 조작, 목차, 테마, 화면 배율, 내레이터와 대용량 문서 응답성을 확인해야 합니다.
