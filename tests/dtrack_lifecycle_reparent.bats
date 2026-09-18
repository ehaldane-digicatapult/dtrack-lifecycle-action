#!/usr/bin/env bats
# Tests for dtrack-lifecycle.sh: cmd_reparent

load test_helper/common

@test "reparent creates the unversioned parent when none exists and reparents orphans" {
    # dtrack_get: no unversioned project present, two versioned orphans
    mock_curl_enqueue 200 '[
        {"uuid":"v1","version":"1.0.0","parent":null},
        {"uuid":"v2","version":"2.0.0","parent":null}
    ]' $'X-Total-Count: 2\r\n'
    # dtrack_put: create the parent
    mock_curl_enqueue 201 '{"uuid":"parent-uuid","name":"demo-service"}'
    # dtrack_patch for each orphan
    mock_curl_enqueue 200 '{"uuid":"v1","parent":{"uuid":"parent-uuid"}}'
    mock_curl_enqueue 200 '{"uuid":"v2","parent":{"uuid":"parent-uuid"}}'

    run cmd_reparent
    assert_success
    assert_output --partial "No unversioned parent found"
    assert_output --partial "Created parent \"demo-service\" with uuid: parent-uuid"
    assert_output --partial "Reparenting demo-service@1.0.0"
    assert_output --partial "Reparenting demo-service@2.0.0"
    assert_equal "$(mock_curl_call_count)" "4"
}

@test "reparent reuses an existing unversioned parent" {
    mock_curl_enqueue 200 '[
        {"uuid":"parent-uuid","version":null,"parent":null},
        {"uuid":"v1","version":"1.0.0","parent":null}
    ]' $'X-Total-Count: 2\r\n'
    mock_curl_enqueue 200 '{"uuid":"v1","parent":{"uuid":"parent-uuid"}}'

    run cmd_reparent
    assert_success
    assert_output --partial "Found existing parent for \"demo-service\" with uuid: parent-uuid"
    refute_output --partial "Created parent"
    assert_equal "$(mock_curl_call_count)" "2"
}

@test "reparent does nothing when there are no orphaned versioned projects" {
    mock_curl_enqueue 200 '[
        {"uuid":"parent-uuid","version":null,"parent":null},
        {"uuid":"v1","version":"1.0.0","parent":{"uuid":"parent-uuid"}}
    ]' $'X-Total-Count: 2\r\n'

    run cmd_reparent
    assert_success
    assert_output --partial "No orphaned versioned projects found"
    assert_equal "$(mock_curl_call_count)" "1"
}

@test "reparent logs a 409 conflict but continues to the next orphan" {
    mock_curl_enqueue 200 '[
        {"uuid":"parent-uuid","version":null,"parent":null},
        {"uuid":"v1","version":"1.0.0","parent":null},
        {"uuid":"v2","version":"2.0.0","parent":null}
    ]' $'X-Total-Count: 3\r\n'
    mock_curl_enqueue 409 '{"error":"conflict"}'
    mock_curl_enqueue 200 '{"uuid":"v2","parent":{"uuid":"parent-uuid"}}'

    run cmd_reparent
    assert_success
    assert_output --partial "returned 409 conflict"
    assert_output --partial "Reparenting demo-service@2.0.0"
    assert_equal "$(mock_curl_call_count)" "3"
}

@test "reparent aborts on a hard PATCH failure" {
    mock_curl_enqueue 200 '[
        {"uuid":"parent-uuid","version":null,"parent":null},
        {"uuid":"v1","version":"1.0.0","parent":null},
        {"uuid":"v2","version":"2.0.0","parent":null}
    ]' $'X-Total-Count: 3\r\n'
    mock_curl_enqueue 500 '{"error":"boom"}'

    run cmd_reparent
    assert_failure 1
    assert_output --partial "Failed to reparent demo-service@1.0.0"
    # second orphan must never be attempted
    assert_equal "$(mock_curl_call_count)" "2"
}

@test "reparent processes multiple comma-delimited project names independently" {
    PROJECT_NAME="svc-a, svc-b"

    mock_curl_enqueue 200 '[
        {"uuid":"parent-a","version":null,"parent":null},
        {"uuid":"a1","version":"1.0.0","parent":null}
    ]' $'X-Total-Count: 2\r\n'
    mock_curl_enqueue 200 '{"uuid":"a1"}'

    mock_curl_enqueue 200 '[
        {"uuid":"parent-b","version":null,"parent":null}
    ]' $'X-Total-Count: 1\r\n'

    run cmd_reparent
    assert_success
    assert_output --partial "Processing project: svc-a"
    assert_output --partial "Processing project: svc-b"
    assert_output --partial "No orphaned versioned projects found for \"svc-b\""
}
