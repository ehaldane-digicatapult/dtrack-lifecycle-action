#!/usr/bin/env bats
# Tests for dtrack-lifecycle.sh: env/argument validation, usage, the
# is_kept_alive predicate, and the HTTP pagination helpers.

load test_helper/common

@test "validate_env fails when DTRACK_URI is unset" {
    unset DTRACK_URI
    run validate_env
    assert_failure 1
    assert_output --partial "DTRACK_URI is not set"
}

@test "validate_env fails when API_KEY is unset" {
    unset API_KEY
    run validate_env
    assert_failure 1
    assert_output --partial "API_KEY is not set"
}

@test "validate_env fails when PROJECT_NAME is unset" {
    unset PROJECT_NAME
    run validate_env
    assert_failure 1
    assert_output --partial "PROJECT_NAME is not set"
}

@test "validate_env reports all missing vars at once" {
    unset DTRACK_URI API_KEY PROJECT_NAME
    run validate_env
    assert_failure 1
    assert_output --partial "DTRACK_URI is not set"
    assert_output --partial "API_KEY is not set"
    assert_output --partial "PROJECT_NAME is not set"
}

@test "validate_env strips a trailing slash from DTRACK_URI" {
    DTRACK_URI="https://dtrack.example.com/"
    validate_env
    assert_equal "$DTRACK_URI" "https://dtrack.example.com"
}

@test "validate_env succeeds and leaves a slash-free DTRACK_URI untouched" {
    DTRACK_URI="https://dtrack.example.com"
    run validate_env
    assert_success
    assert_equal "$DTRACK_URI" "https://dtrack.example.com"
}

@test "usage exits 1 and documents both subcommands" {
    run usage
    assert_failure 1
    assert_output --partial "reparent"
    assert_output --partial "deactivate"
    assert_output --partial "DTRACK_URI"
}

@test "is_kept_alive returns true for a version in KEEP_ACTIVE_LIST" {
    KEEP_ACTIVE_LIST=("1.2.3" "2.0.0-lts")
    run is_kept_alive "1.2.3"
    assert_success
}

@test "is_kept_alive returns false for a version not in KEEP_ACTIVE_LIST" {
    KEEP_ACTIVE_LIST=("1.2.3" "2.0.0-lts")
    run is_kept_alive "9.9.9"
    assert_failure
}

@test "is_kept_alive returns false when KEEP_ACTIVE_LIST is empty" {
    KEEP_ACTIVE_LIST=()
    run is_kept_alive "1.2.3"
    assert_failure
}

@test "is_kept_alive does not raise unbound variable under set -u with an empty KEEP_ACTIVE_LIST" {
    # Regression test for bash < 4.4 (e.g. macOS's stock /bin/bash 3.2).
    KEEP_ACTIVE_LIST=()
    run bash -c '
        set -u
        source "'"${BATS_TEST_DIRNAME}"'/../src/dtrack-lifecycle.sh"
        KEEP_ACTIVE_LIST=()
        is_kept_alive "1.2.3"
    '
    assert_failure
    refute_output --partial "unbound variable"
}

@test "dtrack_get_page returns the body and total count on HTTP 200" {
    mock_curl_enqueue 200 '[{"uuid":"a"}]' $'X-Total-Count: 1\r\n'
    run dtrack_get_page "demo-service" 1
    assert_success
    assert_line --index 0 "1"
    assert_line --index 1 '[{"uuid":"a"}]'
}

@test "dtrack_get_page fails and logs the response body on a non-200" {
    mock_curl_enqueue 500 '{"error":"boom"}'
    run dtrack_get_page "demo-service" 1
    assert_failure 1
    assert_output --partial "returned HTTP 500"
    assert_output --partial "boom"
}

@test "dtrack_get merges a single page of results" {
    mock_curl_enqueue 200 '[{"uuid":"a"},{"uuid":"b"}]' $'X-Total-Count: 2\r\n'
    run dtrack_get "demo-service"
    assert_success
    assert_equal "$(printf '%s' "$output" | jq -c 'sort_by(.uuid)')" \
        '[{"uuid":"a"},{"uuid":"b"}]'
}

@test "dtrack_get fetches every page indicated by X-Total-Count" {
    # page size is 100, so total_count=150 implies 2 pages
    mock_curl_enqueue 200 "$(jq -nc '[range(100) | {uuid: ("p1-" + (. | tostring))}]')" $'X-Total-Count: 150\r\n'
    mock_curl_enqueue 200 "$(jq -nc '[range(50) | {uuid: ("p2-" + (. | tostring))}]')" $'X-Total-Count: 150\r\n'

    run dtrack_get "demo-service"
    assert_success
    assert_equal "$(printf '%s' "$output" | jq 'length')" "150"
    assert_equal "$(mock_curl_call_count)" "2"
}

@test "dtrack_get falls back to paging until an empty page when the header is missing" {
    mock_curl_enqueue 200 "$(jq -nc '[range(100) | {uuid: ("p1-" + (. | tostring))}]')"
    mock_curl_enqueue 200 '[]'

    run dtrack_get "demo-service"
    assert_success
    assert_output --partial "X-Total-Count header missing or invalid"
    assert_equal "$(mock_curl_call_count)" "2"
}
