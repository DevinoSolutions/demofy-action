#!/usr/bin/env bash
# Creates a Demofy demo job, waits for it, downloads the MP4 and reports it to GitHub Actions.
# Inputs arrive as environment variables (see action.yml). The API key is never echoed: it is
# masked, and curl reads the Authorization header from a private temp file, not from argv.
set -euo pipefail

BASE_URL="${INPUT_BASE_URL:-https://app.demofy.io}"
BASE_URL="${BASE_URL%/}"
OUTPUT_FILE="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/null}"
# Test seams: the mocked-API suite shortens the poll cadence and the deadline with these.
POLL_INITIAL="${DEMOFY_POLL_INITIAL:-10}"
POLL_MAX="${DEMOFY_POLL_MAX:-30}"
MAX_CONSECUTIVE_ERRORS=5

# A workflow command carries one line: escape what would end or corrupt it.
fail() {
  local message="$1"
  message="${message//'%'/'%25'}"
  message="${message//$'\r'/'%0D'}"
  message="${message//$'\n'/'%0A'}"
  echo "::error title=Demofy::$message"
  exit 1
}

set_output() {
  printf '%s=%s\n' "$1" "$2" >>"$OUTPUT_FILE"
}

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required on the runner."
done

# ── Inputs ───────────────────────────────────────────────────────────────────────────────────
KEY="${DEMOFY_API_KEY:-}"
[[ -n "$KEY" ]] || fail "api-key is empty. Add a Demofy API key as a repository secret (e.g. DEMOFY_API_KEY) and pass it as api-key."
echo "::add-mask::$KEY"
# Demofy only treats a dmf_ token as an API key; anything else would be served as an anonymous guest.
[[ "$KEY" == dmf_* ]] || fail "api-key is not a Demofy API key (they start with dmf_). Create one in Demofy under Settings > API keys."
[[ -n "${INPUT_URL:-}" ]] || fail "url is required."
[[ -n "${INPUT_PROMPT:-}" ]] || fail "prompt is required."

WAIT="$(tr '[:upper:]' '[:lower:]' <<<"${INPUT_WAIT:-true}")"
TIMEOUT_MINUTES="${INPUT_TIMEOUT_MINUTES:-60}"
[[ "$TIMEOUT_MINUTES" =~ ^[0-9]+$ ]] || fail "timeout-minutes must be a whole number of minutes, got '$TIMEOUT_MINUTES'."
TIMEOUT_MINUTES=$((10#$TIMEOUT_MINUTES))
((TIMEOUT_MINUTES < 1)) && TIMEOUT_MINUTES=1
((TIMEOUT_MINUTES > 180)) && TIMEOUT_MINUTES=180
TIMEOUT_SECONDS="${DEMOFY_TIMEOUT_SECONDS:-$((TIMEOUT_MINUTES * 60))}"

ARTIFACT_NAME="${INPUT_ARTIFACT_NAME:-}"
ARTIFACT_NAME="${ARTIFACT_NAME%.mp4}"
[[ "$ARTIFACT_NAME" =~ ^[A-Za-z0-9._-]*$ ]] || fail "artifact-name may use only letters, digits, '.', '_' and '-'."

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
(umask 077 && printf 'Authorization: Bearer %s\n' "$KEY" >"$WORK_DIR/auth-header")
unset KEY DEMOFY_API_KEY

# ── HTTP ─────────────────────────────────────────────────────────────────────────────────────
BODY_FILE="$WORK_DIR/body.json"
HEADERS_FILE="$WORK_DIR/headers.txt"
CURL_ERROR_FILE="$WORK_DIR/curl-error.txt"

# api METHOD PATH [JSON_BODY_FILE_NAME] -> prints the HTTP status (000 on a network failure).
# curl runs inside WORK_DIR with relative file names: a native Windows curl under Git Bash does
# not translate a /tmp path that follows curl's @.
api() {
  local method="$1" path="$2" data="${3:-}" code
  local args=(-sS -X "$method" -o body.json -D headers.txt -w '%{http_code}'
    --connect-timeout 15 --max-time 60
    -H @auth-header -H 'Accept: application/json' -H 'User-Agent: demofy-github-action')
  if [[ -n "$data" ]]; then
    args+=(-H 'Content-Type: application/json' --data-binary @"$data")
  fi
  : >"$BODY_FILE"
  : >"$HEADERS_FILE"
  code="$(cd "$WORK_DIR" && curl "${args[@]}" "$BASE_URL$path" 2>curl-error.txt)" || true
  echo "${code:-000}"
}

# A native jq.exe under Git Bash writes CRLF; no value read here may carry the CR.
json() {
  { jq -r "$1" "$BODY_FILE" 2>/dev/null || true; } | tr -d '\r'
}

retry_after() {
  local value
  value="$(grep -i '^retry-after:' "$HEADERS_FILE" 2>/dev/null | tail -n1 | tr -dc '0-9')" || true
  echo "${value:-30}"
}

# The API's own sentence for a refusal: `message` when it has one, else `error`, plus 400 issues.
refusal_sentence() {
  local sentence issues
  sentence="$(json 'if type == "object" then (.message // .error // empty) else empty end')"
  [[ -n "$sentence" ]] || sentence="$(head -c 300 "$BODY_FILE" 2>/dev/null || true)"
  issues="$(json 'if type == "object" and (.issues | type) == "array" then [.issues[] | ((.path // []) | map(tostring) | join(".")) + ": " + (.message // "invalid")] | join("; ") else empty end')"
  [[ -n "$issues" ]] && sentence="$sentence ($issues)"
  echo "$sentence"
}

fail_http() {
  local code="$1" what="$2" sentence
  sentence="$(refusal_sentence)"
  case "$code" in
    401) fail "Demofy refused the API key (401) while $what: $sentence" ;;
    403) fail "Demofy refused the request (403) while $what: $sentence" ;;
    402) fail "This needs a paid Demofy plan (402) while $what: $sentence" ;;
    429) fail "Demofy allowance or rate limit reached (429, retry after $(retry_after)s) while $what: $sentence" ;;
    000) fail "Could not reach $BASE_URL while $what: $(head -c 300 "$CURL_ERROR_FILE" 2>/dev/null || true)" ;;
    *) fail "Demofy answered HTTP $code while $what: $sentence" ;;
  esac
}

