#!/usr/bin/env bash
set -euo pipefail

# dtrack-lifecycle.sh
#
# Manages project lifecycle in a Dependency-Track instance via its REST API.
#
# Subcommands:
#   reparent    Assign orphaned versioned projects to their unversioned parent.
#               Creates the unversioned parent project if one does not exist.
#   deactivate  Deactivate all but the KEEP_N most recent (by semver) versions.
#
# Environment variables:
#   DTRACK_URI     Base URL of the Dependency-Track instance (required)
#                  e.g. https://dtrack.example.com
#   API_KEY        Dependency-Track API key (required)
#   PROJECT_NAME   Comma-delimited list of project names to operate on (required)
#   KEEP_N         Number of versions to keep active; deactivate subcommand only
#                  (default: 1)
#   KEEP_ACTIVE    Comma-delimited list of versions to never deactivate;
#                  deactivate subcommand only (default: none). These versions
#                  are excluded from the KEEP_N ranking entirely. They do
#                  not consume a slot in the "N most recent" count. Versions
#                  listed here that are already inactive are left untouched
#                  (KEEP_ACTIVE prevents immediate deactivation; it does not
#                  reactivate anything).

DTRACK_URI="${DTRACK_URI:-}"
API_KEY="${API_KEY:-}"
PROJECT_NAME="${PROJECT_NAME:-}"
KEEP_N="${KEEP_N:-1}"
KEEP_ACTIVE="${KEEP_ACTIVE:-}"

# Dependency check

check_deps() {
    local cmd
    for cmd in curl jq sort awk mktemp grep; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            printf 'ERROR: Required command not found: %s\n' "$cmd" >&2
            exit 1
        fi
    done
}

# Environment validation

validate_env() {
    local missing=0

    if [[ -z "$DTRACK_URI" ]]; then
        printf 'ERROR: DTRACK_URI is not set\n' >&2
        missing=1
    fi
    if [[ -z "$API_KEY" ]]; then
        printf 'ERROR: API_KEY is not set\n' >&2
        missing=1
    fi
    if [[ -z "$PROJECT_NAME" ]]; then
        printf 'ERROR: PROJECT_NAME is not set\n' >&2
        missing=1
    fi

    if [[ "$missing" -eq 1 ]]; then
        exit 1
    fi

    # Normalise: strip trailing slash so path construction is consistent.
    DTRACK_URI="${DTRACK_URI%/}"
}

# HTTP helpers

# dtrack_get_page NAME PAGE_NUMBER
#   GET /api/v1/project?name=<NAME>&pageNumber=<PAGE_NUMBER>&pageSize=100
#   Prints "<X-Total-Count-or-empty>\n<json-array-body>" to stdout.
#   Returns 0 on HTTP 200, 1 on any other response.
dtrack_get_page() {
    local name="$1"
    local page_number="$2"
    local encoded_name headers_file body_file http_code response_body total_count
    encoded_name=$(printf '%s' "$name" | jq -Rr '@uri')
    headers_file=$(mktemp)
    body_file=$(mktemp)
    http_code=$(curl -s \
        -D "$headers_file" \
        -o "$body_file" \
        -w "%{http_code}" \
        -H "X-Api-Key: ${API_KEY}" \
        "${DTRACK_URI}/api/v1/project?name=${encoded_name}&pageNumber=${page_number}&pageSize=100")
    response_body=$(< "$body_file")

    if [[ "$http_code" != "200" ]]; then
        printf 'ERROR: GET /api/v1/project?name=%s&pageNumber=%s returned HTTP %s: %s\n' \
            "$name" "$page_number" "$http_code" "$response_body" >&2
        rm -f "$headers_file" "$body_file"
        return 1
    fi

    # Header names are case-insensitive; match either casing and strip CR/whitespace.
    total_count=$(grep -i '^X-Total-Count:' "$headers_file" | tail -n1 | cut -d: -f2- | tr -d '\r' | tr -d '[:space:]')
    rm -f "$headers_file" "$body_file"

    printf '%s\n%s' "$total_count" "$response_body"
}

