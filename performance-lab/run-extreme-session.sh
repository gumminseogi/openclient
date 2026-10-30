#!/usr/bin/env bash
# One real app build; normal simulator signing; synthetic history on loopback only.
set -euo pipefail
[[ $# == 2 ]] || { echo 'Usage: run-extreme-session.sh <simulator destination> <results directory>' >&2; exit 2; }
destination=$1
results=$2
device_id=${destination##*id=}
bundle=com.ntoporcov.openclient
messages=${OPENCLIENT_EXTREME_MESSAGES:-5000}
[[ "$messages" =~ ^[0-9]+$ ]] && (( messages >= 64 && messages <= 10000 )) || { echo 'Extreme fixture message count must be 64...10000' >&2; exit 2; }
build_root="$RUNNER_TEMP/openclient-extreme-build"
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
  # A cold first launch may have no running/installed app. Other termination
  # failures must stop cache replacement rather than copying a live SQLite store.
  if python3 - "$output/app-terminate.log" <<'PY'
from pathlib import Path
import sys
text=Path(sys.argv[1]).read_text()
if not any(message in text.lower() for message in ('not running','no such process')):
    raise SystemExit('Could not stop the owned app safely: '+text)
PY
  then return 0; fi
  return 1
}

python3 - "$results/provenance.json" "$messages" <<'PY'
import json, platform, subprocess, sys, time
from pathlib import Path
Path(sys.argv[1]).write_text(json.dumps({
    'upstream_source_sha': '4dedc814bd38d3daa5a53bff01d75209f2865502',
    'test_checkout_sha': subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
    'started_epoch_s': time.time(), 'host': platform.platform(),
    'session_id': 'ses_extreme', 'configured_message_count': int(sys.argv[2]),
    'history': 'One opt-in synthetic mixed-tool session; real limit/cursor pagination; no model calls or artificial server delay.',
    'cache_setup': 'Cold controls run first. Warm cache is prepared in an unmeasured hosted test using a real full API request and the production persistent cache writer, then restored while the app is terminated. This is not a timed UI pagination pass.',
    'cases': 'cold x1 and seeded-revisit x1 per grouping; seeded-relaunch x3 per grouping. One native app binary for all 10 measured cases.',
    'measurement_scope': 'Native app phase timestamps plus separately labeled XCTest observations; seconds-level chat loading, not a helper microbenchmark, presented FPS or physical iPhone performance.',
    'failure_policy': 'Export each measured case, attempt the remaining cases after individual UI failures, and fail if any case fails. Build/fixture/cache preparation failures block dependent warm cases; cold results remain available.'
},indent=2)+'\n')
PY

python3 performance-lab/prepare-extreme-instrumentation.py
xcodebuild build-for-testing -project OpenCodeIOSClient.xcodeproj -scheme OpenCodeIOSClient \
  -configuration Debug -destination "$destination" -parallel-testing-enabled NO \
  -derivedDataPath "$build_root/DerivedData" DEVELOPMENT_TEAM= \
  2>&1 | tee "$results/build.log" | awk '/error:|warning:|\*\* TEST|\*\* BUILD/ { print; fflush() }'
run_file=$(python3 - "$build_root/DerivedData/Build/Products" <<'PY'
from pathlib import Path
import sys
paths=list(Path(sys.argv[1]).glob('*.xctestrun'))
if len(paths)!=1: raise SystemExit(f'Expected one built test product, found {len(paths)}')
print(paths[0])
PY
)
[[ -n "$run_file" ]] || { echo 'Native test product missing' >&2; exit 1; }
echo 'EXTREME native build complete'

start_fixture() {
  local output=$1
  cleanup_fixture
  mkdir -p "$output"
  python3 -u performance-lab/lab.py serve --profile extreme --extreme-messages "$messages" \
    --port 14097 --password ci-fixture-only --log "$output/requests.jsonl" \
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
        assert value.get('synthetic') is True and value.get('sessions')=={'ses_extreme':int(sys.argv[2])}
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
  if [[ -d "$output/tests.xcresult" ]]; then
    xcrun xcresulttool get test-results summary --path "$output/tests.xcresult" > "$output/summary.json" || true
    xcrun xcresulttool get test-results tests --path "$output/tests.xcresult" > "$output/tests.json" || true
    xcrun xcresulttool export attachments --path "$output/tests.xcresult" --output-path "$output/attachments" || true
  fi
}

run_test() {
  local output=$1 selector=$2 code=0
  set +e
  xcodebuild test-without-building -xctestrun "$run_file" -destination "$destination" \
    -parallel-testing-enabled NO -test-timeouts-enabled YES \
    -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 600 \
    -resultBundlePath "$output/tests.xcresult" "-only-testing:$selector" \
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
}
set_test_environment

run_case() {
  local kind=$1 grouped=$2 trial=$3
  local output="$results/$kind-$trial-g$grouped"
  local container code=0
  mkdir -p "$output"
  terminate_owned_app "$output"
  container=$(xcrun simctl get_app_container "$device_id" "$bundle" data 2>/dev/null || true)
  if [[ "$kind" == cold ]]; then
    if [[ -n "$container" ]]; then rm -rf "$container/Library/Application Support"; fi
  else
    [[ -n "$container" && -d "$cache_snapshot" ]] || { echo 'Validated warm-cache snapshot missing' >&2; exit 1; }
    rm -rf "$container/Library/Application Support"
    ditto "$cache_snapshot" "$container/Library/Application Support"
  fi
  if [[ -n "$container" ]]; then rm -rf "$container/Documents/OpenClientExtremeSession"; fi
  export TEST_RUNNER_OPENCLIENT_EXTREME_CASE=$kind
  export TEST_RUNNER_OPENCLIENT_EXTREME_GROUPED=$grouped
  export TEST_RUNNER_OPENCLIENT_EXTREME_TRIAL=$trial
  export TEST_RUNNER_OPENCLIENT_EXTREME_INPUT_PREFIX="extreme_${kind}_g${grouped}_${trial}"
  echo "EXTREME starting $kind grouping=$grouped trial=$trial"
  start_fixture "$output"
  if run_test "$output" 'OpenCodeIOSClientUITests/ToolGroupingUITests/testExtremeSessionLoading'; then code=0; else code=$?; fi
  echo "EXTREME finished $kind grouping=$grouped trial=$trial status=$code"
  if (( code != 0 )); then case_failures=$((case_failures+1)); fi
}

# These controls survive even if the much larger persistent-cache preparation fails.
run_case cold 1 trial1
run_case cold 0 trial1

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
if run_test "$seed_output" 'OpenCodeIOSClientTests/OpenCodeLocalCacheRepositoryTests/testPrepareExtremeSessionCache'; then
  seed_code=0
else
  seed_code=$?
fi
if ! terminate_owned_app "$seed_output"; then
  printf '{"reason": "Could not stop the native host before cache snapshot", "warm_cases_skipped": 8}\n' > "$results/warm-blocked.json"
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
    if proof.get('encoded_response_bytes')!=fixture['extreme_profile']['encoded_messages_bytes']:
        errors.append('Native seed HTTP response does not match the configured extreme history')
except (OSError,ValueError,KeyError,TypeError) as error: errors.append(str(error))
(p/'validation.json').write_text(json.dumps({'complete':not errors,'errors':errors},indent=2)+'\n')
if errors: raise SystemExit('\n'.join(errors))
PY
  then seed_code=0; else seed_code=1; fi
fi
if (( seed_code != 0 )); then
  printf '{"reason": "Native production-cache preparation failed", "seed_exit_code": %d, "warm_cases_skipped": 8, "cold_case_failures": %d}\n' "$seed_code" "$case_failures" > "$results/warm-blocked.json"
  exit 1
fi
container=$(xcrun simctl get_app_container "$device_id" "$bundle" data)
[[ -d "$container/Library/Application Support" ]] || { echo 'Production cache directory missing after seed test' >&2; exit 1; }
ditto "$container/Library/Application Support" "$cache_snapshot"
python3 - "$cache_snapshot" "$results/cache-snapshot-files.json" <<'PY'
from pathlib import Path
import json,sys
root=Path(sys.argv[1]); rows=[{'path':str(p.relative_to(root)),'bytes':p.stat().st_size} for p in sorted(root.rglob('*')) if p.is_file()]
if not rows: raise SystemExit('Production cache snapshot is empty')
Path(sys.argv[2]).write_text(json.dumps({'files':rows,'total_bytes':sum(r['bytes'] for r in rows)},indent=2)+'\n')
PY

run_case seeded-revisit 1 trial1
run_case seeded-revisit 0 trial1
for trial in 1 2 3; do
  if [[ "$trial" == 2 ]]; then groups=(0 1); else groups=(1 0); fi
  for grouped in "${groups[@]}"; do run_case seeded-relaunch "$grouped" "trial$trial"; done
done
printf '{"failed_measured_ui_cases": %d, "expected_measured_ui_cases": 10, "cache_seed_exit_code": %d}\n' "$case_failures" "$seed_code" > "$results/case-status.json"

# A successful xcodebuild exit is insufficient if the readable evidence is absent.
python3 - "$results" <<'PY'
from pathlib import Path
import json,math,sys
root=Path(sys.argv[1]);cases=sorted(p for p in root.iterdir() if p.is_dir() and '-trial' in p.name)
errors=[]
def clock_offset(row):
    before,after,epoch=(row[key] for key in ('uptime_before_s','uptime_after_s','epoch_s'))
    if not all(isinstance(v,(int,float)) and not isinstance(v,bool) and math.isfinite(v) for v in (before,after,epoch)) \
            or not 0<=after-before<=.1:
        raise ValueError('Invalid or imprecise app/UI clock calibration')
    return epoch-(before+after)/2
if len(cases)!=10: errors.append(f'Expected 10 measured cases, found {len(cases)}')
for p in cases:
    try:
        status=json.loads((p/'xcodebuild-status.json').read_text())
        summary=json.loads((p/'summary.json').read_text())
        if status['xcodebuild_exit_code']!=0 or summary.get('result')!='Passed' \
                or summary.get('totalTestCount')!=1 or summary.get('passedTests')!=1 \
                or summary.get('failedTests')!=0 or summary.get('skippedTests')!=0:
            errors.append(p.name+': native UI test failed')
        kind,trial,group=p.name.rsplit('-',2)
        grouped=group=='g1'
        count=int(json.loads((root/'provenance.json').read_text())['configured_message_count'])
        expected=20 if kind=='cold' else count
        evidence=[]
        for path in (p/'attachments').rglob('*.json'):
            value=json.loads(path.read_text())
            if isinstance(value,dict) and value.get('experiment')=='extreme_session_load' \
                    and value.get('checkpoint')=='complete' and value.get('complete') is True:
                evidence.append(value)
        if len(evidence)!=1: raise ValueError('Expected one completed UI evidence checkpoint')
        evidence=evidence[0]
        if evidence.get('schema')!=1 or evidence.get('case')!=kind or evidence.get('trial')!=trial \
                or evidence.get('grouping') is not grouped:
            raise ValueError('Completed UI checkpoint labels disagree with this case')
        profile=evidence.get('profile',{})
        if profile.get('session_id')!='ses_extreme' or profile.get('messages')!=count:
            raise ValueError('Completed UI checkpoint has the wrong single-session profile')
        probes=[]
        for path in (p/'probes').glob('*.jsonl'):
            raw=path.read_bytes()
            if not raw or not raw.endswith(b'\n'): raise ValueError('Empty or truncated app probe')
            rows=[json.loads(line) for line in raw.splitlines()]
            if not all(isinstance(row,dict) for row in rows): raise ValueError('Invalid app probe rows')
            meta=rows[0]
            if meta.get('phase')=='metadata' and meta.get('schema')==1 \
                    and meta.get('case')==kind and meta.get('trial')==trial \
                    and meta.get('grouping_requested') is grouped:
                probes.append(rows)
        if len(probes)!=1: raise ValueError('Expected one matching app phase probe')
        rows=probes[0]
        if abs(clock_offset(rows[0])-clock_offset(evidence['clock']))>.1:
            raise ValueError('App and UI clocks disagree by more than 100ms')
        appearance=[r for r in rows if r.get('phase')=='appearance_configured']
        if not appearance or any(r.get('grouping_actual') is not grouped \
                or r.get('tools_actual') is not True or r.get('reasoning_actual') is not True for r in appearance):
            raise ValueError('Actual native grouping/tools/reasoning settings were not verified')
        if kind!='cold' and not any(r.get('phase')=='disk_cache_json_decoded' \
                and r.get('cache_messages')==count for r in rows):
            raise ValueError('Warm app process did not decode the prepared full-history disk cache')
        actions=evidence.get('actions',[])
        stages=['first_open','same_process_revisit','bottom_refresh'] if kind=='seeded-revisit' else ['first_open','bottom_refresh']
        if [a.get('stage') for a in actions]!=stages: raise ValueError('Completed checkpoint is missing an action')
        used_request_ids=set()
        for operation,action in enumerate(actions,1):
            if action.get('operation')!=operation or action.get('minimum_expected_loaded')!=expected:
                raise ValueError('UI action has the wrong operation or loaded-history requirement')
            native=[r for r in rows if r.get('operation')==operation]
            phases={r.get('phase') for r in native}
            required={'canonical_request_started','canonical_typed_page_returned','canonical_published',
                      'typed_token_accepted','post_canonical_typed_token_accepted'}
            required|=({'bottom_refresh_started','bottom_refresh_method_completed'} if action['stage']=='bottom_refresh' \
                       else {'selection_started','transcript_reveal_completed'})
            if not required.issubset(phases): raise ValueError('Native operation has incomplete phase markers: '+str(sorted(required-phases)))
            if not any(r.get('phase')=='canonical_request_started' and r.get('request_limit')==expected for r in native):
                raise ValueError('Native canonical request did not use the required history limit')
            if not any(r.get('phase')=='canonical_published' and r.get('loaded_messages')==expected for r in native):
                raise ValueError('Native canonical publication did not contain the required message count')
            if not any(r.get('phase')=='typed_token_accepted' and r.get('expected_token')==action.get('typed_token') for r in native):
                raise ValueError('Native input delegate did not accept the matching action token')
            after_token=action.get('typed_token') if action['stage']=='bottom_refresh' else action.get('post_canonical_typed_token')
            if not after_token or not any(r.get('phase')=='post_canonical_typed_token_accepted' \
                    and r.get('expected_token')==after_token for r in native):
                raise ValueError('Native input after canonical publication was not verified')
            requests=[r for r in action.get('requests',[]) if r.get('method')=='GET' \
                and r.get('path')=='/session/ses_extreme/message' and r.get('status')==200 \
                and not r.get('query',{}).get('before') \
                and int(r.get('query',{}).get('limit',['0'])[0])==expected and r.get('response_bytes',0)>0]
            ids={r['request_id'] for r in requests}
            if not ids or ids.intersection(used_request_ids): raise ValueError('Canonical HTTP proof is absent or reused from a previous action')
            used_request_ids.update(ids)
    except (OSError,ValueError,KeyError,TypeError) as error: errors.append(p.name+': '+str(error))
Path(root/'validation.json').write_text(json.dumps({'complete':not errors,'measured_case_count':len(cases),'errors':errors},indent=2)+'\n')
if errors: raise SystemExit('\n'.join(errors))
PY
if (( case_failures != 0 )); then exit 1; fi
