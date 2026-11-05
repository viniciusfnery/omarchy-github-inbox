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
  # One GraphQL round trip for everything the pane shows, including the
  # repo's merge settings, and only the last three comments.
  if [[ $kind == pr ]]; then
    q='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) {
      squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed
      item: pullRequest(number: $number) {
        number title state isDraft url createdAt body additions deletions changedFiles
        baseRefName headRefName headRefOid reviewDecision mergeable mergeStateStatus
        author { login } labels(first: 10) { nodes { name } }
        comments(last: 3) { nodes { author { login } createdAt body } }
        commits(last: 1) { nodes { commit { statusCheckRollup { contexts(first: 100) {
          nodes { __typename ... on CheckRun { status conclusion } ... on StatusContext { state } } } } } } } } } }'
  else
    q='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) {
      item: issue(number: $number) {
        number title state url createdAt body author { login }
        labels(first: 10) { nodes { name } } assignees(first: 10) { nodes { login } }
        comments(last: 3) { nodes { author { login } createdAt body } } } } }'
  fi
  # Owner and repo as strings (-f): -F would turn a numeric name into an int.
  json=$(gh api graphql -f query="$q" -f owner="$owner" -f repo="$repo" -F number="${BASH_REMATCH[4]}" 2>/dev/null) ||
    fail "GitHub did not return this $kind"
  # gh output is bounded here, before jq ever sees it, and goes in on stdin.
  (( ${#json} <= 2097152 )) || fail "GitHub data unexpectedly large"
  jq -e '.data.repository.item | type == "object"' >/dev/null 2>&1 <<<"$json" || fail "GitHub did not return this $kind"
  jq --arg kind "$kind" '
    def cut($n): (. // "") | if length > $n then .[0:$n] + "…" else . end;
    def login: ((. // {}).login // "");
    .data.repository as $r | $r.item as $p |
    {
      kind: $kind, number: $p.number, url: $p.url,
      title: ($p.title | cut(300)),
      state: (if $p.isDraft == true and $p.state == "OPEN" then "DRAFT" else ($p.state // "") end),
      author: ($p.author | login),
      createdAt: ($p.createdAt // ""),
      labels: [($p.labels.nodes // [])[] | .name | cut(50)][0:10],
      body: ($p.body | cut(1200)),
      comments: [($p.comments.nodes // [])[] | {author: (.author | login), createdAt: (.createdAt // ""), body: (.body | cut(400))}]
    } + if $kind == "pr" then {
      reviewDecision: ($p.reviewDecision // ""),
      mergeable: ($p.mergeable // ""),
      mergeState: ($p.mergeStateStatus // ""),
      additions: $p.additions, deletions: $p.deletions, changedFiles: $p.changedFiles,
      base: ($p.baseRefName // ""), head: ($p.headRefName // ""), headSha: ($p.headRefOid // ""),
      checks: (reduce (($p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes) // [])[] as $c
        ({passed: 0, failed: 0, pending: 0};
        (($c.conclusion // $c.state) // "") as $res
        | if ($c.__typename == "CheckRun" and ($c.status // "") != "COMPLETED") or ($res | IN("PENDING", "EXPECTED", ""))
          then .pending += 1
          elif ($res | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then .passed += 1
          else .failed += 1 end)),
      mergeMethods: [
        (if $r.squashMergeAllowed == true then "squash" else empty end),
        (if $r.mergeCommitAllowed == true then "merge" else empty end),
        (if $r.rebaseMergeAllowed == true then "rebase" else empty end)]
    } else {
      assignees: [($p.assignees.nodes // [])[] | login][0:10]
    } end' <<<"$json" || fail "Failed to read GitHub data"
  ;;
comment)
  # The limit is in bytes, like the read: counting characters would let a
  # long non-ASCII comment through cut short.
  body=$(head -c 65537)
  [[ -n ${body//[[:space:]]/} ]] || fail "Empty comment"
  (( $(printf '%s' "$body" | wc -c) <= 65536 )) || fail "Comment too long"
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
