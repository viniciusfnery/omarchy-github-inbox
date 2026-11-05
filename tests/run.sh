#!/bin/bash
# Test suite for fetch.sh. Runs the real script against a fake `gh` (tests/bin)
# serving generated fixtures, in an isolated $HOME so the developer's own
# shims, cache, and auth can't leak in. No network, no token.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
FETCH="$PWD/fetch.sh"
TESTS_DIR="$PWD/tests"
BASE_PATH="$PATH"

pass=0
fail=0
t() {
  if [[ $2 == true ]]; then
    pass=$((pass + 1))
    echo "ok    $1"
  else
    fail=$((fail + 1))
    echo "FAIL  $1"
  fi
}

# jqt '<jq predicate>' '<json>' -> true/false
jqt() { jq -e "$1" <<<"$2" >/dev/null 2>&1 && echo true || echo false; }

iso() { date -u -d "$1" +%Y-%m-%dT%H:%M:%SZ; }

# One search-result item in the post-`--jq .items` shape. PR items carry a
# pull_request key and a /pull/ web URL, like the real search API.
item() { # id title repo number kind date
  jq -n --argjson id "$1" --arg title "$2" --arg repo "$3" --argjson n "$4" --arg kind "$5" --arg d "$6" '
    {id: $id, title: $title, number: $n, draft: false, updated_at: $d, closed_at: $d,
     html_url: ("https://github.com/" + $repo + (if $kind == "pr" then "/pull/" else "/issues/" end) + ($n | tostring)),
     repository_url: ("https://api.github.com/repos/" + $repo)}
    + (if $kind == "pr" then {pull_request: {url: "x"}} else {} end)'
}

write_fixtures() {
  local d="$1" recent old
  recent=$(iso "2 days ago")
  old=$(iso "60 days ago")

  jq -s . >"$d/authored.json" <<EOF
$(item 1 "My PR one" "acme/repo1" 1 pr "$recent")
$(item 2 "My PR two" "testorg/repo2" 2 pr "$recent")
EOF
  item 1 "My PR one" "acme/repo1" 1 pr "$recent" | jq -s . >"$d/assigned.json"
  item 3 "Please review" "testorg/repo2" 3 pr "$recent" | jq -s . >"$d/reviews.json"
  item 4 "Assigned issue" "acme/repo1" 4 issue "$recent" | jq -s . >"$d/issues.json"
  jq -s . >"$d/mentions.json" <<EOF
$(item 5 "Mentioned with unread notification" "acme/repo1" 5 issue "$recent")
$(item 6 "Mentioned, all read" "testorg/repo2" 6 issue "$recent")
EOF
  jq -s . >"$d/closed-prs.json" <<EOF
$(item 7 "Recently closed PR" "acme/repo1" 7 pr "$recent")
$(item 8 "Ancient closed PR" "acme/repo1" 8 pr "$old")
EOF
  item 9 "Recently closed issue" "acme/repo1" 9 issue "$recent" | jq -s . >"$d/closed-issues.json"
  jq -s . >"$d/closed-mentions.json" <<EOF
$(item 9 "Recently closed issue" "acme/repo1" 9 issue "$recent")
$(item 10 "Closed PR I was mentioned in" "testorg/repo2" 10 pr "$recent")
EOF

  jq -n --arg d "$recent" '[
    {id: "11", reason: "mention", updated_at: $d,
     subject: {title: "Mentioned with unread notification", type: "Issue",
               url: "https://api.github.com/repos/acme/repo1/issues/5"},
     repository: {full_name: "acme/repo1", html_url: "https://github.com/acme/repo1"}},
    {id: "12", reason: "ci_activity", updated_at: $d,
     subject: {title: "CI failed", type: "CheckSuite", url: null},
     repository: {full_name: "acme/repo1", html_url: "https://github.com/acme/repo1"}},
    {id: "13", reason: "review_requested", updated_at: $d,
     subject: {title: "Please review", type: "PullRequest",
               url: "https://api.github.com/repos/testorg/repo2/pulls/3"},
     repository: {full_name: "testorg/repo2", html_url: "https://github.com/testorg/repo2"}}
  ]' >"$d/notifications.json"
}

