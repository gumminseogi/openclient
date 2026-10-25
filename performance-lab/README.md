# OpenClient 성능 테스트 환경

2026-10-25. 기준 소스는 `ntoporcov/openclient@6b3054a18e731f342a3b98009c259191f5e67f51`입니다.

개인 OpenCode 서버나 실제 모델 없이 긴 채팅, 큰 도구 출력, 스트리밍을 생성합니다. Python 서버는 OpenCode v1 API의 필요한 부분을 구현한 합성 fixture입니다. 실제 OpenCode 프로세스는 아닙니다.

현재 Linux에서 서버의 HTTP·pagination·SSE 계약 11개를 검증했습니다. 실제 Swift/iOS 앱 빌드와 아래 GitHub Actions 구성은 아직 실행하지 않았습니다. Python 테스트 결과를 iOS 성능 측정으로 해석하면 안 됩니다.

## Mac 없이 자동 테스트하기

압축 파일은 OpenClient 포크의 루트에 적용하는 구조입니다. 기존 앱 코드는 포함하거나 변경하지 않으며, `.github/workflows/openclient-performance.yml`과 `performance-lab/`만 추가합니다.

1. 테스트 전용 OpenClient 포크를 준비하고 GitHub 연결에 접근 권한을 줍니다.
2. 이 파일들을 `performance-lab` 브랜치에 추가하면 workflow가 실행됩니다. 기본 브랜치에 workflow를 넣으면 Actions의 수동 실행도 사용할 수 있습니다.
3. Linux에서 fixture 테스트를 실행합니다. 통과하면 GitHub의 `xcode-27` 표준 macOS runner에서 실제 앱의 Swift 테스트와 기존 그룹화 UI 테스트를 실행합니다.
4. 커밋, Xcode/SDK, 선택한 시뮬레이터, 테스트 목록, 종료 상태, 빌드 로그와 `.xcresult`를 3일간 보관합니다. 실패 결과도 저장합니다.

원본 작성자의 개발 팀 설정만 비우고 시뮬레이터 코드 서명은 유지합니다. Apple 계정이나 배포 인증서를 workflow에 넣지 않습니다. 실제 모델 요청은 없습니다. 공개 저장소의 표준 GitHub-hosted runner는 무료이며, private 저장소나 larger runner의 요금 조건은 다릅니다.

현재 연결 도구에는 새 저장소·포크 생성 기능이 없어 초기 포크 준비는 별도로 필요합니다. 원격 workflow는 아직 게시하거나 실행하지 않았습니다.

## 자동 검증의 범위

| 경로 | 검증 대상 | 현재 상태 |
| --- | --- | --- |
| Python fixture | 인증, v1 감지, bootstrap, 엄격한 페이지 크기, 모든 페이지 무결성, 상세 일치, SSE 방송·재연결·취소, 로그 경계 | Linux에서 11개 통과 |
| 실제 Swift unit tests | 기존 canonical/grouping/window/cache/UI coordinator 회귀와 기존 performance measure | CI 실행 준비, 미실행 |
| 기존 ToolGrouping UI tests | 실제 앱 실행과 그룹화 UI | CI 실행 준비, 미실행; 작은 별도 fixture |
| 긴 ChatView 전체 | 실제 과거 페이지 로드 후 streaming·하단 새로고침·그룹화 ON/OFF | CI 프로토타입 작성, 미컴파일·미실행 |
| iPhone 15 Pro 실기기 | 발열, 전력, 실제 터치/키보드와 frame pacing | 시뮬레이터로 대체 불가 |

기존 `ForegroundChatRefreshTests`와 `V2TranscriptPerformanceTests`는 v2 중심입니다. 공유 경로의 회귀 검증에 활용하지만 v1 수동 새로고침 전체를 측정하지 않습니다. 기존 그룹화 UI 테스트도 전체 ChatView의 긴 기록을 재현하는 테스트는 아닙니다.

이를 보완하는 `long_transcript_ui.swift`를 CI에서 기존 UI 테스트 파일에만 덧붙입니다. 실제 연결한 ChatView에서 20·200·2,000개 seed와 그룹화 ON/OFF를 확인하고, 앱이 보낸 paging 및 refresh 요청, 스트리밍 중 초안 보존, 최종 텍스트를 검사합니다. 첫 Mac 실행에서 컴파일·UI 탐색을 검증하고 조정해야 하는 프로토타입입니다. 앱 production 코드는 바꾸지 않습니다.

기본으로 실제 로딩을 확인하는 목표는 80개입니다. **2,000개 seed를 사용해도 이것을 2,000개 loaded 테스트라고 부르면 안 됩니다.** workflow의 `TEST_RUNNER_OPENCLIENT_LAB_UI_TARGET_LOADED`를 `2000`으로 높이면 전체 로딩을 시도하며, 제스처 횟수와 timeout 안에 도달하지 못하면 실패합니다. 첨부 시간은 XCTest 관찰 비용을 포함하는 smoke 기록이며 FPS나 정확한 새로고침 완료 시간은 아닙니다. 같은 runner에서 반복한 뒤 해석해야 합니다.

## Linux에서 실행

Python 3.10 이상, 추가 패키지 없음. 압축을 푼 뒤 `performance-lab` 폴더에서 실행합니다.

```bash
python3 -B -m unittest discover -p 'test_*.py' -v
python3 lab.py serve --port 14097 --log requests.jsonl
```