# ── Create ───────────────────────────────────────────────────────────────────────────────────
# require_object INPUT_NAME VALUE
require_object() {
  if [[ -n "$2" ]] && ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$2"; then
    fail "$1 must be a JSON object."
  fi
}
require_object look "${INPUT_LOOK:-}"
require_object extra-json "${INPUT_EXTRA_JSON:-}"

jq -n \
  --arg url "$INPUT_URL" \
  --arg prompt "$INPUT_PROMPT" \
  --arg quality "${INPUT_QUALITY:-}" \
  --arg format "${INPUT_FORMAT:-}" \
  --arg captureProfile "${INPUT_CAPTURE_PROFILE:-}" \
  --arg connectionId "${INPUT_CONNECTION_ID:-}" \
  --arg pacing "${INPUT_PACING:-}" \
  --arg captions "${INPUT_CAPTIONS:-}" \
  --arg narration "${INPUT_NARRATION:-}" \
  --arg music "${INPUT_MUSIC:-}" \
  --arg voiceProfileId "${INPUT_VOICE_PROFILE_ID:-}" \
  --arg setupUrl "${INPUT_SETUP_URL:-}" \
  --arg look "${INPUT_LOOK:-}" \
  --arg extra "${INPUT_EXTRA_JSON:-}" \
  '{url: $url, prompt: $prompt, quality: $quality, format: $format, captureProfile: $captureProfile,
    connectionId: $connectionId, pacing: $pacing, captions: $captions, narration: $narration,
    music: $music, voiceProfileId: $voiceProfileId, setupUrl: $setupUrl}
   | with_entries(select(.value != ""))
   + (if $look == "" then {} else {look: ($look | fromjson)} end)
   + (if $extra == "" then {} else ($extra | fromjson) end)' >"$WORK_DIR/request.json"

echo "Creating a Demofy demo of $INPUT_URL"
code="$(api POST /api/jobs request.json)"
[[ "$code" == "202" || "$code" == "200" || "$code" == "201" ]] || fail_http "$code" "creating the job"

JOB_ID="$(json '.id // empty')"
[[ -n "$JOB_ID" ]] || fail "Demofy accepted the job but returned no id."
STATUS="$(json '.status // "queued"')"
PAGE_URL="$BASE_URL$(json '.url // empty')"
[[ "$PAGE_URL" == "$BASE_URL" ]] && PAGE_URL="$BASE_URL/jobs/$JOB_ID"
set_output job-id "$JOB_ID"
set_output page-url "$PAGE_URL"
set_output status "$STATUS"
echo "Job $JOB_ID created ($STATUS): $PAGE_URL"

write_summary() {
  local outcome="$1" detail="${2:-}"
  {
    echo "### Demofy demo: $outcome"
    echo
    echo "| | |"
    echo "| --- | --- |"
    echo "| Job | [\`$JOB_ID\`]($PAGE_URL) |"
    echo "| Status | \`$STATUS\` |"
    echo "| URL | $INPUT_URL |"
    [[ -n "${SHARE_URL:-}" ]] && echo "| Share link | $SHARE_URL |"
    [[ -n "${VIDEO_URL:-}" ]] && echo "| Video | [Download the MP4]($VIDEO_URL) (signed link, valid for 7 days) |"
    [[ -n "${VIDEO_BYTES:-}" ]] && echo "| Size | $VIDEO_BYTES bytes |"
    [[ -n "$detail" ]] && echo "| Detail | $detail |"
    echo
  } >>"$SUMMARY_FILE"
}