fresh_env() {
  TMP=$(mktemp -d)
  export HOME="$TMP/home"
  export XDG_CACHE_HOME="$TMP/cache"
  export PATH="$TESTS_DIR/bin:$BASE_PATH"
  export FAKE_GH_FIXTURES="$TMP/fixtures"
  export FAKE_GH_LOG="$TMP/gh.log"
  unset FAKE_GH_AUTH_FAIL FAKE_GH_API_FAIL FAKE_GH_PATCH_FAIL FAKE_NOTIFY_ACTION
  mkdir -p "$HOME" "$XDG_CACHE_HOME" "$FAKE_GH_FIXTURES"
  : >"$FAKE_GH_LOG"
  write_fixtures "$FAKE_GH_FIXTURES"
  CACHE="$XDG_CACHE_HOME/omarchy-github-tasks.json"
}

# ---------------------------------------------------------------- happy path
fresh_env
out=$(bash "$FETCH")
t "happy: valid JSON, no error" "$(jqt '.error == "" and .user == "testuser"' "$out")"
t "happy: authored+assigned PRs dedupe by id" "$(jqt '.prs | length == 2' "$out")"
t "happy: reviews and issues pass through" "$(jqt '(.reviews | length == 1) and (.issues | length == 1)' "$out")"
t "happy: mention with unread notification is annotated" \
  "$(jqt '.mentions[] | select(.number == 5) | .notifUnread == true and .threadId == "11"' "$out")"
t "happy: mention without notification stays unannotated" \
  "$(jqt '.mentions[] | select(.number == 6) | .notifUnread == false' "$out")"
t "happy: mention-reason notifications are filtered out" \
  "$(jqt '(.notifications | length == 2) and ([.notifications[].reason] | index("mention") | not)' "$out")"
t "happy: PR notification URL munged /pulls/ -> /pull/" \
  "$(jqt '.notifications[] | select(.threadId == "13") | .url == "https://github.com/testorg/repo2/pull/3"' "$out")"
t "happy: subject-less notification falls back to repo URL" \
  "$(jqt '.notifications[] | select(.threadId == "12") | .url == "https://github.com/acme/repo1"' "$out")"
t "happy: closed merges three sources, dedupes, drops >30d" \
  "$(jqt '(.closed | length == 3) and ([.closed[].number] | sort == [7, 9, 10])' "$out")"
t "happy: closed kinds detected (mention-sourced PR included)" \
  "$(jqt '[.closed[] | select(.kind == "pr")] | length == 2' "$out")"
t "happy: result cached" "$(jqt '.error == ""' "$(cat "$CACHE")")"
t "happy: output carries when GitHub was asked, in epoch seconds" \
  "$(jqt '(.fetchedAt | type == "number") and (now - .fetchedAt < 60)' "$out")"

# A mention notification on a thread the open-mentions search cannot see (a
# closed thread, say) must stay in Notifications instead of vanishing.
fresh_env
jq --arg d "$(iso "1 hour ago")" '. + [{id: "14", reason: "mention", updated_at: $d,
  subject: {title: "Mentioned on a closed thread", type: "Issue",
            url: "https://api.github.com/repos/acme/repo1/issues/99"},
  repository: {full_name: "acme/repo1", html_url: "https://github.com/acme/repo1"}}]' \
  "$FAKE_GH_FIXTURES/notifications.json" >"$TMP/n.json" && mv "$TMP/n.json" "$FAKE_GH_FIXTURES/notifications.json"
out=$(bash "$FETCH")
t "mentions: a mention notification outside the mentions list stays a notification" \
  "$(jqt '([.notifications[].threadId] | index("14")) and ([.notifications[].threadId] | index("11") | not)' "$out")"

# ------------------------------------------------------------- cache behavior
calls_before=$(wc -l <"$FAKE_GH_LOG")
out2=$(bash "$FETCH")
t "cache: second run served from cache, no API calls" \
  "$([[ $(wc -l <"$FAKE_GH_LOG") -eq $calls_before && "$out2" == "$out" ]] && echo true || echo false)"

