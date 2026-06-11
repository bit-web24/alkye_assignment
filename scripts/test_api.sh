#!/usr/bin/env bash
# =============================================================================
#  Alkye Assignment — Automated API Test Suite
# =============================================================================

# Do NOT use set -e — we handle errors explicitly so curl failures show nicely
set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────
BASE_URL="${BASE_URL:-http://localhost:8000}"
VERBOSE="${VERBOSE:-0}"    # set to 1 to show raw curl output

# ─── ANSI Theme ───────────────────────────────────────────────────────────────
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"

# Backgrounds / colours
BG_HEADER="\033[48;5;17m"      # deep navy
BG_SECTION="\033[48;5;235m"   # dark grey
FG_TITLE="\033[38;5;39m"       # electric blue
FG_STEP="\033[38;5;213m"       # lavender/pink
FG_URL="\033[38;5;87m"         # cyan
FG_METHOD="\033[38;5;220m"     # amber
FG_KEY="\033[38;5;147m"        # soft purple
FG_VALUE="\033[38;5;222m"      # warm yellow
FG_CAPTURE="\033[38;5;118m"    # bright green
FG_PASS="\033[38;5;46m"        # green
FG_FAIL="\033[38;5;196m"       # red
FG_WARN="\033[38;5;214m"       # orange
FG_DIM="\033[38;5;244m"        # grey
FG_JSON_KEY="\033[38;5;75m"    # blue
FG_JSON_STR="\033[38;5;150m"   # sage green
FG_JSON_NUM="\033[38;5;215m"   # peach
FG_JSON_BOOL="\033[38;5;204m"  # salmon

# ─── Counters ─────────────────────────────────────────────────────────────────
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
STEP=0

# ─── Captured values (passed between steps) ───────────────────────────────────
CAPTURED_LOGIN_CHALLENGE_ID=""
CAPTURED_OTP_CODE=""
CAPTURED_ADMIN_TOKEN=""
CAPTURED_USER_TOKEN=""
CAPTURED_TASK_ID=""
CAPTURED_USER_ID=""

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Pretty-print JSON (colourised inline, no jq required but uses it if present)
pretty_json() {
    local json="$1"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r '.' 2>/dev/null | while IFS= read -r line; do
            # Colorise keys, strings, numbers, booleans
            line="${line//\": \"/\"${FG_JSON_KEY}&${RESET}\"}"
            echo -e "    ${FG_DIM}│${RESET}  $line"
        done
    else
        # Fallback: minimal manual coloring
        echo "$json" | sed 's/,/,\n/g; s/{/{\n/g; s/}/\n}/g' | while IFS= read -r line; do
            echo -e "    ${FG_DIM}│${RESET}  ${FG_VALUE}$line${RESET}"
        done
    fi
}

# Print a top-level banner
banner() {
    echo ""
    echo -e "${BG_HEADER}${BOLD}${FG_TITLE}                                                                 ${RESET}"
    echo -e "${BG_HEADER}${BOLD}${FG_TITLE}    ██████  API TEST SUITE  ●  Alkye Assignment                 ${RESET}"
    echo -e "${BG_HEADER}${BOLD}${FG_TITLE}    Target: ${FG_URL}${BASE_URL}${FG_TITLE}                                       ${RESET}"
    echo -e "${BG_HEADER}${BOLD}${FG_TITLE}                                                                 ${RESET}"
    echo ""
}

# Print a section header
section() {
    local title="$1"
    echo ""
    echo -e "${BG_SECTION}${BOLD}${FG_STEP}  ◈  ${title}  ${RESET}"
    echo -e "${FG_DIM}  $(printf '─%.0s' {1..65})${RESET}"
}

# Print step header
step_header() {
    local method="$1"
    local path="$2"
    local desc="$3"
    STEP=$((STEP + 1))
    echo ""
    echo -e "  ${BOLD}${FG_STEP}STEP ${STEP}${RESET}  ${FG_DIM}─────────────────────────────────────────────────${RESET}"
    echo -e "  ${BOLD}${FG_METHOD}${method}${RESET}  ${FG_URL}${BASE_URL}${path}${RESET}"
    echo -e "  ${FG_DIM}▸ ${desc}${RESET}"
    echo ""
}

# Print request body
print_request() {
    local body="$1"
    if [[ -n "$body" ]]; then
        echo -e "  ${BOLD}${FG_KEY}  REQUEST BODY:${RESET}"
        pretty_json "$body"
        echo ""
    fi
}

