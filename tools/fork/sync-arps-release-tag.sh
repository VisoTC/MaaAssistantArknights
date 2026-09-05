#!/usr/bin/env bash
set -euo pipefail

TARGET_BRANCH="${TARGET_BRANCH:-arps/master-v2}"
UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/MaaAssistantArknights/MaaAssistantArknights.git}"
INPUT_TAG="${INPUT_TAG:-}"
SYNC_BRANCH_PREFIX="${SYNC_BRANCH_PREFIX:-sync/upstream-tag}"
OPEN_PR="${OPEN_PR:-false}"
PR_REPOSITORY="${PR_REPOSITORY:-${GITHUB_REPOSITORY:-}}"
STABLE_TAG_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$'

write_output() {
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
    fi
}

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

fetch_upstream_tag() {
    local tag="$1"

    git fetch --force --no-tags "$UPSTREAM_URL" \
        "refs/tags/$tag:refs/upstream-tags/$tag"
}

upstream_tag_commit() {
    git rev-parse "refs/upstream-tags/$1^{}"
}

remote_fork_tag_commit() {
    local tag="$1"

    if ! git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
        return 1
    fi

    git fetch --force --no-tags origin \
        "refs/tags/$tag:refs/fork-tags/$tag" >/dev/null
    git rev-parse "refs/fork-tags/$tag^{}"
}

restore_target_branch() {
    local target_ref="$1"

    git switch -C "$TARGET_BRANCH" "$target_ref"
    if git show-ref --verify --quiet "refs/remotes/origin/$TARGET_BRANCH"; then
        git branch --set-upstream-to="origin/$TARGET_BRANCH" "$TARGET_BRANCH" >/dev/null
    fi
}

restore_pinned_fork_workflows() {
    local source_ref="$1"

    # The fork workflow tree was bootstrapped from official v6.12.2 and then
    # extended with fork-owned YAML. Later upstream tags must never change it.
    git rm -r -f --quiet --ignore-unmatch -- .github/workflows
    if git cat-file -e "$source_ref:.github/workflows" 2>/dev/null; then
        git checkout "$source_ref" -- .github/workflows
    fi
}

make_overlay_commit() {
    local tag="$1"
    local upstream_sha="$2"
    local overlay_source="$3"

    git commit \
        -m "feat(arps): 应用 $tag 单提交覆盖层" \
        -m "基于官方上游 $tag 重放 ARPS 功能、fork 维护配置和标签构建流程。" \
        -m "ARPS-Upstream-Tag: $tag" \
        -m "ARPS-Upstream-Commit: $upstream_sha" \
        -m "ARPS-Overlay-Source: $overlay_source"
}

find_open_pr_number() {
    local sync_branch="$1"
    local repository_owner="${PR_REPOSITORY%%/*}"

    gh api --method GET "repos/$PR_REPOSITORY/pulls" \
        -f state=open \
        -f base="$TARGET_BRANCH" \
        -f head="$repository_owner:$sync_branch" \
        --jq '.[0].number // empty'
}

