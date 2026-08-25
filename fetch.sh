#!/bin/bash
# omarchy-shell's environment may lack version-manager shims; extend PATH for
# gh installed via mise — harmless when absent.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

cache="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-github-tasks.json"

# Tunables, passed by the panel from its widget settings (manifest.json).
mention_limit=30
closed_days=30

while (( $# > 0 )); do
  case "$1" in
  # The cache drop keeps the next refresh from resurrecting the dismissed row.
  --mark-read)
    rm -f "$cache"
    [[ -n ${2:-} ]] && gh api --method PATCH "notifications/threads/$2" >/dev/null 2>&1
    exit 0
    ;;
  --mentions)
    [[ ${2:-} =~ ^[0-9]+$ ]] && mention_limit="$2"
    shift 2
    ;;
  --closed-days)
    [[ ${2:-} =~ ^[0-9]+$ ]] && closed_days="$2"
    shift 2
    ;;
  *)
    shift
    ;;
  esac
done

# The cache collapses the per-monitor bar instances into one API burst. Its
# path is predictable and user-writable: dd's nofollow/nonblock/count keep a
# planted FIFO, symlink, or oversized file from stalling or flooding us.
read_bounded() { dd if="$1" iflag=nofollow,nonblock bs=64k count=32 status=none 2>/dev/null; }

if [[ -f $cache && ! -L $cache && $(($(date +%s) - $(stat -c %Y "$cache"))) -lt 60 ]]; then
  cached=$(read_bounded "$cache")
  if [[ -n $cached ]] && jq -e . <<<"$cached" >/dev/null 2>&1; then
    printf '%s\n' "$cached"
    exit 0
  fi
fi

fail() { jq -n --arg e "$1" '{error: $e, prs: [], reviews: [], issues: [], mentions: [], notifications: []}'; exit 0; }

command -v jq >/dev/null || { echo '{"error":"jq not found","prs":[],"reviews":[],"issues":[],"mentions":[],"notifications":[]}'; exit 0; }
command -v gh >/dev/null || fail "GitHub CLI (gh) not found"
gh auth status >/dev/null 2>&1 || fail "Not signed in — run: gh auth login"

user=$(gh api user --jq .login 2>/dev/null) || fail "GitHub API unreachable"

# gh api prints error bodies to stdout on HTTP failures, so exit codes alone
# cannot be trusted — only pass through actual JSON arrays.
as_array() { jq -e 'type == "array"' >/dev/null 2>&1 <<<"$1" && echo "$1" || echo '[]'; }

search() { as_array "$(gh api "search/issues?q=$1&sort=updated&order=desc&per_page=$2" --jq '.items' 2>/dev/null)"; }

# ponytail: top 50 per list, newest first; add --paginate if a list ever exceeds that
authored=$(search "is:open+is:pr+author:@me+archived:false" 50)
assigned=$(search "is:open+is:pr+assignee:@me+archived:false" 50)
# ponytail: direct review requests only; add team-review-requested:org/team queries if team reviews matter
reviews=$(search "is:open+is:pr+review-requested:@me+archived:false" 50)
issues=$(search "is:open+is:issue+assignee:@me+archived:false" 50)
mentions=$(search "is:open+mentions:@me" "$mention_limit")
# ponytail: 20-deep recency window per type; an org whose last closure is older
# than that shows fewer than 5 in its Recently Closed tab
closed_prs=$(search "is:closed+is:pr+author:@me+archived:false" 20)
closed_issues=$(search "is:closed+is:issue+assignee:@me+archived:false" 20)
# Threads that only involved the user by mention would otherwise vanish
# silently when they close (the mentions section is open-only).
closed_mentions=$(search "is:closed+mentions:@me+archived:false" 20)
notifications=$(as_array "$(gh api "notifications?per_page=50" 2>/dev/null)")

# Blobs go in as files (--slurpfile), never argv: a large notification set
# once blew past the kernel's 128KB per-argument limit (E2BIG).
out=$(jq -n --arg user "$user" --argjson closedDays "$closed_days" \
  --slurpfile authored <(printf '%s' "$authored") \
  --slurpfile assigned <(printf '%s' "$assigned") \
  --slurpfile reviews <(printf '%s' "$reviews") \
  --slurpfile mentions <(printf '%s' "$mentions") \
  --slurpfile issues <(printf '%s' "$issues") \
  --slurpfile closedPrs <(printf '%s' "$closed_prs") \
  --slurpfile closedIssues <(printf '%s' "$closed_issues") \
  --slurpfile closedMentions <(printf '%s' "$closed_mentions") \
  --slurpfile notifications <(printf '%s' "$notifications") '
def item: {
  title, number, url: .html_url, draft: (.draft == true), updatedAt: .updated_at,
  repo: (.repository_url | sub(".*/repos/"; ""))
} | .org = (.repo | split("/")[0]);

# Only Issue/PR subject URLs map onto web URLs by string surgery; other
# subject types must fall back to the repo page.
def notifUrl:
  if (.subject.type == "PullRequest" or .subject.type == "Issue") and .subject.url
  then (.subject.url | sub("api\\.github\\.com/repos"; "github.com") | sub("/pulls/"; "/pull/"))
  else .repository.html_url end;

# Unread notifications by thread web-URL: your own comments never create
# notifications, so this lets the mention dots ignore your own activity.
($notifications[0] | map({key: notifUrl, value: (.id | tostring)}) | from_entries) as $threadByUrl |

{
  user: $user,
  error: "",
  prs: (($authored[0] + $assigned[0]) | unique_by(.id) | map(item) | sort_by(.updatedAt) | reverse),
  reviews: ($reviews[0] | map(item) | sort_by(.updatedAt) | reverse),
  issues: ($issues[0] | map(item) | sort_by(.updatedAt) | reverse),
  mentions: ($mentions[0] | map(.html_url as $u | item
    + {threadId: ($threadByUrl[$u] // ""), notifUnread: ($threadByUrl | has($u))})),
  closed: ((($closedPrs[0] | map(item + {kind: "pr", closedAt: (.closed_at // .updated_at)}))
    + ($closedIssues[0] | map(item + {kind: "issue", closedAt: (.closed_at // .updated_at)}))
    + ($closedMentions[0] | map(item
        + {kind: (if .pull_request then "pr" else "issue" end), closedAt: (.closed_at // .updated_at)})))
    | unique_by(.url)
    | map(select((.closedAt | fromdateiso8601? // 0) > (now - $closedDays * 86400)))
    | sort_by(.closedAt) | reverse),
  # The mentions section owns mention events; team mentions stay because the
  # mentions search cannot see them.
  notifications: ($notifications[0] | map(select(.reason != "mention")) | map({
    threadId: (.id | tostring),
    title: .subject.title,
    type: .subject.type,
    reason: .reason,
    repo: .repository.full_name,
    org: (.repository.full_name | split("/")[0]),
    updatedAt: .updated_at,
    url: notifUrl
  }))
}') || fail "Failed to assemble GitHub data"

[[ -n $out ]] || fail "Empty result from GitHub"
# API page caps keep real results far below this; larger means garbage.
(( ${#out} <= 2097152 )) || fail "GitHub data unexpectedly large"
printf '%s\n' "$out"
# Temp file + atomic rename: never open the predictable path for writing
# (a FIFO would block, a symlink would redirect the write).
if tmp=$(mktemp "$cache.XXXXXX" 2>/dev/null); then
  printf '%s\n' "$out" >"$tmp" && mv -f "$tmp" "$cache" || rm -f "$tmp"
fi
