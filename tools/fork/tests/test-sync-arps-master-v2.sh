#!/usr/bin/env bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
sync_script="$test_dir/../sync-arps-master-v2.sh"
resolver_script="$test_dir/../resolve-upstream-merge.sh"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/maa-fork-sync-test.XXXXXX")"
trap 'rm -rf "$test_root"' EXIT

upstream_repo="$test_root/upstream"
origin_repo="$test_root/origin.git"
fork_worktree="$test_root/fork-worktree"
runner_worktree="$test_root/runner-worktree"
fake_bin="$test_root/fake-bin"
gh_log="$test_root/gh.log"

write_fixture() {
    local path="$1"
    local content="$2"

    mkdir -p "$(dirname -- "$path")"
    printf '%s\n' "$content" > "$path"
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"

    if [[ "$expected" != "$actual" ]]; then
        printf 'FAIL: %s\nexpected: %s\nactual:   %s\n' "$message" "$expected" "$actual" >&2
        exit 1
    fi
}

mkdir -p "$fake_bin"
write_fixture "$fake_bin/gh" '#!/usr/bin/env bash
printf "%s\n" "$*" >> "$GH_TEST_LOG"
if [[ "$1 $2" == "pr create" ]]; then
    printf "%s\n" "https://github.com/example/fork/pull/1"
fi'
chmod +x "$fake_bin/gh"

git init -q -b master-v2 "$upstream_repo"
git -C "$upstream_repo" config user.name "Test Upstream"
git -C "$upstream_repo" config user.email "upstream@example.test"

write_fixture "$upstream_repo/.github/workflows/fork.yml" "base workflow"
write_fixture "$upstream_repo/src/shared.txt" "base implementation"
git -C "$upstream_repo" add .
git -C "$upstream_repo" commit -qm "chore: create base"

git clone -q --bare "$upstream_repo" "$origin_repo"
git clone -q "$origin_repo" "$fork_worktree"
git -C "$fork_worktree" config user.name "Test Fork"
git -C "$fork_worktree" config user.email "fork@example.test"
git -C "$fork_worktree" switch -q -c arps/master-v2

write_fixture "$fork_worktree/.github/workflows/fork.yml" "fork-owned workflow"
write_fixture "$fork_worktree/AGENTS.md" "fork-owned Codex guidance"
write_fixture "$fork_worktree/src/shared.txt" "ARPS implementation"
write_fixture "$fork_worktree/src/arps-only.txt" "ARPS capture behavior"
write_fixture "$fork_worktree/tools/fork/guide.txt" "fork-owned maintenance tool"
git -C "$fork_worktree" add .
git -C "$fork_worktree" commit -qm "feat: add fork changes"
git -C "$fork_worktree" push -q origin arps/master-v2
fork_sha="$(git -C "$fork_worktree" rev-parse HEAD)"

write_fixture "$upstream_repo/.github/workflows/fork.yml" "upstream workflow"
write_fixture "$upstream_repo/.github/workflows/ci-avalonia.yml" "new upstream workflow"
write_fixture "$upstream_repo/src/shared.txt" "upstream implementation"
write_fixture "$upstream_repo/src/upstream-only.txt" "upstream feature"
git -C "$upstream_repo" add .
git -C "$upstream_repo" commit -qm "feat: update upstream"
upstream_sha="$(git -C "$upstream_repo" rev-parse HEAD)"
upstream_short="${upstream_sha:0:12}"
sync_branch="sync/upstream-master-v2-$upstream_short"

git clone -q "$origin_repo" "$runner_worktree"
git -C "$runner_worktree" switch -q -c arps/master-v2 --track origin/arps/master-v2

set +e
(
    cd "$runner_worktree"
    PATH="$fake_bin:$PATH" \
        GH_TEST_LOG="$gh_log" \
        TARGET_BRANCH="arps/master-v2" \
        UPSTREAM_BRANCH="master-v2" \
        UPSTREAM_URL="$upstream_repo" \
        SYNC_BRANCH_PREFIX="sync/upstream-master-v2" \
        OPEN_PR="true" \
        RESOLVER="$resolver_script" \
        bash "$sync_script"
)
sync_status=$?
set -e

