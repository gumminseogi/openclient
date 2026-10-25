# OpenClient 성능 테스트 환경

2026-10-25. [테스트 포크의 `performance-lab` 브랜치](https://github.com/gumminseogi/openclient/tree/performance-lab)에서 실제 앱을 빌드하고 iPhone·iPad 시뮬레이터의 XCTest를 실행합니다. 기준 production 소스는 `ntoporcov/openclient@6b3054a18e731f342a3b98009c259191f5e67f51`입니다. `main`은 유지하며, 테스트 브랜치에는 개선 패치를 추가했습니다.

Python fixture는 OpenCode v1 API의 필요한 부분을 구현해 긴 기록, 큰 도구 출력, SSE 스트리밍을 만듭니다. 실제 OpenCode 프로세스나 모델은 사용하지 않습니다.

개선 패치 `04b82e4127499d50b41e2ac8b83874c5b82f1fec`는 v1 legacy idle 중복 재조회와 취소된 reload 실행을 방지합니다. [개선 후 CI](https://github.com/gumminseogi/openclient/actions/runs/40175478549)는 두 기기 모두 성공했습니다. Swift 검사 각각 51개, UI 검사 각각 2개(긴 채팅 6개 시나리오 포함)가 통과했습니다.

2,000개/grouping ON에서 스트림 제어 이후 시나리오 종료 증거 수집 전까지의 canonical 조회는 두 기기 모두 **2건 → 1건**이었습니다. iPhone 응답 본문 합계는 16,827,280 → 8,413,639바이트, iPad는 16,827,278 → 8,413,642바이트였습니다. 이것은 해당 구간의 합성 HTTP 본문 크기 비교이며 전체 통신량·FPS·실기기 체감 속도를 뜻하지 않습니다. 수동 새로고침과 종료 동기화의 전체 기록 조회 한 번은 유지합니다. 아래 표는 개선 전 기준입니다.

## 확인된 결과

| 실행 | 확인된 결과 | 제한 |
| --- | --- | --- |
| [실제 Swift 테스트 — 40164300946](https://github.com/gumminseogi/openclient/actions/runs/40164300946) | iPhone·iPad 각각 50개 통과 | 같은 실행의 초기 UI smoke는 실패해 workflow 전체는 실패 |
| [loaded 목표 80 UI — 40166110713](https://github.com/gumminseogi/openclient/actions/runs/40166110713) | iPhone UI 테스트 2개 통과. iPad의 새 ChatView smoke에서 seed 20·200·2,000 × grouping ON/OFF 6개 시나리오 통과 | iPad의 기존 별도 그룹화 화면 실행이 실패해 workflow 전체는 실패. 2,000개 loaded 결과가 아님 |
| [loaded 목표 2,000 UI — 40167869834](https://github.com/gumminseogi/openclient/actions/runs/40167869834) | **최종 workflow 성공**. iPhone attempt 1과 iPad attempt 2에서 각각 6개 시나리오 통과 | 같은 SHA에서 실패한 iPad job만 재실행. iPhone 성공과 fixture 11개 통과는 attempt 1 결과를 재사용. iPad attempt 1의 시작 단계 실패는 아래 기록에 보존. Swift 50개는 재실행하지 않음 |

관측한 native 환경은 Xcode 27.1 / iOS 27.0, iPhone 18 Pro Max 및 iPad Pro 13-inch (M5) 시뮬레이터입니다. iPhone 15 Pro 실기기 검증은 하지 않았습니다.

iPhone과 iPad의 전체 loaded profile은 `4711a6804fc70c9675271b70c677e715e4a4c1f2`에서 각각 UI test 1개 안의 seed 20·200·2,000 × grouping ON/OFF 6개 시나리오를 완료했습니다. 두 기기 모두 6개 시나리오의 초안 입력 직전·직후에 합성 스트리밍이 진행 중이었음을 확인했습니다. XCTest 경과 시간은 iPhone 1,378.497초, iPad 1,124.063초로 전체 UI 절차의 시간입니다.

| iPhone 하단 refresh | 요청 limit | 응답 body bytes |
| --- | ---: | ---: |
| 20개 seed / grouping ON | 20 | 81,961 |
| 200개 seed / grouping ON | 200 | 839,642 |
| 2,000개 seed / grouping ON | 2,000 | 8,410,893 |
| 2,000개 seed / grouping OFF | 2,002 | 8,413,640 |

이는 이 fixture 설정의 실제 refresh 응답 크기이며 사용자의 서버 데이터 크기나 전체 전송 비용을 뜻하지 않습니다. 모두 `before` 없는 앱 요청입니다.

2,000개/grouping ON의 응답 종료 뒤에는 `limit=2002` 조회 두 건이 각각 8,413,640바이트를 기록했습니다. OFF에서도 같은 범위 조회 두 건이 있었지만 첫 건은 body 0바이트로 끝났으므로 두 건 모두 전체 다운로드로 세면 안 됩니다. 전체 6개 시나리오의 합계는 단일 새로고침 비용이 아닙니다.

기준 [OpenCode 종료 처리](https://github.com/anomalyco/opencode/blob/733b2c627e5aec39cb33cc22373bdce33053ef2c/packages/opencode/src/session/status.ts)는 status idle과 idle 이벤트를 모두 발행합니다. OpenClient는 둘 다 재조회 대상으로 처리하며, [scheduleReload](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClient/ViewModels/AppViewModel/AppViewModel%2BEvents.swift)의 대기 취소를 삼킨 뒤 취소 여부를 검사하지 않습니다. 중복 패턴과 맞는 수정 후보지만 각 GET의 호출자를 trace로 확정하지는 않았습니다. 취소된 작업이 항상 전송되는 것도 아니며, 취소 검사만으로 이미 완료된 첫 조회 이후의 중복까지 막을 수는 없습니다. 델타마다 전체 기록을 HTTP로 조회하는 구조는 아닙니다.

iPad attempt 1에는 transcript API 요청이 없었고 `Connected home`에서 실패했습니다. watchdog의 143,917ms main-thread stall과 spindump의 `SpeechVoiceStore.init → refreshVoices → AVSpeechSynthesisVoice.speechVoices → AX 동기 semaphore 대기`가 관측되었습니다. 긴 채팅 시나리오에 도달하기 전의 시작 단계 실패이며 긴 기록 성능 실패로 해석하지 않습니다. 같은 SHA의 iPad attempt 2는 6개 시나리오 모두 통과했습니다. 2,000개/grouping ON의 refresh는 `limit=2000`, body 8,410,893바이트였고 OFF는 `limit=2002`, body 8,413,639바이트였습니다.

## UI 검증의 범위

`long_transcript_ui.swift`를 CI에서 기존 UI 테스트 파일에만 덧붙여 실제 연결된 ChatView를 조작합니다. 과거 기록 paging, 하단 pull로 발생한 canonical refresh, 스트리밍 중 초안 유지와 키보드 닫기, 최종 응답 표시를 확인합니다. 자동 UI 테스트의 스트림은 `text`입니다. 서버의 `reasoning` 옵션은 이번 native UI 테스트에서 검증하지 않았습니다.

**seed 수와 앱이 로딩한 수는 다릅니다.** 목표는 각 seed와 설정값 중 작은 수입니다. 페이지 요청의 coverage는 HTTP 관측에 따른 추정이며, 최종 하단 refresh의 `before` 없는 요청과 `limit >= 목표`를 함께 확인합니다. 기준 앱은 canonical store의 메시지 수로 이 refresh limit을 정하므로 앱 store의 로딩 근거가 됩니다. 모든 메시지 행을 동시에 렌더링했다는 뜻은 아닙니다.

첨부 시간은 XCTest 제어·관찰 비용이 포함된 smoke 기록입니다. 기존 V2 replacement 측정은 production 상태 함수와 테스트 안의 legacy 구현을 비교하는 unit microbenchmark입니다. 전체 앱 속도, v1 문제 해결, FPS, 정확한 렌더 완료 시간, Release 성능, 발열·전력을 입증하지 않습니다. 이 작업은 재현·검증 환경을 만들며 production 성능 수정을 포함하지 않습니다.

## CI 실행과 결과 보관

- `performance-lab` 브랜치 push로 실행합니다. 현재 workflow는 기본 브랜치에 없으므로 Actions 수동 실행은 사용할 수 없습니다.
- 일반 push는 fixture → 실제 Swift 테스트 → UI를 실행합니다. 커밋 메시지의 `[ui-only]`는 이미 통과한 Swift 테스트를 생략합니다.
- 현재 push의 UI loaded 목표는 2,000개입니다. `TEST_RUNNER_OPENCLIENT_LAB_UI_TARGET_LOADED`와 최대 swipe 안에서 목표에 도달하지 못하면 실패합니다.
- 커밋, Xcode/SDK, 시뮬레이터, 명령, 빌드 로그, 읽을 수 있는 XCTest JSON 요약·테스트 목록, JSON·스크린샷 첨부, fixture 요청과 hang 로그를 **3일간** 보관합니다. raw `.xcresult`와 DerivedData는 업로드하지 않습니다.

원본 개발 팀 설정만 비우고 시뮬레이터 서명은 유지합니다. CI에 Apple 계정이나 배포 인증서를 넣지 않습니다. `validation.json`은 실행별 상태, `source_manifest.json`은 기준 소스와 파일 해시를 기록합니다.

## Linux에서 fixture 실행

Python 3.10 이상이며 추가 패키지가 없습니다. `performance-lab` 폴더에서 실행합니다.

```bash
python3 -B -m unittest discover -p 'test_*.py' -v
python3 lab.py serve --port 14097 --log requests.jsonl
```

시작 시 URL·사용자 이름·임시 비밀번호를 표시합니다. 기본 주소는 `127.0.0.1`입니다. 세션 `ses_20`, `ses_200`, `ses_2000`은 각각 20·200·2,000개로 시작하며 요청한 limit만 반환합니다. 기본적으로 user 1개 다음 assistant 7개가 이어지고 도구 출력을 포함합니다.

설치된 iPhone 앱으로 재현할 때는 본인 서버의 Tailscale IPv4 주소를 사용합니다. 아래 주소를 실제 값으로 바꾸고 OpenClient에 표시된 URL·사용자 `opencode`·임시 비밀번호로 연결합니다. 실기기 연결은 아직 검증하지 않았습니다.

```bash
python3 lab.py serve --host 100.101.102.103 --port 14097 --log requests.jsonl
python3 lab.py stream --url http://100.101.102.103:14097 --password 'DISPLAYED_PASSWORD' --session ses_2000 --chunks 300 --interval-ms 100
python3 lab.py summary requests.jsonl
```

`--tool-bytes`, `--text-bytes`, `--assistants-per-turn`, `--latency-ms`, `--detail-latency-ms`로 조건을 바꿉니다. 메시지 수, 출력 크기, grouping, idle/streaming, cold/warm는 한 번에 하나씩 비교하고 캐시 영향을 기록합니다. `stream --part-type reasoning`도 지원합니다. 일반 프롬프트 전송 등 구현하지 않은 endpoint는 404를 반환합니다.

요청 로그는 경로·쿼리·상태·body bytes·서버 처리 시간을 기록하며 인증 헤더와 본문은 저장하지 않습니다. 열린 SSE의 진행량은 인증된 `GET /_lab/status`에서 확인합니다. 서버 시간과 bytes는 앱 화면 완료·FPS 또는 전체 네트워크 비용의 측정값이 아닙니다.

## 소스 근거

- [v1 API와 pagination](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClient/API/OpenCodeAPIClient.swift)
- [loaded canonical store를 이용하는 refresh](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClient/ViewModels/AppViewModel/AppViewModel%2BSessions.swift)
- [기존 grouping 성능 테스트](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClientTests/ChatStoreTests.swift)
- [기존 V2 replacement 테스트](https://github.com/ntoporcov/openclient/blob/6b3054a18e731f342a3b98009c259191f5e67f51/OpenCodeIOSClientTests/V2TranscriptPerformanceTests.swift)

원본 OpenClient 라이선스는 `UPSTREAM_LICENSE`를 참고하십시오.