fresh_env
: >"$CACHE" # poisoned: exists, empty
out=$(bash "$FETCH")
t "cache: empty (poisoned) cache is ignored and rebuilt" \
  "$(jqt '.error == "" and (.prs | length == 2)' "$out")"

# ------------------------------------------------------------- failure modes
fresh_env
export FAKE_GH_API_FAIL=1
out=$(bash "$FETCH")
# The panel keeps its last good lists on an error record, so a rate-limited
# refresh must say so instead of passing for an empty inbox.
t "rate limit: error bodies on stdout become an error record, not empty lists" \
  "$(jqt '(.error | contains("GitHub API")) and .prs == [] and .notifications == []' "$out")"
t "rate limit: nothing is cached" "$([[ ! -e $CACHE ]] && echo true || echo false)"

fresh_env
export FAKE_GH_AUTH_FAIL=1
out=$(bash "$FETCH")
t "signed out: clean error record" \
  "$(jqt '(.error | contains("Not signed in")) and .prs == []' "$out")"

# ------------------------------------------------------------- huge payloads
fresh_env
long=$(printf 'a%.0s' $(seq 1 1000))
jq -n --arg t "$long" --arg d "$(iso "2 days ago")" '[range(300) | {
  id: (. + 100 | tostring), reason: "ci_activity", updated_at: $d,
  subject: {title: ($t + (. | tostring)), type: "CheckSuite", url: null},
  repository: {full_name: "acme/repo1", html_url: "https://github.com/acme/repo1"}}]' \
  >"$FAKE_GH_FIXTURES/notifications.json"
size=$(wc -c <"$FAKE_GH_FIXTURES/notifications.json")
out=$(bash "$FETCH")
t "huge payload: ${size}B of notifications clears the 128KB argv limit" \
  "$([[ $size -gt 200000 ]] && jqt '.notifications | length == 300' "$out")"

# ------------------------------------------------------------------ settings
fresh_env
bash "$FETCH" --mentions 7 >/dev/null
t "settings: --mentions changes the mention query size" \
  "$(grep -q 'is:open+mentions:@me&sort=updated&order=desc&per_page=7' "$FAKE_GH_LOG" && echo true || echo false)"

fresh_env
out=$(bash "$FETCH" --closed-days 1)
t "settings: --closed-days shrinks the closed window" "$(jqt '.closed == []' "$out")"

# ----------------------------------------------------------------- mark-read
fresh_env
echo '{"cached": true}' >"$CACHE"
bash "$FETCH" --mark-read 42 >/dev/null
t "mark-read: PATCHes the thread and drops the cache" \
  "$(grep -q 'api --method PATCH notifications/threads/42' "$FAKE_GH_LOG" && [[ ! -e $CACHE ]] && echo true || echo false)"

fresh_env
bash "$FETCH" --mark-read 42 43 >/dev/null
t "mark-read: several ids in one call PATCH each thread" \
  "$(grep -q 'notifications/threads/42' "$FAKE_GH_LOG" && grep -q 'notifications/threads/43' "$FAKE_GH_LOG" && echo true || echo false)"

fresh_env
export FAKE_GH_PATCH_FAIL=43
out=$(bash "$FETCH" --mark-read 42 43)
t "mark-read: prints the ids GitHub refused, one per line" "$([[ $out == 43 ]] && echo true || echo false)"
unset FAKE_GH_PATCH_FAIL

fresh_env
bash "$FETCH" --mark-read 42 "1;touch $TMP/pwned" "../x" >/dev/null
t "mark-read: non-numeric ids are skipped, numeric ones still sent" \
  "$([[ $(grep -c PATCH "$FAKE_GH_LOG") -eq 1 && ! -e $TMP/pwned ]] && echo true || echo false)"

# ------------------------------------------------------ desktop notifications
# notify.sh detaches one waiter per notification. FAKE_NOTIFY_ACTION is what
# the fake notify-send reports the user clicked.
wait_for() { for _ in $(seq 50); do eval "$1" && return 0; sleep 0.1; done; return 1; }