assert_equal "2" "$sync_status" "a conflict handoff should use the documented exit status"

create_args="$(sed -n '/^pr create /p' "$gh_log")"
if [[ "$create_args" != *" --no-maintainer-edit "* ]]; then
    printf 'FAIL: pull request creation should disable maintainer edits for the fork token\n' >&2
    exit 1
fi

git -C "$runner_worktree" fetch -q origin \
    "refs/heads/$sync_branch:refs/remotes/origin/$sync_branch"
sync_ref="refs/remotes/origin/$sync_branch"

assert_equal \
    "fork-owned workflow" \
    "$(git -C "$runner_worktree" show "$sync_ref:.github/workflows/fork.yml")" \
    "the sync branch should retain the fork workflow"

if git -C "$runner_worktree" cat-file -e "$sync_ref:.github/workflows/ci-avalonia.yml" 2>/dev/null; then
    printf 'FAIL: the sync branch retained an upstream-only workflow\n' >&2
    exit 1
fi

if ! git -C "$runner_worktree" diff --quiet \
    "refs/remotes/origin/arps/master-v2" "$sync_ref" -- \
    .github/workflows AGENTS.md tools/fork; then
    printf 'FAIL: the sync branch maintenance files differ from the target branch\n' >&2
    exit 1
fi

if ! git -C "$runner_worktree" diff --quiet \
    "refs/remotes/origin/arps/master-v2...$sync_ref" -- \
    .github/workflows; then
    printf 'FAIL: the pull request comparison contains workflow changes\n' >&2
    exit 1
fi

assert_equal \
    "fork-owned Codex guidance" \
    "$(git -C "$runner_worktree" show "$sync_ref:AGENTS.md")" \
    "the sync branch should include fork-owned Codex guidance"

assert_equal \
    "fork-owned maintenance tool" \
    "$(git -C "$runner_worktree" show "$sync_ref:tools/fork/guide.txt")" \
    "the sync branch should include fork-owned maintenance tools"

assert_equal \
    "upstream feature" \
    "$(git -C "$runner_worktree" show "$sync_ref:src/upstream-only.txt")" \
    "the sync branch should retain upstream source changes"

assert_equal \
    "$fork_sha" \
    "$(git -C "$runner_worktree" rev-parse refs/remotes/origin/arps/master-v2)" \
    "the conflict handoff should not update the target branch"

if ! git -C "$runner_worktree" merge-base --is-ancestor "$upstream_sha" "$sync_ref"; then
    printf 'FAIL: the sync branch should contain the requested upstream commit\n' >&2
    exit 1
fi

if ! git -C "$runner_worktree" merge-base --is-ancestor "$fork_sha" "$sync_ref"; then
    printf 'FAIL: the sync branch should descend from the target branch\n' >&2
    exit 1
fi

assert_equal \
    "$fork_sha" \
    "$(git -C "$runner_worktree" rev-parse "$sync_ref^1")" \
    "the target branch should be the first merge parent"

assert_equal \
    "$upstream_sha" \
    "$(git -C "$runner_worktree" rev-parse "$sync_ref^2")" \
    "the upstream branch should be the second merge parent"

shared_content="$(git -C "$runner_worktree" show "$sync_ref:src/shared.txt")"
if [[ "$shared_content" != *"<<<<<<< HEAD"* ]] || \
    [[ "$shared_content" != *"ARPS implementation"* ]] || \
    [[ "$shared_content" != *"upstream implementation"* ]] || \
    [[ "$shared_content" != *">>>>>>>"* ]]; then
    printf 'FAIL: the sync branch should commit both sides as conflict markers\n' >&2
    exit 1
fi

assert_equal \
    "chore: 暂存上游合并冲突" \
    "$(git -C "$runner_worktree" log -1 --format=%s "$sync_ref")" \
    "the conflict handoff merge commit should be explicit"

assert_equal \
    "arps/master-v2" \
    "$(git -C "$runner_worktree" branch --show-current)" \
    "the runner worktree should return to the target branch"

