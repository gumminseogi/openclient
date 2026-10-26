# 긴 채팅 응답성 비교

2026-10-26. **중복 정렬을 없앤 helper 처리 시간은 줄었지만, 시뮬레이터 ChatView의 입력·스크롤 지연 지표는 일관되게 개선되지 않았습니다.**

[마지막 실행](https://github.com/gumminseogi/openclient/actions/runs/40269284935)의 측정 소스는 `bc3349bcd322ee910720969afcc6c4f912ddd09a`입니다. iPhone job은 성공했고 iPad job은 아래의 UI 초기화 실패 두 건으로 실패했습니다. 전체 workflow가 통과한 결과로 표시하지 않습니다. 수정 코드는 포크의 `performance-lab` 브랜치에 있습니다.

## 검사 결과

| 기기 | 관련 Swift 검사 | 측정 UI case | 분석 범위 |
| --- | --- | --- | --- |
| iPhone | 3 통과 / 0 실패 | 12 통과 / 0 실패 | 12개 전체 case, text/reasoning 각각 ON/OFF 3쌍 |
| iPad | 3 통과 / 0 실패 | 10 통과 / 2 실패 | 전체 10개 + text 부분 결과 2개. reasoning ON은 1쌍뿐 |

기기마다 비측정 paging 준비 검사 한 번은 별도로 통과했습니다. 위 Swift 검사 3개는 관련 회귀 검사 두 개와 helper microbenchmark이며, 일반 workflow의 전체 검사 53개를 이번 실행에서 다시 돌렸다는 뜻은 아닙니다. Python fixture·분석기 검사 17개도 통과했습니다.

iPad의 `pair1-candidate-g1`, `pair2-candidate-g1`은 text 측정을 끝낸 후 **reasoning 시작 전 idle 상태에서 이전 초안을 전체 선택·삭제하는 assertion**에 실패했습니다. 그 뒤 reasoning 측정은 없으며 text checkpoint는 유효합니다. 이 기록만으로 앱의 일반 타이핑 유실이나 성능 회귀를 확정하지 않습니다.

## helper 처리 시간

| 기기 | 기존 경로(ms/update) | 수정 경로(ms/update) |
| --- | ---: | ---: |
| iPhone | 31.433 | 2.509 |
| iPad | 33.789 | 2.556 |

2,000개 메시지·1,800개 tool part, canonical envelope JSON 12,680,601바이트에서 순서를 교대하는 7개 trial × 12회 changed-tail 업데이트를 측정한 중앙값입니다. **Debug helper 측정이며 UI 렌더링, grouping, reducer 적용, 네트워크, 키 입력 처리 시간은 제외합니다. 앱 전체가 같은 비율로 빨라졌다는 수치가 아닙니다.**

## 응답 중 콜백 지연

아래는 실제 서버 run 전체 구간입니다. 각 variant의 값은 trial별 통계의 중앙값이며, Δ는 **같은 pair의 candidate − baseline을 먼저 계산한 뒤 구한 중앙값**입니다. 두 variant 중앙값을 뺀 값과 다를 수 있습니다. 음수 Δ가 작은 지연입니다. `개선 방향`은 gap budget이 줄어든 pair 수입니다. 기기별 결과를 합치지 않습니다.

gap budget은 callback interval의 처음 25ms를 제외하고 phase와 겹친 시간만 합친 ms/s입니다. FPS나 CPU 점유율이 아닙니다. 누락된 case가 있을 때 원본 JSON의 `medians`를 그대로 비교하지 않고, 이 표는 **`paired=true`인 동일 trial만** 사용합니다.

| 기기 | 응답 / 그룹화 | 쌍 | gap budget 기존→수정(ms/s) | paired Δ(ms/s) | callback p95 paired Δ(ms) | 개선 방향 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| iPhone | text / ON | 3 | 795.220 → 832.867 | +3.181 | -4.659 | 1/3 |
| iPhone | text / OFF | 3 | 704.612 → 704.283 | -21.964 | -19.627 | 2/3 |
| iPhone | reasoning / ON | 3 | 771.171 → 761.460 | +21.541 | +33.931 | 1/3 |
| iPhone | reasoning / OFF | 3 | 652.487 → 700.942 | -29.873 | -50.174 | 2/3 |
| iPad | text / ON | 3 | 820.770 → 766.217 | -47.796 | -84.107 | 2/3 |
| iPad | text / OFF | 3 | 649.527 → 619.825 | -37.363 | -17.594 | 3/3 |
| iPad | reasoning / ON | 1 | 판정 제외 | — | — | — |
| iPad | reasoning / OFF | 3 | 809.316 → 689.849 | -72.509 | -127.207 | 3/3 |

iPhone에서는 같은 조건의 세 pair 모두 좋아진 whole-stream 조건이 없었습니다. iPad의 grouping OFF에서는 text·reasoning의 gap budget이 세 pair 모두 줄었지만, ON의 text는 2/3 개선이고 reasoning은 자료가 부족합니다. 일부 지표의 개선을 전체 앱의 개선율로 환산하지 않습니다.

## 입력·스크롤 구간

아래 heartbeat p95는 **main queue에 보낸 작업의 실행 지연**입니다. 정확한 키 입력 latency가 아닙니다. phase 경계를 넘는 interval의 전체 길이도 분포에 포함하므로 인접 작업의 지연이 섞일 수 있습니다.

| 기기 | text 구간 / 그룹화 | 기존→수정 trial median(ms) | paired Δ(ms) | 감소한 pair |
| --- | --- | ---: | ---: | ---: |
| iPhone | typing / ON | 391.910 → 281.624 | -110.286 | 2/3 |
| iPhone | typing / OFF | 398.956 → 356.351 | -116.825 | 2/3 |
| iPhone | scrolling / ON | 324.759 → 246.280 | -124.675 | 2/3 |
| iPhone | scrolling / OFF | 228.200 → 158.732 | -111.630 | 3/3 |
| iPad | typing / ON | 401.789 → 358.118 | -37.804 | 2/3 |
| iPad | typing / OFF | 230.162 → 229.641 | +28.785 | 1/3 |
| iPad | scrolling / ON | 377.437 → 347.853 | -11.526 | 2/3 |
| iPad | scrolling / OFF | 205.375 → 150.509 | -54.867 | 3/3 |

전체 응답 구간의 개선이 모든 입력·스크롤 구간의 개선을 뜻하지 않습니다. iPad text OFF의 typing heartbeat paired Δ는 +28.785ms로 일관된 키보드 개선을 뒷받침하지 않습니다. 실제 iPhone 15 Pro의 체감·발열·배터리·Release 성능은 측정하지 않았습니다.

## 실제 입력 부하

설정은 응답 종류마다 600 chunks × 간격 100ms × 16바이트입니다. nominal 60초로 해석하지 않고 아래의 실제 run 시간을 사용했습니다. rate 변화는 **설정한 600을 실제 run 시간으로 나눈 값**의 paired 변화이며 클라이언트 수신률 직접 측정이 아닙니다.

| 기기 | 응답 / 그룹화 | 쌍 | 실제 run 시간 기존→수정 중앙값(s) | paired rate 변화 중앙값 |
| --- | --- | ---: | ---: | ---: |
| iPhone | text / ON | 3 | 129.947 → 130.205 | +0.080% |
| iPhone | text / OFF | 3 | 127.836 → 129.353 | -0.101% |
| iPhone | reasoning / ON | 3 | 133.480 → 129.389 | +1.851% |
| iPhone | reasoning / OFF | 3 | 128.677 → 133.048 | -2.971% |
| iPad | text / ON | 3 | 127.791 → 126.602 | +0.974% |
| iPad | text / OFF | 3 | 125.875 → 125.219 | -0.301% |
| iPad | reasoning / ON | 1 | 126.784 → 131.267 | -3.415% |
| iPad | reasoning / OFF | 3 | 126.630 → 123.229 | +2.760% |

입력 rate·호스트 스케줄링·Accessibility 조작 비용이 같다고 가정하지 않습니다. 이 작은 반복 실험만으로 UI 지연 변화 전부를 코드 수정의 인과 효과로 단정하지 않습니다. 이 평균값은 전체 실행에서 약 4.26~4.95 chunks/s였으며, 명목 간격보다 느려진 원인은 규명하지 못했습니다. `done=true`, accepted/completed message ID와 run 시각, abort 요청이 없다는 점은 확인했습니다. 개별 delta 직접 counter나 최종 part 9,600바이트 본문·표시 완료의 직접 증거는 artifact에 없습니다.

## 남은 코드 비용

새 경로도 전체 envelope 투영과 배열 비교를 수행합니다. grouping ON에서는 화면에 표시할 창을 고르기 전에 전체 loaded 대화를 처리하고, transcript 발행에 따른 SwiftUI 갱신도 남습니다. 이번 수정은 발행 횟수를 줄이거나 전체 기록의 canonical HTTP 조회를 제거한 수정이 아닙니다. 이 비용들이 원래 증상의 기여 원인인지 분리하려면 별도의 프로파일이 필요합니다.

## 비교하는 코드

선택된 v1 세션의 reducer state를 화면용 canonical 메시지로 발행하는 경로를 비교합니다.

| 경로 | 동작 |
| --- | --- |
| baseline | `messageEnvelopes`로 투영 → 현재 메시지와 비교 → `replaceActiveMessagesWithCanonical`에서 중복 제거·정렬 등 normalization → 발행 |
| candidate | `replaceActiveMessagesFromSyncState`에서 이미 canonical인 reducer state를 투영 → 현재 메시지와 비교 → 직접 발행 |

HTTP·cache에서 들어오는 메시지의 normalization 경로는 유지합니다. 기존 idle 중복 조회 수정도 양쪽에 포함됩니다. 이 실험의 baseline reference는 `1cbcf2a6da9b579e7fc35038b5a8218de63ca010`입니다.

**최종 UI 실험은 서로 다른 커밋을 각각 빌드하는 방식이 아닙니다.** candidate 앱을 한 번 빌드한 뒤 CI에서만 삽입하는 `OpenClientLabPerformanceProbe.baselinePublication` 분기로 기존 publication 호출 경로를 재현합니다. baseline과 candidate label은 같은 바이너리·계측·UI 테스트를 사용합니다. probe metadata의 `publication_path`가 각각 `legacy_normalized`, `reduced_direct`인지 분석기가 확인합니다. 이 runtime 분기와 probe는 CI checkout에서만 주입하며 production 소스에 설정으로 추가하지 않습니다.

## 실험 조건

기기별로 하나의 macOS runner와 명시적인 simulator UDID를 사용합니다. iPhone 18 Pro Max와 iPad Pro 13-inch (M5)는 각각 별도 job이며, 서로 다른 기기의 수치를 합쳐 하나의 개선율로 만들지 않습니다. Debug 빌드와 정상 simulator 서명을 사용합니다. 실제 iPhone 15 Pro나 App Store 배포 앱을 측정하는 실험은 아닙니다.

앱이 실제 스크롤로 과거 기록을 읽는 초기 warmup을 한 번 수행합니다. 이후 앱을 종료하고 `Library/Application Support`의 앱 전용 캐시를 snapshot으로 보관합니다. 각 측정 case에서 같은 snapshot을 복원하고 합성 fixture를 새로 시작합니다. 캐시를 복원한 뒤에도 앱의 `before` 없는 canonical refresh 요청과 `limit >= 2000`을 확인해야 측정에 들어갑니다. 현재 앱이 loaded canonical store 크기로 limit을 정하므로 2,000개가 실제 store에 들어왔다는 근거가 됩니다. 모든 행을 동시에 화면에 렌더링한다는 뜻은 아닙니다.

| 항목 | 최종 실행의 설정 |
| --- | --- |
| case 수 | 기기당 12개: baseline/candidate × grouping ON/OFF × 3개 pair |
| variant 순서 | baseline → candidate → candidate → baseline → baseline → candidate (`ABBAAB`) |
| grouping 순서 | pair 1·3은 ON → OFF, pair 2는 OFF → ON |
| backend | 로컬 Python 합성 OpenCode v1 fixture. 실제 모델·개인 대화 없음 |
| 측정 전 준비 | case마다 짧은 비측정 text stream, native idle·transcript HTTP quiet 확인 |
| 측정 stream | `text`와 `reasoning` 각각 600 chunks, 요청 간격 100ms, chunk당 16바이트 |
| 사용자 동작 | steady 4초, 일반 초안 입력, 키보드 닫기, 왕복 스크롤 1회(2개 drag) |
| 완료 뒤 관찰 | UI가 fixture 완료를 확인한 뒤 8초. 실제 fixture 종료 시각 기준 8초도 별도 산출 |

600 × 100ms는 **요청한 nominal stream 길이**입니다. 머신 스케줄링에 따라 실제 길이가 달라질 수 있으므로 60초로 가정하지 않습니다. fixture가 기록한 `started_epoch_s`·`ended_epoch_s`와 accepted/completed message ID를 사용합니다. 분석기는 steady·typing·scrolling 구간 전체가 실제 stream 시간 안에 있었는지도 확인합니다.

초안은 각 stream을 시작하기 전에 **idle 상태에서** 전체 선택·삭제하고 키보드를 닫아 정리합니다. 측정하는 live typing 구간에는 일반 문자열 입력만 수행합니다.

## 기록하는 지표

| 지표 | 의미 |
| --- | --- |
| callback gap | 60Hz를 요청한 `CADisplayLink` callback의 실제 진입 시각 간격 |
| main-queue heartbeat delay | 별도 thread에서 main queue에 작업을 보낸 뒤 실행될 때까지의 시간. 한 번에 한 작업만 outstanding이며 완료 후 50ms를 기다림 |
| 분포·긴 지연 빈도 | callback gap의 p50·p95·최대, 50/100/250ms 초과 횟수/초, heartbeat의 p95·최대·100ms 초과 횟수/초 |
| callback gap의 25ms 초과 부분 | 각 gap의 처음 25ms를 제외한 나머지를 해당 phase에 잘라 합산한 시간/초. 이 실험의 집계 규칙이며 Core Animation의 hitch 지표가 아님 |

phase 경계를 가로지르는 긴 interval도 버리지 않습니다. 겹치는 interval의 전체 길이 분포와 경계 기록을 남기고, 시간 합계는 phase와 겹치는 부분만 반영합니다. callback 기록이 phase 전체를 덮지 못하거나 앱이 inactive인 구간은 거부합니다. 서로 인접한 phase의 분포에는 같은 경계 interval이 포함될 수 있으므로 단순 합산하지 않습니다.

앱 probe와 UI runner가 함께 기록하는 epoch/uptime clock offset도 대조합니다. 계측은 양쪽 경로에서 동일하며, main thread는 작은 숫자 record를 writer queue에 넘깁니다. 파일 쓰기는 별도 serial queue에서 묶어 수행합니다. 기존 main-thread watchdog은 이 실험에서 끕니다.

각 기기·grouping·phase마다 trial 원본 수치와 pair별 차이, 3개 trial의 중앙값을 보존합니다. **callback gap은 실제 화면에 표시된 FPS가 아니며 heartbeat는 실제 키 입력 latency가 아닙니다.** 이 지표만으로 CPU 연산, OS 스케줄링, Accessibility snapshot 정지의 기여도를 분리할 수 없습니다. 실제 폰의 체감 개선율·발열·배터리 변화로 환산하지 않습니다.

## 실패와 부분 결과

text를 완료하면 그 단계의 evidence를 바로 첨부하고, reasoning을 완료한 뒤 누적 evidence를 다시 첨부합니다. 두 번째 stream에서 실패해도 첫 번째의 정확한 phase와 stream 시각을 보존하기 위한 것입니다. 분석기는 가장 마지막으로 완료된 checkpoint를 선택하며 부분 결과를 별도 표시합니다.

개별 UI case가 실패해도 남은 case를 시도하고 exit code를 보관합니다. **실패를 성공으로 바꾸지 않습니다.** UI case가 하나라도 실패하거나 최종 분석이 유효한 비교를 만들지 못하면 job은 실패합니다. 초기 warmup·fixture·cache 준비 실패는 즉시 중단합니다.

[구 harness 실행 40264817475](https://github.com/gumminseogi/openclient/actions/runs/40264817475)에서는 live typing 중 `Cmd+A`로 이전 초안을 대체한다고 가정했고, 기존 초안 뒤에 새 초안이 붙어 assertion이 실패한 case가 있었습니다. 이 기록은 **전체 선택·초안 대체를 가정한 구 테스트의 실패**로 보존합니다. 일반 입력 문자가 사라졌다는 증거나 현재 수정의 성능 결과로 해석하지 않습니다. 최종 실행은 idle 상태에서 초안을 정리하도록 변경했으므로 구 harness의 수치와 합치지 않습니다.


## 이전 실행 보존

이전 실행과 마지막 실행의 수치를 한 표본으로 합치지 않았습니다.

| 실행 | 보존할 상태 |
| --- | --- |
| 40258923135 | iPad helper·관련 검사 통과 후 shallow checkout의 baseline commit 조회 실패. UI 비교에 도달하지 않음 |
| 40260216691 | build·관련 검사·paging 이후 UI 실패. iPad reasoning 준비 guard 실패, iPhone은 측정 전 시작 단계 crash. crash 원인을 확정하지 못함 |
| 40264817475 | live Cmd+A 초안 대체 가정이 실패한 구 harness. iPad 6/12, iPhone 5/12 측정 case 통과. 부분 text 자료는 탐색용으로 별도 보존 |
| 40269284935 | 이 문서의 마지막 실행. iPhone 12/12, iPad 10/12. iPad 누락 reasoning 두 건은 제외 |

원본 artifact에는 읽을 수 있는 XCTest summary·첨부, 요청 로그, probe와 소스 revision을 보존합니다. 표의 통계는 원본 `responsiveness-summary.json`의 paired trial 값에서 다시 계산했습니다. 원본 JSON의 경로는 CI 머신 경로이며 내려받은 위치로 재분석하면 경로 문자열만 달라집니다.
