#!/usr/bin/env bash
# One real app build; normal simulator signing; synthetic history on loopback only.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: run-window-session.sh <simulator destination> <results directory>' >&2; exit 2; }
destination=$1
results=$2
device_id=${destination##*id=}
bundle=com.ntoporcov.openclient
messages=${OPENCLIENT_EXTREME_MESSAGES:-20000}
[[ "$messages" =~ ^[0-9]+$ ]] && (( messages >= 64 && messages <= 50000 )) || { echo 'Window fixture count must be 64...50000' >&2; exit 2; }
variant=${OPENCLIENT_EXTREME_VARIANT:-baseline}
[[ "$variant" == baseline || "$variant" == patched ]] || exit 2
export OPENCLIENT_WINDOW_VARIANT=$variant
input_policy=loading-only
paired_baseline_sha=e35444a66c150cc8dbb887de9b2c0f3d23cb4837
initial_canonical_reads=1
groupings=0
grouped_cases=(0)
expected_cases=1
verify_telemetry_retry=${OPENCLIENT_EXTREME_VERIFY_TELEMETRY_RETRY:-1}
reuse_build=${OPENCLIENT_WINDOW_REUSE_BUILD:-0}
canary=${OPENCLIENT_WINDOW_CANARY:-0}
[[ "$reuse_build" =~ ^[01]$ && "$canary" =~ ^[01]$ && "$verify_telemetry_retry" =~ ^[01]$ ]] || exit 2
build_root="$RUNNER_TEMP/openclient-window-build-$variant"
cache_snapshot="$build_root/cache-snapshot"
mkdir -p "$results" "$build_root"
fixture_pid=''
case_failures=0
cleanup_fixture() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null || true
    wait "$fixture_pid" 2>/dev/null || true
    fixture_pid=''
  fi
}
trap cleanup_fixture EXIT

terminate_owned_app() {
  local output=$1
  if xcrun simctl terminate "$device_id" "$bundle" > "$output/app-terminate.log" 2>&1; then return 0; fi
  # Before the first hosted launch there may be no running/installed app. Other termination
  # failures must stop cache replacement rather than copying a live SQLite store.
  if python3 - "$output/app-terminate.log" <<'PY'
from pathlib import Path
import re,sys
text=Path(sys.argv[1]).read_text()
already_stopped = any(message in text.lower() for message in ('not running','no such process'))
already_stopped |= bool(re.search(r'\bdomain=NSPOSIXErrorDomain,\s*code=3\b',text)) \
    and 'found nothing to terminate' in text.lower()
if not already_stopped:
    raise SystemExit('Could not stop the owned app safely: '+text)
PY
  then return 0; fi
  return 1
}

if xcrun simctl get_app_container "$device_id" "$bundle" data >/dev/null 2>&1; then
  terminate_owned_app "$results"
  xcrun simctl uninstall "$device_id" "$bundle"
fi

python3 - "$results/provenance.json" "$messages" "$variant" "$paired_baseline_sha" "$reuse_build" "$canary" <<'PYTHON'
import json,os,platform,subprocess,sys,time
from pathlib import Path
sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
value={'schema':1,'test_checkout_sha':sha,'harness_checkout_sha':os.environ.get('OPENCLIENT_EXTREME_HARNESS_SHA',sha),
 'paired_baseline_sha':sys.argv[4], 'variant':sys.argv[3], 'groupings':[False],
 'configured_message_count':int(sys.argv[2]), 'input_validation_policy':'loading-only','input_validation_performed':False,
 'started_epoch_s':time.time(),'host':platform.platform(),'reused_build':sys.argv[5]=='1','canary':sys.argv[6]=='1',
 'order_label':os.environ.get('OPENCLIENT_WINDOW_ORDER_LABEL',''),
 'history':'Single synthetic mixed-tool legacy1.x cursorless session; no artificial delay or model calls.',
 'cache_setup':'Unmeasured native production full-cache write and second-repository readback; patched additionally verifies bounded preview. Fresh seed per ABBA observation. Retained archive remains on disk.',
 'measurement_scope':'Healthy uninterrupted SSE. Comparable latest-answer visibility and HTTP/cache readiness; baseline full inventory versus patched bounded newest window are NOT equal full-sync completion. Warm patched cache reuse is zero message GETs. Lost-continuity unbounded safety fallback is covered by separate native tests. No keyboard/FPS/physical iPhone measurement.'}
