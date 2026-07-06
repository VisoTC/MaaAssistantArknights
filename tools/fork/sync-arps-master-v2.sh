#!/usr/bin/env bash
set -euo pipefail

TARGET_BRANCH="${TARGET_BRANCH:-arps/master-v2}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master-v2}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/MaaAssistantArknights/MaaAssistantArknights.git}"
SYNC_BRANCH_PREFIX="${SYNC_BRANCH_PREFIX:-sync/upstream-master-v2}"
OPEN_PR="${OPEN_PR:-false}"
RESOLVER="${RESOLVER:-tools/fork/resolve-upstream-merge.sh}"

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

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

if ! git remote get-url "$UPSTREAM_REMOTE" >/dev/null 2>&1; then
    git remote add "$UPSTREAM_REMOTE" "$UPSTREAM_URL"
fi

git fetch --force --tags "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
git fetch origin "$TARGET_BRANCH"
git switch -C "$TARGET_BRANCH" "origin/$TARGET_BRANCH"

before="$(git rev-parse HEAD)"
upstream_ref="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"
upstream_sha="$(git rev-parse "$upstream_ref")"
upstream_short="${upstream_sha:0:12}"
write_output upstream_sha "$upstream_sha"

set +e
git merge --no-edit "$upstream_ref"
merge_status=$?
set -e

if [[ "$merge_status" -eq 0 ]]; then
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
        git commit --no-edit
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
git switch -C "$sync_branch" "$upstream_ref"
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
        echo "Resolve locally:"
        echo '```bash'
        echo "git fetch origin $TARGET_BRANCH $sync_branch"
        echo "git switch $TARGET_BRANCH"
        echo "git merge origin/$sync_branch"
        echo "# resolve conflicts, commit, push"
        echo '```'
    } > "$body_file"

    title="Sync upstream master-v2 into ARPS branch (${upstream_short})"
    existing_pr="$(gh pr list --base "$TARGET_BRANCH" --head "$sync_branch" --state open --json url --jq '.[0].url' 2>/dev/null || true)"
    if [[ -n "$existing_pr" ]]; then
        gh pr edit "$existing_pr" --title "$title" --body-file "$body_file"
        write_output pr_url "$existing_pr"
    else
        pr_url="$(gh pr create --base "$TARGET_BRANCH" --head "$sync_branch" --title "$title" --body-file "$body_file")"
        write_output pr_url "$pr_url"
    fi
fi

exit 2