fresh_env
export FAKE_NOTIFY_ACTION=default
bash "$PWD/notify.sh" "https://github.com/acme/repo1/pull/1" "Fix it" "acme/repo1 · review requested"
t "notify: click opens the github.com URL" \
  "$(wait_for 'grep -q "^browser https://github.com/acme/repo1/pull/1$" "$FAKE_GH_LOG"' && echo true || echo false)"
t "notify: summary and body reach notify-send with a default action" \
  "$(grep -q '^notify-send --app-name=GitHub -A default=Open -- Fix it acme/repo1 · review requested$' "$FAKE_GH_LOG" && echo true || echo false)"

fresh_env
export FAKE_NOTIFY_ACTION=default
bash "$PWD/notify.sh" "https://evil.example/x" "A" "B" "https://github.com/a/b" "C" "D"
wait_for '[[ $(grep -c "^notify-send" "$FAKE_GH_LOG") -eq 2 ]]'
sleep 0.3
t "notify: several notifications in one call, only github.com ever opens" \
  "$([[ $(grep -c '^notify-send' "$FAKE_GH_LOG") -eq 2 && $(grep -c '^browser' "$FAKE_GH_LOG") -eq 1 ]] && grep -q '^browser https://github.com/a/b$' "$FAKE_GH_LOG" && echo true || echo false)"
unset FAKE_NOTIFY_ACTION

# The notification body is markup to the server (Omarchy renders it as
# StyledText), so GitHub text must arrive escaped, never as tags.
fresh_env
bash "$PWD/notify.sh" "https://github.com/a/b" "Title <b>x</b>" "<a href='https://evil.example'>click</a> & more"
wait_for '[[ $(grep -c "^notify-send" "$FAKE_GH_LOG") -eq 1 ]]'
t "notify: body markup is escaped, summary stays as given" \
  "$(grep -qF -- "-- Title <b>x</b> &lt;a href='https://evil.example'&gt;click&lt;/a&gt; &amp; more" "$FAKE_GH_LOG" && echo true || echo false)"

# ------------------------------------------------------------------ preview
PREVIEW="$PWD/preview.sh"
pr_fixture() { # [body padding bytes]
  long=$(printf 'b%.0s' $(seq 1 5000))
  pad=$(head -c "${1:-0}" /dev/zero | tr '\0' p)
  jq -n --arg long "$long" --rawfile pad <(printf '%s' "$pad") '{data: {repository: {
    squashMergeAllowed: true, mergeCommitAllowed: false, rebaseMergeAllowed: true,
    item: {number: 7, title: "Fix it", state: "OPEN", isDraft: false,
      author: {login: "alice"}, createdAt: "2026-01-01T00:00:00Z", body: ("intro\n" + $long + $pad),
      labels: {nodes: [{name: "bug"}]}, reviewDecision: "APPROVED", mergeable: "MERGEABLE",
      mergeStateStatus: "CLEAN", additions: 10, deletions: 2, changedFiles: 3,
      baseRefName: "main", headRefName: "fix", headRefOid: "abc123",
      url: "https://github.com/acme/repo1/pull/7",
      commits: {nodes: [{commit: {statusCheckRollup: {contexts: {nodes: [
        {__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"},
        {__typename: "CheckRun", status: "COMPLETED", conclusion: "FAILURE"},
        {__typename: "CheckRun", status: "IN_PROGRESS", conclusion: null},
        {__typename: "StatusContext", state: "SUCCESS"}]}}}}]},
      comments: {nodes: [range(3; 6) | {author: {login: ("u" + tostring)}, createdAt: "2026-01-02T00:00:00Z",
        body: ("comment " + tostring + " " + $long)}]}}}}}' >"$FAKE_GH_FIXTURES/graphql.json"
}

fresh_env
pr_fixture
out=$(bash "$PREVIEW" view "https://github.com/acme/repo1/pull/7")
t "preview: a PR comes back normalized" \
  "$(jqt '.kind == "pr" and .number == 7 and .author == "alice" and .labels == ["bug"] and .headSha == "abc123" and .mergeable == "MERGEABLE"' "$out")"