ensure_conflict_pr() {
    local sync_branch="$1"
    local tag="$2"
    local upstream_sha="$3"
    local conflicts="$4"
    local body_file
    local pr_number
    local pr_url
    local title

    if [[ "$OPEN_PR" != "true" ]]; then
        return 0
    fi
    if [[ -z "$PR_REPOSITORY" ]]; then
        fail "OPEN_PR=true 时必须设置 PR_REPOSITORY 或 GITHUB_REPOSITORY。"
    fi

    title="同步上游标签 $tag 到 ARPS"
    body_file="$(mktemp)"
    {
        echo "自动同步无法把 ARPS 单提交覆盖层重放到官方上游 \`$tag\`，已创建冲突交接分支。"
        echo
        echo "官方标签提交：\`$upstream_sha\`"
        echo "同步分支：\`$sync_branch\`"
        echo
        echo "冲突文件："
        echo '```'
        echo "$conflicts"
        echo '```'
        echo
        echo "请在同步分支上解决全部冲突，另建一个提交并推送到同一分支。不要合并此 PR。"
        echo "下一次同步任务会验证结果，将该分支压成官方标签之上的单一 ARPS 覆盖提交，随后更新 \`$TARGET_BRANCH\`、创建同名 fork 标签并关闭此 PR。"
        echo
        echo "交给 Codex Cloud 时，请发布以下新评论："
        echo '```text'
        echo "@codex 请解决这个上游标签同步 PR 中已经提交的全部冲突标记。"
        echo
        echo "此分支以官方上游标签提交为父提交，后面是冲突交接提交。请按语义合并上游变化和 ARPS 覆盖层，不要再次合并基础分支。"
        echo
        echo "要求："
        echo "- 保留 ARPS 捕获行为。"
        echo "- 保留 fork 自有的 .github/workflows、AGENTS.md 和 tools/fork。"
        echo "- 处理 WPF 冲突时，不要不加判断地选择 ours 或 theirs。"
        echo "- 运行相关检查，并报告所有无法在云端环境运行的项目。"
        echo "- 创建一个新的解决提交，只推送到此 PR 分支。"
        echo "- 不要合并此 PR。"
        echo '```'
    } > "$body_file"

    pr_number="$(find_open_pr_number "$sync_branch")"
    if [[ -n "$pr_number" ]]; then
        pr_url="$(
            gh api --method PATCH "repos/$PR_REPOSITORY/pulls/$pr_number" \
                --raw-field title="$title" \
                --field body=@"$body_file" \
                --jq .html_url
        )"
    else
        pr_url="$(
            gh api --method POST "repos/$PR_REPOSITORY/pulls" \
                --raw-field title="$title" \
                --raw-field head="$sync_branch" \
                --raw-field base="$TARGET_BRANCH" \
                --field body=@"$body_file" \
                --field draft=true \
                --field maintainer_can_modify=false \
                --jq .html_url
        )"
    fi

    rm -f "$body_file"
    write_output pr_url "$pr_url"
    printf '冲突交接 PR：%s\n' "$pr_url"
}

close_conflict_pr() {
    local sync_branch="$1"
    local pr_number

    if [[ "$OPEN_PR" != "true" || -z "$PR_REPOSITORY" ]]; then
        return 0
    fi

    pr_number="$(find_open_pr_number "$sync_branch")"
    if [[ -n "$pr_number" ]]; then
        gh api --method PATCH "repos/$PR_REPOSITORY/pulls/$pr_number" \
            --raw-field state=closed \
            --jq .html_url >/dev/null
    fi
}

conflict_paths_from_handoff() {
    local handoff_commit="$1"

    git show -s --format=%B "$handoff_commit" |
        sed -n 's/^ARPS-Conflict-File: //p'
}

has_conflict_markers() {
    local ref="$1"
    local conflict_paths="$2"
    local path

    while IFS= read -r path; do
        if [[ -z "$path" ]]; then
            continue
        fi
        if git grep -n -E '^(<<<<<<<|=======|>>>>>>>)' "$ref" -- "$path" \
            >/dev/null 2>&1; then
            return 0
        fi
    done <<< "$conflict_paths"

    return 1
}

