#!/usr/bin/env bash
# shellcheck disable=SC2016  # the checks are single-quoted on purpose: check() evals them later.
# Runs scripts/demofy.sh against tests/mock_api.py for each scenario and checks exit code,
# outputs, the error sentence and that the key never reaches the log.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PYTHON="${PYTHON:-python3}"
PORT="${MOCK_PORT:-18765}"
TMP="$(mktemp -d)"
"$PYTHON" "$ROOT/tests/mock_api.py" "$PORT" "$TMP" >"$TMP/mock.log" 2>&1 &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true; rm -rf "$TMP"' EXIT

for _ in $(seq 1 50); do
  curl -s --max-time 2 -o /dev/null "http://127.0.0.1:$PORT/files/ping" && break
  sleep 0.2
done

PASS=0
FAILED=0

# run_case NAME KEY EXPECTED_EXIT [VAR=value ...] -> leaves $OUT and $LOG for the checks.
run_case() {
  local name="$1" key="$2" expected="$3"
  shift 3
  OUT="$TMP/$name.out"
  LOG="$TMP/$name.log"
  : >"$OUT"
  local status=0
  # SYSTEMROOT keeps sockets working when this suite runs under Git Bash on Windows.
  env -i PATH="$PATH" HOME="${HOME:-/tmp}" SYSTEMROOT="${SYSTEMROOT:-}" \
    GITHUB_OUTPUT="$OUT" GITHUB_STEP_SUMMARY="$TMP/$name.md" RUNNER_TEMP="$TMP" \
    DEMOFY_API_KEY="$key" INPUT_URL="https://example.com" INPUT_PROMPT="Show the home page" \
    INPUT_BASE_URL="http://127.0.0.1:$PORT" INPUT_WAIT=true INPUT_TIMEOUT_MINUTES=5 \
    DEMOFY_POLL_INITIAL=1 DEMOFY_POLL_MAX=1 "$@" \
    bash "$ROOT/scripts/demofy.sh" >"$LOG" 2>&1 || status=$?
  CASE="$name"
  check "exit code $expected" "[[ $status == $expected ]]"
  # The runner hides the ::add-mask:: line; every other line must not carry the key.
  check "key not printed" "! grep -v '^::add-mask::' '$LOG' | grep -q -- '$key'"
}

check() {
  if eval "$2"; then
    PASS=$((PASS + 1))
  else
    FAILED=$((FAILED + 1))
    echo "FAIL [$CASE] $1"
    sed 's/^/    /' "$LOG"
  fi
}

output() { grep "^$1=" "$OUT" | tail -n1 | cut -d= -f2-; }

run_case success dmf_success 0 INPUT_QUALITY="" INPUT_PACING=unhurried INPUT_LOOK='{"backdrop":"beam"}'
check "job-id" '[[ $(output job-id) == job-success ]]'
check "status done" '[[ $(output status) == done ]]'
check "video-url" '[[ $(output video-url) == http://127.0.0.1:$PORT/files/job-success.mp4 ]]'
check "share-url" '[[ $(output share-url) == http://127.0.0.1:$PORT/s/abc ]]'
check "page-url" '[[ $(output page-url) == http://127.0.0.1:$PORT/jobs/job-success ]]'
check "mp4 downloaded as demofy-<job-id>.mp4" '[[ -s $(output video-path) && $(output video-path) == */demofy-job-success.mp4 ]]'
check "summary links the video" 'grep -q "Download the MP4" "$TMP/success.md"'
check "body has pacing and look, drops empty quality" \
  'jq -e ".pacing == \"unhurried\" and .look.backdrop == \"beam\" and (has(\"quality\") | not) and .url == \"https://example.com\"" "$TMP/success.json" >/dev/null'

run_case named dmf_success 0 INPUT_ARTIFACT_NAME=release-demo.mp4 INPUT_TIMEOUT_MINUTES=08
check "artifact-name sets the file name" '[[ $(output video-path) == */release-demo.mp4 ]]'

run_case failed dmf_fail 1
check "status failed" '[[ $(output status) == failed ]]'
check "error-code" '[[ $(output error-code) == page_not_found ]]'
check "API sentence shown" 'grep -q "page not found screen" "$LOG"'

run_case timeout dmf_stuck 1 DEMOFY_TIMEOUT_SECONDS=3
check "timeout message" 'grep -q "Timed out after 3 s" "$LOG"'
check "status capturing" '[[ $(output status) == capturing ]]'

run_case unauthorized dmf_bad 1
check "401 sentence" 'grep -q "refused the API key (401) while creating the job: This API key is not valid." "$LOG"'
check "no job-id" '[[ -z $(output job-id) ]]'

run_case forbidden dmf_scope 1
check "403 sentence" 'grep -q "(403) while creating the job: This key cannot do this" "$LOG"'

run_case invalid dmf_invalid 1 INPUT_QUALITY=best
check "400 issues listed" 'grep -q "HTTP 400 while creating the job: invalid request (quality: Invalid enum value)" "$LOG"'

run_case upgrade dmf_pro 1 INPUT_QUALITY=high
check "402 sentence" 'grep -q "paid Demofy plan (402).*High quality is a Pro feature." "$LOG"'

run_case quota dmf_quota 1
check "429 sentence with Retry-After" 'grep -q "(429, retry after 3600s).*today.s 3 demos" "$LOG"'

run_case signin dmf_signin 1
check "sign-in URL shown" 'grep -q "job-signin#sign-in" "$LOG"'

run_case flaky dmf_flaky 0
check "recovered to done" '[[ $(output status) == done ]]'

run_case nowait dmf_success 0 INPUT_WAIT=false
check "created only" '[[ $(output status) == queued && -z $(output video-path) ]]'

run_case not-a-key not_a_demofy_key 1
check "non-dmf key refused locally" 'grep -q "not a Demofy API key" "$LOG"'

run_case bad-look dmf_success 1 INPUT_LOOK='[1]'
check "look must be an object" 'grep -q "look must be a JSON object" "$LOG"'

echo "$PASS checks passed, $FAILED failed"
((FAILED == 0))
