#!/bin/bash
# Desktop notifications for the panel. Takes groups of three arguments:
#   <github.com url> <summary> <body>
# Each one waits on its own detached notify-send so the caller never blocks
# and a click can still open the page later.
export PATH="$HOME/.local/share/mise/shims:$HOME/.local/bin:$PATH"

if [[ ${1:-} == --one ]]; then
  # The body is markup to the notification server and carries GitHub text:
  # escape it so a title can never become tags or links.
  # Quoted replacements: bash 5.2 reads a bare & there as the match itself.
  body=${4//&/"&amp;"}
  body=${body//</"&lt;"}
  body=${body//>/"&gt;"}
  # Bounded wait: a toast never closed by the server must not leave this
  # process behind for good.
  action=$(timeout 3600 notify-send --app-name=GitHub -A default=Open -- "$3" "$body")
  [[ $action == default && $2 == https://github.com/* ]] && omarchy-launch-browser "$2"
  exit 0
fi

while (( $# >= 3 )); do
  setsid -f bash "$0" --one "$1" "$2" "$3" >/dev/null 2>&1
  shift 3
done