시작할 때 URL·사용자 이름·임시 비밀번호를 표시합니다. 기본 바인딩은 `127.0.0.1`이며 Ctrl+C로 종료합니다. 다른 프로세스가 쓰는 포트를 빼앗지 않습니다.

세션은 `ses_20`, `ses_200`, `ses_2000`이고 초기 메시지 수가 각각 20·200·2,000개입니다. 기본적으로 user 1개 다음 assistant 7개가 이어지며, assistant에 완료된 도구 출력이 있어 메시지를 넘는 도구 그룹을 만들 수 있습니다.

## 설치된 iPhone 앱으로 수동 재현

필요할 때 우분투의 실제 Tailscale IPv4 주소로 바인딩합니다. 공인 주소나 전체 인터페이스로 열 필요는 없습니다.

```bash
python3 lab.py serve --host 100.101.102.103 --port 14097 --log requests.jsonl
```

주소는 본인 서버의 값으로 바꿉니다. OpenClient에 새 서버를 추가하고 표시된 URL, 사용자 `opencode`, 임시 비밀번호를 입력합니다. 앱이 제공하는 API 프로필 선택이 있다면 v1 또는 자동을 사용합니다. 설치된 앱과의 실제 연결은 아직 검증하지 않았습니다.

**서버에 2,000개가 있어도 앱의 최초 요청이 20개라면 20개만 반환합니다.** 긴 기록 갱신을 시험하려면 앱에서 위쪽 과거 기록을 실제로 불러와야 합니다. 로그의 `limit`과 `before`가 이를 확인하는 증거입니다. 서버가 limit을 무시해서 전체를 반환하도록 만들지 않았습니다.

스트리밍은 앱에 프롬프트를 보내는 대신 두 번째 터미널에서 시작합니다. 아래 비밀번호는 시작 시 표시된 값으로 바꿉니다.

```bash
python3 lab.py stream --url http://100.101.102.103:14097 --password 'DISPLAYED_PASSWORD' --session ses_2000 --chunks 300 --interval-ms 100
```

`--part-type reasoning`으로 추론 스트림도 만들 수 있습니다. 앱의 Stop은 합성 스트림을 중단합니다. 일반 프롬프트 전송, 파일·웹 미리보기, 삭제·revert 등은 구현하지 않았습니다. 지원하지 않는 endpoint는 404를 반환합니다.

## 비교할 조건

메시지 수와 출력 크기를 따로 바꿉니다. 서버를 다시 시작하거나 새 연결을 사용해 앱의 영구 캐시가 섞이지 않도록 하고, cold/warm 여부를 기록합니다. 고정 세션 ID로 서버 크기만 바꾸면 기존 앱 캐시가 영향을 줄 수 있습니다.

```bash
python3 lab.py serve --tool-bytes 1024 --text-bytes 512 --assistants-per-turn 7 --latency-ms 50 --detail-latency-ms 100
```

`--assistants-per-turn`은 연속 활동 그룹의 크기, `--tool-bytes`는 개별 도구 출력 크기, `--text-bytes`는 응답 본문 크기입니다. `--detail-latency-ms`로 상세 조회만 늦추면 본문과 새로고침 종료 사이의 관계를 살펴볼 수 있습니다. CLI 옵션의 허용 범위는 `python3 lab.py serve --help`와 코드의 입력 검사에 따릅니다.

20·200·2,000개 기록, 짧은/큰 도구 출력, grouping ON/OFF, idle/streaming, cold/warm를 한 번에 하나씩 비교합니다. 다른 세션의 선읽기 요청이 섞일 수 있으므로 로그를 session 경로별로 나눠 봅니다.

## 기록 해석

```bash
python3 lab.py summary requests.jsonl
```

완료된 HTTP 요청의 경로·쿼리·상태·응답 body bytes·서버 처리 구간을 기록합니다. 시작·종료 monotonic timestamp로 요청 겹침과 상세 요청의 순서를 확인할 수 있습니다. 인증 헤더와 요청·응답 본문은 기록하지 않습니다. URL 경로와 쿼리는 기록하므로 fixture 용도로만 사용합니다.

열린 SSE는 아직 완료 요청에 집계되지 않습니다. 인증된 `GET /_lab/status`의 `inflight`에서 진행 중인 bytes를 확인할 수 있습니다. body bytes에는 HTTP 헤더·TLS·Tailscale 전송량이 포함되지 않습니다. 서버 처리 시간은 네트워크 왕복·앱 디코딩·화면 완료·FPS 측정값이 아닙니다.

## 소스 근거

- [v1 요청과 pagination](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClient/API/OpenCodeAPIClient.swift#L1629-L1878)
- [loaded history를 이용하는 새로고침](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClient/ViewModels/AppViewModel/AppViewModel%2BSessions.swift#L2457-L2517)
- [실제 v1.19.0 서버의 limit 처리](https://github.com/anomalyco/opencode/blob/733b2c627e5aec39cb33cc22373bdce33053ef2c/packages/opencode/src/server/routes/instance/httpapi/handlers/session.ts#L106-L153)
- [기존 그룹화 성능 테스트](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClientTests/ChatStoreTests.swift#L1260-L1269)
- [기존 성능 signpost](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClient/Diagnostics/OpenClientPerformanceDiagnostics.swift#L4-L30)
- [GitHub-hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

원본 OpenClient의 라이선스는 함께 둔 `UPSTREAM_LICENSE`를 참고하십시오.