if value['variant']=='baseline' and sha!=value['paired_baseline_sha']: raise SystemExit('Baseline revision mismatch')
Path(sys.argv[1]).write_text(json.dumps(value,indent=2)+'\n')
PYTHON
if [[ "$reuse_build" == 0 ]]; then
  python3 performance-lab/prepare-window-instrumentation.py
  xcodegen --version | tee "$results/xcodegen-version.txt"
  INCLUDE_PROJECT_LOCAL_YAML=NO xcodegen generate 2>&1 | tee "$results/xcodegen.log"
  cp OpenCodeIOSClient.xcodeproj/project.pbxproj "$results/generated-project.pbxproj"
  # Generation must register newly added product and regression Swift files.
  python3 - <<'PYTHON'
from pathlib import Path
project=Path('OpenCodeIOSClient.xcodeproj/project.pbxproj').read_text()
for path in (Path('OpenCodeIOSClient/Coordinators/LegacyTranscriptCoordinator.swift'),Path('OpenCodeIOSClientTests/LegacyMessagePaginationTests.swift'),Path('OpenCodeIOSClientTests/OpenCodeLocalCachePreviewTests.swift'),Path('OpenCodeIOSClientTests/LegacyTranscriptWindowTests.swift')):
    if path.exists() and path.name not in project: raise SystemExit('Generated project is missing '+str(path))
PYTHON
  xcodebuild build-for-testing -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient \
    -configuration Debug -destination "$destination" -parallel-testing-enabled NO \
    -derivedDataPath "$build_root/DerivedData" DEVELOPMENT_TEAM= \
    2>&1 | tee "$results/build.log" | awk '/error:|warning:|\*\* TEST|\*\* BUILD/ { print; fflush() }'
  python3 - "$build_root/build-manifest.json" "$variant" "$device_id" <<'PYTHON'
import json,os,subprocess,sys
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({'source':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'harness':os.environ['OPENCLIENT_EXTREME_HARNESS_SHA'],'variant':sys.argv[2],'device':sys.argv[3]},indent=2)+'\n')
PYTHON
else
  python3 - "$build_root/build-manifest.json" "$variant" "$device_id" <<'PYTHON'
import json,os,subprocess,sys
value=json.loads(open(sys.argv[1]).read())
expected={'source':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
 'harness':os.environ['OPENCLIENT_EXTREME_HARNESS_SHA'],'variant':sys.argv[2],'device':sys.argv[3]}
if value!=expected: raise SystemExit('Refusing stale/mismatched native build reuse')
PYTHON
fi
run_file=$(python3 - "$build_root/DerivedData/Build/Products" <<'PYTHON'
from pathlib import Path
import sys
paths=list(Path(sys.argv[1]).glob('*.xctestrun'))
if len(paths)!=1: raise SystemExit(f'Expected one native product, found {len(paths)}')
print(paths[0])
PYTHON
)
echo "EXTREME native build ready variant=$variant reused=$reuse_build"

start_fixture() {
  local output=$1
  cleanup_fixture
  mkdir -p "$output"
  local fixture_args=(serve --profile extreme --legacy-cursorless --extreme-messages "$messages"
    --port 14097 --password ci-fixture-only --log "$output/requests.jsonl")
  if [[ "$verify_telemetry_retry" == 1 ]]; then fixture_args+=(--fail-first-startup-phase); fi
  python3 -u performance-lab/lab.py "${fixture_args[@]}" \
    > "$output/fixture.log" 2>&1 &
  fixture_pid=$!
  python3 - "$output/fixture-initial-status.json" "$messages" "$fixture_pid" <<'PY'
import base64,json,os,sys,time,urllib.request
from pathlib import Path
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
request=urllib.request.Request('http://127.0.0.1:14097/_lab/status',headers={
    'Authorization':'Basic '+base64.b64encode(b'opencode:ci-fixture-only').decode()})
deadline=time.monotonic()+90
while time.monotonic()<deadline:
    try:
        os.kill(int(sys.argv[3]),0)
        with opener.open(request,timeout=2) as response: value=json.load(response)
        assert value.get('synthetic') is True and value.get('legacy_cursorless') is True and value.get('sessions')=={'ses_extreme':int(sys.argv[2])}
        Path(sys.argv[1]).write_text(json.dumps(value,indent=2)+'\n')
        break
    except (OSError,ValueError,AssertionError): time.sleep(.25)
else: raise SystemExit('Owned single-session extreme fixture did not become ready')
PY
}

