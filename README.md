# dtrack-lifecycle-action

This action is a simple, readable Bash script (`src/dtrack-lifecycle.sh`)
for managing Dependency-Track project lifecycles in CI/CD, courtesy of
cURL calls against the service's `/v1/project` endpoint.

It's intended to solve the lifecycle management gap in CI where
Dependency-Track administrators are unable to deprecate or deactivate
older versions at scale or automatically, to prevent vulnerability
scanners running against them. Each scanner (Snyk, Trivy, Sonatype,
etc.) available on demand within Dependency-Track will very likely
consume API calls per component scanned, something the API vendor will
factor into the bill. Deactivating projects makes them ineligible for
re-scanning and helps control the cost for the enterprise hosting the
platform.

Dependency-Track's own
[gh-upload-sbom](https://github.com/DependencyTrack/gh-upload-sbom/)
action allows the creation of a project, defines a project hierarchy
(`parent`), flags the latest version of a release (`is-latest`), but
there isn't any further lifecycle management baked in. This action
tries to fill that gap.

There are two subcommands to the script:
- **reparent**: Assign orphaned versioned projects to their unversioned
  parent, creating the parent if it doesn't exist yet.
- **deactivate**: Deactivate all but the most recent *N* versions of a
  project, so downstream vulnerability scanners (Snyk, Trivy, Sonatype,
  etc.) only re-scan the versions you actually care about instead of every
  historical version ever uploaded.

The action itself has few dependencies, e.g. `curl`, `jq`, `awk`, and `grep`.
[ShellCheck](https://github.com/koalaman/shellcheck),
[yamllint](https://github.com/adrienverge/yamllint), and
[actionlint](https://github.com/rhysd/actionlint) together provide YAML
linting and POSIX suitability checks against the action, while the
[Bats-core](https://github.com/bats-core/bats-core) suite handles testing.

## Requirements

The API key used must have both the `PORTFOLIO_MANAGEMENT` and
`VIEW_PORTFOLIO` permissions in Dependency-Track.

## Usage as a GitHub Action

```yaml
- name: Manage Dependency-Track project lifecycle
  uses: <org>/dtrack-lifecycle-action@v1
  with:
    dtrack-uri: https://dtrack.example.com
    api-key: ${{ secrets.DTRACK_API_KEY }}
    project-name: my-service
    operation: deactivate
    keep-n: 3
    keep-active: 1.2.3,2.0.0-lts
```

### Inputs

| Input          | Required | Default      | Description                                                                                        |
|----------------|----------|--------------|----------------------------------------------------------------------------------------------------|
| `dtrack-uri`   | yes      | —            | Base URL of the Dependency-Track instance                                                          |
| `api-key`      | yes      | —            | Dependency-Track API key (`PORTFOLIO_MANAGEMENT` + `VIEW_PORTFOLIO`); pass via a secret            |
| `project-name` | yes      | —            | Comma-delimited list of project names to operate on                                                |
| `operation`    | no       | `deactivate` | `reparent`, `deactivate`, or `both` (runs reparent then deactivate)                                |
| `keep-n`       | no       | `1`          | Number of most recent versions to keep active (deactivate only)                                    |
| `keep-active`  | no       | `''`         | Comma-delimited versions to always keep active, excluded from the `keep-n` count (deactivate only) |

## Usage as a standalone script

```bash
export DTRACK_URI=https://dtrack.example.com
export API_KEY=...
export PROJECT_NAME=my-service
export KEEP_N=3
export KEEP_ACTIVE=1.2.3,2.0.0-lts

./src/dtrack-lifecycle.sh reparent
./src/dtrack-lifecycle.sh deactivate
```

### Environment variables

| Variable       | Required | Default | Applies to   | Description                                                            |
|----------------|----------|---------|--------------|------------------------------------------------------------------------|
| `DTRACK_URI`   | yes      | —       | both         | Base URL of the Dependency-Track instance                              |
| `API_KEY`      | yes      | —       | both         | Dependency-Track API key                                               |
| `PROJECT_NAME` | yes      | —       | both         | Comma-delimited list of project names                                  |
| `KEEP_N`       | no       | `1`     | `deactivate` | Number of most recent versions to keep active                          |
| `KEEP_ACTIVE`  | no       | `''`    | `deactivate` | Comma-delimited versions to always keep active, excluded from `KEEP_N` |

## Behaviour

- Pagination: Calling `GET /v1/project` against Dependency-Track will
  return up to 100 versions per page. The script reads the `X-Total-Count`
  response header to determine how many pages exist and fetches all of them,
  so projects with more than 100 versions are handled correctly. If the header
  is missing or unparseable, the script falls back to paging until an empty
  page is returned.
- `KEEP_ACTIVE`: Versions listed here are never deactivated and do not
  count against `KEEP_N`, e.g. with `KEEP_N=1` and `KEEP_ACTIVE=1.0.0`, the
  single newest version *and* `1.0.0` both remain active. If a
  `KEEP_ACTIVE` version is already inactive, it is left as-is; `KEEP_ACTIVE`
  prevents future deactivation, it does not reactivate anything.
- 409 conflicts on deactivation (e.g. a project has active children)
  are logged as warnings and do not abort the run; the script continues to
  the next project.

## Development

The lifecycle script lives in `src/dtrack-lifecycle.sh`; tests live in
`tests/` and are split by subcommand:

- `tests/dtrack_lifecycle_helpers.bats`: argument validation, `usage`,
  `is_kept_alive`, and the HTTP pagination helpers
- `tests/dtrack_lifecycle_reparent.bats`: `cmd_reparent`
- `tests/dtrack_lifecycle_deactivate.bats`: `cmd_deactivate`

Tests use [Bats-core](https://github.com/bats-core/bats-core) with the
[bats-support](https://github.com/bats-core/bats-support) and
[bats-assert](https://github.com/bats-core/bats-assert) helper libraries,
and stub out `curl` (see `tests/test_helper/mock_curl.bash`) so no real
Dependency-Track instance is required.

To run the tests locally:

```bash
# install bats-core, bats-support, and bats-assert if not already present,
# then point BATS_LIB_PATH at wherever bats-support/bats-assert were cloned
BATS_LIB_PATH=/path/to/bats-libs bats tests/
```

CI (`.github/workflows/ci.yml`) additionally runs:

- [ShellCheck](https://github.com/koalaman/shellcheck) against
  `src/dtrack-lifecycle.sh` and the test helpers
- [yamllint](https://github.com/adrienverge/yamllint) and
  [actionlint](https://github.com/rhysd/actionlint) against `action.yml`
  and the workflow files themselves
