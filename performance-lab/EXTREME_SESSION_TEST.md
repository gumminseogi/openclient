# 한 세션의 긴 채팅 로딩 재현

2026-10-30. 사용자가 보고한 **약 30초의 채팅 로딩**을 대상으로 합니다. 작은 내부 함수의 처리 시간이나 FPS 개선율을 측정하는 실험이 아닙니다. 아래 예비 실행은 자동화 검증에 실패했으며, 5,000개 전체 캐시 조건의 최종 결과는 아직 없습니다.

측정 대상 production 소스는 `ntoporcov/openclient@4dedc814bd38d3daa5a53bff01d75209f2865502`(1.0.28)입니다. 포크의 별도 `extreme-session-lab` 브랜치에서 실행하며 이전 `performance-lab`의 개선 패치와 결과를 섞지 않습니다. 이 브랜치는 production 동작을 수정하지 않고 CI checkout에 관찰용 hook을 삽입합니다.

## 합성 세션

`lab.py serve --profile extreme --extreme-messages 5000`은 **`ses_extreme` 하나만** 만듭니다. 실제 모델이나 도구를 실행한 대화가 아니라, 서버의 정상 메시지·도구 기록 형식으로 생성한 합성 기록입니다.

| 항목 | 크기 |
| --- | ---: |
| 메시지 | 5,000 |
| 파트 | 18,125 |
| 도구 기록 | 8,750 / 13종 |
| 추론 파트 | 4,375 |
| 전체 canonical JSON | 134,609,894바이트 / 약 128.4MiB |

`bash`, `read`, `grep`, `glob`, `list`, `write`, `edit`, `apply_patch`, `task`, `todowrite`, `webfetch`, `websearch`, `openclient_execute_tool` 기록에 긴 추론·Markdown·코드·표·정적 HTML 미리보기를 섞습니다. HTTP 지연을 인위적으로 추가하지 않습니다. HTML은 외부 리소스를 사용하지 않고 웹 참조도 loopback의 작은 정적 문서만 사용합니다. `limit`와 `before`는 실제 요청대로 적용합니다.

## 구분할 로딩 상태

| 경우 | 준비 상태 | 확인하려는 동작 |
| --- | --- | --- |
| 예비 cold | 앱의 대화 캐시 없음 | 정상 초기 20개 요청과 화면 표시. 전체 캐시 실험과 별개 |
| seeded-revisit 최초 열기 | 5,000개 기록을 정상 영속 캐시에 저장한 뒤 앱을 다시 실행 | 디스크 캐시 읽기, 보관된 범위 재조회, 첫 내용 표시와 입력 준비 |
| seeded-revisit 재진입 | 위 캐시에서 처음 연 뒤 같은 프로세스에서 목록으로 돌아가 같은 세션 선택 | 메모리에 이미 있는 긴 대화의 재진입 |

본 실행은 그룹화 ON/OFF 두 UI case로 전체 캐시 조건에 집중합니다. 각 case에서 최초 열기·같은 프로세스의 재진입·하단 새로고침을 실행합니다. 도구 기록·추론 표시도 켭니다. 각 조건은 한 번이므로 중앙값이나 안정된 개선율을 주장하지 않습니다.

영속 캐시는 **비측정 준비 단계**에서 일반 API의 `limit=5000` 응답을 읽고 production 캐시 저장 API로 만듭니다. SQL을 직접 편집하거나 앱의 실제 조회 limit을 바꾸지 않습니다. 이 준비는 사용자가 UI로 5,000개 기록을 스크롤해 불러오는 시간을 측정한 것이 아닙니다. 캐시가 없는 앱도 첫 진입부터 항상 5,000개를 가져온다고 해석하면 안 됩니다.

## 시간의 의미

앱의 세션 선택, 디스크 읽기, canonical 응답 처리, 실제 transcript reveal gate와 입력 수락 지점을 관찰합니다. 전체 세션 진입, 재진입, 하단 새로고침을 **초 단위**로 구분합니다. 첫 캐시 내용 표시와 전체 canonical 동기화 완료도 분리합니다.

XCTest의 조작·관찰 시간은 앱 안의 monotonic timestamp와 별도로 보존합니다. 접근성 snapshot이나 자동화의 idle 대기까지 앱의 순수 로딩 시간으로 세지 않습니다. HTTP 응답 완료, collection view 존재, 메시지 수만으로 사용 가능한 화면이 됐다고 판정하지 않습니다.

