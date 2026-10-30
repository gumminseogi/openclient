# 한 세션의 긴 채팅 로딩 재현

2026-10-30. 사용자가 보고한 **약 30초의 채팅 로딩**을 대상으로 합니다. 작은 내부 함수의 처리 시간이나 FPS 개선율을 측정하는 실험이 아닙니다. 현재 코드에 대한 측정이며 제품 최적화 패치는 포함하지 않습니다. **iPhone·iPad, 그룹화 ON/OFF 네 조건 모두 전체 검증을 통과했습니다.**

## 본 측정 결과

실행 [41057678342](https://github.com/gumminseogi/openclient/actions/runs/41057678342), 테스트 SHA `cb1e791d62f13f0792d095ddc321662f065307ec`. 두 기기의 그룹화 ON/OFF 각각 최초 진입·같은 프로세스 재진입·하단 overscroll 새로고침을 모두 통과했습니다. 총 네 UI case·12개 동작입니다. 시작 전 정상 Activity 캐시 적용 5,000개, 디렉터리 세션 1개와 대화 5,000개의 별도 repository readback, 각 동작의 실제 transcript 문구·입력·GET 5,000개·native publication/입력 기록을 검증했습니다. 두 기기 모두 `validation.complete=true`, 오류 0개입니다.

| iPhone simulator, 초 | 그룹화 ON | 그룹화 OFF |
| --- | ---: | ---: |
| 최초 선택 → 화면 공개 callback | 14.465 | 17.308 |
| 재진입 선택 → 화면 공개 callback | 13.182 | 16.288 |
| 하단 새로고침 시작 → 메서드 완료 | **25.930** | **12.733** |

| iPad simulator, 초 | 그룹화 ON | 그룹화 OFF |
| --- | ---: | ---: |
| 최초 선택 → 화면 공개 callback | 22.645 | 29.282 |
| 재진입 선택 → 화면 공개 callback | 20.513 | 26.823 |
| 하단 새로고침 시작 → 메서드 완료 | 23.722 | 19.272 |

각 조건 한 번의 관측입니다. 첫 진입·재진입에서는 OFF가 더 빨랐다는 결과가 아니며, 새로고침 수치만으로 grouping의 일반적인 개선율을 주장하지 않습니다. 새로고침 완료는 spinner 종료 animation보다 앞의 native 메서드 완료이며 화면 공개는 실제 presented frame 보장이 아닌 callback입니다.

실제 대화 영역 안의 마커를 UI가 확인한 것은 첫 tap 후 iPhone ON 29.584초/OFF 28.345초, iPad ON 39.309초/OFF 35.191초였습니다. 이 값에는 터치 전달·XCTest·접근성 관측 비용이 포함되므로 순수 앱 로딩 시간이나 최초 사용 가능 시점으로 치환하지 않습니다. 입력도 실제 native delegate가 토큰을 수락했음을 확인했으나 자동화가 시도한 시각이며 earliest readiness나 키 하나의 지연이 아닙니다. 이 실행에서 입력 수락은 마지막 canonical 반영 뒤에 관측돼 응답 처리 중 키보드 지연을 검증한 결과는 아닙니다. 전체 XCTest(iPhone 323.190초/170.346초, iPad 316.585초/246.243초)도 앱 로딩 시간으로 사용하지 않습니다.

| iPhone 각 조건의 canonical 요청 | 시작 GET 수 | 온전한 응답 본문 수 | 기록된 본문 바이트 |
| --- | ---: | ---: | ---: |
| 최초 진입 | 2 | 2 | 269,219,788 |
| 같은 프로세스 재진입 | 3 | 2 | 269,219,788 |
| 하단 새로고침 | 1 | 1 | 134,609,894 |
| 합계 | 6 | 5 | **673,049,470** |

iPhone 재진입의 한 요청은 본문 0바이트로 기록됐습니다. 이를 134.6MB 다운로드로 세지 않으며, 반대로 실제 wire 사용량이 0이었다고 보장하지도 않습니다. iPad는 각 조건 최초 진입 2건·재진입 2건·새로고침 1건으로 총 다섯 요청을 완료했으며, 온전한 응답 수와 본문 합계는 위 표와 같습니다. 합계는 압축 없는 합성 fixture의 기록된 JSON 본문 크기로, 추가 개별 메시지·헤더·부분 전송을 제외합니다. 실제 사용자 이동통신 사용량 측정은 아닙니다. 앱 프로세스에는 이미 5,000개가 있었고 각 완료 응답도 5,000개였으므로 작은 페이지나 helper 작업을 큰 세션 결과로 잘못 센 경우가 아닙니다.

확실한 코드 개선 후보는 한 진입에서 두 경로가 전체 조회를 각각 시작하는 부분입니다. 진행 중인 초기 조회를 공유하고 같은 진입에서 이미 끝난 조회를 다시 시작하지 않도록 만드는 방향을 우선 검토할 수 있습니다. 중복을 줄였을 때의 화면 로딩 개선율은 별도 패치 전후 실험이 필요합니다.

측정 대상 production 소스는 `ntoporcov/openclient@4dedc814bd38d3daa5a53bff01d75209f2865502`(1.0.28)입니다. 포크의 별도 `extreme-session-lab` 브랜치에서 실행하며 이전 `performance-lab`의 개선 패치와 결과를 섞지 않습니다. 이 브랜치는 production 동작을 수정하지 않고 CI checkout에 관찰용 hook을 삽입합니다.

실행 환경은 Xcode 27.1(build 27A9275), iOS 27.0, Debug build입니다. 기기는 iPhone 18 Pro Max와 iPad Pro 13-inch(M5) 시뮬레이터이며, 사용자의 iPhone 15 Pro 실기기 측정값이 아닙니다.

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

영속 캐시는 **비측정 준비 단계**에서 일반 API의 `limit=5000` 응답과 실제 `/session`의 유일한 세션 목록을 읽고 production 캐시 저장 API로 만듭니다. 새 repository에서 대화 5,000개와 디렉터리 세션 목록을 모두 다시 읽어 검증합니다. SQL을 직접 편집하거나 앱의 실제 조회 limit을 바꾸지 않습니다. 이 준비는 사용자가 UI로 5,000개 기록을 스크롤해 불러오는 시간을 측정한 것이 아닙니다. 캐시가 없는 앱도 첫 진입부터 항상 5,000개를 가져온다고 해석하면 안 됩니다.

각 측정 앱은 정상 Activity 캐시 복원 경로가 실제 canonical store에 5,000개를 적용한 `startup_cache_published`를 기록한 뒤 세션 선택을 시작합니다. 앱 시작·선택 전 캐시 복원(op 0)의 시간도 별도로 보존합니다. 이는 동일한 전체 캐시 상태의 재진입 조건이며 앱 아이콘을 누른 시점부터의 cold launch 측정은 아닙니다.

## 시간의 의미

앱의 세션 선택, 디스크 읽기, canonical 응답 처리, 실제 transcript reveal gate와 입력 수락 지점을 관찰합니다. 전체 세션 진입, 재진입, 하단 새로고침을 **초 단위**로 구분합니다. 첫 캐시 내용 표시와 전체 canonical 동기화 완료도 분리합니다.

XCTest의 조작·관찰 시간은 앱 안의 monotonic timestamp와 별도로 보존합니다. 접근성 snapshot이나 자동화의 idle 대기까지 앱의 순수 로딩 시간으로 세지 않습니다. HTTP 응답 완료, collection view 존재, 메시지 수만으로 사용 가능한 화면이 됐다고 판정하지 않습니다.

입력 수락 시각은 자동화가 입력을 시도했을 때 앱 delegate가 토큰을 확인한 시각입니다. 최초 입력 가능 시점이나 키 하나의 지연을 뜻하지 않습니다. reveal 완료는 기존 opacity animation의 callback이며 실제 디스플레이에 표시된 프레임을 검증한 값은 아닙니다. 하단 refresh method 완료도 spinner 종료 animation의 완료와는 구분합니다.

canonical 요청 시작부터 typed page 반환까지에는 전송·decode·호출자 actor 복귀 대기가 함께 들어갑니다. 디스크 읽기 시작부터 JSON decode 완료까지도 DB 조회와 큰 Data 읽기를 포함합니다. 이 구간을 각각 순수 네트워크 또는 순수 JSON decode 비용으로 해석하지 않습니다. 선택 전 startup/prefetch(op 0)의 비용은 별도로 유지하고, 겹치는 요청은 임의로 한 구간으로 합치지 않습니다.

서버의 메시지 수·파트 수·본문 바이트, 실제 앱 요청의 limit·cursor·응답 크기와 probe를 함께 보존합니다. 5,000개가 store에 있다는 것은 5,000개 행을 동시에 화면에 그렸다는 뜻이 아닙니다.

## 실행과 보존

`.github/workflows/openclient-extreme-session.yml`은 이 테스트 브랜치의 push에서 iPhone Pro Max와 13-inch iPad Pro 시뮬레이터를 각각 사용합니다. 시뮬레이터 서명은 유지합니다. 실제 iPhone 15 Pro의 30초 증상과 같은 원인이라는 결론은 별도로 검증해야 합니다.

비측정 캐시 준비와 두 번째 production repository의 디스크 readback 검증을 먼저 수행합니다. 준비가 실패하면 의존하는 두 UI 조건을 사유와 함께 생략합니다. Native startup 5,000개 조건과 각 동작의 전체 GET·반영·입력이 일치해야 완전한 case입니다. 개별 UI case 실패도 원본 summary·부분 checkpoint·probe·요청 로그·진단·영상과 최종 화면을 보존하며 성공으로 바꾸지 않습니다. fixture 본문과 DerivedData 전체를 artifact로 올리지 않습니다.

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

## 전체 캐시의 첫 진입 부분 관측

실행 `41048101562`, 테스트 SHA `edc5d8f57fecc3cd72486956f5214856d33cbac4`에서 두 기기 모두 production 캐시의 5,000개 저장과 별도 repository readback을 통과했습니다. 그룹화 ON의 최초 열기에서 전역 마커 검사는 통과했으나 이후 테스트가 `chat.scroll` 식별자를 찾는 과정에서 실패했습니다. 최신 DEBUG navigation 식별자 `navigation.chat.ses_extreme`가 덮어쓰는 상황을 양쪽 실패 snapshot과 `RootView` 코드로 확인했습니다. 전역 마커는 sidebar 세션 미리보기에서도 일치하므로 대화 본문 표시 증거로 사용하지 않습니다. 아래는 native callback 기록이며 입력·재진입·하단 새로고침 통과 결과는 아닙니다.

| Native 구간, 초 | iPhone simulator | iPad simulator |
| --- | ---: | ---: |
| 선택 → reveal 완료 callback | 15.315 | 27.233 |
| 선택 → 첫 canonical 5,000개 반영 | 20.142 | 11.967 |
| 선택 → 두 번째 canonical 5,000개 반영 | 25.188 | 34.924 |
| 선택 전 전체 캐시 읽기 | 3.137 | 3.570 |
| 선택 후 전체 캐시 읽기 | 2.288 | 1.784 |

각 기기에서 133,777,002바이트의 캐시 JSON 5,000개 decode가 두 번 기록됐습니다. iPad의 후속 snapshot 반환값은 0이지만 실제 decode는 5,000개이므로 cache miss나 기록 손실로 해석하지 않습니다. 동시에 도착한 canonical 결과에 대한 취소·stale guard 등으로 snapshot이 폐기됐을 가능성을 남깁니다.

두 기기 모두 `limit=5000` canonical GET을 두 번 완료했습니다. **각 응답 본문 134,609,894바이트, 합계 269,219,788바이트**이며 추가 개별 메시지 조회는 이 합계에 포함하지 않습니다. fixture는 압축을 사용하지 않으며 이 합계는 합성 자료의 HTTP 응답 본문 크기입니다. 실제 사용자 세션의 이동통신 사용량을 측정한 값은 아닙니다. iPhone에서는 두 요청이 겹쳐 native return을 개별 HTTP 요청과 임의로 짝짓지 않습니다.

소스에서도 독립적인 두 경로가 확인됩니다. `SessionListFacade.completeSelection → AppViewModel.selectSession`은 `loadMessages`를 시작하고, `ChatView.task → ChatFacade.hydrateSessionForPresentation`도 `loadMessages`를 호출합니다. optional agent activity의 `children` 요청 실패는 별도 `try?`에서 소거되며 두 번째 전체 조회가 먼저 시작됐으므로 관측된 중복 요청의 원인으로 보지 않습니다. 이 fixture의 optional children API는 404를 반환하므로 해당 활동 상태 갱신의 비용까지 정상 서버와 같다고 주장하지 않습니다.

캐시 준비 XCTest 전체 시간이나 준비용 HTTP await는 위의 채팅 로딩 수치와 별개입니다. 각 환경의 host·작업 스케줄링이 달라 iPhone/iPad 숫자를 기기 성능 순위로 비교하지 않습니다. 본 측정에서는 CI checkout의 DEBUG 부모 태그만 제거하고 원래 transcript/composer 식별자를 사용하며, HTTP native 단계·대화 영역 안의 실제 문구·실제 입력 값·native 입력 JSONL을 함께 확인합니다.

후속 실행 `41051357147`도 입력 시도 전에 composer 선택자에서 실패했습니다. iPad ON은 실제 canonical 20개, OFF는 5,000개였고 iPhone은 둘 다 20개였습니다. 저장된 chat payload만으로는 초기 Activity 캐시 후보를 보장하지 못했으므로 이 수치는 그룹화 성능 비교에서 제외합니다. 이를 보완해 실제 디렉터리 세션 메타데이터도 seed하고, 정상 startup 적용 5,000개를 명시적으로 확인합니다. CI checkout에서는 Release에 없는 DEBUG 부모 접근성 태그 한 줄만 제거해 원래 transcript/composer ID를 유지하고, 마커를 실제 transcript 안으로 제한합니다. 별도 custom accessibility value 변경은 하지 않습니다. 종료 전에는 성공/실패 모두 화면·접근성 트리·native 상태를 보존합니다.
