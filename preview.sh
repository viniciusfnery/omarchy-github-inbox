#!/bin/bash
# Pull request and issue previews for the panel, and the two actions it can
# take on them:
#   preview.sh view <url>
#   preview.sh comment <url>                       (comment text on stdin)
#   preview.sh merge <pr url> <squash|merge|rebase> <head sha> <base branch>
#   preview.sh ready <pr url>                      (a draft, ready for review)
# Output is one JSON object, {error: "..."} on failure. Every entry point
# checks the URL first, so only a github.com PR or issue ever reaches gh,
# never another host or something gh would read as a flag.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

# The message goes to jq on stdin, bounded: GitHub error text never becomes
# an argument (visible to other users, and capped by the kernel).
fail() { printf '%s' "${1:0:2000}" | jq -Rs '{error: .}'; exit 0; }
command -v jq >/dev/null || { echo '{"error":"jq not found"}'; exit 0; }
command -v gh >/dev/null || fail "GitHub CLI (gh) not found"
# A call that hangs (a dropped network) must not hold the pane on
# "Merging…" forever: timeout stops gh after 30 s and exits 124.
gh() { timeout 30 gh "$@"; }
# Fails with gh's message, or says the call timed out and the action may
# have gone through.
refused() { (( $1 == 124 )) && fail "No answer from GitHub in 30 seconds. Check the $noun on GitHub before trying again"; fail "$2"; }

verb=${1:-}
url=${2:-}
[[ $url =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/(pull|issues)/([0-9]+)$ ]] ||
  fail "Not a GitHub pull request or issue"
owner=${BASH_REMATCH[1]}
repo=${BASH_REMATCH[2]}
number=${BASH_REMATCH[4]}
kind=$([[ ${BASH_REMATCH[3]} == pull ]] && echo pr || echo issue)
noun=$([[ $kind == pr ]] && echo PR || echo issue)