# Print request header being sent
print_auth_header() {
    local token="$1"
    local short="${token:0:40}..."
    echo -e "  ${BOLD}${FG_KEY}  REQUEST HEADER:${RESET}"
    echo -e "    ${FG_DIM}│${RESET}  ${FG_KEY}Authorization:${RESET} ${FG_VALUE}Bearer ${short}${RESET}"
    echo ""
}

# Print HTTP response
print_response() {
    local status="$1"
    local body="$2"
    local color
    if [[ "$status" -ge 200 && "$status" -lt 300 ]]; then
        color="$FG_PASS"
    elif [[ "$status" -ge 400 && "$status" -lt 500 ]]; then
        color="$FG_WARN"
    else
        color="$FG_FAIL"
    fi
    echo -e "  ${BOLD}${FG_KEY}  RESPONSE:${RESET}  ${color}${BOLD}HTTP ${status}${RESET}"
    pretty_json "$body"
    echo ""
}

# Print a captured value being forwarded to next step
print_capture() {
    local label="$1"
    local value="$2"
    # Truncate long values (e.g. JWT)
    local display="$value"
    if [[ ${#value} -gt 80 ]]; then
        display="${value:0:77}..."
    fi
    echo -e "  ${BOLD}${FG_CAPTURE}  ✦ CAPTURED${RESET}  ${FG_KEY}${label}${RESET} ${FG_DIM}→${RESET} ${FG_VALUE}${display}${RESET}"
}

# Assert: pass/fail
assert() {
    local label="$1"
    local condition="$2"   # "true" or "false"
    TESTS_RUN=$((TESTS_RUN + 1))
    if [[ "$condition" == "true" ]]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo -e "  ${FG_PASS}  ✔  ${label}${RESET}"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        echo -e "  ${FG_FAIL}  ✘  ${label}${RESET}"
    fi
}

# Perform a curl request; sets HTTP_STATUS and HTTP_BODY globals
do_request() {
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local token="${4:-}"

    local curl_args=(-s -w "\n%{http_code}" --connect-timeout 5 -X "$method" "${BASE_URL}${path}" \
        -H "Content-Type: application/json")

    if [[ -n "$token" ]]; then
        curl_args+=(-H "Authorization: Bearer ${token}")
    fi

    if [[ -n "$body" ]]; then
        curl_args+=(-d "$body")
    fi

    local raw
    local curl_exit
    raw=$(curl "${curl_args[@]}" 2>&1) || curl_exit=$?

    if [[ "${curl_exit:-0}" -ne 0 ]]; then
        HTTP_STATUS="000"
        HTTP_BODY="{\"error\":\"curl failed — is the server running at ${BASE_URL}? (curl exit ${curl_exit:-?})\"}"
        return 0
    fi

    HTTP_STATUS=$(echo "$raw" | tail -n1)
    HTTP_BODY=$(echo "$raw" | head -n -1)

    # Guard: if status is empty or non-numeric, treat as connection failure
    if ! [[ "$HTTP_STATUS" =~ ^[0-9]{3}$ ]]; then
        HTTP_BODY="{\"error\":\"no HTTP response — server may be down at ${BASE_URL}\"}"
        HTTP_STATUS="000"
    fi
}

# Extract a JSON field value (no jq needed, but uses it if available)
json_field() {
    local json="$1"
    local field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".${field} // empty" 2>/dev/null
    else
        # Fallback: basic grep-based extraction
        echo "$json" | grep -o "\"${field}\":[[:space:]]*\"[^\"]*\"" \
            | sed "s/\"${field}\":[[:space:]]*\"//;s/\"//"
    fi
}

json_field_num() {
    local json="$1"
    local field="$2"
    if command -v jq &>/dev/null; then
        echo "$json" | jq -r ".${field} // empty" 2>/dev/null
    else
        echo "$json" | grep -o "\"${field}\":[[:space:]]*[0-9]*" \
            | sed "s/\"${field}\":[[:space:]]*//"
    fi
}

# ─── Final summary ─────────────────────────────────────────────────────────────
print_summary() {
    echo ""
    echo -e "${FG_DIM}  $(printf '═%.0s' {1..65})${RESET}"
    echo ""
    echo -e "  ${BOLD}${FG_TITLE}  TEST SUMMARY${RESET}"
    echo ""
    echo -e "  ${FG_KEY}  Total   ${RESET}${BOLD}${FG_VALUE}${TESTS_RUN}${RESET}"
    echo -e "  ${FG_PASS}  Passed  ${RESET}${BOLD}${FG_PASS}${TESTS_PASSED}${RESET}"
    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "  ${FG_FAIL}  Failed  ${RESET}${BOLD}${FG_FAIL}${TESTS_FAILED}${RESET}"
    else
        echo -e "  ${FG_DIM}  Failed  ${RESET}${FG_DIM}0${RESET}"
    fi
    echo ""
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "  ${BG_HEADER}${BOLD}${FG_PASS}  ✔  ALL TESTS PASSED  ${RESET}"
    else
        echo -e "  ${BG_HEADER}${BOLD}${FG_FAIL}  ✘  ${TESTS_FAILED} TEST(S) FAILED  ${RESET}"
    fi
    echo ""
}

# =============================================================================
#  TEST CASES
# =============================================================================

banner

# ─── Pre-flight: check server is reachable ───────────────────────────────────
echo -e "  ${FG_DIM}Checking server at ${BASE_URL} ...${RESET}"
do_request "GET" "/dev/email-logs/latest"
if [[ "$HTTP_STATUS" == "000" ]]; then
    echo ""
    echo -e "  ${FG_FAIL}${BOLD}  ✘  SERVER UNREACHABLE${RESET}  ${FG_WARN}${BASE_URL}${RESET}"
    echo -e "  ${FG_DIM}  Make sure the server is running:  cargo run${RESET}"
    echo -e "  ${FG_DIM}  Or override:  BASE_URL=http://localhost:PORT ./scripts/test_api.sh${RESET}"
    echo ""
    exit 1
fi
echo -e "  ${FG_PASS}  ✔  Server is up (HTTP ${HTTP_STATUS})${RESET}"

# ─────────────────────────────────────────────────────────────────────────────
section "SETUP — SEED USERS"
# ─────────────────────────────────────────────────────────────────────────────

step_header "POST" "/seed/users" "Seed admin + regular user into the database"
do_request "POST" "/seed/users"
print_response "$HTTP_STATUS" "$HTTP_BODY"

# Accept both 201 (seeded) and 409 (already seeded)
if [[ "$HTTP_STATUS" == "201" || "$HTTP_STATUS" == "409" ]]; then
    assert "Seed endpoint returns 201 or 409" "true"
else
    assert "Seed endpoint returns 201 or 409 (got ${HTTP_STATUS})" "false"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "AUTH FLOW — ADMIN LOGIN → OTP → JWT"
# ─────────────────────────────────────────────────────────────────────────────

# STEP: Admin login
ADMIN_CREDS='{"email":"admin@example.com","password":"admin123"}'
step_header "POST" "/auth/login" "Submit admin credentials → receive login_challenge_id"
print_request "$ADMIN_CREDS"
do_request "POST" "/auth/login" "$ADMIN_CREDS"
print_response "$HTTP_STATUS" "$HTTP_BODY"

assert "Admin login returns 200" "$([[ "$HTTP_STATUS" == "200" ]] && echo true || echo false)"
assert "Response has requires_2fa=true" "$([[ "$(json_field "$HTTP_BODY" requires_2fa)" == "true" ]] && echo true || echo false)"

CAPTURED_LOGIN_CHALLENGE_ID=$(json_field "$HTTP_BODY" "login_challenge_id")
assert "login_challenge_id is present" "$([[ -n "$CAPTURED_LOGIN_CHALLENGE_ID" ]] && echo true || echo false)"
print_capture "login_challenge_id" "$CAPTURED_LOGIN_CHALLENGE_ID"

# STEP: Fetch OTP from dev email log
echo ""
step_header "GET" "/dev/email-logs/latest" "Read OTP code from the dev email log endpoint"
do_request "GET" "/dev/email-logs/latest"
print_response "$HTTP_STATUS" "$HTTP_BODY"

assert "Email log endpoint returns 200" "$([[ "$HTTP_STATUS" == "200" ]] && echo true || echo false)"

CAPTURED_OTP_CODE=$(json_field "$HTTP_BODY" "code")
assert "OTP code is present in email log" "$([[ -n "$CAPTURED_OTP_CODE" ]] && echo true || echo false)"
print_capture "otp_code" "$CAPTURED_OTP_CODE"

# Verify challenge IDs match
EMAIL_CHALLENGE=$(json_field "$HTTP_BODY" "login_challenge_id")
assert "Email log challenge_id matches login challenge_id" \
    "$([[ "$EMAIL_CHALLENGE" == "$CAPTURED_LOGIN_CHALLENGE_ID" ]] && echo true || echo false)"

# STEP: Verify OTP → get JWT
VERIFY_PAYLOAD=$(printf '{"login_challenge_id":"%s","code":"%s"}' \
    "$CAPTURED_LOGIN_CHALLENGE_ID" "$CAPTURED_OTP_CODE")

step_header "POST" "/auth/verify-2fa" "Submit challenge_id + OTP code → receive Bearer JWT"
print_request "$VERIFY_PAYLOAD"
echo -e "  ${BOLD}${FG_KEY}  PASSING CAPTURED VALUES:${RESET}"
print_capture "login_challenge_id" "$CAPTURED_LOGIN_CHALLENGE_ID"
print_capture "otp_code" "$CAPTURED_OTP_CODE"
echo ""
do_request "POST" "/auth/verify-2fa" "$VERIFY_PAYLOAD"
print_response "$HTTP_STATUS" "$HTTP_BODY"

assert "2FA verify returns 200" "$([[ "$HTTP_STATUS" == "200" ]] && echo true || echo false)"
assert "Response token_type is Bearer" "$([[ "$(json_field "$HTTP_BODY" token_type)" == "Bearer" ]] && echo true || echo false)"

CAPTURED_ADMIN_TOKEN=$(json_field "$HTTP_BODY" "token")
assert "Admin JWT token is present" "$([[ -n "$CAPTURED_ADMIN_TOKEN" ]] && echo true || echo false)"
print_capture "admin_jwt" "$CAPTURED_ADMIN_TOKEN"

# ─────────────────────────────────────────────────────────────────────────────
section "AUTH FLOW — REGULAR USER LOGIN → OTP → JWT"
# ─────────────────────────────────────────────────────────────────────────────

USER_CREDS='{"email":"user@example.com","password":"jamesbond123"}'
step_header "POST" "/auth/login" "Submit regular user credentials"
print_request "$USER_CREDS"
do_request "POST" "/auth/login" "$USER_CREDS"
print_response "$HTTP_STATUS" "$HTTP_BODY"

assert "User login returns 200" "$([[ "$HTTP_STATUS" == "200" ]] && echo true || echo false)"
USER_CHALLENGE_ID=$(json_field "$HTTP_BODY" "login_challenge_id")
assert "User login_challenge_id is present" "$([[ -n "$USER_CHALLENGE_ID" ]] && echo true || echo false)"
print_capture "user_login_challenge_id" "$USER_CHALLENGE_ID"

step_header "GET" "/dev/email-logs/latest" "Read OTP for regular user"
do_request "GET" "/dev/email-logs/latest"
print_response "$HTTP_STATUS" "$HTTP_BODY"

USER_OTP=$(json_field "$HTTP_BODY" "code")
assert "User OTP code is present" "$([[ -n "$USER_OTP" ]] && echo true || echo false)"
print_capture "user_otp_code" "$USER_OTP"

USER_VERIFY=$(printf '{"login_challenge_id":"%s","code":"%s"}' "$USER_CHALLENGE_ID" "$USER_OTP")
step_header "POST" "/auth/verify-2fa" "Verify user OTP → get user JWT"
print_request "$USER_VERIFY"
echo -e "  ${BOLD}${FG_KEY}  PASSING CAPTURED VALUES:${RESET}"
print_capture "login_challenge_id" "$USER_CHALLENGE_ID"
print_capture "otp_code" "$USER_OTP"
echo ""
do_request "POST" "/auth/verify-2fa" "$USER_VERIFY"
print_response "$HTTP_STATUS" "$HTTP_BODY"

assert "User 2FA verify returns 200" "$([[ "$HTTP_STATUS" == "200" ]] && echo true || echo false)"
CAPTURED_USER_TOKEN=$(json_field "$HTTP_BODY" "token")
CAPTURED_USER_ID=$(json_field_num "$HTTP_BODY" "user_id") # not in response directly
assert "User JWT token is present" "$([[ -n "$CAPTURED_USER_TOKEN" ]] && echo true || echo false)"
print_capture "user_jwt" "$CAPTURED_USER_TOKEN"

# ─────────────────────────────────────────────────────────────────────────────
section "NEGATIVE AUTH TESTS"
# ─────────────────────────────────────────────────────────────────────────────

step_header "POST" "/auth/login" "Wrong password → should return 401"
WRONG_CREDS='{"email":"admin@example.com","password":"wrongpassword"}'
print_request "$WRONG_CREDS"
do_request "POST" "/auth/login" "$WRONG_CREDS"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Wrong password returns 401" "$([[ "$HTTP_STATUS" == "401" ]] && echo true || echo false)"

step_header "POST" "/auth/verify-2fa" "Wrong OTP code → should return 401"
WRONG_OTP=$(printf '{"login_challenge_id":"%s","code":"000000"}' "$CAPTURED_LOGIN_CHALLENGE_ID")
print_request "$WRONG_OTP"
do_request "POST" "/auth/verify-2fa" "$WRONG_OTP"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Wrong OTP returns 401" "$([[ "$HTTP_STATUS" == "401" ]] && echo true || echo false)"

step_header "POST" "/auth/verify-2fa" "Replayed (already used) OTP → should return 401"
REPLAY_PAYLOAD=$(printf '{"login_challenge_id":"%s","code":"%s"}' \
    "$CAPTURED_LOGIN_CHALLENGE_ID" "$CAPTURED_OTP_CODE")
print_request "$REPLAY_PAYLOAD"
do_request "POST" "/auth/verify-2fa" "$REPLAY_PAYLOAD"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Replayed OTP returns 401 (single-use enforcement)" "$([[ "$HTTP_STATUS" == "401" ]] && echo true || echo false)"

# ─────────────────────────────────────────────────────────────────────────────
section "TASK MANAGEMENT — ADMIN OPERATIONS"
# ─────────────────────────────────────────────────────────────────────────────

echo -e "  ${BOLD}${FG_KEY}  USING CAPTURED VALUE:${RESET}"
print_capture "admin_jwt" "$CAPTURED_ADMIN_TOKEN"
echo ""

TASK_PAYLOAD='{"title":"Test Task from API Script","description":"Automated test task"}'
step_header "POST" "/tasks" "Admin creates a new task (requires Bearer token)"
print_auth_header "$CAPTURED_ADMIN_TOKEN"
print_request "$TASK_PAYLOAD"
do_request "POST" "/tasks" "$TASK_PAYLOAD" "$CAPTURED_ADMIN_TOKEN"
print_response "$HTTP_STATUS" "$HTTP_BODY"

assert "Create task returns 201" "$([[ "$HTTP_STATUS" == "201" ]] && echo true || echo false)"
assert "Task has title field" "$([[ -n "$(json_field "$HTTP_BODY" title)" ]] && echo true || echo false)"
assert "Task status is 'open'" "$([[ "$(json_field "$HTTP_BODY" status)" == "open" ]] && echo true || echo false)"

CAPTURED_TASK_ID=$(json_field_num "$HTTP_BODY" "id")
assert "Task ID captured" "$([[ -n "$CAPTURED_TASK_ID" ]] && echo true || echo false)"
print_capture "task_id" "$CAPTURED_TASK_ID"

# Get user ID from DB indirectly — user@example.com is always id=2 from seed
CAPTURED_USER_ID=2
print_capture "user_id (seed default)" "$CAPTURED_USER_ID"

# Assign task
ASSIGN_PAYLOAD=$(printf '{"task_id":%s,"user_id":%s}' "$CAPTURED_TASK_ID" "$CAPTURED_USER_ID")
step_header "POST" "/tasks/assign" "Admin assigns task to regular user"
print_auth_header "$CAPTURED_ADMIN_TOKEN"
print_request "$ASSIGN_PAYLOAD"
echo -e "  ${BOLD}${FG_KEY}  PASSING CAPTURED VALUES:${RESET}"
print_capture "task_id" "$CAPTURED_TASK_ID"
print_capture "user_id" "$CAPTURED_USER_ID"
echo ""
do_request "POST" "/tasks/assign" "$ASSIGN_PAYLOAD" "$CAPTURED_ADMIN_TOKEN"
print_response "$HTTP_STATUS" "$HTTP_BODY"

assert "Assign task returns 200" "$([[ "$HTTP_STATUS" == "200" ]] && echo true || echo false)"
assert "assigned_to_id matches user" \
    "$([[ "$(json_field_num "$HTTP_BODY" assigned_to_id)" == "$CAPTURED_USER_ID" ]] && echo true || echo false)"

# ─────────────────────────────────────────────────────────────────────────────
section "TASK MANAGEMENT — USER OPERATIONS"
# ─────────────────────────────────────────────────────────────────────────────

echo -e "  ${BOLD}${FG_KEY}  USING CAPTURED VALUE:${RESET}"
print_capture "user_jwt" "$CAPTURED_USER_TOKEN"
echo ""

step_header "GET" "/tasks/view-my-tasks" "Regular user views their assigned tasks"
print_auth_header "$CAPTURED_USER_TOKEN"
do_request "GET" "/tasks/view-my-tasks" "" "$CAPTURED_USER_TOKEN"
print_response "$HTTP_STATUS" "$HTTP_BODY"

assert "View my tasks returns 200" "$([[ "$HTTP_STATUS" == "200" ]] && echo true || echo false)"
assert "Response is a JSON array" "$([[ "$HTTP_BODY" == \[* ]] && echo true || echo false)"

# ─────────────────────────────────────────────────────────────────────────────
section "NEGATIVE AUTHORIZATION TESTS"
# ─────────────────────────────────────────────────────────────────────────────

step_header "POST" "/tasks" "Regular user tries to create task → should return 403"
print_auth_header "$CAPTURED_USER_TOKEN"
print_request "$TASK_PAYLOAD"
do_request "POST" "/tasks" "$TASK_PAYLOAD" "$CAPTURED_USER_TOKEN"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Non-admin create task returns 403" "$([[ "$HTTP_STATUS" == "403" ]] && echo true || echo false)"

step_header "POST" "/tasks/assign" "Regular user tries to assign task → should return 403"
print_auth_header "$CAPTURED_USER_TOKEN"
print_request "$ASSIGN_PAYLOAD"
do_request "POST" "/tasks/assign" "$ASSIGN_PAYLOAD" "$CAPTURED_USER_TOKEN"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Non-admin assign task returns 403" "$([[ "$HTTP_STATUS" == "403" ]] && echo true || echo false)"

step_header "GET" "/tasks/view-my-tasks" "No token → should return 401"
do_request "GET" "/tasks/view-my-tasks"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Missing token returns 401" "$([[ "$HTTP_STATUS" == "401" ]] && echo true || echo false)"

step_header "GET" "/tasks/view-my-tasks" "Malformed token → should return 401"
do_request "GET" "/tasks/view-my-tasks" "" "not.a.valid.jwt"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Invalid token returns 401" "$([[ "$HTTP_STATUS" == "401" ]] && echo true || echo false)"

step_header "POST" "/tasks" "Empty title → should return 400"
print_auth_header "$CAPTURED_ADMIN_TOKEN"
EMPTY_TITLE='{"title":"   ","description":"test"}'
print_request "$EMPTY_TITLE"
do_request "POST" "/tasks" "$EMPTY_TITLE" "$CAPTURED_ADMIN_TOKEN"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Empty title returns 400" "$([[ "$HTTP_STATUS" == "400" ]] && echo true || echo false)"

step_header "POST" "/tasks/assign" "Non-existent task → should return 404"
print_auth_header "$CAPTURED_ADMIN_TOKEN"
MISSING_TASK='{"task_id":999999,"user_id":1}'
print_request "$MISSING_TASK"
do_request "POST" "/tasks/assign" "$MISSING_TASK" "$CAPTURED_ADMIN_TOKEN"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Non-existent task returns 404" "$([[ "$HTTP_STATUS" == "404" ]] && echo true || echo false)"

step_header "POST" "/tasks/assign" "Non-existent assignee → should return 404"
print_auth_header "$CAPTURED_ADMIN_TOKEN"
MISSING_USER=$(printf '{"task_id":%s,"user_id":999999}' "$CAPTURED_TASK_ID")
print_request "$MISSING_USER"
do_request "POST" "/tasks/assign" "$MISSING_USER" "$CAPTURED_ADMIN_TOKEN"
print_response "$HTTP_STATUS" "$HTTP_BODY"
assert "Non-existent assignee returns 404" "$([[ "$HTTP_STATUS" == "404" ]] && echo true || echo false)"

# ─────────────────────────────────────────────────────────────────────────────
print_summary

# Exit with failure if any tests failed
if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
