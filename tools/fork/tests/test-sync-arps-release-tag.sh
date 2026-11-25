#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sync_script="$test_dir/../sync-arps-release-tag.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/maa-arps-tag-sync-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

write_fixture() {
    local path="$1"
    local content="$2"

    mkdir -p "$(dirname -- "$path")"
    printf '%s\n' "$content" > "$path"
}

configure_identity() {
    git -C "$1" config user.name "Test User"
    git -C "$1" config user.email "test@example.test"
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' \
            "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

assert_file_at_ref() {
    local repo="$1"
    local ref="$2"
    local path="$3"
    local expected="$4"
    local message="$5"

    assert_equal \
        "$expected" \
        "$(git -C "$repo" show "$ref:$path")" \
        "$message"
}

assert_path_missing_at_ref() {
    local repo="$1"
    local ref="$2"
    local path="$3"
    local message="$4"

    if git -C "$repo" cat-file -e "$ref:$path" 2>/dev/null; then
        printf 'FAIL: %s\nunexpected path: %s\n' "$message" "$path" >&2
        exit 1
    fi
}

fake_bin="$test_root/fake-bin"
gh_log="$test_root/gh.log"
gh_body="$test_root/gh-body.md"
gh_pr_exists="$test_root/gh-pr-exists"
mkdir -p "$fake_bin"
write_fixture "$fake_bin/gh" '#!/usr/bin/env bash
printf "gh" >> "$GH_TEST_LOG"
printf " %q" "$@" >> "$GH_TEST_LOG"
printf "\n" >> "$GH_TEST_LOG"

previous=""
method=""
endpoint=""
for argument in "$@"; do
    if [[ "$previous" == "--method" ]]; then
        method="$argument"
    elif [[ "$previous" == "--field" && "$argument" == body=@* ]]; then
        cp "${argument#body=@}" "$GH_TEST_BODY"
    elif [[ "$argument" == repos/* ]]; then
        endpoint="$argument"
    fi
    previous="$argument"
done

if [[ "$method" == "GET" && "$endpoint" == */pulls ]]; then
    if [[ -e "$GH_TEST_PR_EXISTS" ]]; then
        printf "1\n"
    fi
    exit 0
fi

if [[ "$method" == "POST" && "$endpoint" == */pulls ]]; then
    touch "$GH_TEST_PR_EXISTS"
    printf "https://github.com/example/fork/pull/1\n"
    exit 0
fi

if [[ "$method" == "PATCH" && "$endpoint" == */pulls/* ]]; then
    printf "https://github.com/example/fork/pull/1\n"
    exit 0
fi

printf "unexpected gh invocation\n" >&2
exit 1'
chmod +x "$fake_bin/gh"

conflict_upstream="$test_root/conflict-upstream"
conflict_origin="$test_root/conflict-origin.git"
conflict_fork="$test_root/conflict-fork"
conflict_runner="$test_root/conflict-runner"

git init -q -b master-v2 "$conflict_upstream"
configure_identity "$conflict_upstream"
write_fixture "$conflict_upstream/src/shared.txt" "base implementation"
write_fixture "$conflict_upstream/src/base-only.txt" "base feature"
write_fixture \
    "$conflict_upstream/.github/workflows/release-preparation.yml" \
    "official v1.0 workflow"
git -C "$conflict_upstream" add .
git -C "$conflict_upstream" commit -qm "chore: create base"
conflict_base_sha="$(git -C "$conflict_upstream" rev-parse HEAD)"
git -C "$conflict_upstream" tag -a v1.0.0 -m "v1.0.0"

git clone -q --bare "$conflict_upstream" "$conflict_origin"
git clone -q "$conflict_origin" "$conflict_fork"
configure_identity "$conflict_fork"
git -C "$conflict_fork" switch -q -c arps/master-v2
write_fixture "$conflict_fork/src/shared.txt" "ARPS implementation"
write_fixture "$conflict_fork/src/arps-only.txt" "ARPS capture behavior"
write_fixture "$conflict_fork/.github/workflows/fork.yml" "fork workflow"
write_fixture "$conflict_fork/AGENTS.md" "fork guidance"
write_fixture "$conflict_fork/tools/fork/guide.txt" "fork maintenance"
git -C "$conflict_fork" add .
git -C "$conflict_fork" commit -qm "feat(arps): 应用 v1.0.0 单提交覆盖层" \
    -m "ARPS-Upstream-Tag: v1.0.0" \
    -m "ARPS-Upstream-Commit: $conflict_base_sha"
conflict_fork_sha="$(git -C "$conflict_fork" rev-parse HEAD)"
conflict_workflows_tree="$(
    git -C "$conflict_fork" rev-parse HEAD:.github/workflows
)"
git -C "$conflict_fork" tag -f -a v1.0.0 -m "MAA-ARPS v1.0.0"
git -C "$conflict_fork" push -q origin arps/master-v2
git -C "$conflict_fork" push -q --force origin refs/tags/v1.0.0

write_fixture "$conflict_upstream/src/shared.txt" "upstream implementation"
write_fixture "$conflict_upstream/src/upstream-only.txt" "upstream feature"
write_fixture \
    "$conflict_upstream/.github/workflows/release-preparation.yml" \
    "official v1.1 workflow"
write_fixture \
    "$conflict_upstream/.github/workflows/upstream-new.yml" \
    "new official workflow"
git -C "$conflict_upstream" add .
git -C "$conflict_upstream" commit -qm "feat: update upstream"
conflict_upstream_sha="$(git -C "$conflict_upstream" rev-parse HEAD)"
git -C "$conflict_upstream" tag -a v1.1.0 -m "v1.1.0"

git clone -q "$conflict_origin" "$conflict_runner"
configure_identity "$conflict_runner"
git -C "$conflict_runner" switch -q -c arps/master-v2 \
    --track origin/arps/master-v2
conflict_output="$test_root/conflict-output"

set +e
(
    cd "$conflict_runner"
    PATH="$fake_bin:$PATH" \
        GH_TEST_LOG="$gh_log" \
        GH_TEST_BODY="$gh_body" \
        GH_TEST_PR_EXISTS="$gh_pr_exists" \
        GITHUB_OUTPUT="$conflict_output" \
        GITHUB_REPOSITORY="example/fork" \
        TARGET_BRANCH="arps/master-v2" \
        UPSTREAM_URL="$conflict_upstream" \
        INPUT_TAG="v1.1.0" \
        OPEN_PR="true" \
        bash "$sync_script"
)
conflict_status=$?
set -e

assert_equal "2" "$conflict_status" "conflicts should use the handoff exit status"
sync_branch="sync/upstream-tag-v1.1.0"
git -C "$conflict_runner" fetch -q origin \
    "refs/heads/$sync_branch:refs/remotes/origin/$sync_branch"
sync_ref="refs/remotes/origin/$sync_branch"

assert_equal \
    "$conflict_upstream_sha" \
    "$(git -C "$conflict_runner" rev-parse "$sync_ref^")" \
    "the conflict handoff should be based directly on the official tag"
assert_equal \
    "1" \
    "$(git -C "$conflict_runner" rev-list --count "$conflict_upstream_sha..$sync_ref")" \
    "the initial conflict handoff should contain one overlay snapshot"
assert_equal \
    "$conflict_fork_sha" \
    "$(git -C "$conflict_runner" rev-parse refs/remotes/origin/arps/master-v2)" \
    "a conflict handoff must not move the target branch"
assert_equal \
    "$conflict_workflows_tree" \
    "$(git -C "$conflict_runner" rev-parse "$sync_ref:.github/workflows")" \
    "the handoff must preserve the complete v1.0 fork workflow tree"
assert_file_at_ref \
    "$conflict_runner" "$sync_ref" \
    .github/workflows/release-preparation.yml \
    "official v1.0 workflow" \
    "the handoff must ignore later upstream workflow edits"
assert_file_at_ref \
    "$conflict_runner" "$sync_ref" .github/workflows/fork.yml \
    "fork workflow" \
    "the handoff must retain fork-owned workflow YAML"
assert_path_missing_at_ref \
    "$conflict_runner" "$sync_ref" .github/workflows/upstream-new.yml \
    "the handoff must ignore later upstream workflow additions"

shared_with_markers="$(git -C "$conflict_runner" show "$sync_ref:src/shared.txt")"
if [[ "$shared_with_markers" != *"<<<<<<<"* ]] || \
    [[ "$shared_with_markers" != *"ARPS implementation"* ]] || \
    [[ "$shared_with_markers" != *"upstream implementation"* ]] || \
    [[ "$shared_with_markers" != *">>>>>>>"* ]]; then
    printf 'FAIL: the handoff commit should preserve both sides as markers\n' >&2
    exit 1
fi

if ! rg -q -- '--method POST .*repos/example/fork/pulls' "$gh_log"; then
    printf 'FAIL: the handoff should create the pull request through REST\n' >&2
    exit 1
fi
if ! rg -q -- '--field maintainer_can_modify=false' "$gh_log"; then
    printf 'FAIL: the handoff should disable maintainer edits\n' >&2
    exit 1
fi
if ! rg -q '自动同步无法把 ARPS 单提交覆盖层重放到官方上游 `v1.1.0`' "$gh_body"; then
    printf 'FAIL: the pull request body should explain the Chinese handoff flow\n' >&2
    exit 1
fi
if git -C "$conflict_runner" ls-remote --exit-code --tags origin \
    refs/tags/v1.1.0 >/dev/null 2>&1; then
    printf 'FAIL: a conflicted sync must not publish the fork tag\n' >&2
    exit 1
fi

git -C "$conflict_fork" fetch -q origin \
    "refs/heads/$sync_branch:refs/remotes/origin/$sync_branch"
git -C "$conflict_fork" switch -q -C "$sync_branch" \
    "refs/remotes/origin/$sync_branch"
write_fixture "$conflict_fork/src/shared.txt" \
    "upstream implementation with ARPS behavior"
write_fixture \
    "$conflict_fork/.github/workflows/release-preparation.yml" \
    "accidental handoff workflow edit"
git -C "$conflict_fork" add \
    src/shared.txt \
    .github/workflows/release-preparation.yml
git -C "$conflict_fork" commit -qm "fix(arps): 解决标签同步冲突"
git -C "$conflict_fork" push -q origin "HEAD:refs/heads/$sync_branch"

: > "$conflict_output"
(
    cd "$conflict_runner"
    PATH="$fake_bin:$PATH" \
        GH_TEST_LOG="$gh_log" \
        GH_TEST_BODY="$gh_body" \
        GH_TEST_PR_EXISTS="$gh_pr_exists" \
        GITHUB_OUTPUT="$conflict_output" \
        GITHUB_REPOSITORY="example/fork" \
        TARGET_BRANCH="arps/master-v2" \
        UPSTREAM_URL="$conflict_upstream" \
        INPUT_TAG="v1.1.0" \
        OPEN_PR="true" \
        bash "$sync_script"
)

git -C "$conflict_runner" fetch -q --force origin \
    "refs/heads/arps/master-v2:refs/remotes/origin/arps/master-v2" \
    "refs/tags/v1.1.0:refs/fork-tags/v1.1.0"
rebuilt_ref="refs/remotes/origin/arps/master-v2"
rebuilt_sha="$(git -C "$conflict_runner" rev-parse "$rebuilt_ref")"

assert_equal \
    "$conflict_upstream_sha" \
    "$(git -C "$conflict_runner" rev-parse "$rebuilt_ref^")" \
    "the rebuilt branch should have the official tag as its parent"
assert_equal \
    "1" \
    "$(git -C "$conflict_runner" rev-list --count "$conflict_upstream_sha..$rebuilt_ref")" \
    "the resolved handoff should be squashed to one ARPS commit"
assert_equal \
    "$rebuilt_sha" \
    "$(git -C "$conflict_runner" rev-parse refs/fork-tags/v1.1.0^{})" \
    "the same-name fork tag should point to the rebuilt ARPS commit"
assert_file_at_ref \
    "$conflict_runner" "$rebuilt_ref" src/shared.txt \
    "upstream implementation with ARPS behavior" \
    "the semantic conflict resolution should survive the squash"
assert_file_at_ref \
    "$conflict_runner" "$rebuilt_ref" src/arps-only.txt \
    "ARPS capture behavior" \
    "the rebuilt commit should retain the ARPS overlay"
assert_file_at_ref \
    "$conflict_runner" "$rebuilt_ref" src/upstream-only.txt \
    "upstream feature" \
    "the rebuilt commit should retain the upstream tag"
assert_equal \
    "$conflict_workflows_tree" \
    "$(git -C "$conflict_runner" rev-parse "$rebuilt_ref:.github/workflows")" \
    "finalization must discard handoff and upstream workflow edits"

if git -C "$conflict_runner" ls-remote --exit-code --heads origin \
    "$sync_branch" >/dev/null 2>&1; then
    printf 'FAIL: a finalized handoff should delete its temporary branch\n' >&2
    exit 1
fi
if ! rg -q -- '--raw-field state=closed' "$gh_log"; then
    printf 'FAIL: finalization should close the handoff pull request\n' >&2
    exit 1
fi
if ! rg -q '^pushed=true$' "$conflict_output"; then
    printf 'FAIL: finalization should report that it published the tag\n' >&2
    exit 1
fi

clean_upstream="$test_root/clean-upstream"
clean_origin="$test_root/clean-origin.git"
clean_fork="$test_root/clean-fork"
clean_runner="$test_root/clean-runner"

git init -q -b master-v2 "$clean_upstream"
configure_identity "$clean_upstream"
write_fixture "$clean_upstream/src/base.txt" "base feature"
write_fixture \
    "$clean_upstream/.github/workflows/release-preparation.yml" \
    "official v2.0 workflow"
git -C "$clean_upstream" add .
git -C "$clean_upstream" commit -qm "chore: create clean base"
clean_base_sha="$(git -C "$clean_upstream" rev-parse HEAD)"
git -C "$clean_upstream" tag -a v2.0.0 -m "v2.0.0"

git clone -q --bare "$clean_upstream" "$clean_origin"
git clone -q "$clean_origin" "$clean_fork"
configure_identity "$clean_fork"
git -C "$clean_fork" switch -q -c arps/master-v2
write_fixture "$clean_fork/src/arps-only.txt" "ARPS capture behavior"
write_fixture "$clean_fork/.github/workflows/fork.yml" "fork workflow"
git -C "$clean_fork" add .
git -C "$clean_fork" commit -qm "feat(arps): 应用 v2.0.0 单提交覆盖层" \
    -m "ARPS-Upstream-Tag: v2.0.0" \
    -m "ARPS-Upstream-Commit: $clean_base_sha"
clean_workflows_tree="$(
    git -C "$clean_fork" rev-parse HEAD:.github/workflows
)"
git -C "$clean_fork" tag -f -a v2.0.0 -m "MAA-ARPS v2.0.0"
git -C "$clean_fork" push -q origin arps/master-v2
git -C "$clean_fork" push -q --force origin refs/tags/v2.0.0

write_fixture "$clean_upstream/src/upstream-only.txt" "upstream feature"
write_fixture \
    "$clean_upstream/.github/workflows/release-preparation.yml" \
    "official v2.1 workflow"
write_fixture \
    "$clean_upstream/.github/workflows/upstream-new.yml" \
    "new official workflow"
git -C "$clean_upstream" add .
git -C "$clean_upstream" commit -qm "feat: add clean upstream change"
clean_upstream_sha="$(git -C "$clean_upstream" rev-parse HEAD)"
git -C "$clean_upstream" tag -a v2.1.0 -m "v2.1.0"

git clone -q "$clean_origin" "$clean_runner"
configure_identity "$clean_runner"
git -C "$clean_runner" switch -q -c arps/master-v2 \
    --track origin/arps/master-v2
clean_output="$test_root/clean-output"

(
    cd "$clean_runner"
    GITHUB_OUTPUT="$clean_output" \
        TARGET_BRANCH="arps/master-v2" \
        UPSTREAM_URL="$clean_upstream" \
        INPUT_TAG="v2.1.0" \
        OPEN_PR="false" \
        bash "$sync_script"
)

git -C "$clean_runner" fetch -q --force origin \
    "refs/heads/arps/master-v2:refs/remotes/origin/arps/master-v2" \
    "refs/tags/v2.1.0:refs/fork-tags/v2.1.0"
clean_ref="refs/remotes/origin/arps/master-v2"
clean_sha="$(git -C "$clean_runner" rev-parse "$clean_ref")"

assert_equal \
    "$clean_upstream_sha" \
    "$(git -C "$clean_runner" rev-parse "$clean_ref^")" \
    "a clean update should rebase the overlay directly onto the new tag"
assert_equal \
    "1" \
    "$(git -C "$clean_runner" rev-list --count "$clean_upstream_sha..$clean_ref")" \
    "a clean update should also retain the one-commit invariant"
assert_equal \
    "$clean_sha" \
    "$(git -C "$clean_runner" rev-parse refs/fork-tags/v2.1.0^{})" \
    "a clean update should create the same-name fork tag"
assert_file_at_ref \
    "$clean_runner" "$clean_ref" src/arps-only.txt \
    "ARPS capture behavior" \
    "a clean update should retain fork changes"
assert_file_at_ref \
    "$clean_runner" "$clean_ref" src/upstream-only.txt \
    "upstream feature" \
    "a clean update should retain upstream changes"
assert_equal \
    "$clean_workflows_tree" \
    "$(git -C "$clean_runner" rev-parse "$clean_ref:.github/workflows")" \
    "a clean update must preserve the complete fork workflow tree"
assert_file_at_ref \
    "$clean_runner" "$clean_ref" \
    .github/workflows/release-preparation.yml \
    "official v2.0 workflow" \
    "a clean update must ignore later upstream workflow edits"
assert_path_missing_at_ref \
    "$clean_runner" "$clean_ref" .github/workflows/upstream-new.yml \
    "a clean update must ignore later upstream workflow additions"

: > "$clean_output"
(
    cd "$clean_runner"
    GITHUB_OUTPUT="$clean_output" \
        TARGET_BRANCH="arps/master-v2" \
        UPSTREAM_URL="$clean_upstream" \
        INPUT_TAG="v2.1.0" \
        OPEN_PR="false" \
        bash "$sync_script"
)
if ! rg -q '^pushed=false$' "$clean_output"; then
    printf 'FAIL: rerunning the current tag should be a no-op\n' >&2
    exit 1
fi

printf 'PASS: stable tags rebuild ARPS as one commit and hand off conflicts safely\n'