# dtrack_get NAME
#   Fetches all pages of /api/v1/project?name=<NAME> (pageSize=100 per page).
#   Prints the merged JSON array (all pages combined) to stdout.
#   Returns 0 on success, 1 if any page request fails.
dtrack_get() {
    local name="$1"
    local page_size=100
    local page_number=1 total_count total_pages page_output page_body
    local -a page_bodies=()

    page_output=$(dtrack_get_page "$name" "$page_number") || return 1
    total_count=$(printf '%s' "$page_output" | head -n1)
    page_body=$(printf '%s' "$page_output" | tail -n +2)
    page_bodies+=("$page_body")

    if [[ "$total_count" =~ ^[0-9]+$ ]]; then
        total_pages=$(( (total_count + page_size - 1) / page_size ))
        [[ "$total_pages" -lt 1 ]] && total_pages=1

        while [[ "$page_number" -lt "$total_pages" ]]; do
            page_number=$(( page_number + 1 ))
            page_output=$(dtrack_get_page "$name" "$page_number") || return 1
            page_body=$(printf '%s' "$page_output" | tail -n +2)
            page_bodies+=("$page_body")
        done
    else
        # Header missing/unparseable: keep paging until an empty array is returned.
        printf 'WARN: X-Total-Count header missing or invalid for "%s", paging until empty result\n' \
            "$name" >&2
        while [[ "$(printf '%s' "$page_body" | jq -r 'length')" -eq "$page_size" ]]; do
            page_number=$(( page_number + 1 ))
            page_output=$(dtrack_get_page "$name" "$page_number") || return 1
            page_body=$(printf '%s' "$page_output" | tail -n +2)
            page_bodies+=("$page_body")
        done
    fi

    printf '%s\n' "${page_bodies[@]}" | jq -s 'add'
}

# dtrack_patch UUID BODY
#   PATCH /api/v1/project/<UUID> with a JSON body.
#   Prints the response body to stdout.
#   Returns 0 on HTTP 200, 2 on HTTP 409 (conflict), 1 on any other error.
#   409 is logged as a warning and does not abort the caller.
dtrack_patch() {
    local uuid="$1"
    local body="$2"
    local tmpfile http_code response_body
    tmpfile=$(mktemp)
    http_code=$(curl -s \
        -X PATCH \
        -o "$tmpfile" \
        -w "%{http_code}" \
        -H "X-Api-Key: ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${DTRACK_URI}/api/v1/project/${uuid}")
    response_body=$(< "$tmpfile")
    rm -f "$tmpfile"

    case "$http_code" in
        200)
            printf '%s' "$response_body"
            return 0
            ;;
        409)
            printf 'WARN: PATCH /api/v1/project/%s returned 409 conflict: %s\n' \
                "$uuid" "$response_body" >&2
            return 2
            ;;
        *)
            printf 'ERROR: PATCH /api/v1/project/%s returned HTTP %s: %s\n' \
                "$uuid" "$http_code" "$response_body" >&2
            return 1
            ;;
    esac
}

