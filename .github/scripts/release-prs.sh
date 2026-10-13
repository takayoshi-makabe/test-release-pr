#!/usr/bin/env bash
# release 対象の PR を列挙する。
#
#   release-prs.sh list <head>   対象 PR を JSON で出力 (status: included | excluded)
#   release-prs.sh body <head>   release PR の本文を出力 (OLD_BODY のチェック状態を引き継ぐ)
#
# 対象 = (develop または staging に merge 済みで <head> に含まれる PR) - (前回の release でリリース済みの PR)
#
# リリース済み = 前回 merge された release PR (staging → main) の head に含まれ、
#               かつその head 上で revert されていない PR。
# <head> 上で `git revert` されている PR は excluded (今回はリリースされず次回に持ち越し)。
set -euo pipefail

mode="$1"
head="$2"
production="${PRODUCTION_BRANCH:-main}"
develop="${DEVELOP_BRANCH:-develop}"
staging="${STAGING_BRANCH:-staging}"

# <ref> にだけある commit から revert 対象の sha を拾う。revert の revert は打ち消しとして扱う。
reverted_shas() {
  local ref="$1" active="" sha target
  for sha in $(git rev-list --reverse "origin/${develop}..${ref}"); do
    target=$(git log -1 --format=%B "$sha" | sed -nE 's/.*This reverts commit ([0-9a-f]{7,40}).*/\1/p' | head -1)
    [ -n "$target" ] || continue
    target=$(git rev-parse --verify -q "${target}^{commit}" || true)
    [ -n "$target" ] || continue
    if grep -q "^${target} " <<<"$active"; then
      active=$(grep -v "^${target} " <<<"$active" || true)
    else
      active+="${sha} ${target}"$'\n'
    fi
  done
  awk 'NF { print $2 }' <<<"$active"
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# develop 向けの PR に加えて、staging に直接 merge された PR も対象にする
for base in "$develop" "$staging"; do
  gh pr list --base "$base" --state merged --limit 500 --json number,title,author,mergeCommit
done |
  jq -s 'add | map({number, title, author: (.author.login // "ghost"), sha: .mergeCommit.oid})' >"$tmp/prs.json"
jq -r '.[].sha' "$tmp/prs.json" >"$tmp/candidates"

# 今回の head に含まれる PR / そのうち revert されているもの
git rev-list "$head" | { grep -Fx -f "$tmp/candidates" || true; } >"$tmp/in_head"
reverted_shas "$head" >"$tmp/reverted_in_head"

# 前回の release でリリース済みの PR
: >"$tmp/released"
last=$(gh pr list --base "$production" --head "$staging" --state merged --limit 1 \
  --json number --jq '.[0].number // empty')
if [ -n "$last" ]; then
  # staging は削除済みなので PR の head から取得する
  git fetch -q origin "+refs/pull/${last}/head:refs/remotes/origin/last-release-head"
  reverted_shas origin/last-release-head >"$tmp/reverted_in_last"
  git rev-list origin/last-release-head |
    { grep -Fx -f "$tmp/candidates" || true; } |
    { grep -Fxv -f "$tmp/reverted_in_last" || true; } >"$tmp/released"
fi

prs=$(
  jq --rawfile in_head "$tmp/in_head" \
    --rawfile released "$tmp/released" \
    --rawfile reverted "$tmp/reverted_in_head" '
    def lines: split("\n") | map(select(. != ""));
    ($in_head | lines) as $in_head
    | ($released | lines) as $released
    | ($reverted | lines) as $reverted
    | map(
        .sha as $sha
        | select(($in_head | index($sha)) != null and ($released | index($sha)) == null)
        | . + {status: (if ($reverted | index($sha)) != null then "excluded" else "included" end)})
    | sort_by(.number)' "$tmp/prs.json"
)

case "$mode" in
  list)
    echo "$prs"
    ;;
  body)
    checked=$(
      { grep -oE '^- \[x\] #[0-9]+' <<<"${OLD_BODY:-}" || true; } |
        { grep -oE '[0-9]+$' || true; } | jq -s '.'
    )
    jq -r --argjson checked "$checked" '
      def item: "#\(.number) \(.title) @\(.author)";
      def visible: map(select(.author | test("dependabot") | not));
      (map(select(.status == "included")) | visible) as $included
      | (map(select(.status == "excluded")) | visible) as $excluded
      | ["## Contents", ""]
        + ($included | map(
            "- [" + (if (.number as $n | $checked | index($n)) != null then "x" else " " end) + "] " + item))
        + (if ($excluded | length) > 0
           then ["", "## Excluded (reverted on staging)", ""] + ($excluded | map("- " + item))
           else [] end)
      | join("\n")' <<<"$prs"
    ;;
  *)
    echo "usage: $0 {list|body} <head>" >&2
    exit 1
    ;;
esac