t "preview: checks are counted, not listed" \
  "$(jqt '.checks == {passed: 2, failed: 1, pending: 1}' "$out")"
t "preview: body and comments are cut to size, the last 3 comments in order" \
  "$(jqt '(.body | length) <= 1201 and (.comments | length) == 3 and .comments[0].author == "u3" and ([.comments[].body | length] | max) <= 401' "$out")"
t "preview: one GraphQL call, owner and repo as strings" \
  "$([[ $(grep -c '^api graphql' "$FAKE_GH_LOG") -eq 1 ]] && grep -q -- '-f owner=acme -f repo=repo1 -F number=7' "$FAKE_GH_LOG" && echo true || echo false)"
t "preview: merge methods follow the repo settings, squash first" \
  "$(jqt '.mergeMethods == ["squash", "rebase"]' "$out")"

fresh_env
for bad in "https://evil.example/acme/repo1/pull/7" "https://github.com/acme/repo1/pull/7x" \
  "https://github.com/acme/repo1/pull/7/../../x" "https://github.com/acme/repo1/commits/7" "--repo=x"; do
  out=$(bash "$PREVIEW" view "$bad")
  [[ $(jq -r '.error' <<<"$out") == "Not a GitHub pull request or issue" ]] || { t "preview: rejects $bad" false; continue; }
done
t "preview: anything but a github.com PR or issue URL is refused before gh runs" \
  "$([[ ! -s $FAKE_GH_LOG ]] && echo true || echo false)"

fresh_env
export FAKE_GH_PREVIEW_FAIL=1
out=$(bash "$PREVIEW" view "https://github.com/acme/repo1/issues/3")
t "preview: a gh failure is an error record" "$(jqt '.error | length > 0' "$out")"
unset FAKE_GH_PREVIEW_FAIL

fresh_env
# The comment travels on stdin, never argv, which any local user can read.
printf '%s' 'Looks good; $(id) stays text' | bash "$PREVIEW" comment "https://github.com/acme/repo1/issues/3" >/dev/null
t "preview: comment goes to the issue on stdin, byte for byte" \
  "$(grep -qxF 'issue comment https://github.com/acme/repo1/issues/3 --body-file -' "$FAKE_GH_LOG" && grep -qxF 'stdin: Looks good; $(id) stays text' "$FAKE_GH_LOG" && echo true || echo false)"

# Limits count bytes: 30000 three-byte characters are 90KB, over 64KB,
# and must be refused, not cut short and posted.
fresh_env
out=$(head -c 30000 /dev/zero | tr '\0' 'x' | sed 's/x/あ/g' | bash "$PREVIEW" comment "https://github.com/acme/repo1/pull/7")
t "preview: a comment over 64KB in bytes is refused, never truncated" \
  "$([[ $(jq -r '.error' <<<"$out") == "Comment too long" ]] && ! grep -q 'comment' "$FAKE_GH_LOG" && echo true || echo false)"

fresh_env
pr_fixture 140000
out=$(bash "$PREVIEW" view "https://github.com/acme/repo1/pull/7")
t "preview: a response past the 128KB argv limit still previews" \
  "$(jqt '.number == 7 and .mergeMethods == ["squash", "rebase"] and (.body | length) <= 1201' "$out")"

fresh_env
out=$(printf '   ' | bash "$PREVIEW" comment "https://github.com/acme/repo1/pull/7")
t "preview: an empty comment is refused" "$(jqt '.error | length > 0' "$out")"

fresh_env
bash "$PREVIEW" merge "https://github.com/acme/repo1/pull/7" squash abc123 >/dev/null
t "preview: merge pins the head commit that was shown" \
  "$(grep -qxF 'pr merge https://github.com/acme/repo1/pull/7 --squash --match-head-commit abc123' "$FAKE_GH_LOG" && echo true || echo false)"

