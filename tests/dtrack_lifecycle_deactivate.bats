#!/usr/bin/env bats
# Tests for dtrack-lifecycle.sh: cmd_deactivate

load test_helper/common

@test "deactivate keeps the KEEP_N newest versions and deactivates the rest" {
    KEEP_N="1"
    mock_curl_enqueue 200 '[
        {"uuid":"v1","version":"1.0.0","active":true},
        {"uuid":"v2","version":"2.0.0","active":true},
        {"uuid":"v3","version":"3.0.0","active":true}
    ]' $'X-Total-Count: 3\r\n'
    mock_curl_enqueue 200 '{"uuid":"v2","active":false}'
    mock_curl_enqueue 200 '{"uuid":"v1","active":false}'

    run cmd_deactivate
    assert_success
    assert_output --partial "Deactivating demo-service@2.0.0"
    assert_output --partial "Deactivating demo-service@1.0.0"
    refute_output --partial "Deactivating demo-service@3.0.0"
    assert_equal "$(mock_curl_call_count)" "3"
}

@test "deactivate excludes KEEP_ACTIVE versions from both deactivation and the KEEP_N count" {
    KEEP_N="1"
    KEEP_ACTIVE="1.0.0"
    mock_curl_enqueue 200 '[
        {"uuid":"v1","version":"1.0.0","active":true},
        {"uuid":"v2","version":"2.0.0","active":true},
        {"uuid":"v3","version":"3.0.0","active":true}
    ]' $'X-Total-Count: 3\r\n'
    mock_curl_enqueue 200 '{"uuid":"v2","active":false}'

    run cmd_deactivate
    assert_success
    assert_output --partial "1.0.0 (uuid: v1) is in KEEP_ACTIVE"
    assert_output --partial "Deactivating demo-service@2.0.0"
    refute_output --partial "Deactivating demo-service@1.0.0"
    refute_output --partial "Deactivating demo-service@3.0.0"
    assert_equal "$(mock_curl_call_count)" "2"
}

@test "deactivate skips versions that are already inactive" {
    KEEP_N="1"
    mock_curl_enqueue 200 '[
        {"uuid":"v1","version":"1.0.0","active":false},
        {"uuid":"v2","version":"2.0.0","active":true}
    ]' $'X-Total-Count: 2\r\n'

    run cmd_deactivate
    assert_success
    assert_output --partial "1.0.0 (uuid: v1) already inactive"
    assert_equal "$(mock_curl_call_count)" "1"
}

@test "deactivate logs a 409 conflict but continues to the next candidate" {
    KEEP_N="0"
    mock_curl_enqueue 200 '[
        {"uuid":"v1","version":"1.0.0","active":true},
        {"uuid":"v2","version":"2.0.0","active":true}
    ]' $'X-Total-Count: 2\r\n'
    mock_curl_enqueue 409 '{"error":"conflict"}'
    mock_curl_enqueue 200 '{"uuid":"v1","active":false}'

    run cmd_deactivate
    assert_success
    assert_output --partial "returned 409 conflict"
    assert_output --partial "Deactivating demo-service@1.0.0"
    assert_equal "$(mock_curl_call_count)" "3"
}

@test "deactivate aborts on a hard PATCH failure" {
    KEEP_N="0"
    mock_curl_enqueue 200 '[
        {"uuid":"v1","version":"1.0.0","active":true},
        {"uuid":"v2","version":"2.0.0","active":true}
    ]' $'X-Total-Count: 2\r\n'
    mock_curl_enqueue 500 '{"error":"boom"}'

    run cmd_deactivate
    assert_failure 1
    assert_output --partial "Failed to deactivate demo-service@2.0.0"
    assert_equal "$(mock_curl_call_count)" "2"
}

@test "deactivate reports when there are no versioned projects" {
    mock_curl_enqueue 200 '[{"uuid":"parent","version":null,"active":true}]' $'X-Total-Count: 1\r\n'

    run cmd_deactivate
    assert_success
    assert_output --partial "No versioned projects found"
    assert_equal "$(mock_curl_call_count)" "1"
}

@test "deactivate reports when every version is within the keep window" {
    KEEP_N="5"
    mock_curl_enqueue 200 '[
        {"uuid":"v1","version":"1.0.0","active":true}
    ]' $'X-Total-Count: 1\r\n'

    run cmd_deactivate
    assert_success
    assert_output --partial "within the keep window (5)"
    assert_equal "$(mock_curl_call_count)" "1"
}

@test "deactivate reports when every remaining version is covered by KEEP_ACTIVE" {
    KEEP_ACTIVE="1.0.0"
    mock_curl_enqueue 200 '[
        {"uuid":"v1","version":"1.0.0","active":true}
    ]' $'X-Total-Count: 1\r\n'

    run cmd_deactivate
    assert_success
    assert_output --partial "covered by KEEP_ACTIVE"
    assert_equal "$(mock_curl_call_count)" "1"
}
