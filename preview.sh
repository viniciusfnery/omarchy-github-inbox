#!/bin/bash
# Pull request and issue previews for the panel, and the two actions it can
# take on them:
#   preview.sh view <url>
#   preview.sh comment <url>                       (comment text on stdin)
#   preview.sh merge <pr url> <squash|merge|rebase> <head sha>
# Output is one JSON object, {error: "..."} on failure. Every entry point
# checks the URL first, so only a github.com PR or issue ever reaches gh,
# never another host or something gh would read as a flag.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

fail() { jq -n --arg e "$1" '{error: $e}'; exit 0; }
command -v jq >/dev/null || { echo '{"error":"jq not found"}'; exit 0; }
command -v gh >/dev/null || fail "GitHub CLI (gh) not found"

verb=${1:-}
url=${2:-}
[[ $url =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/(pull|issues)/([0-9]+)$ ]] ||
  fail "Not a GitHub pull request or issue"
owner=${BASH_REMATCH[1]}
repo=${BASH_REMATCH[2]}
kind=$([[ ${BASH_REMATCH[3]} == pull ]] && echo pr || echo issue)

case $verb in
view)
  if [[ $kind == pr ]]; then
    fields=number,title,state,isDraft,author,createdAt,body,labels,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,additions,deletions,changedFiles,baseRefName,headRefName,headRefOid,comments,url
  else
    fields=number,title,state,author,createdAt,body,labels,assignees,comments,url
  fi
  json=$(gh "$kind" view "$url" --json "$fields" 2>/dev/null) || fail "GitHub did not return this $kind"
  # gh output is bounded here, before jq ever sees it.
  (( ${#json} <= 2097152 )) || fail "GitHub data unexpectedly large"
  jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json" || fail "GitHub did not return this $kind"
  methods='{}'
  [[ $kind == pr ]] && methods=$(gh api "repos/$owner/$repo" 2>/dev/null) && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$methods" || methods='{}'
  jq --arg kind "$kind" --argjson m "$methods" '
    def cut($n): (. // "") | if length > $n then .[0:$n] + "…" else . end;
    def login: (.login // "");
    {
      kind: $kind, number, url,
      title: (.title | cut(300)),
      state: (if .isDraft == true and .state == "OPEN" then "DRAFT" else (.state // "") end),
      author: (.author | login),
      createdAt: (.createdAt // ""),
      labels: [(.labels // [])[] | .name | cut(50)][0:10],
      body: (.body | cut(1200)),
      comments: [(.comments // [])[-3:][] | {author: (.author | login), createdAt: (.createdAt // ""), body: (.body | cut(400))}]
    } + if $kind == "pr" then {
      reviewDecision: (.reviewDecision // ""),
      mergeable: (.mergeable // ""),
      mergeState: (.mergeStateStatus // ""),
      additions, deletions, changedFiles,
      base: (.baseRefName // ""), head: (.headRefName // ""), headSha: (.headRefOid // ""),
      checks: (reduce (.statusCheckRollup // [])[] as $c ({passed: 0, failed: 0, pending: 0};
        (($c.conclusion // $c.state) // "") as $r
        | if ($c.__typename == "CheckRun" and ($c.status // "") != "COMPLETED") or ($r | IN("PENDING", "EXPECTED", ""))
          then .pending += 1
          elif ($r | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then .passed += 1
          else .failed += 1 end)),
      mergeMethods: [
        (if $m.allow_squash_merge == true then "squash" else empty end),
        (if $m.allow_merge_commit == true then "merge" else empty end),
        (if $m.allow_rebase_merge == true then "rebase" else empty end)]
    } else {
      assignees: [(.assignees // [])[] | login][0:10]
    } end' <<<"$json" || fail "Failed to read GitHub data"
  ;;
comment)
  body=$(head -c 65537)
  [[ -n ${body//[[:space:]]/} ]] || fail "Empty comment"
  (( ${#body} <= 65536 )) || fail "Comment too long"
  err=$(printf '%s' "$body" | gh "$kind" comment "$url" --body-file - 2>&1 >/dev/null) ||
    fail "GitHub refused the comment: ${err%%$'\n'*}"
  echo '{"ok": true}'
  ;;
merge)
  [[ $kind == pr ]] || fail "Only pull requests merge"
  method=${3:-}
  sha=${4:-}
  [[ $method =~ ^(squash|merge|rebase)$ ]] || fail "Unknown merge method"
  # The head the user looked at: a PR pushed to since then does not merge.
  [[ $sha =~ ^[0-9a-f]{6,40}$ ]] || fail "Missing head commit"
  err=$(gh pr merge "$url" "--$method" --match-head-commit "$sha" 2>&1 >/dev/null) ||
    fail "GitHub refused the merge: ${err%%$'\n'*}"
  echo '{"ok": true}'
  ;;
*)
  fail "Unknown action"
  ;;
esac