입력 수락 시각은 자동화가 입력을 시도했을 때 앱 delegate가 토큰을 확인한 시각입니다. 최초 입력 가능 시점이나 키 하나의 지연을 뜻하지 않습니다. reveal 완료는 기존 opacity animation의 callback이며 실제 디스플레이에 표시된 프레임을 검증한 값은 아닙니다. 하단 refresh method 완료도 spinner 종료 animation의 완료와는 구분합니다.

canonical 요청 시작부터 typed page 반환까지에는 전송·decode·호출자 actor 복귀 대기가 함께 들어갑니다. 디스크 읽기 시작부터 JSON decode 완료까지도 DB 조회와 큰 Data 읽기를 포함합니다. 이 구간을 각각 순수 네트워크 또는 순수 JSON decode 비용으로 해석하지 않습니다. 선택 전 startup/prefetch(op 0)의 비용은 별도로 유지하고, 겹치는 요청은 임의로 한 구간으로 합치지 않습니다.

서버의 메시지 수·파트 수·본문 바이트, 실제 앱 요청의 limit·cursor·응답 크기와 probe를 함께 보존합니다. 5,000개가 store에 있다는 것은 5,000개 행을 동시에 화면에 그렸다는 뜻이 아닙니다.

## 실행과 보존

`.github/workflows/openclient-extreme-session.yml`은 이 테스트 브랜치의 push에서 iPhone Pro Max와 13-inch iPad Pro 시뮬레이터를 각각 사용합니다. 시뮬레이터 서명은 유지합니다. 실제 iPhone 15 Pro의 30초 증상과 같은 원인이라는 결론은 별도로 검증해야 합니다.

비측정 캐시 준비와 두 번째 production repository의 디스크 readback 검증을 먼저 수행합니다. 준비가 실패하면 의존하는 두 UI 조건을 사유와 함께 생략합니다. 개별 UI case 실패도 원본 summary·부분 checkpoint·probe·요청 로그·진단·실패 영상과 화면을 보존하며 성공으로 바꾸지 않습니다. fixture 본문과 DerivedData 전체를 artifact로 올리지 않습니다.

## 예비 실행 — 전체 캐시 로딩 결과가 아님

실행 `41043314385`, 테스트 SHA `81e435b5f3088b1d43912a372dc85c66a052f09c`는 첫 cold 조건의 검증 실패 후 반복을 중단했습니다. 두 기기의 native build는 성공했습니다.

| iPad cold, 그룹화 ON | native 초 |
| --- | ---: |
| 선택 → 첫 canonical 반영, 최근 20개 | 4.821 |
| 선택 → reveal 시작 | 35.167 |
| 선택 → reveal 완료 callback | 35.749 |
| 첫 canonical 반영 → reveal 완료 | 30.929 |
| 선택 → 두 번째 canonical 반영, 최근 20개 | 39.999 |

최근 20개 응답은 각각 549,096바이트였고 두 서버 handler는 0.009·0.013초였습니다. 캐시는 miss였습니다. 9.831초·19.990초의 main queue heartbeat 지연도 관측됐지만 특정 blocking 함수나 렌더링 비용으로 원인을 분해할 stack은 없습니다. 반복 접근성 조회가 이 시각에 영향을 주었을 가능성도 배제하지 않습니다.

UI는 reveal 이후에도 마지막 응답 마커를 찾지 못했습니다. 따라서 **241.129초의 XCTest 실패 시간은 앱 로딩 시간이 아니며**, 화면 표시·입력까지 성공한 case도 아닙니다. iPhone은 연결 준비 단계에서 끝나 selection marker가 없으므로 **293.948초 역시 채팅 로딩 결과가 아닙니다**. 이 실행에서 5,000개 캐시 복원이나 하단 새로고침을 측정하지 못했습니다. 실패 영상은 당시 upload glob에서 누락됐고 probe·요청·summary는 보존했습니다.

본 실행에서는 작은 native phase event를 루프백 fixture에 비동기로 보내고, UI는 native 연결·reveal 완료를 HTTP로 기다린 다음 실제 문구와 입력을 검사합니다. 반복적으로 긴 접근성 트리를 조회하는 간섭을 줄이기 위한 계측 변경이며 앱의 연결·조회·화면 공개 조건을 우회하지 않습니다. 예비 실행과 이 방법 변경의 숫자를 제품 성능 개선율로 비교하지 않습니다.
