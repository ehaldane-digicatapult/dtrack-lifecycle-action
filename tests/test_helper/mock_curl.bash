#!/usr/bin/env bash
# Sequential FIFO mock for curl, used to unit-test dtrack-lifecycle.sh
# without making real HTTP requests.
#
# dtrack-lifecycle.sh always invokes curl via command substitution
# (e.g. `http_code=$(curl ...)`), which runs in a subshell. Any state a
# mock keeps in ordinary bash variables/arrays would be mutated only in
# that subshell and lost once it exits, so the queue below is backed by
# a temp directory instead of in-process variables.
#
# Usage in a test:
#   mock_curl_reset
#   mock_curl_enqueue 200 '[{"uuid":"abc"}]'
#   mock_curl_enqueue 200 '[]' $'X-Total-Count: 0\r\n'
#   run cmd_reparent
#   mock_curl_call_count   # => number of curl invocations made

mock_curl_reset() {
    [[ -n "${MOCK_CURL_DIR:-}" && -d "$MOCK_CURL_DIR" ]] && rm -rf "$MOCK_CURL_DIR"
    MOCK_CURL_DIR=$(mktemp -d)
    mkdir -p "$MOCK_CURL_DIR/queue"
    printf '0' > "$MOCK_CURL_DIR/enqueued"
    printf '0' > "$MOCK_CURL_DIR/consumed"
    : > "$MOCK_CURL_DIR/calls"
}

# mock_curl_enqueue HTTP_CODE BODY [HEADERS]
#   HTTP_CODE - status code curl should report via its -w output
#   BODY      - content written to the file passed via -o
#   HEADERS   - content written to the file passed via -D, if any
#               (ignored for calls that don't request response headers)
mock_curl_enqueue() {
    local n
    n=$(($(< "$MOCK_CURL_DIR/enqueued") + 1))
    printf '%s' "$n" > "$MOCK_CURL_DIR/enqueued"
    printf '%s' "$1" > "$MOCK_CURL_DIR/queue/$n.code"
    printf '%s' "$2" > "$MOCK_CURL_DIR/queue/$n.body"
    printf '%s' "${3:-}" > "$MOCK_CURL_DIR/queue/$n.headers"
}

# mock_curl_call_count
#   Prints the number of times the curl mock has been invoked (whether
#   or not a queued response was available for the call).
mock_curl_call_count() {
    wc -l < "$MOCK_CURL_DIR/calls" | tr -d ' '
}

# mock_curl_calls
#   Prints one "METHOD URL" per line, in call order.
mock_curl_calls() {
    cat "$MOCK_CURL_DIR/calls"
}

# Overrides the real curl for the lifetime of the sourcing shell.
curl() {
    local args=("$@")
    local out_file="" headers_file="" method="GET" url=""
    local i=0

    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            -o) out_file="${args[$((i + 1))]}"; i=$((i + 2)) ;;
            -D) headers_file="${args[$((i + 1))]}"; i=$((i + 2)) ;;
            -X) method="${args[$((i + 1))]}"; i=$((i + 2)) ;;
            -H | -d | -w) i=$((i + 2)) ;;
            -s) i=$((i + 1)) ;;
            *) url="${args[$i]}"; i=$((i + 1)) ;;
        esac
    done

    printf '%s %s\n' "$method" "$url" >> "$MOCK_CURL_DIR/calls"

    local consumed total idx
    consumed=$(< "$MOCK_CURL_DIR/consumed")
    total=$(< "$MOCK_CURL_DIR/enqueued")
    idx=$((consumed + 1))

    if [[ "$idx" -gt "$total" ]]; then
        printf 'mock_curl: no queued response left for %s %s\n' "$method" "$url" >&2
        return 1
    fi
    printf '%s' "$idx" > "$MOCK_CURL_DIR/consumed"

    local code body headers
    code=$(< "$MOCK_CURL_DIR/queue/$idx.code")
    body=$(< "$MOCK_CURL_DIR/queue/$idx.body")
    headers=$(< "$MOCK_CURL_DIR/queue/$idx.headers")

    [[ -n "$out_file" ]] && printf '%s' "$body" > "$out_file"
    [[ -n "$headers_file" ]] && printf '%s' "$headers" > "$headers_file"

    printf '%s' "$code"
}
