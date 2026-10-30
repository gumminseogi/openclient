# 한 세션의 긴 채팅 로딩 재현

2026-10-30. 사용자가 보고한 **약 30초의 채팅 로딩**을 대상으로 합니다. 작은 내부 함수의 처리 시간이나 FPS 개선율을 측정하는 실험이 아닙니다. 현재 결과 수집 전이며, 실행 뒤 실제 초 단위 결과와 실패를 이 문서에 추가합니다.

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
| cold | 앱의 대화 캐시 없음 | 처음 긴 세션을 선택할 때의 정상 초기 요청과 화면 표시 |
| seeded-relaunch | 5,000개 기록을 정상 영속 캐시에 저장한 뒤 앱을 다시 실행 | 디스크 캐시 읽기, 보관된 범위 재조회, 첫 내용 표시와 입력 준비 |
| seeded-revisit | 위 캐시에서 처음 연 뒤 같은 프로세스에서 목록으로 돌아가 같은 세션 선택 | 메모리에 이미 있는 긴 대화의 재진입 |

그룹화 ON/OFF를 나눠 cold·revisit은 각각 한 번, seeded-relaunch는 각각 세 번 실행합니다. 기기당 측정 UI case는 열 개입니다. 도구 기록·추론 표시도 켜 실제로 무거운 내용을 보여 줍니다.

영속 캐시는 **비측정 준비 단계**에서 일반 API의 `limit=5000` 응답을 읽고 production 캐시 저장 API로 만듭니다. SQL을 직접 편집하거나 앱의 실제 조회 limit을 바꾸지 않습니다. 이 준비는 사용자가 UI로 5,000개 기록을 스크롤해 불러오는 시간을 측정한 것이 아닙니다. 캐시가 없는 앱도 첫 진입부터 항상 5,000개를 가져온다고 해석하면 안 됩니다.

## 시간의 의미

앱의 세션 선택, 디스크 읽기, canonical 응답 처리, 실제 transcript reveal gate와 입력 수락 지점을 관찰합니다. 전체 세션 진입, 재진입, 하단 새로고침을 **초 단위**로 구분합니다. 첫 캐시 내용 표시와 전체 canonical 동기화 완료도 분리합니다.

XCTest의 조작·관찰 시간은 앱 안의 monotonic timestamp와 별도로 보존합니다. 접근성 snapshot이나 자동화의 idle 대기까지 앱의 순수 로딩 시간으로 세지 않습니다. HTTP 응답 완료, collection view 존재, 메시지 수만으로 사용 가능한 화면이 됐다고 판정하지 않습니다.

서버의 메시지 수·파트 수·본문 바이트, 실제 앱 요청의 limit·cursor·응답 크기와 probe를 함께 보존합니다. 5,000개가 store에 있다는 것은 5,000개 행을 동시에 화면에 그렸다는 뜻이 아닙니다.

## 실행과 보존

`.github/workflows/openclient-extreme-session.yml`은 이 테스트 브랜치의 push에서 iPhone Pro Max와 13-inch iPad Pro 시뮬레이터를 각각 사용합니다. 시뮬레이터 서명은 유지합니다. 실제 iPhone 15 Pro의 30초 증상과 같은 원인이라는 결론은 별도로 검증해야 합니다.

cold 두 조건을 먼저 실행합니다. 큰 캐시 준비가 실패하면 cold 결과는 보존하고 준비에 의존하는 warm 조건을 실패 사유와 함께 생략합니다. 개별 UI case 실패도 원본 summary·부분 checkpoint·probe·요청 로그·진단을 보존하며 성공으로 바꾸지 않습니다. fixture 본문과 DerivedData 전체를 artifact로 올리지 않습니다.
