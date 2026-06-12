#!/usr/bin/env bash
set -euo pipefail

# ----------------------------
# Required env vars
# ----------------------------
: "${GH_SOURCE_PAT:?GH_SOURCE_PAT not set}"
: "${GH_PAT:?GH_PAT not set}"
: "${GHES_API_URL:?GHES_API_URL not set}"

GHES_API_URL="${GHES_API_URL%/}"

# ----------------------------
# Logging
# ----------------------------
LOG_FILE="validation-log-$(date +%Y%m%d).txt"

TARGET_HOST="${GH_TARGET_HOST:-github.com}"
export GH_HOST="$TARGET_HOST"

write_log() {
  echo "$1" | tee -a "$LOG_FILE"
}

# ----------------------------
# Helpers
# ----------------------------
is_json() { jq -e . >/dev/null 2>&1; }
urlencode() { jq -rn --arg s "$1" '$s|@uri'; }

# ----------------------------
# GHES pagination (UNLIMITED ✅)
# ----------------------------
get_ghes_branches_json() {
  local org="$1" repo="$2"
  local page=1 per_page=100
  local all='[]'

  local enc_org enc_repo
  enc_org="$(urlencode "$org")"
  enc_repo="$(urlencode "$repo")"

  while true; do
    local url="${GHES_API_URL}/repos/${enc_org}/${enc_repo}/branches?page=$page&per_page=$per_page"

    local resp
    resp="$(curl -sS \
      -H "Accept: application/vnd.github+json" \
      -H "Authorization: token ${GH_SOURCE_PAT}" \
      "$url")"

    if ! echo "$resp" | is_json; then
      break
    fi

    local batch_len
    batch_len="$(echo "$resp" | jq 'length')"

    all="$(jq -c -n --argjson a "$all" --argjson b "$resp" '$a + $b')"

    [[ "$batch_len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "$all"
}

# ----------------------------
# GitHub pagination (FIXED ✅)
# ----------------------------
get_github_branches_json() {
  local org="$1" repo="$2"
  local page=1 per_page=100
  local all='[]'

  while true; do
    local resp
    resp="$(gh api "/repos/$org/$repo/branches?page=$page&per_page=$per_page" 2>/dev/null)" || break

    if ! echo "$resp" | is_json; then
      break
    fi

    local batch_len
    batch_len="$(echo "$resp" | jq 'length')"

    all="$(jq -c -n --argjson a "$all" --argjson b "$resp" '$a + $b')"

    [[ "$batch_len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "$all"
}

# ----------------------------
# Commit comparison
# ----------------------------
get_commit_count_and_latest() {
  local mode="$1" org="$2" repo="$3" branch="$4"

  local page=1 per_page=100 count=0 latest=""

  local enc_branch
  enc_branch="$(urlencode "$branch")"

  while true; do
    local resp

    if [[ "$mode" == "ghes" ]]; then
      resp="$(curl -sS \
        -H "Authorization: token ${GH_SOURCE_PAT}" \
        "${GHES_API_URL}/repos/$(urlencode "$org")/$(urlencode "$repo")/commits?sha=$enc_branch&page=$page&per_page=$per_page")"
    else
      resp="$(gh api "/repos/$org/$repo/commits?sha=$enc_branch&page=$page&per_page=$per_page" 2>/dev/null)" || break
    fi

    if ! echo "$resp" | is_json; then break; fi

    local batch_len
    batch_len="$(echo "$resp" | jq 'length')"

    if [[ $page -eq 1 && "$batch_len" -gt 0 ]]; then
      latest="$(echo "$resp" | jq -r '.[0].sha // empty')"
    fi

    count=$((count + batch_len))
    [[ "$batch_len" -lt "$per_page" ]] && break
    ((page++))
  done

  echo "${count}|${latest}"
}

# ----------------------------
# Validation
# ----------------------------
validate_migration() {
  local ghes_org="$1"
  local ghes_repo="$2"
  local github_org="$3"
  local github_repo="$4"

  write_log "[$(date -u +%FT%TZ)] Validating: $ghes_org/$ghes_repo -> $github_org/$github_repo"

  local gh_branches ghes_branches

  gh_branches="$(get_github_branches_json "$github_org" "$github_repo")"
  ghes_branches="$(get_ghes_branches_json "$ghes_org" "$ghes_repo")"

  mapfile -t gh_array < <(echo "$gh_branches" | jq -r '.[].name')
  mapfile -t ghes_array < <(echo "$ghes_branches" | jq -r '.[].name')

  # ----------------------------
  # ✅ HASH-BASED branch compare
  # ----------------------------
  declare -A gh_map ghes_map
  local b

  for b in "${gh_array[@]}"; do gh_map["$b"]=1; done
  for b in "${ghes_array[@]}"; do ghes_map["$b"]=1; done

  local missing_in_github=()
  local missing_in_ghes=()

  for b in "${ghes_array[@]}"; do
    [[ -z "${gh_map[$b]:-}" ]] && missing_in_github+=("$b")
  done

  for b in "${gh_array[@]}"; do
    [[ -z "${ghes_map[$b]:-}" ]] && missing_in_ghes+=("$b")
  done

  write_log "Branch Count GHES=${#ghes_array[@]} GitHub=${#gh_array[@]}"

  [[ ${#missing_in_github[@]} -gt 0 ]] && \
    write_log "Missing in GitHub: ${missing_in_github[*]}"

  [[ ${#missing_in_ghes[@]} -gt 0 ]] && \
    write_log "Missing in GHES: ${missing_in_ghes[*]}"

  # ----------------------------
  # Commit validation
  # ----------------------------
  for branch in "${gh_array[@]}"; do
    [[ -z "${ghes_map[$branch]:-}" ]] && continue

    gh_pair="$(get_commit_count_and_latest github "$github_org" "$github_repo" "$branch")"
    ghes_pair="$(get_commit_count_and_latest ghes "$ghes_org" "$ghes_repo" "$branch")"

    gh_count="${gh_pair%%|*}"
    gh_sha="${gh_pair#*|}"

    ghes_count="${ghes_pair%%|*}"
    ghes_sha="${ghes_pair#*|}"

    write_log "Branch: $branch | Commits GHES=$ghes_count GitHub=$gh_count"
    write_log "Branch: $branch | SHA GHES=$ghes_sha GitHub=$gh_sha"
  done

  write_log "Validation complete: $github_org/$github_repo"
}

# ----------------------------
# CSV Processing
# ----------------------------
validate_from_csv() {
  local csv="repos.csv"

  tail -n +2 "$csv" | while IFS=',' read -r ghes_org ghes_repo _ _ github_org github_repo _; do
    validate_migration "$ghes_org" "$ghes_repo" "$github_org" "$github_repo"
  done
}

validate_from_csv

