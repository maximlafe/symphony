#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_FILE=${1:-"$REPO_ROOT/elixir/test/fixtures/parity/parity_14_actionable_feedback_live_sanitized.json"}

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh auth is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

cases_jsonl="$tmp_dir/cases.jsonl"
repos_json="$tmp_dir/repos.json"
printf '%s\n' '["maximlafe/symphony","maximlafe/lead_status","facebook/react"]' >"$repos_json"
per_page="${PARITY14_PER_PAGE:-25}"

classify_pr_case() {
  local repo="$1"
  local pr_number="$2"
  local core_file="$3"
  local issue_comments_file="$4"
  local reviews_file="$5"
  local inline_comments_file="$6"

  jq -n \
    --arg repo "$repo" \
    --argjson pr_number "$pr_number" \
    --slurpfile core "$core_file" \
    --slurpfile issue_comments "$issue_comments_file" \
    --slurpfile reviews "$reviews_file" \
    --slurpfile inline_comments "$inline_comments_file" '
    def normalized_author($author):
      ($author // "")
      | tostring
      | ascii_downcase
      | gsub("^\\s+|\\s+$"; "");

    def trusted_review_bot($author):
      ($author | test("^chatgpt-codex(?:-connector)?\\[bot\\]$")) or
      ($author | test("^openai-codex(?:-connector)?\\[bot\\]$"));

    def actionable_source($author):
      normalized_author($author) as $a
      | if $a == "" then true
        elif ($a == "github-actions" or $a == "linear") then false
        elif ($a | endswith("[bot]")) then trusted_review_bot($a)
        else true
        end;

    def body_text($body):
      ($body // "")
      | tostring
      | gsub("[\\r\\n\\t]+"; " ")
      | gsub("\\s+"; " ")
      | gsub("^\\s+|\\s+$"; "");

    def actionable_intent($body):
      body_text($body) as $text
      | ($text | ascii_downcase) as $n
      | ($n != "")
      and ($n | startswith("thanks") | not)
      and ($n | startswith("thank you") | not)
      and ($n | startswith("lgtm") | not)
      and ($n | startswith("sgtm") | not)
      and ($n | startswith("resolved") | not)
      and ($n | startswith("fixed") | not)
      and ($n | startswith("done") | not)
      and ($n | startswith("addressed") | not)
      and ($n | test("^(updated|applied|implemented)\\s+in\\s+[0-9a-f]{7,40}\\b") | not)
      and ($n | startswith("build details:") | not);

    def review_state_key($state):
      ($state // "")
      | tostring
      | ascii_upcase
      | if . == "CHANGES_REQUESTED" then "changes_requested"
        elif . == "APPROVED" then "approved"
        elif . == "COMMENTED" then "commented"
        elif . == "DISMISSED" then "dismissed"
        elif . == "PENDING" then "pending"
        else "unknown"
        end;

    ($core[0] // {}) as $core_obj
    | ($issue_comments[0] // []) as $issue_nodes
    | ($reviews[0] // []) as $review_nodes
    | ($inline_comments[0] // []) as $inline_nodes
    | {
        changes_requested: 0,
        approved: 0,
        commented: 0,
        dismissed: 0,
        pending: 0,
        unknown: 0
      } as $empty_summary
    | (
        reduce $review_nodes[] as $review ($empty_summary;
          ($review.user.login // $review.author.login // $review.user.name // $review.author.name // null) as $author
          | if actionable_source($author) then
              .[review_state_key($review.state)] += 1
            else .
            end
        )
      ) as $review_summary
    | (
        [
          $issue_nodes[]
          | (.user.login // .author.login // .user.name // .author.name // null) as $author
          | select(actionable_source($author))
          | select(actionable_intent(.body))
          | {
              channel: "top_level_comment",
              author: $author,
              body_excerpt: (body_text(.body)[0:180])
            }
        ]
        +
        [
          $review_nodes[]
          | (.user.login // .author.login // .user.name // .author.name // null) as $author
          | select(actionable_source($author))
          | select((.state // "" | tostring | ascii_upcase) == "CHANGES_REQUESTED")
          | {
              channel: "review",
              author: $author,
              body_excerpt: (body_text(.body)[0:180])
            }
        ]
        +
        [
          $inline_nodes[]
          | (.user.login // .author.login // .user.name // .author.name // null) as $author
          | (.in_reply_to_id // .inReplyToId // null) as $reply_to
          | select($reply_to == null)
          | select(actionable_source($author))
          | select(actionable_intent(.body))
          | {
              channel: "inline_comment",
              author: $author,
              body_excerpt: (body_text(.body)[0:180])
            }
        ]
      ) as $actionable_items
    | (
        if ($review_summary.changes_requested // 0) > 0 then
          "changes_requested"
        elif ($actionable_items | length) > 0 then
          "actionable_comments"
        else
          "none"
        end
      ) as $state
    | {
        observed: {
          repo: $repo,
          pr_number: $pr_number,
          pr_url: ($core_obj.html_url // $core_obj.url // null),
          review_state_summary: $review_summary,
          actionable_feedback_state: $state,
          has_actionable_feedback: ($state != "none")
        },
        expected: {
          workflow_blocks: ($state != "none")
        },
        source: {
          sampled_review_count: ($review_nodes | length),
          sampled_issue_comment_count: ($issue_nodes | length),
          sampled_inline_comment_count: ($inline_nodes | length),
          actionable_items_preview: ($actionable_items[0:3])
        }
      }'
}

gh_api_with_retry() {
  local endpoint="$1"
  local out_file="$2"
  local attempt

  for attempt in 1 2 3 4 5 6; do
    if gh api "$endpoint" >"$out_file"; then
      return 0
    fi
    sleep 2
  done

  return 1
}

seed_pr_numbers() {
  local repo="$1"

  case "$repo" in
    "facebook/react")
      printf '%s\n' 35137 35124 31273 8627 8604
      ;;
    *)
      ;;
  esac
}

while IFS= read -r repo; do
  pr_numbers_file="$tmp_dir/pr-numbers-$(echo "$repo" | tr '/:' '__').txt"
  repo_prs_file="$tmp_dir/pr-list-${repo//\//_}.json"
  if ! gh_api_with_retry "repos/${repo}/pulls?state=all&per_page=${per_page}" "$repo_prs_file"; then
    echo "Failed to list PRs for ${repo} after retries." >&2
    exit 1
  fi

  jq '.[].number' "$repo_prs_file" >"$pr_numbers_file"
  seed_pr_numbers "$repo" >>"$pr_numbers_file"
  sort -n "$pr_numbers_file" | uniq >"${pr_numbers_file}.uniq"
  mv "${pr_numbers_file}.uniq" "$pr_numbers_file"

  while IFS= read -r pr_number; do
    [ -z "$pr_number" ] && continue
    core_file="$tmp_dir/core-${repo//\//_}-${pr_number}.json"
    issue_comments_file="$tmp_dir/issue-comments-${repo//\//_}-${pr_number}.json"
    reviews_file="$tmp_dir/reviews-${repo//\//_}-${pr_number}.json"
    inline_comments_file="$tmp_dir/inline-comments-${repo//\//_}-${pr_number}.json"

    if ! gh_api_with_retry "repos/${repo}/pulls/${pr_number}" "$core_file"; then
      echo "Failed to fetch PR core for ${repo}#${pr_number} after retries." >&2
      exit 1
    fi

    if ! gh_api_with_retry "repos/${repo}/issues/${pr_number}/comments?per_page=100" "$issue_comments_file"; then
      echo "Failed to fetch issue comments for ${repo}#${pr_number} after retries." >&2
      exit 1
    fi

    if ! gh_api_with_retry "repos/${repo}/pulls/${pr_number}/reviews?per_page=100" "$reviews_file"; then
      echo "Failed to fetch reviews for ${repo}#${pr_number} after retries." >&2
      exit 1
    fi

    if ! gh_api_with_retry "repos/${repo}/pulls/${pr_number}/comments?per_page=100" "$inline_comments_file"; then
      echo "Failed to fetch inline comments for ${repo}#${pr_number} after retries." >&2
      exit 1
    fi

    classify_pr_case "$repo" "$pr_number" "$core_file" "$issue_comments_file" "$reviews_file" "$inline_comments_file" >>"$cases_jsonl"
  done <"$pr_numbers_file"
done < <(jq -r '.[]' "$repos_json")

if [ ! -s "$cases_jsonl" ]; then
  echo "No live PR cases collected for PARITY-14." >&2
  exit 1
fi

jq -s --argjson repos "$(cat "$repos_json")" '
  unique_by(.observed.repo, .observed.pr_number) as $all
  | ($all | map(select(.observed.actionable_feedback_state == "changes_requested")) | .[0:8]) as $changes
  | ($all | map(select(.observed.actionable_feedback_state == "actionable_comments")) | .[0:8]) as $comments
  | ($all | map(select(.observed.actionable_feedback_state == "none")) | .[0:8]) as $none
  | ($changes + $comments + $none) as $picked
  | if ($picked | length) == 0 then
      error("No PARITY-14 cases selected after classification.")
    else
      {
        ticket: "PARITY-14",
        generated_at: (now | todateiso8601),
        scope: {
          repositories: $repos,
          decision_surface: ["changes_requested", "actionable_comments", "none"],
          workflow_decision: "workflow_blocks"
        },
        source: {
          sampled_case_count: ($picked | length),
          sampled_changes_requested_count: ($changes | length),
          sampled_actionable_comments_count: ($comments | length),
          sampled_none_count: ($none | length)
        },
        cases: (
          $picked
          | to_entries
          | map(.value + {case_id: ("LIVE-" + ((.key + 1) | tostring))})
        )
      }
    end
' "$cases_jsonl" >"$OUT_FILE"

changes_count=$(jq '.source.sampled_changes_requested_count' "$OUT_FILE")
none_count=$(jq '.source.sampled_none_count' "$OUT_FILE")
case_count=$(jq '.cases | length' "$OUT_FILE")

if [ "$case_count" -eq 0 ]; then
  echo "PARITY-14 live fixture has no cases." >&2
  exit 1
fi

if [ "$changes_count" -eq 0 ]; then
  echo "PARITY-14 live fixture is missing changes_requested cases." >&2
  exit 1
fi

if [ "$none_count" -eq 0 ]; then
  echo "PARITY-14 live fixture is missing none-state cases." >&2
  exit 1
fi

hash=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
echo "Generated $OUT_FILE"
echo "SHA256 $hash"
