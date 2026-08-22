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
  unset FAKE_GH_AUTH_FAIL FAKE_GH_API_FAIL
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
t "rate limit: error bodies on stdout never corrupt the output" \
  "$(jqt '.error == "" and .prs == [] and .notifications == []' "$out")"

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

echo
echo "$pass passed, $fail failed"
exit "$((fail > 0 ? 1 : 0))"
