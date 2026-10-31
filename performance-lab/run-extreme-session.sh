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
variant=${OPENCLIENT_EXTREME_VARIANT:-baseline}
[[ "$variant" == baseline || "$variant" == patched ]] || { echo 'Unknown paired variant' >&2; exit 2; }
groupings=${OPENCLIENT_EXTREME_GROUPINGS:-'1 0'}
case "$groupings" in
  '1 0'|'0 1'|0|1) ;;
  *) echo 'Grouping cases must be unique 0/1 values: 1 0, 0 1, 0, or 1' >&2; exit 2 ;;
esac
read -r -a grouped_cases <<< "$groupings"
expected_cases=${#grouped_cases[@]}
verify_telemetry_retry=${OPENCLIENT_EXTREME_VERIFY_TELEMETRY_RETRY:-0}
[[ "$verify_telemetry_retry" == 0 || "$verify_telemetry_retry" == 1 ]] || { echo 'Telemetry retry verification must be 0 or 1' >&2; exit 2; }
build_root="$RUNNER_TEMP/openclient-extreme-build-$variant"
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

python3 - "$results/provenance.json" "$messages" "$variant" "$groupings" "$verify_telemetry_retry" <<'PY'
import json, os, platform, subprocess, sys, time
from pathlib import Path
checkout_sha=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
Path(sys.argv[1]).write_text(json.dumps({
    'upstream_source_sha': '4dedc814bd38d3daa5a53bff01d75209f2865502',
    'test_checkout_sha': checkout_sha,
    'harness_checkout_sha': os.environ.get('OPENCLIENT_EXTREME_HARNESS_SHA',checkout_sha),
    'variant': sys.argv[3],
    'groupings': [value=='1' for value in sys.argv[4].split()],
    'verify_telemetry_retry': sys.argv[5]=='1',
    'paired_baseline_sha': '31ad585ce08321ae7c4de7b1f33b991144fa2de5',
    'started_epoch_s': time.time(), 'host': platform.platform(),
    'session_id': 'ses_extreme', 'configured_message_count': int(sys.argv[2]),
    'history': 'One opt-in synthetic mixed-tool session; real limit/cursor pagination; no model calls or artificial server delay.',
    'cache_setup': 'First prepare directory session metadata and the full chat history in an unmeasured hosted test using real API requests and the production persistent cache writer, verify both through a second repository, then restore the cache while the app is terminated before each measured case. This is not a timed UI pagination pass.',
    'cases': 'seeded-revisit x1 per requested grouping: first open, same-process revisit, and bottom refresh. One native app binary for all requested measured cases.',
    'measurement_scope': 'Native app phase timestamps plus separately labeled XCTest observations for loading a fully retained long session. Full startup cache hydration is recorded separately and must complete before measured project/session selection. These are not helper microbenchmarks, presented FPS or physical iPhone performance.',
    'failure_policy': 'Export each measured case, attempt the remaining requested cases after an individual UI failure, and fail if any case fails. Build/fixture/cache preparation failures block all requested measured cases; retain setup failure evidence.'
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
  local fixture_args=(serve --profile extreme --extreme-messages "$messages"
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

if [[ "$variant" == patched ]]; then
  unit_output="$results/dedup-regressions"
  mkdir -p "$unit_output"
  run_test "$unit_output" 'OpenCodeIOSClientTests/InitialChatHydrationTests'
  python3 - "$unit_output/summary.json" <<'PY'
import json,sys
summary=json.load(open(sys.argv[1]))
if summary.get('result')!='Passed' or summary.get('totalTestCount')!=4 \
        or summary.get('passedTests')!=summary.get('totalTestCount') \
        or summary.get('failedTests')!=0 or summary.get('skippedTests')!=0:
    raise SystemExit('Initial hydration regression tests did not all run and pass')
PY
  if xcrun simctl get_app_container "$device_id" "$bundle" data >/dev/null 2>&1; then
    terminate_owned_app "$unit_output"
    xcrun simctl uninstall "$device_id" "$bundle"
  fi
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
  if run_test "$output" 'OpenCodeIOSClientUITests/ToolGroupingUITests/testExtremeSessionLoading'; then code=0; else code=$?; fi
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
if run_test "$seed_output" 'OpenCodeIOSClientTests/OpenCodeLocalCacheRepositoryTests/testPrepareExtremeSessionCache'; then
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

# A successful xcodebuild exit is insufficient if the readable evidence is absent.
python3 - "$results" <<'PY'
from pathlib import Path
import json,math,sys
root=Path(sys.argv[1]);cases=sorted(p for p in root.iterdir() if p.is_dir() and '-trial' in p.name)
errors=[]
measurements=[]
provenance=json.loads((root/'provenance.json').read_text())
variant=provenance['variant']
groupings=provenance['groupings']
if not isinstance(groupings,list) or not 1<=len(groupings)<=2 \
        or not all(isinstance(value,bool) for value in groupings) or len(set(groupings))!=len(groupings):
    raise ValueError('Invalid requested grouping cases')
if variant=='baseline' and provenance['test_checkout_sha']!=provenance['paired_baseline_sha']:
    errors.append('Baseline source is not the pinned pre-fix commit')
def clock_offset(row):
    before,after,epoch=(row[key] for key in ('uptime_before_s','uptime_after_s','epoch_s'))
    if not all(isinstance(v,(int,float)) and not isinstance(v,bool) and math.isfinite(v) for v in (before,after,epoch)) \
            or not 0<=after-before<=.1:
        raise ValueError('Invalid or imprecise app/UI clock calibration')
    return epoch-(before+after)/2
expected_case_names={'seeded-revisit-trial1-g'+str(int(grouped)) for grouped in groupings}
if {p.name for p in cases}!=expected_case_names:
    errors.append('Requested seeded-revisit grouping cases are missing or unexpected: '+str([p.name for p in cases]))
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
        expected=count
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
        if not any(r.get('phase')=='disk_cache_json_decoded' \
                and r.get('cache_messages')==count for r in rows):
            raise ValueError('Warm app process did not decode the prepared full-history disk cache')
        startup=[(index,r) for index,r in enumerate(rows) if r.get('phase')=='startup_cache_published' \
            and r.get('operation')==0 and r.get('operation_kind')=='startup' \
            and r.get('loaded_messages')==count and r.get('grouping_actual') is grouped]
        selection=next(((index,r) for index,r in enumerate(rows) \
            if r.get('phase')=='selection_started' and r.get('operation')==1),None)
        if selection is None or not any(index<selection[0] \
                and r['uptime_after_s']<=selection[1]['uptime_before_s'] for index,r in startup):
            raise ValueError('Full startup cache was not published with the actual grouping before first selection')
        actions=evidence.get('actions',[])
        stages=['first_open','same_process_revisit','bottom_refresh']
        if [a.get('stage') for a in actions]!=stages: raise ValueError('Completed checkpoint is missing an action')
        used_request_ids=set()
        measured_actions=[]
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
            expected_returns=1 if variant=='patched' or action['stage']=='bottom_refresh' else 2
            returned=[r for r in native if r.get('phase')=='canonical_typed_page_returned']
            if len(returned)!=expected_returns or any(r.get('page_messages')!=count for r in returned):
                raise ValueError('Unexpected full canonical return count for '+variant+' '+action['stage'])
            if variant=='patched' and sum(r.get('phase')=='canonical_request_started' for r in native)!=1:
                raise ValueError('Patched action started a duplicate canonical request')
            start_phase='bottom_refresh_started' if action['stage']=='bottom_refresh' else 'selection_started'
            end_phase='bottom_refresh_method_completed' if action['stage']=='bottom_refresh' else 'transcript_reveal_completed'
            start=next(r for r in native if r.get('phase')==start_phase)
            end=next(r for r in native if r.get('phase')==end_phase)
            seconds=(end['uptime_before_s']+end['uptime_after_s']-start['uptime_before_s']-start['uptime_after_s'])/2
            published=[r for r in native if r.get('phase')=='canonical_published']
            last=max(published,key=lambda r:r['uptime_after_s'])
            canonical_seconds=(last['uptime_before_s']+last['uptime_after_s']-start['uptime_before_s']-start['uptime_after_s'])/2
            if not math.isfinite(seconds) or seconds<0:
                raise ValueError('Invalid native action duration')
            measured_actions.append({'stage':action['stage'],'native_metric':end_phase,
                'native_seconds':seconds,'last_canonical_seconds':canonical_seconds,
                'canonical_request_starts':sum(r.get('phase')=='canonical_request_started' for r in native),
                'canonical_returns':len(returned)})
        body_bytes=json.loads((p/'fixture-initial-status.json').read_text())['extreme_profile']['encoded_messages_bytes']
        log=[json.loads(line) for line in (p/'requests.jsonl').read_text().splitlines()]
        full=[r for r in log if r.get('method')=='GET' and r.get('path')=='/session/ses_extreme/message'
            and r.get('status')==200 and not r.get('query',{}).get('before')
            and int(r.get('query',{}).get('limit',['0'])[0])==count and r.get('response_bytes')==body_bytes]
        expected_bodies=3 if variant=='patched' else 5
        if len(full)!=expected_bodies:
            raise ValueError('Expected '+str(expected_bodies)+' complete full-history HTTP bodies, found '+str(len(full)))
        if provenance.get('verify_telemetry_retry') is True:
            if not any(r.get('method')=='POST' and r.get('path')=='/_lab/native-phase' and r.get('status')==503 for r in log):
                raise ValueError('Injected startup telemetry HTTP 503 was not recorded')
            delivery=[r for r in rows if r.get('phase')=='native_phase_upload_attempt'
                and r.get('native_phase')=='startup_cache_published' and r.get('grouping_actual') is grouped]
            retried=any(failed.get('http_status')==503 and failed.get('error_code')==0
                and accepted.get('http_status')==202 and accepted.get('error_code')==0
                and accepted.get('attempt')==failed.get('attempt',0)+1
                and accepted['uptime_before_s']>=failed['uptime_after_s']
                for failed in delivery for accepted in delivery)
            if not retried:
                raise ValueError('Native startup telemetry did not retry the injected 503 successfully')
        measurements.append({'grouping':grouped,'message_count':count,'canonical_body_bytes':body_bytes,
            'full_body_count':len(full),'full_body_bytes':sum(r['response_bytes'] for r in full),'actions':measured_actions})
    except (OSError,ValueError,KeyError,TypeError) as error: errors.append(p.name+': '+str(error))
Path(root/'validation.json').write_text(json.dumps({'complete':not errors,'measured_case_count':len(cases),
    'expected_measured_case_count':len(groupings),'requested_groupings':groupings,'errors':errors},indent=2)+'\n')
Path(root/'measurements.json').write_text(json.dumps({'complete':not errors,'variant':variant,
    'test_checkout_sha':provenance['test_checkout_sha'],'harness_checkout_sha':provenance['harness_checkout_sha'],
    'cases':measurements},indent=2)+'\n')
if errors: raise SystemExit('\n'.join(errors))
PY
if (( case_failures != 0 )); then exit 1; fi