if [[ "$WAIT" == "false" ]]; then
  write_summary "created" "Not waited for (wait: false)."
  exit 0
fi

# ── Wait ─────────────────────────────────────────────────────────────────────────────────────
started=$SECONDS
deadline=$((SECONDS + TIMEOUT_SECONDS))
interval="$POLL_INITIAL"
errors=0
last_status=""
while :; do
  if ((SECONDS >= deadline)); then
    set_output status "$STATUS"
    write_summary "timed out" "Still $STATUS after $TIMEOUT_SECONDS s; the job keeps running in Demofy."
    fail "Timed out after $TIMEOUT_SECONDS s waiting for job $JOB_ID (last status: $STATUS). It keeps running in Demofy: $PAGE_URL"
  fi

  code="$(api GET "/api/jobs/$JOB_ID")"
  case "$code" in
    200)
      errors=0
      STATUS="$(json '.status // empty')"
      ;;
    429)
      wait_for="$(retry_after)"
      remaining=$((deadline - SECONDS))
      ((wait_for > remaining)) && wait_for=$((remaining > 0 ? remaining : 1))
      echo "Rate limited while polling; waiting ${wait_for}s."
      sleep "$wait_for"
      continue
      ;;
    000 | 5??)
      errors=$((errors + 1))
      ((errors >= MAX_CONSECUTIVE_ERRORS)) && fail_http "$code" "reading job $JOB_ID"
      echo "Demofy answered HTTP $code while polling ($errors/$MAX_CONSECUTIVE_ERRORS); retrying."
      sleep "$interval"
      continue
      ;;
    *) fail_http "$code" "reading job $JOB_ID" ;;
  esac

  if [[ "$STATUS" != "$last_status" ]]; then
    echo "Status: $STATUS ($((SECONDS - started))s)"
    last_status="$STATUS"
  fi

  sign_in="$(json 'if (.needsSignIn | type) == "array" and (.needsSignIn | length) > 0 then .needsSignIn[0] | "\(.site // "the site"): \(.reason // "sign-in needed") Sign in: \(.signInUrl // "")" else empty end')"
  if [[ -n "$sign_in" ]]; then
    set_output status "$STATUS"
    write_summary "paused for sign-in" "$sign_in"
    fail "Job $JOB_ID is paused for a sign-in, which only a person can give. $sign_in. Or record with a saved connection (connection-id)."
  fi

  case "$STATUS" in
    done) break ;;
    failed)
      error_code="$(json '.errorCode // empty')"
      error_sentence="$(json '.error // "The job failed."')"
      [[ "$(json '.cancelled // false')" == "true" ]] && error_sentence="Stopped: $error_sentence"
      set_output status failed
      set_output error-code "$error_code"
      write_summary "failed" "${error_code:+\`$error_code\`: }$error_sentence"
      fail "Job $JOB_ID failed${error_code:+ ($error_code)}: $error_sentence $PAGE_URL"
      ;;
  esac

  sleep "$interval"
  interval=$((interval * 3 / 2))
  ((interval > POLL_MAX)) && interval="$POLL_MAX"
done

# ── Deliver ──────────────────────────────────────────────────────────────────────────────────
VIDEO_URL="$(json '.video.url // empty')"
DOWNLOAD_URL="$(json '.video.downloadUrl // .video.url // empty')"
SHARE_URL="$(json '.shareUrl // empty')"
set_output status "done"
set_output video-url "$VIDEO_URL"
set_output share-url "$SHARE_URL"
[[ -n "$DOWNLOAD_URL" ]] || fail "Job $JOB_ID is done but has no video URL."

OUT_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/demofy-$JOB_ID"
mkdir -p "$OUT_DIR"
VIDEO_PATH="$OUT_DIR/${ARTIFACT_NAME:-demofy-$JOB_ID}.mp4"
# A signed storage URL: no Authorization header goes with it.
curl -fsSL --retry 3 --connect-timeout 15 --max-time 600 -o "$VIDEO_PATH" "$DOWNLOAD_URL" ||
  fail "Could not download the video of job $JOB_ID."
VIDEO_BYTES="$(wc -c <"$VIDEO_PATH" | tr -d ' ')"
((VIDEO_BYTES > 0)) || fail "The downloaded video of job $JOB_ID is empty."
set_output video-path "$VIDEO_PATH"

write_summary "done"
echo "Video ready after $((SECONDS - started))s: $VIDEO_BYTES bytes at $VIDEO_PATH"
