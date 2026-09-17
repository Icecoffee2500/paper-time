#!/bin/sh
# Puts Website/ on the page, with no release to ride on: a fixed sentence, a
# new card, a count that was not there before.
#
#   Scripts/publish-page.sh ["commit message"]
#
# The page lives on its own branch, gh-pages, holding nothing but itself:
# the site is what a visitor gets, and the source is what a reader of the
# source gets. publish-release.sh calls this after it has rewritten
# releases.json; on its own it publishes whatever Website/ holds right now.
set -e

MESSAGE="${1:-The page}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

WORK="/tmp/papertime-pages"
rm -rf "$WORK"
git worktree remove --force "$WORK" 2>/dev/null || true
git worktree add -q "$WORK" gh-pages 2>/dev/null || {
  git worktree add -q --detach "$WORK"
  git -C "$WORK" checkout -q --orphan gh-pages
  git -C "$WORK" rm -rq --cached . 2>/dev/null || true
  rm -f "$WORK"/* 2>/dev/null || true
}
trap 'git -C "$ROOT" worktree remove --force "$WORK" 2>/dev/null || true' EXIT
# The whole site, not two files of it. Cleared first, so a file dropped
# from Website/ leaves the branch too.
git -C "$WORK" rm -rq --ignore-unmatch . >/dev/null 2>&1 || true
cp -R Website/. "$WORK/"
git -C "$WORK" add -A
git -C "$WORK" commit -qm "$MESSAGE" || echo "the page was already up to date"
git -C "$WORK" push -q origin gh-pages

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo Icecoffee2500/paper-time)"
echo "the page: https://$(echo "$REPO" | cut -d/ -f1 | tr "A-Z" "a-z").github.io/$(echo "$REPO" | cut -d/ -f2)/"
