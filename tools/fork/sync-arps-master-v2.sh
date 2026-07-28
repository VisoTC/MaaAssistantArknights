#!/usr/bin/env bash
set -euo pipefail

TARGET_BRANCH="${TARGET_BRANCH:-arps/master-v2}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master-v2}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/MaaAssistantArknights/MaaAssistantArknights.git}"
SYNC_BRANCH_PREFIX="${SYNC_BRANCH_PREFIX:-sync/upstream-master-v2}"
OPEN_PR="${OPEN_PR:-false}"
RESOLVER="${RESOLVER:-tools/fork/resolve-upstream-merge.sh}"
FORK_OWNED_PATHS=(
    .github/workflows
    AGENTS.md
    tools/fork
)

write_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

write_multiline_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        {
            printf '%s<<EOF\n' "$1"
            printf '%s\n' "$2"
            printf 'EOF\n'
        } >> "$GITHUB_OUTPUT"
    fi
}

preserve_fork_maintenance() {
    local base_ref="$1"
    local path

    # GITHUB_TOKEN cannot push commits that update workflow files. Keep the
    # fork-owned maintenance files while still merging upstream changes.
    for path in "${FORK_OWNED_PATHS[@]}"; do
        git rm -r -f --quiet --ignore-unmatch "$path"
        if git cat-file -e "$base_ref:$path" 2>/dev/null; then
            git checkout "$base_ref" -- "$path"
        fi
    done
}

commit_pending_merge() {
    local base_ref="$1"

    preserve_fork_maintenance "$base_ref"
    if git diff-index --cached --quiet HEAD -- && git diff-files --quiet --; then
        git commit --allow-empty --no-edit
    else
        git commit --no-edit
    fi
}

prepare_sync_branch() {
    local base_ref="$1"
    local upstream_ref="$2"
    local sync_branch="$3"

    git switch -C "$sync_branch" "$upstream_ref"
    preserve_fork_maintenance "$base_ref"

    if ! git diff-index --cached --quiet HEAD -- || ! git diff-files --quiet --; then
        git commit -m "chore: 保留 fork 维护文件"
    fi

    if ! git diff --quiet "$base_ref" HEAD -- "${FORK_OWNED_PATHS[@]}"; then
        echo "Refusing to push a sync branch that changes fork-owned maintenance files."
        return 1
    fi
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

git fetch --force --no-tags "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
git fetch origin "$TARGET_BRANCH"
git switch -C "$TARGET_BRANCH" "origin/$TARGET_BRANCH"

before="$(git rev-parse HEAD)"
upstream_ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
upstream_sha="$(git rev-parse "$upstream_ref")"
upstream_short="${upstream_sha:0:12}"
write_output upstream_sha "$upstream_sha"

set +e
git merge --no-commit --no-ff "$upstream_ref"
merge_status=$?
set -e

if [[ "$merge_status" -eq 0 ]]; then
    if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
        commit_pending_merge "$before"
    fi
    after="$(git rev-parse HEAD)"
    if [[ "$before" != "$after" ]]; then
        git push origin "HEAD:$TARGET_BRANCH"
        write_output pushed true
    else
        write_output pushed false
    fi
    write_output conflict false
    exit 0
fi

conflict_files="$(git diff --name-only --diff-filter=U || true)"

if bash "$RESOLVER"; then
    if [[ -z "$(git diff --name-only --diff-filter=U || true)" ]]; then
        commit_pending_merge "$before"
        git push origin "HEAD:$TARGET_BRANCH"
        write_output conflict false
        write_output pushed true
        write_output resolved_by fork-resolver
        exit 0
    fi
fi

remaining="$(git diff --name-only --diff-filter=U || true)"
if [[ -z "$remaining" ]]; then
    remaining="$conflict_files"
fi

write_output conflict true
write_multiline_output conflict_files "$remaining"

git merge --abort || true

sync_branch="${SYNC_BRANCH_PREFIX}-${upstream_short}"
prepare_sync_branch "$before" "$upstream_ref" "$sync_branch"
git push --force origin "HEAD:$sync_branch"
write_output sync_branch "$sync_branch"

if [[ "$OPEN_PR" == "true" ]]; then
    body_file="$(mktemp)"
    {
        echo "Automated upstream sync could not be merged into \`$TARGET_BRANCH\`."
        echo
        echo "Upstream head: \`$upstream_sha\`"
        echo "Sync branch: \`$sync_branch\`"
        echo
        echo "Unresolved conflict files:"
        echo '```'
        echo "$remaining"
        echo '```'
        echo
        echo "Resolve on the sync branch so this pull request receives the fix:"
        echo '```bash'
        echo "git fetch origin \\"
        echo "  refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH \\"
        echo "  refs/heads/$sync_branch:refs/remotes/origin/$sync_branch"
        echo "git switch -C $sync_branch origin/$sync_branch"
        echo "git merge origin/$TARGET_BRANCH"
        echo "# resolve conflicts, commit, then push HEAD:$sync_branch"
        echo '```'
        echo
        echo "To delegate the resolution to Codex Cloud, post this as a new pull request comment:"
        echo '```text'
        echo "@codex resolve this upstream synchronization pull request."
        echo
        echo "Merge $TARGET_BRANCH into this sync branch and resolve every conflict semantically."
        echo
        echo "Requirements:"
        echo "- Preserve ARPS capture behavior."
        echo "- Preserve fork-owned .github/workflows."
        echo "- Do not blindly choose ours or theirs for WPF conflicts."
        echo "- Run the relevant checks and report anything that cannot run in the cloud environment."
        echo "- Push only to this pull request branch."
        echo "- Do not merge the pull request."
        echo '```'
    } > "$body_file"

    title="Sync upstream master-v2 into ARPS branch (${upstream_short})"
    existing_pr="$(gh pr list --base "$TARGET_BRANCH" --head "$sync_branch" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
    if [[ -n "$existing_pr" ]]; then
        gh pr edit "$existing_pr" --title "$title" --body-file "$body_file"
        write_output pr_url "$existing_pr"
    else
        pr_url="$(gh pr create --draft --base "$TARGET_BRANCH" --head "$sync_branch" --title "$title" --body-file "$body_file")"
        write_output pr_url "$pr_url"
    fi
fi

exit 2