clean_upstream_repo="$test_root/clean-upstream"
clean_origin_repo="$test_root/clean-origin.git"
clean_fork_worktree="$test_root/clean-fork-worktree"
clean_runner_worktree="$test_root/clean-runner-worktree"

git init -q -b master-v2 "$clean_upstream_repo"
git -C "$clean_upstream_repo" config user.name "Test Upstream"
git -C "$clean_upstream_repo" config user.email "upstream@example.test"

write_fixture "$clean_upstream_repo/.github/workflows/fork.yml" "base workflow"
write_fixture "$clean_upstream_repo/src/base.txt" "base implementation"
git -C "$clean_upstream_repo" add .
git -C "$clean_upstream_repo" commit -qm "chore: create clean base"

git clone -q --bare "$clean_upstream_repo" "$clean_origin_repo"
git clone -q "$clean_origin_repo" "$clean_fork_worktree"
git -C "$clean_fork_worktree" config user.name "Test Fork"
git -C "$clean_fork_worktree" config user.email "fork@example.test"
git -C "$clean_fork_worktree" switch -q -c arps/master-v2

write_fixture "$clean_fork_worktree/.github/workflows/fork.yml" "fork-owned workflow"
write_fixture "$clean_fork_worktree/AGENTS.md" "fork-owned Codex guidance"
write_fixture "$clean_fork_worktree/tools/fork/guide.txt" "fork-owned maintenance tool"
git -C "$clean_fork_worktree" add .
git -C "$clean_fork_worktree" commit -qm "feat: add clean fork changes"
git -C "$clean_fork_worktree" push -q origin arps/master-v2

write_fixture "$clean_upstream_repo/src/upstream-only.txt" "upstream feature"
git -C "$clean_upstream_repo" add .
git -C "$clean_upstream_repo" commit -qm "feat: add clean upstream change"
clean_upstream_sha="$(git -C "$clean_upstream_repo" rev-parse HEAD)"
clean_upstream_short="${clean_upstream_sha:0:12}"
clean_sync_branch="sync/upstream-master-v2-$clean_upstream_short"

git clone -q "$clean_origin_repo" "$clean_runner_worktree"
git -C "$clean_runner_worktree" switch -q -c arps/master-v2 --track origin/arps/master-v2

(
    cd "$clean_runner_worktree"
    TARGET_BRANCH="arps/master-v2" \
        UPSTREAM_BRANCH="master-v2" \
        UPSTREAM_URL="$clean_upstream_repo" \
        SYNC_BRANCH_PREFIX="sync/upstream-master-v2" \
        OPEN_PR="false" \
        RESOLVER="$resolver_script" \
        bash "$sync_script"
)

git -C "$clean_runner_worktree" fetch -q origin \
    "refs/heads/arps/master-v2:refs/remotes/origin/arps/master-v2"
clean_target_ref="refs/remotes/origin/arps/master-v2"

if ! git -C "$clean_runner_worktree" merge-base --is-ancestor \
    "$clean_upstream_sha" "$clean_target_ref"; then
    printf 'FAIL: a clean sync should update the target branch to include upstream\n' >&2
    exit 1
fi

assert_equal \
    "fork-owned workflow" \
    "$(git -C "$clean_runner_worktree" show "$clean_target_ref:.github/workflows/fork.yml")" \
    "a clean sync should retain the fork workflow"

assert_equal \
    "chore: 同步上游 master-v2" \
    "$(git -C "$clean_runner_worktree" log -1 --format=%s "$clean_target_ref")" \
    "a clean sync merge commit should describe the target operation"

assert_equal \
    "arps/master-v2" \
    "$(git -C "$clean_runner_worktree" branch --show-current)" \
    "a clean sync should return to the target branch"

if git -C "$clean_runner_worktree" ls-remote --exit-code --heads origin \
    "$clean_sync_branch" >/dev/null 2>&1; then
    printf 'FAIL: a clean sync should not publish a conflict branch\n' >&2
    exit 1
fi

printf 'PASS: conflict and clean sync paths preserve fork workflows safely\n'