publish_overlay() {
    local overlay_commit="$1"
    local tag="$2"
    local upstream_sha="$3"
    local before="$4"
    local existing_tag_commit=""
    local tag_refspec=()

    if [[ "$(git rev-parse "$overlay_commit^")" != "$upstream_sha" ]]; then
        fail "拒绝发布：ARPS 覆盖提交不是官方 $tag 的直接子提交。"
    fi

    if existing_tag_commit="$(remote_fork_tag_commit "$tag")"; then
        if [[ "$existing_tag_commit" != "$overlay_commit" ]]; then
            fail "fork 标签 $tag 已存在且指向 $existing_tag_commit，拒绝覆盖。"
        fi
    else
        git tag -f -a "$tag" -m "MAA-ARPS $tag" "$overlay_commit"
        tag_refspec=("refs/tags/$tag:refs/tags/$tag")
    fi

    git switch --detach "$overlay_commit"
    if [[ "$before" != "$overlay_commit" || ${#tag_refspec[@]} -gt 0 ]]; then
        git push --atomic \
            --force-with-lease="refs/heads/$TARGET_BRANCH:$before" \
            origin \
            "HEAD:refs/heads/$TARGET_BRANCH" \
            "${tag_refspec[@]}"
        write_output pushed true
    else
        write_output pushed false
    fi

    write_output tag "$tag"
    write_output upstream_sha "$upstream_sha"
    write_output conflict false
}

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

git fetch --force origin \
    "refs/heads/$TARGET_BRANCH:refs/remotes/origin/$TARGET_BRANCH"

before="$(git rev-parse "refs/remotes/origin/$TARGET_BRANCH")"
parent_count="$(git rev-list --parents -n 1 "$before" | awk '{ print NF - 1 }')"
if [[ "$parent_count" != "1" ]]; then
    fail "$TARGET_BRANCH 必须是官方稳定标签之上的单一覆盖提交。"
fi

current_tag="$(
    git show -s --format=%B "$before" |
        sed -nE 's/^ARPS-Upstream-Tag:[[:space:]]*(v[0-9]+\.[0-9]+\.[0-9]+)[[:space:]]*$/\1/p' |
        tail -n 1
)"
if [[ ! "$current_tag" =~ $STABLE_TAG_PATTERN ]]; then
    fail "$TARGET_BRANCH 的提交信息缺少有效的 ARPS-Upstream-Tag。"
fi

fetch_upstream_tag "$current_tag"
current_upstream_sha="$(upstream_tag_commit "$current_tag")"
if [[ "$(git rev-parse "$before^")" != "$current_upstream_sha" ]]; then
    fail "$TARGET_BRANCH 的父提交与官方 $current_tag 不一致。"
fi

target_tag="$INPUT_TAG"
if [[ -z "$target_tag" ]]; then
    target_tag="$(
        git ls-remote --tags --refs "$UPSTREAM_URL" 'refs/tags/v*' |
            sed 's#^.*refs/tags/##' |
            grep -E "$STABLE_TAG_PATTERN" |
            sort -V |
            tail -n 1 || true
    )"
fi
if [[ ! "$target_tag" =~ $STABLE_TAG_PATTERN ]]; then
    fail "没有找到有效的官方稳定标签。"
fi

fetch_upstream_tag "$target_tag"
target_upstream_sha="$(upstream_tag_commit "$target_tag")"
write_output tag "$target_tag"
write_output upstream_sha "$target_upstream_sha"

if [[ "$target_tag" == "$current_tag" ]]; then
    existing_tag_commit=""
    if existing_tag_commit="$(remote_fork_tag_commit "$target_tag")"; then
        if [[ "$existing_tag_commit" != "$before" ]]; then
            fail "fork 标签 $target_tag 未指向当前 ARPS 覆盖提交。"
        fi
        write_output pushed false
    else
        git tag -f -a "$target_tag" -m "MAA-ARPS $target_tag" "$before"
        git push origin "refs/tags/$target_tag:refs/tags/$target_tag"
        write_output pushed true
    fi
    write_output conflict false
    restore_target_branch "$before"
    exit 0
fi

newest_of_pair="$(printf '%s\n%s\n' "$current_tag" "$target_tag" | sort -V | tail -n 1)"
if [[ "$newest_of_pair" != "$target_tag" ]]; then
    fail "拒绝从 $current_tag 自动降级到 $target_tag。"
fi

sync_branch="${SYNC_BRANCH_PREFIX}-${target_tag}"
sync_remote_ref="refs/remotes/origin/$sync_branch"

if git ls-remote --exit-code --heads origin "$sync_branch" >/dev/null 2>&1; then
    git fetch --force origin \
        "refs/heads/$sync_branch:$sync_remote_ref"
    sync_sha="$(git rev-parse "$sync_remote_ref")"

    if ! git merge-base --is-ancestor "$target_upstream_sha" "$sync_sha"; then
        fail "现有同步分支 $sync_branch 并非基于官方 $target_tag。"
    fi

    handoff_commit="$(
        git rev-list --reverse "$target_upstream_sha..$sync_sha" |
            sed -n '1p'
    )"
    if [[ -z "$handoff_commit" ]] || \
        ! git show -s --format=%B "$handoff_commit" |
            grep '^ARPS-Conflict-Handoff: true$' >/dev/null; then
        fail "现有同步分支 $sync_branch 缺少冲突交接元数据。"
    fi

    conflict_paths="$(conflict_paths_from_handoff "$handoff_commit")"
    if [[ -z "$conflict_paths" ]]; then
        fail "现有同步分支 $sync_branch 没有记录冲突文件。"
    fi

    overlay_commit_count="$(git rev-list --count "$target_upstream_sha..$sync_sha")"
    if [[ "$overlay_commit_count" -ge 2 ]] && \
        ! has_conflict_markers "$sync_sha" "$conflict_paths"; then
        git switch --detach "$sync_sha"
        git reset --soft "$target_upstream_sha"
        restore_pinned_fork_workflows "$before"
        make_overlay_commit "$target_tag" "$target_upstream_sha" "$before"
        rebuilt_commit="$(git rev-parse HEAD)"
        publish_overlay \
            "$rebuilt_commit" "$target_tag" "$target_upstream_sha" "$before"
        close_conflict_pr "$sync_branch"
        git push \
            --force-with-lease="refs/heads/$sync_branch:$sync_sha" \
            origin ":refs/heads/$sync_branch"
        restore_target_branch "$rebuilt_commit"
        exit 0
    fi

    ensure_conflict_pr \
        "$sync_branch" "$target_tag" "$target_upstream_sha" "$conflict_paths"
    write_output conflict true
    write_output pushed false
    write_output sync_branch "$sync_branch"
    restore_target_branch "$before"
    exit 2