# dtrack_put BODY
#   PUT /api/v1/project with a JSON body.
#   Prints the response body to stdout.
#   Returns 0 on HTTP 201, 1 on any other response.
dtrack_put() {
    local body="$1"
    local tmpfile http_code response_body
    tmpfile=$(mktemp)
    http_code=$(curl -s \
        -X PUT \
        -o "$tmpfile" \
        -w "%{http_code}" \
        -H "X-Api-Key: ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "${DTRACK_URI}/api/v1/project")
    response_body=$(< "$tmpfile")
    rm -f "$tmpfile"

    if [[ "$http_code" != "201" ]]; then
        printf 'ERROR: PUT /api/v1/project returned HTTP %s: %s\n' \
            "$http_code" "$response_body" >&2
        return 1
    fi

    printf '%s' "$response_body"
}

# Subcommand: reparent
# For each project name in PROJECT_NAME:
#   1. Fetch all projects with that name.
#   2. Identify the unversioned parent (version is null or "").
#      If none exists, create it via PUT.
#   3. Find versioned projects that have no parent assigned at all.
#   4. PATCH each orphan to set its parent to the unversioned project.
#
# Projects already assigned to any parent are left untouched.
# Unversioned projects (other than the intended parent) are never modified.

cmd_reparent() {
    local -a names
    IFS=',' read -r -a names <<< "$PROJECT_NAME"

    local name
    for name in "${names[@]}"; do
        # Trim surrounding whitespace.
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"

        printf 'INFO: [reparent] Processing project: %s\n' "$name"

        local projects
        projects=$(dtrack_get "$name")

        # Locate the unversioned parent (version absent, null, or empty string).
        local parent_uuid
        parent_uuid=$(printf '%s' "$projects" \
            | jq -r 'map(select((.version == null) or (.version == ""))) | .[0].uuid // empty')

        if [[ -z "$parent_uuid" ]]; then
            printf 'INFO: [reparent] No unversioned parent found for "%s", creating one\n' "$name"
            local put_body new_parent
            put_body=$(jq -n --arg n "$name" '{"name": $n}')
            new_parent=$(dtrack_put "$put_body")
            parent_uuid=$(printf '%s' "$new_parent" | jq -r '.uuid')
            printf 'INFO: [reparent] Created parent "%s" with uuid: %s\n' "$name" "$parent_uuid"
        else
            printf 'INFO: [reparent] Found existing parent for "%s" with uuid: %s\n' \
                "$name" "$parent_uuid"
        fi

        # Select versioned projects that have no parent assigned.
        local orphans
        orphans=$(printf '%s' "$projects" \
            | jq -r '.[] | select(
                (.version != null) and
                (.version != "") and
                (.parent == null)
              ) | "\(.version)\t\(.uuid)"')

        if [[ -z "$orphans" ]]; then
            printf 'INFO: [reparent] No orphaned versioned projects found for "%s"\n' "$name"
            continue
        fi

        local version uuid patch_body rc
        while IFS=$'\t' read -r version uuid; do
            printf 'INFO: [reparent] Reparenting %s@%s (uuid: %s)\n' "$name" "$version" "$uuid"
            patch_body=$(jq -n --arg p "$parent_uuid" '{"parent": {"uuid": $p}}')
            rc=0
            dtrack_patch "$uuid" "$patch_body" > /dev/null || rc=$?
            if [[ "$rc" -eq 1 ]]; then
                printf 'ERROR: [reparent] Failed to reparent %s@%s, aborting\n' \
                    "$name" "$version" >&2
                return 1
            fi
            # rc=2: 409 conflict, already logged by dtrack_patch.
        done <<< "$orphans"
    done
}

# Subcommand: deactivate
# For each project name in PROJECT_NAME:
#   1. Fetch all projects with that name.
#   2. Filter to versioned projects only (unversioned parent is never a target).
#   3. Set aside any version listed in KEEP_ACTIVE. It is never deactivated
#      and does not consume a slot in the KEEP_N count below.
#   4. Sort the remaining versions by semver, descending (newest first).
#   5. Retain the first KEEP_N as active; deactivate all others.
#      Projects already inactive are skipped.

# is_kept_alive VERSION
#   Returns 0 if VERSION appears in the KEEP_ACTIVE list, 1 otherwise.
is_kept_alive() {
    local version="$1"
    local kept
    if [[ "${#KEEP_ACTIVE_LIST[@]}" -eq 0 ]]; then
        return 1
    fi
    for kept in "${KEEP_ACTIVE_LIST[@]}"; do
        [[ "$version" == "$kept" ]] && return 0
    done
    return 1
}

cmd_deactivate() {
    local -a names
    IFS=',' read -r -a names <<< "$PROJECT_NAME"

    local -a KEEP_ACTIVE_LIST=()
    if [[ -n "$KEEP_ACTIVE" ]]; then
        local raw_keep
        IFS=',' read -r -a KEEP_ACTIVE_LIST <<< "$KEEP_ACTIVE"
        local i
        for i in "${!KEEP_ACTIVE_LIST[@]}"; do
            raw_keep="${KEEP_ACTIVE_LIST[$i]}"
            raw_keep="${raw_keep#"${raw_keep%%[![:space:]]*}"}"
            raw_keep="${raw_keep%"${raw_keep##*[![:space:]]}"}"
            KEEP_ACTIVE_LIST[i]="$raw_keep"
        done
    fi

    local name
    for name in "${names[@]}"; do
        # Trim surrounding whitespace.
        name="${name#"${name%%[![:space:]]*}"}"
        name="${name%"${name##*[![:space:]]}"}"

        printf 'INFO: [deactivate] Processing project: %s, keeping %s active version(s)\n' \
            "$name" "$KEEP_N"
        if [[ "${#KEEP_ACTIVE_LIST[@]}" -gt 0 ]]; then
            printf 'INFO: [deactivate] Versions kept active (excluded from KEEP_N): %s\n' \
                "$KEEP_ACTIVE"
        fi

        local projects
        projects=$(dtrack_get "$name")

        # Extract versioned projects as tab-separated: version, uuid, active.
        local versioned
        versioned=$(printf '%s' "$projects" \
            | jq -r '.[] | select((.version != null) and (.version != "")) |
                "\(.version)\t\(.uuid)\t\(.active)"')

        if [[ -z "$versioned" ]]; then
            printf 'INFO: [deactivate] No versioned projects found for "%s"\n' "$name"
            continue
        fi

        # Partition out KEEP_ACTIVE versions before ranking the rest.
        local version uuid active
        local -a candidate_lines=()
        while IFS=$'\t' read -r version uuid active; do
            if [[ "${#KEEP_ACTIVE_LIST[@]}" -gt 0 ]] && is_kept_alive "$version"; then
                printf 'INFO: [deactivate] %s@%s (uuid: %s) is in KEEP_ACTIVE, skipping\n' \
                    "$name" "$version" "$uuid"
                continue
            fi
            candidate_lines+=("${version}"$'\t'"${uuid}"$'\t'"${active}")
        done <<< "$versioned"

        if [[ "${#candidate_lines[@]}" -eq 0 ]]; then
            printf 'INFO: [deactivate] All versions of "%s" are covered by KEEP_ACTIVE\n' "$name"
            continue
        fi

        # Sort descending by version (field 1) using GNU version sort.
        local sorted to_deactivate
        sorted=$(printf '%s\n' "${candidate_lines[@]}" | sort -Vr -t$'\t' -k1,1)

        # Drop the KEEP_N newest; everything after is a deactivation candidate.
        to_deactivate=$(printf '%s\n' "$sorted" | awk -v keep="$KEEP_N" 'NR > keep')

        if [[ -z "$to_deactivate" ]]; then
            printf 'INFO: [deactivate] All versions of "%s" are within the keep window (%s)\n' \
                "$name" "$KEEP_N"
            continue
        fi

        local rc
        while IFS=$'\t' read -r version uuid active; do
            if [[ "$active" == "false" ]]; then
                printf 'INFO: [deactivate] %s@%s (uuid: %s) already inactive, skipping\n' \
                    "$name" "$version" "$uuid"
                continue
            fi
            printf 'INFO: [deactivate] Deactivating %s@%s (uuid: %s)\n' \
                "$name" "$version" "$uuid"
            rc=0
            dtrack_patch "$uuid" '{"active": false}' > /dev/null || rc=$?
            if [[ "$rc" -eq 1 ]]; then
                printf 'ERROR: [deactivate] Failed to deactivate %s@%s, aborting\n' \
                    "$name" "$version" >&2
                return 1
            fi
            # rc=2: 409 conflict (project has active children).
        done <<< "$to_deactivate"
    done
}

# Usage

usage() {
    printf 'Usage: %s <subcommand>\n\n' "$(basename "$0")"
    printf 'Subcommands:\n'
    printf '  reparent    Assign orphaned versioned projects to their unversioned parent\n'
    printf '  deactivate  Deactivate all but the KEEP_N most recent versions\n'
    printf '\n'
    printf 'Environment variables:\n'
    printf '  DTRACK_URI     Base URL of the Dependency-Track instance  (required)\n'
    printf '  API_KEY        Dependency-Track API key                    (required)\n'
    printf '  PROJECT_NAME   Comma-delimited list of project names       (required)\n'
    printf '  KEEP_N         Versions to keep active (deactivate only)   (default: 1)\n'
    printf '  KEEP_ACTIVE     Comma-delimited versions never deactivated\n'
    printf '                 (deactivate only)                          (default: none)\n'
    exit 1
}

# Entrypoint

main() {
    check_deps

    if [[ $# -lt 1 ]]; then
        usage
    fi

    # Validate the subcommand before spending time on environment checks.
    case "$1" in
        reparent|deactivate) : ;;
        *) usage ;;
    esac

    validate_env

    case "$1" in
        reparent)   cmd_reparent ;;
        deactivate) cmd_deactivate ;;
    esac
}

# Only run main when executed directly (not sourced by tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
