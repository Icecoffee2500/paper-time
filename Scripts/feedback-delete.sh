#!/bin/bash
# Removes a report and everything it left behind: the issue, the screenshot on
# the `feedback-assets` branch, and the reply-to address in KV.
#
#   Scripts/feedback-delete.sh 3          # one
#   Scripts/feedback-delete.sh 3 4 5      # several
#
# For your own test reports. A real one belongs closed, not deleted — the page
# reads the issues, so closing is how a fix gets its check mark. Deleting an
# issue cannot be undone and it takes its number with it.
#
# Needs `gh` logged in as somebody who can administer the repository, and
# `wrangler` logged in to the Cloudflare account the worker runs on.
set -euo pipefail
cd "$(dirname "$0")/.."

REPO="Icecoffee2500/paper-time"
BRANCH="feedback-assets"

[ $# -gt 0 ] || { echo "usage: Scripts/feedback-delete.sh <issue number>..." >&2; exit 2; }

for number in "$@"; do
  title=$(gh issue view "$number" --repo "$REPO" --json title -q .title 2>/dev/null) || {
    echo "#$number: no such issue"; continue
  }

  # The screenshot the worker committed for this report, if there was one.
  body=$(gh issue view "$number" --repo "$REPO" --json body -q .body)
  path=$(printf '%s' "$body" | grep -o "$BRANCH/shots/[^)\" ]*\.png" | head -1 | sed "s|^$BRANCH/||")
  if [ -n "$path" ]; then
    sha=$(gh api "repos/$REPO/contents/$path" -X GET -f ref="$BRANCH" --jq .sha 2>/dev/null || true)
    if [ -n "$sha" ]; then
      gh api -X DELETE "repos/$REPO/contents/$path" -f message="remove the screenshot of #$number" \
        -f branch="$BRANCH" -f sha="$sha" >/dev/null && echo "#$number: screenshot removed"
    fi
  fi

  # The reply-to address, which never entered the issue.
  (cd Feedback && npx --yes wrangler kv key delete --binding REPLIES --remote "reply:$number" >/dev/null 2>&1) \
    && echo "#$number: reply address removed" || true

  id=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){id}}}' \
    -f o="${REPO%%/*}" -f r="${REPO##*/}" -F n="$number" -q .data.repository.issue.id)
  gh api graphql -f query='mutation($id:ID!){deleteIssue(input:{issueId:$id}){repository{name}}}' -f id="$id" >/dev/null
  echo "#$number deleted — $title"
done

# The page reads the issues, so it has to be told they are gone.
Scripts/feedback-sync.sh || true
echo "run Scripts/publish-page.sh \"the wall, after a test\" to put the page back up"