export_result() {
  local output=$1
  local container
  container=$(xcrun simctl get_app_container "$device_id" "$bundle" data 2>/dev/null || true)
  if [[ -n "$container" && -d "$container/Documents/OpenClientExtremeSession" ]]; then
    ditto "$container/Documents/OpenClientExtremeSession" "$output/probes"
  fi
  if [[ -n "$container" && -f "$container/Documents/OpenClientExtremeCacheSeed.json" ]]; then
    cp "$container/Documents/OpenClientExtremeCacheSeed.json" "$output/cache-seed-proof.json"
  fi
  if [[ -n "$container" && -f "$container/Documents/OpenClientExtremeCacheSeedProgress.json" ]]; then
    cp "$container/Documents/OpenClientExtremeCacheSeedProgress.json" "$output/cache-seed-progress.json"
  fi
  if [[ -d "$output/tests.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$output/tests.xcresult" > "$output/summary.json" || true
    xcrun xcresulttool get test-results tests --path "$output/tests.xcresult" > "$output/tests.json" || true
    xcrun xcresulttool export attachments --path "$output/tests.xcresult" --output-path "$output/attachments" || true
  fi
}

run_test() {
  local output=$1 code=0
  shift
  local selectors=("$@")
  local allowance=1200
  if [[ "$canary" == 1 ]]; then allowance=300; fi
  set +e
  xcodebuild test-without-building -xctestrun "$run_file" -destination "$destination" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance "$allowance" -maximum-test-execution-time-allowance "$allowance" \
    -resultBundlePath "$output/tests.xcresult" "${selectors[@]}" \
    2>&1 | tee "$output/xcodebuild.log" | awk '/error:|Test Case|Test Suite|EXTREME |\*\* TEST/ { print; fflush() }'
  code=${PIPESTATUS[0]}
  set -e
  printf '{"xcodebuild_exit_code": %d}\n' "$code" > "$output/xcodebuild-status.json"
  export_result "$output"
  cleanup_fixture
  return "$code"
}

set_test_environment() {
  export TEST_RUNNER_OPENCLIENT_EXTREME_URL=http://127.0.0.1:14097
  export TEST_RUNNER_OPENCLIENT_EXTREME_PASSWORD=ci-fixture-only
  export TEST_RUNNER_OPENCLIENT_EXTREME_COUNT=$messages
  export TEST_RUNNER_OPENCLIENT_EXTREME_INPUT_POLICY=$input_policy
  export TEST_RUNNER_OPENCLIENT_WINDOW_VARIANT=$variant
}
set_test_environment

if [[ "$variant" == patched && "$reuse_build" == 0 ]]; then
  unit_output="$results/native-regressions"
  mkdir -p "$unit_output"
  selectors=()
  regression_suites=(LegacyMessagePaginationTests LegacyTranscriptWindowTests OpenCodeLocalCachePreviewTests OpenCodeLocalCacheIntegrationTests OpenCodeLocalCacheRepositoryTests ChatStoreTests ChatFacadeTests InitialChatHydrationTests ForegroundChatRefreshTests OpenCodeAPIClientTests OpenCodeStreamingTests DirectoryStoreTests ActivityFacadeTests)
  for suite in "${regression_suites[@]}"; do
    selectors+=("-only-testing:OpenCodeIOSClientTests/$suite")
  done
  selectors+=('-skip-testing:OpenCodeIOSClientTests/OpenCodeLocalCacheRepositoryTests/testPrepareExtremeSessionCache')
  run_test "$unit_output" "${selectors[@]}"
  python3 - "$unit_output/summary.json" "$unit_output/tests.json" "${regression_suites[@]}" <<'PYTHON'
import json,sys
s=json.load(open(sys.argv[1]))
if s.get('result')!='Passed' or s.get('totalTestCount',0)<=0 or s.get('passedTests')!=s.get('totalTestCount') or s.get('failedTests')!=0 or s.get('skippedTests')!=0:
    raise SystemExit('Selected native regression tests did not all run and pass')
tests=json.dumps(json.load(open(sys.argv[2])))
missing=[suite for suite in sys.argv[3:] if suite not in tests]
if missing: raise SystemExit('Selected native suites absent from executed-test tree: '+str(missing))
PYTHON
fi
if [[ "$reuse_build" == 0 && "$canary" == 0 ]]; then
  # Same compiled binaries and real route, including warm revisit and overscroll.
  # Small payload catches instrumentation/navigation failures before 539MB setup.
  OPENCLIENT_WINDOW_REUSE_BUILD=1 OPENCLIENT_WINDOW_CANARY=1 OPENCLIENT_EXTREME_MESSAGES=64 \
    bash performance-lab/run-window-session.sh "$destination" "$results/canary-64"
fi

run_case() {
  local kind=$1 grouped=$2 trial=$3
  local output="$results/$kind-$trial-g$grouped"
  local container code=0
  mkdir -p "$output"
  terminate_owned_app "$output"
  container=$(xcrun simctl get_app_container "$device_id" "$bundle" data 2>/dev/null || true)
  [[ -n "$container" && -d "$cache_snapshot" ]] || { echo 'Validated warm-cache snapshot missing' >&2; exit 1; }
  rm -rf "$container/Library/Application Support"
  ditto "$cache_snapshot" "$container/Library/Application Support"
  if [[ -n "$container" ]]; then rm -rf "$container/Documents/OpenClientExtremeSession"; fi
  export TEST_RUNNER_OPENCLIENT_EXTREME_CASE=$kind
  export TEST_RUNNER_OPENCLIENT_EXTREME_GROUPED=$grouped
  export TEST_RUNNER_OPENCLIENT_EXTREME_TRIAL=$trial
  export TEST_RUNNER_OPENCLIENT_EXTREME_INPUT_PREFIX="extreme_${kind}_g${grouped}_${trial}"
  echo "EXTREME starting $kind grouping=$grouped trial=$trial"
  start_fixture "$output"
  if run_test "$output" '-only-testing:OpenCodeIOSClientUITests/ToolGroupingUITests/testWindowSessionLoading'; then code=0; else code=$?; fi
  echo "EXTREME finished $kind grouping=$grouped trial=$trial status=$code"
  if (( code != 0 )); then case_failures=$((case_failures+1)); fi
}

# Prepare and verify the retained full-history cache before the measured cases.
seed_output="$results/cache-seed"
mkdir -p "$seed_output"
container=$(xcrun simctl get_app_container "$device_id" "$bundle" data 2>/dev/null || true)
if [[ -n "$container" ]]; then rm -f "$container/Documents/OpenClientExtremeCacheSeed.json"; fi
export TEST_RUNNER_OPENCLIENT_EXTREME_CASE=seed
export TEST_RUNNER_OPENCLIENT_EXTREME_GROUPED=0
export TEST_RUNNER_OPENCLIENT_EXTREME_TRIAL=setup
export TEST_RUNNER_OPENCLIENT_EXTREME_SEED_ONLY=1
export TEST_RUNNER_OPENCODE_UI_TEST_MODE=0
export TEST_RUNNER_OPENCODE_UI_TEST_AUTO_CONNECT=0
start_fixture "$seed_output"
seed_code=0
if run_test "$seed_output" '-only-testing:OpenCodeIOSClientTests/OpenCodeLocalCacheRepositoryTests/testPrepareExtremeSessionCache'; then
  seed_code=0
else
  seed_code=$?
fi
if ! terminate_owned_app "$seed_output"; then
  printf '{"reason": "Could not stop the native host before cache snapshot", "warm_cases_skipped": %d}\n' "$expected_cases" > "$results/warm-blocked.json"
  exit 1
fi
unset TEST_RUNNER_OPENCLIENT_EXTREME_SEED_ONLY
unset TEST_RUNNER_OPENCODE_UI_TEST_MODE
unset TEST_RUNNER_OPENCODE_UI_TEST_AUTO_CONNECT
if (( seed_code == 0 )); then
  if python3 - "$seed_output" "$messages" <<'PY'
from pathlib import Path
import json,sys
p=Path(sys.argv[1]);count=int(sys.argv[2]);errors=[]
try:
    summary=json.loads((p/'summary.json').read_text())
    if summary.get('result')!='Passed' or summary.get('totalTestCount')!=1 \
            or summary.get('passedTests')!=1 or summary.get('failedTests')!=0 or summary.get('skippedTests')!=0:
        errors.append('Expected exactly one passed native cache preparation test')
    proof=json.loads((p/'cache-seed-proof.json').read_text())
    fixture=json.loads((p/'fixture-initial-status.json').read_text())
    if proof.get('schema')!=1 or proof.get('synthetic') is not True or proof.get('setup_only') is not True \
            or proof.get('session_id')!='ses_extreme' or proof.get('messages')!=count \
            or proof.get('readback_messages')!=count or proof.get('readback_used_second_repository') is not True:
        errors.append('Native seed proof does not verify the requested full-history cache readback')
    if proof.get('directory_sessions')!=1 or proof.get('readback_directory_sessions')!=1 \
            or proof.get('readback_directory_session_ids')!=['ses_extreme']:
        errors.append('Native seed proof does not verify the sole directory session metadata readback')
    if proof.get('todos_via_production_api') is not True or proof.get('readback_todos_known') is not True \
            or proof.get('readback_todos_stale') is not True or proof.get('readback_todos')!=proof.get('todos'):
        errors.append('Native seed proof does not verify known stale todos through the production API/cache writer')
    if proof.get('encoded_response_bytes')!=fixture['extreme_profile']['encoded_messages_bytes']:
        errors.append('Native seed HTTP response does not match the configured extreme history')
except (OSError,ValueError,KeyError,TypeError) as error: errors.append(str(error))
(p/'validation.json').write_text(json.dumps({'complete':not errors,'errors':errors},indent=2)+'\n')
if errors: raise SystemExit('\n'.join(errors))
PY
  then seed_code=0; else seed_code=1; fi
fi
if (( seed_code != 0 )); then
  printf '{"reason": "Native production-cache preparation failed", "seed_exit_code": %d, "warm_cases_skipped": %d}\n' "$seed_code" "$expected_cases" > "$results/warm-blocked.json"
  exit 1
fi
container=$(xcrun simctl get_app_container "$device_id" "$bundle" data)
[[ -d "$container/Library/Application Support" ]] || { echo 'Production cache directory missing after seed test' >&2; exit 1; }
rm -rf "$cache_snapshot"
ditto "$container/Library/Application Support" "$cache_snapshot"
python3 - "$cache_snapshot" "$results/cache-snapshot-files.json" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]); rows=[{'path':str(p.relative_to(root)),'bytes':p.stat().st_size} for p in sorted(root.rglob('*')) if p.is_file()]
if not rows: raise SystemExit('Production cache snapshot is empty')
Path(sys.argv[2]).write_text(json.dumps({'files':rows,'total_bytes':sum(r['bytes'] for r in rows)},indent=2)+'\n')
PY

for grouped in "${grouped_cases[@]}"; do
  run_case seeded-revisit "$grouped" trial1
done
printf '{"failed_measured_ui_cases": %d, "expected_measured_ui_cases": %d, "cache_seed_exit_code": %d}\n' "$case_failures" "$expected_cases" "$seed_code" > "$results/case-status.json"

python3 performance-lab/validate-window-results.py "$results"
(( case_failures == 0 ))