fi

git switch --detach "$target_upstream_sha"
set +e
git cherry-pick --no-commit "$before"
cherry_pick_status=$?
set -e

restore_pinned_fork_workflows "$before"
conflicts="$(git diff --name-only --diff-filter=U || true)"

if [[ "$cherry_pick_status" -eq 0 || -z "$conflicts" ]]; then
    make_overlay_commit "$target_tag" "$target_upstream_sha" "$before"
    rebuilt_commit="$(git rev-parse HEAD)"
    publish_overlay \
        "$rebuilt_commit" "$target_tag" "$target_upstream_sha" "$before"
    restore_target_branch "$rebuilt_commit"
    exit 0
fi

git add -A
if [[ -n "$(git diff --name-only --diff-filter=U || true)" ]]; then
    fail "无法把冲突快照暂存为普通提交。"
fi

message_file="$(mktemp)"
{
    echo "chore(ci): 暂存 $target_tag 覆盖层冲突"
    echo
    echo "ARPS-Conflict-Handoff: true"
    echo "ARPS-Upstream-Tag: $target_tag"
    echo "ARPS-Upstream-Commit: $target_upstream_sha"
    echo "ARPS-Overlay-Source: $before"
    while IFS= read -r path; do
        if [[ -n "$path" ]]; then
            echo "ARPS-Conflict-File: $path"
        fi
    done <<< "$conflicts"
} > "$message_file"
git commit -F "$message_file"
rm -f "$message_file"

git push origin "HEAD:refs/heads/$sync_branch"
ensure_conflict_pr \
    "$sync_branch" "$target_tag" "$target_upstream_sha" "$conflicts"

write_output conflict true
write_output pushed false
write_output sync_branch "$sync_branch"
restore_target_branch "$before"
exit 2
