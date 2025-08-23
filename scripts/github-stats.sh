#!/usr/bin/env bash
set -euo pipefail

USER_ARG="${1:-}"
GH_USER="${USER_ARG:-${GH_USER:-}}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

if [[ -z "${GH_USER}" ]]; then
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    ORIGIN_URL="$(git config --get remote.origin.url || true)"
    GH_USER="$(sed -E 's#(git@github\.com:|https://github\.com/)([^/]+).*#\2#' <<<"$ORIGIN_URL" 2>/dev/null || echo "")"
  fi
fi
[[ -z "${GH_USER}" ]] && { echo "ERROR: set GH_USER"; exit 2; }

headers=( "-sS" "-L" "-H" "User-Agent: gh-stats-script" "-H" "Accept: application/vnd.github+json" )
[[ -n "${GITHUB_TOKEN}" ]] && headers+=( "-H" "Authorization: Bearer ${GITHUB_TOKEN}" )

api() { curl "${headers[@]}" "$1"; }

# collect repos (paginate)
collect_repos() {
  local page=1 per=100 all="[]"
  while :; do
    local chunk; chunk="$(api "https://api.github.com/users/${GH_USER}/repos?per_page=${per}&page=${page}")"
    local cnt; cnt="$(jq 'length' <<<"$chunk")"
    all="$(jq -s 'add' <(echo "$all") <(echo "$chunk"))"
    [[ "$cnt" -lt "$per" ]] && break
    page=$((page+1)); [[ "$page" -gt 10 ]] && break
  done
  echo "$all"
}

filter_repos() {
  jq '[ .[] | { name, stargazers_count, forks_count, language, archived, fork, pushed_at } ]'
}

search_commits_total() {
  local start_date="${1:-2017-01-01}"
  local out
  if [[ -n "${GITHUB_TOKEN}" ]]; then
    out="$(curl -sS -L \
      -H "User-Agent: gh-stats-script" \
      -H "Authorization: Bearer ${GITHUB_TOKEN}" \
      -H "Accept: application/vnd.github.cloak-preview" \
      "https://api.github.com/search/commits?q=author:${GH_USER}+author-date:>=${start_date}" \
      | jq -r '.total_count // empty' || true)"
  else
    out="$(curl -sS -L \
      -H "User-Agent: gh-stats-script" \
      -H "Accept: application/vnd.github.cloak-preview" \
      "https://api.github.com/search/commits?q=author:${GH_USER}+author-date:>=${start_date}" \
      | jq -r '.total_count // empty' || true)"
  fi
  [[ -z "$out" ]] && out="$(api "https://api.github.com/search/commits?q=author:${GH_USER}+author-date:>=${start_date}" | jq -r '.total_count // 0' || echo 0)"
  echo "${out:-0}"
}

USER_JSON="$(api "https://api.github.com/users/${GH_USER}")"
REPOS_JSON="$(collect_repos | filter_repos)"

NAME="$(jq -r '.name // empty' <<<"$USER_JSON")"
FOLLOWERS="$(jq -r '.followers // 0' <<<"$USER_JSON")"
PUBLIC_REPOS="$(jq -r '.public_repos // 0' <<<"$USER_JSON")"
TOTAL_STARS="$(jq '[.[].stargazers_count] | add // 0' <<<"$REPOS_JSON")"
TOTAL_FORKS="$(jq '[.[].forks_count] | add // 0' <<<"$REPOS_JSON")"

TOP_REPOS="$(jq -r 'sort_by(.stargazers_count) | reverse | .[:5] |
  map("⭐ " + .name + " (" + (.stargazers_count|tostring) + ")") | .[]' <<<"$REPOS_JSON")"

TOP_LANGS="$(jq -r '
  map(.language) | del(.[] | select(.==null)) |
  group_by(.) | map({lang: .[0], count: length}) |
  sort_by(.count) | reverse | .[:5] |
  map("• " + .lang + " (" + (.count|tostring) + ")") | .[]
' <<<"$REPOS_JSON")"

START_DATE="${GH_START_DATE:-2017-01-01}"
COMMITS_TOTAL="$(search_commits_total "${START_DATE}")"

printf "root@%s:~# ./github-stats.sh\n" "${GH_USER}"
if [[ -n "$NAME" ]]; then
  printf "User: %s (%s)\n" "$NAME" "$GH_USER"
else
  printf "User: %s\n" "$GH_USER"
fi
printf "Followers: %s\n" "$FOLLOWERS"
printf "Public Repos: %s\n" "$PUBLIC_REPOS"
printf "Stars (total): %s   Forks (total): %s\n" "$TOTAL_STARS" "$TOTAL_FORKS"
printf "Commits since %s: %s\n" "$START_DATE" "$COMMITS_TOTAL"

printf "\nTop repos by stars:\n"
if [[ -n "$TOP_REPOS" ]]; then
  echo "$TOP_REPOS"
else
  echo "• (no repositories found)"
fi

printf "\nTop languages (by primary tag):\n"
if [[ -n "$TOP_LANGS" ]]; then
  echo "$TOP_LANGS"
else
  echo "• (no languages detected)"
fi
printf "\nDone.\n"