fresh_env
out=$(bash "$PREVIEW" merge "https://github.com/acme/repo1/pull/7" octopus abc123)
out2=$(bash "$PREVIEW" merge "https://github.com/acme/repo1/pull/7" squash "")
out3=$(bash "$PREVIEW" merge "https://github.com/acme/repo1/issues/7" squash abc123)
verdicts="$(jqt '.error | length > 0' "$out") $(jqt '.error | length > 0' "$out2") $(jqt '.error | length > 0' "$out3")"
t "preview: merge refuses an unknown method, a missing head sha, or an issue" \
  "$([[ $verdicts == "true true true" && ! -s $FAKE_GH_LOG ]] && echo true || echo false)"

# ------------------------------------------------- hostile cache-path shapes
fresh_env
mkfifo "$CACHE"
out=$(timeout 10 bash "$FETCH")
t "fifo cache: no hang, fresh data served" \
  "$([[ $? -ne 124 ]] && jqt '.error == "" and (.prs | length == 2)' "$out")"
t "fifo cache: replaced by a regular file" \
  "$([[ -f $CACHE && ! -p $CACHE ]] && echo true || echo false)"

fresh_env
echo '{"error":"","prs":[1],"reviews":[],"issues":[],"mentions":[],"notifications":[],"closed":[]}' >"$TMP/target.json"
ln -s "$TMP/target.json" "$CACHE"
out=$(timeout 10 bash "$FETCH")
t "symlink cache: never followed, fresh data served" \
  "$(jqt '.prs | length == 2' "$out")"
t "symlink cache: replaced by regular file, target untouched" \
  "$([[ -f $CACHE && ! -L $CACHE ]] && jqt '.prs == [1]' "$(cat "$TMP/target.json")")"

fresh_env
jq -n '{error: "", pad: [range(30000) | "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"], prs: []}' >"$CACHE"
size=$(wc -c <"$CACHE")
out=$(timeout 10 bash "$FETCH")
t "oversized cache (${size}B): bounded read rejects it, fresh data served" \
  "$([[ $size -gt 2500000 ]] && jqt '.prs | length == 2' "$out")"

fresh_env
long=$(printf 'x%.0s' $(seq 1 2000))
jq -n --arg t "$long" --arg d "$(iso "1 hour ago")" '[range(2000) | {
  id: (. + 500 | tostring), reason: "ci_activity", updated_at: $d,
  subject: {title: ($t + (. | tostring)), type: "CheckSuite", url: null},
  repository: {full_name: "acme/repo1", html_url: "https://github.com/acme/repo1"}}]' \
  >"$FAKE_GH_FIXTURES/notifications.json"
out=$(timeout 30 bash "$FETCH")
t "oversized assembly: output ceiling produces error record, nothing cached" \
  "$(jqt '(.error | contains("unexpectedly large")) and .prs == []' "$out")"

# -------------------------------------------------------------- url allowlist
fresh_env
{
  item 4 "Assigned issue" "acme/repo1" 4 issue "$(iso "2 days ago")"
  jq -n --arg d "$(iso "1 hour ago")" '{id: 99, title: "Planted phishing row", number: 9,
    draft: false, updated_at: $d, html_url: "https://evil.example/login",
    repository_url: "https://api.github.com/repos/acme/repo1"}'
} | jq -s . >"$FAKE_GH_FIXTURES/issues.json"
jq -n --arg d "$(iso "1 hour ago")" '[{id: "77", reason: "ci_activity", updated_at: $d,
  subject: {title: "CI", type: "CheckSuite", url: null},
  repository: {full_name: "acme/repo1", html_url: "https://evil.example"}}]' \
  >"$FAKE_GH_FIXTURES/notifications.json"
out=$(bash "$FETCH")
t "url allowlist: non-github.com rows are dropped everywhere" \
  "$(jqt '(.issues | length == 1) and (.issues[0].url | startswith("https://github.com/")) and (.notifications | length == 0)' "$out")"

echo
node tests/inbox.test.js || fail=$((fail + 1))
echo
echo "$pass passed, $fail failed"
exit "$((fail > 0 ? 1 : 0))"