case $verb in
view)
  # One GraphQL round trip for everything the pane shows, including the
  # repo's merge settings, and only the last three comments.
  # shellcheck disable=SC2016 # $owner and friends are GraphQL variables
  if [[ $kind == pr ]]; then
    q='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) {
      squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed viewerPermission
      item: pullRequest(number: $number) {
        number title state isDraft url createdAt updatedAt body additions deletions changedFiles
        baseRefName headRefName headRefOid reviewDecision mergeable mergeStateStatus
        author { login } labels(first: 10) { nodes { name } }
        comments(last: 3) { totalCount nodes { author { login __typename } createdAt body } }
        reviews(last: 3) { totalCount nodes { author { login __typename } createdAt state body } }
        latestOpinionatedReviews(first: 10) { nodes { author { login } state } }
        reviewRequests(first: 10) { nodes { requestedReviewer { __typename ... on User { login } ... on Bot { login }
          ... on Mannequin { login } ... on Team { combinedSlug } } } }
        commits(last: 1) { nodes { commit { statusCheckRollup { state contexts(first: 100) { totalCount
          nodes { __typename ... on CheckRun { status conclusion } ... on StatusContext { state } } } } } } } } } }'
  else
    # shellcheck disable=SC2016
    q='query($owner: String!, $repo: String!, $number: Int!) { repository(owner: $owner, name: $repo) {
      item: issue(number: $number) {
        number title state stateReason url createdAt updatedAt body author { login }
        labels(first: 10) { nodes { name } } assignees(first: 10) { nodes { login } }
        comments(last: 3) { totalCount nodes { author { login __typename } createdAt body } } } } }'
  fi
  # Owner and repo as strings (-f): -F would turn a numeric name into an int.
  errfile=$(mktemp) || fail "No temporary file"
  trap 'rm -f "$errfile"' EXIT
  json=$(gh api graphql -f query="$q" -f owner="$owner" -f repo="$repo" -F number="$number" 2>"$errfile") || {
    (( $? == 124 )) && fail "No answer from GitHub in 30 seconds: try again"
    # Name the cause, so Retry is not a guess. Only a bounded first line of
    # gh's own message is ever shown, never as an argument.
    err=$(head -c 500 "$errfile" | head -n 1)
    case $err in
    *"Bad credentials"* | *"HTTP 401"* | *"auth login"*) fail "Not signed in to GitHub: run gh auth login" ;;
    *"Could not resolve to a"* | *"HTTP 404"* | *"NOT_FOUND"*) fail "This $noun does not exist, or you cannot see it" ;;
    *"rate limit"*) fail "GitHub rate limit reached, try again in a minute" ;;
    *"connecting to"* | *"no such host"* | *"timeout"* | *"network"*) fail "GitHub is unreachable: check the connection" ;;
    *) fail "GitHub did not return this $noun: ${err:-no details}" ;;
    esac
  }
  # gh output is bounded here, before jq ever sees it, and goes in on stdin.
  (( ${#json} <= 2097152 )) || fail "GitHub data unexpectedly large"
  jq -e '.data.repository.item | type == "object"' >/dev/null 2>&1 <<<"$json" || fail "GitHub did not return this $noun"
  jq --arg kind "$kind" '
    # HTML comments (bots open with long hidden ones) go before the cut, so
    # the cut keeps text a reader would see. split and index, not a lazy
    # regex, which is quadratic on a body of unclosed "<!--". Text after an
    # unclosed one goes, as on GitHub.
    def nocomments: split("<!--") | .[0] + ([.[1:][] | index("-->") as $i | if $i then .[$i + 3:] else "" end] | add // "");
    def cut($n): (. // "") | nocomments | if length > $n then .[0:$n] + "…" else . end;
    def login: ((. // {}).login // "");
    .data.repository as $r | $r.item as $p |
    {
      kind: $kind, number: $p.number, url: $p.url,
      title: ($p.title | cut(300)),
      state: (if $p.isDraft == true and $p.state == "OPEN" then "DRAFT" else ($p.state // "") end),
      author: ($p.author | login),
      createdAt: ($p.createdAt // ""),
      updatedAt: ($p.updatedAt // ""),
      labels: [($p.labels.nodes // [])[] | .name | cut(50)][0:10],
      body: ($p.body | cut(1200)),
      # Comments and reviews that say something, in time order, the last
      # three. A review with no body and no verdict (only inline comments)
      # has nothing to show here.
      comments: ([(($p.comments.nodes // [])[] | . + {state: ""}),
          (($p.reviews.nodes // [])[] | select(((.body // "") != "") or (.state | IN("APPROVED", "CHANGES_REQUESTED"))))]
        | sort_by(.createdAt // "") | .[-3:]
        | map({author: (.author | login), createdAt: (.createdAt // ""), body: (.body | cut(400)), state: (.state // ""),
          bot: (((.author // {}).__typename // "") == "Bot" or ((.author | login) | endswith("[bot]")))})),
      commentTotal: ((($p.comments.totalCount) // 0)
        # Every review counts, as on GitHub, so the total never reads low.
        + (($p.reviews.totalCount) // 0))
    } + if $kind == "pr" then {
      reviewDecision: ($p.reviewDecision // ""),
      reviews: [($p.latestOpinionatedReviews.nodes // [])[] | {author: (.author | login), state: (.state // "")}][0:10],
      requested: [($p.reviewRequests.nodes // [])[] | .requestedReviewer // {} | (.login // .combinedSlug // empty) | cut(80)][0:10],
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
      assignees: [($p.assignees.nodes // [])[] | login][0:10],
      stateReason: ($p.stateReason // "")
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
    refused $? "GitHub refused the comment: ${err%%$'\n'*}"
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
  now=$(gh pr view "$url" --json baseRefName,headRefOid,state 2>/dev/null) || refused $? "GitHub did not return this PR"
  now_base=$(jq -r '.baseRefName // ""' <<<"$now" 2>/dev/null)
  [[ $now_base == "$base" ]] || fail "This PR now targets ${now_base:-another branch}, not $base. Review it again."
  [[ $(jq -r '.headRefOid // ""' <<<"$now" 2>/dev/null) == "$sha" ]] || fail "New commits arrived. Review them, then merge again."
  [[ $(jq -r '.state // ""' <<<"$now" 2>/dev/null) == OPEN ]] || fail "This PR is no longer open"
  out=$(gh api --method PUT "repos/$owner/$repo/pulls/$number/merge" -f merge_method="$method" -f sha="$sha" 2>&1) || {
    (( $? == 124 )) && refused 124 ""
    fail "GitHub refused the merge: $(jq -r '.message // empty' <<<"${out%%$'\n'gh:*}" 2>/dev/null || echo "${out%%$'\n'*}")"
  }
  [[ $(jq -r '.merged // false' <<<"$out" 2>/dev/null) == true ]] || fail "GitHub did not merge it"
  # The inbox changed: drop its 60s cache so the next refresh asks GitHub.
  rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-github-tasks.json"
  echo '{"ok": true}'
  ;;
ready)
  # Reversible (a PR can go back to draft), so one confirmed step is enough.
  [[ $kind == pr ]] || fail "Only pull requests have drafts"
  err=$(gh pr ready "$url" 2>&1 >/dev/null) || refused $? "GitHub refused: ${err%%$'\n'*}"
  echo '{"ok": true}'
  ;;
*)
  fail "Unknown action"
  ;;
esac
