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
    TARGET_BRANCH="arps/master-v2" \
        UPSTREAM_BRANCH="master-v2" \
        UPSTREAM_URL="$upstream_repo" \
        SYNC_BRANCH_PREFIX="sync/upstream-master-v2" \
        OPEN_PR="false" \
        RESOLVER="$resolver_script" \
        bash "$sync_script"
)
sync_status=$?
set -e

assert_equal "2" "$sync_status" "a conflict handoff should use the documented exit status"

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
    printf 'FAIL: the sync branch should descend from the requested upstream commit\n' >&2
    exit 1
fi

assert_equal \
    "chore: 保留 fork 维护文件" \
    "$(git -C "$runner_worktree" log -1 --format=%s "$sync_ref")" \
    "the maintenance-preservation commit should be explicit"

printf 'PASS: conflict sync branch preserves fork workflows and upstream source changes\n'
