#!/bin/bash
# Pull request and issue previews for the panel, and the two actions it can
# take on them:
#   preview.sh view <url>
#   preview.sh comment <url>                       (comment text on stdin)
#   preview.sh merge <pr url> <squash|merge|rebase> <head sha> <base branch>
# Output is one JSON object, {error: "..."} on failure. Every entry point
# checks the URL first, so only a github.com PR or issue ever reaches gh,
# never another host or something gh would read as a flag.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

# The message goes to jq on stdin, bounded: GitHub error text never becomes
# an argument (visible to other users, and capped by the kernel).
fail() { printf '%s' "${1:0:2000}" | jq -Rs '{error: .}'; exit 0; }
command -v jq >/dev/null || { echo '{"error":"jq not found"}'; exit 0; }
command -v gh >/dev/null || fail "GitHub CLI (gh) not found"

verb=${1:-}
url=${2:-}
[[ $url =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/(pull|issues)/([0-9]+)$ ]] ||
  fail "Not a GitHub pull request or issue"
owner=${BASH_REMATCH[1]}
repo=${BASH_REMATCH[2]}
number=${BASH_REMATCH[4]}
kind=$([[ ${BASH_REMATCH[3]} == pull ]] && echo pr || echo issue)

case $verb in
view)
  # One GraphQL round trip for everything the pane shows, including the
  # repo's merge settings, and only the last three comments.
  if [[ $kind == pr ]]; then
    q='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) {
      squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed viewerPermission
      item: pullRequest(number: $number) {
        number title state isDraft url createdAt body additions deletions changedFiles
        baseRefName headRefName headRefOid reviewDecision mergeable mergeStateStatus
        author { login } labels(first: 10) { nodes { name } }
        comments(last: 3) { nodes { author { login } createdAt body } }
        commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { totalCount
          nodes { __typename ... on CheckRun { status conclusion } ... on StatusContext { state } } } } } } } } } }'
  else
    q='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) {
      item: issue(number: $number) {
        number title state url createdAt body author { login }
        labels(first: 10) { nodes { name } } assignees(first: 10) { nodes { login } }
        comments(last: 3) { nodes { author { login } createdAt body } } } } }'
  fi
  # Owner and repo as strings (-f): -F would turn a numeric name into an int.
  errfile=$(mktemp) || fail "No temporary file"
  trap 'rm -f "$errfile"' EXIT
  json=$(gh api graphql -f query="$q" -f owner="$owner" -f repo="$repo" -F number="$number" 2>"$errfile") || {
    # Name the cause, so Retry is not a guess. Only a bounded first line of
    # gh's own message is ever shown, never as an argument.
    err=$(head -c 500 "$errfile" | head -n 1)
    case $err in
    *"Bad credentials"* | *"HTTP 401"* | *"auth login"*) fail "Not signed in to GitHub: run gh auth login" ;;
    *"Could not resolve to a"* | *"HTTP 404"* | *"NOT_FOUND"*) fail "This $kind does not exist, or you cannot see it" ;;
    *"rate limit"*) fail "GitHub rate limit reached, try again in a minute" ;;
    *"connecting to"* | *"no such host"* | *"timeout"* | *"network"*) fail "GitHub is unreachable: check the connection" ;;
    *) fail "GitHub did not return this $kind: ${err:-no details}" ;;
    esac
  }
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
      checks: (($p.commits.nodes[0].commit.statusCheckRollup) as $roll | (reduce (($roll.contexts.nodes) // [])[] as $c
        ({passed: 0, failed: 0, pending: 0};
        (($c.conclusion // $c.state) // "") as $res
        | if ($c.__typename == "CheckRun" and ($c.status // "") != "COMPLETED") or ($res | IN("PENDING", "EXPECTED", ""))
          then .pending += 1
          elif ($res | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then .passed += 1
          else .failed += 1 end)
        # Only 100 contexts are counted; the overall state covers them all.
        + {total: (($roll.contexts.totalCount) // 0), state: (($roll.state) // "")})),
      # Read and triage access cannot merge; say so before the confirmation.
      canMerge: ($r.viewerPermission | IN("ADMIN", "MAINTAIN", "WRITE")),
      mergeMethods: [
        (if $r.squashMergeAllowed == true then "squash" else empty end),
        (if $r.mergeCommitAllowed == true then "merge" else empty end),
        (if $r.rebaseMergeAllowed == true then "rebase" else empty end)]
    } else {
      assignees: [($p.assignees.nodes // [])[] | login][0:10]
    } end' <<<"$json" || fail "Failed to read GitHub data"
  ;;
comment)
  # Read into a private temp file and post that file: the byte count and the
  # NUL check see exactly what is posted ($(...) drops NULs and trailing
  # newlines, which once let a long comment through cut short).
  tmp=$(mktemp) || fail "No temporary file"
  trap 'rm -f "$tmp"' EXIT
  # A write cut short (disk full, a file-size limit) must not post the part
  # that made it to disk.
  head -c 65537 >"$tmp" || fail "Could not read the comment"
  size=$(wc -c <"$tmp") || fail "Could not read the comment"
  (( size <= 65536 )) || fail "Comment too long"
  (( $(tr -d '\000' <"$tmp" | wc -c) == size )) || fail "Comment contains a NUL byte"
  [[ -n $(tr -d '[:space:]' <"$tmp" | head -c 1) ]] || fail "Empty comment"
  err=$(gh "$kind" comment "$url" --body-file "$tmp" 2>&1 >/dev/null) ||
    fail "GitHub refused the comment: ${err%%$'\n'*}"
  echo '{"ok": true}'
  ;;
merge)
  [[ $kind == pr ]] || fail "Only pull requests merge"
  method=${3:-}
  sha=${4:-}
  base=${5:-}
  [[ $method =~ ^(squash|merge|rebase)$ ]] || fail "Unknown merge method"
  # The head the user looked at: a PR pushed to since then does not merge.
  [[ $sha =~ ^[0-9a-f]{6,40}$ ]] || fail "Missing head commit"
  [[ $base =~ ^[A-Za-z0-9._/-]+$ ]] || fail "Missing base branch"
  # GitHub's merge APIs pin the head (sha) but not the base, so the base is
  # read again right before the merge, leaving a window of about a second.
  # The REST merge endpoint merges now or fails: it never joins a merge
  # queue or turns on auto-merge, as `gh pr merge` would on such a base.
  now=$(gh pr view "$url" --json baseRefName,headRefOid,state 2>/dev/null) || fail "GitHub did not return this pr"
  now_base=$(jq -r '.baseRefName // ""' <<<"$now" 2>/dev/null)
  [[ $now_base == "$base" ]] || fail "This PR now targets ${now_base:-another branch}, not $base. Review it again."
  [[ $(jq -r '.headRefOid // ""' <<<"$now" 2>/dev/null) == "$sha" ]] || fail "New commits arrived. Review them, then merge again."
  [[ $(jq -r '.state // ""' <<<"$now" 2>/dev/null) == OPEN ]] || fail "This PR is no longer open"
  out=$(gh api --method PUT "repos/$owner/$repo/pulls/$number/merge" -f merge_method="$method" -f sha="$sha" 2>&1) ||
    fail "GitHub refused the merge: $(jq -r '.message // empty' <<<"${out%%$'\n'gh:*}" 2>/dev/null || echo "${out%%$'\n'*}")"
  [[ $(jq -r '.merged // false' <<<"$out" 2>/dev/null) == true ]] || fail "GitHub did not merge it"
  # The inbox changed: drop its 60s cache so the next refresh asks GitHub.
  rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-github-tasks.json"
  echo '{"ok": true}'
  ;;
*)
  fail "Unknown action"
  ;;
esac
