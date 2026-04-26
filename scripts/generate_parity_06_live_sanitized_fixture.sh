#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_FILE=${1:-"$REPO_ROOT/elixir/test/fixtures/parity/parity_06_merge_gating_live_sanitized.json"}

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "LINEAR_API_KEY is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

query_payload() {
  jq -n '
    {
      query: "query Parity06MergeGating($teamKey: String!, $needle: String!, $first: Int!, $commentsFirst: Int!) { issues(first: $first, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $needle } } }) { nodes { id identifier state { name } comments(first: $commentsFirst) { nodes { id createdAt body } } } } }",
      variables: {
        teamKey: "LET",
        needle: "merge_state_status",
        first: 140,
        commentsFirst: 220
      }
    }'
}

linear_query_with_retry() {
  local payload="$1"
  local out_file="$2"
  local attempt

  for attempt in 1 2 3 4 5 6; do
    if curl --http1.1 -sS https://api.linear.app/graphql \
      -H "Authorization: ${LINEAR_API_KEY}" \
      -H "Content-Type: application/json" \
      --data "$payload" >"$out_file"; then
      return 0
    fi
    sleep 2
  done

  return 1
}

sanitize_raw_json() {
  local in_file="$1"
  local out_file="$2"
  perl -pe 's/[\x00-\x08\x0B\x0C\x0E-\x1F]/ /g' "$in_file" >"$out_file"
}

raw_response=$(mktemp)
clean_response=$(mktemp)
trap 'rm -f "$raw_response" "$clean_response"' EXIT

if ! linear_query_with_retry "$(query_payload)" "$raw_response"; then
  echo "Failed to query Linear merge-gating traces after retries." >&2
  exit 1
fi

sanitize_raw_json "$raw_response" "$clean_response"

if jq -e '.errors and (.errors | length > 0)' "$clean_response" >/dev/null; then
  echo "Linear merge-gating query returned errors:" >&2
  jq '.errors' "$clean_response" >&2
  exit 1
fi

jq '
  def normalize_text:
    (if . == null then "" else tostring end)
    | gsub("[\r\n\t]+"; " ")
    | gsub("\\s+"; " ")
    | gsub("^\\s+|\\s+$"; "");

  def extract_bool($name; $body):
    (
      try (
        ($body // "")
        | capture("(?i)" + $name + "[^A-Za-z0-9]+(?<value>true|false)")
        | (.value | ascii_downcase == "true")
      ) catch null
    );

  def extract_status($body):
    (
      try (
        ($body // "")
        | capture("(?i)merge_state_status[^A-Za-z0-9]+(?<value>[A-Z_]+)")
        | .value
        | ascii_upcase
      ) catch null
    );

  def merge_ready($all_green; $pending; $feedback; $status):
    ($all_green == true)
    and ($pending == false)
    and ($feedback == false)
    and ($status == "CLEAN" or $status == "HAS_HOOKS");

  def missing_items($all_green; $pending; $feedback; $status):
    []
    + (if $all_green == true then [] else ["pull request checks are not fully green"] end)
    + (if $pending == false then [] else ["pull request still has pending checks"] end)
    + (if $feedback == false then [] else ["pull request still has actionable feedback"] end)
    + (if ($status == "CLEAN" or $status == "HAS_HOOKS") then [] else ["pull request is not merge-ready"] end);

  (
    (.data.issues.nodes // [])
    | map(
        . as $issue
        | ($issue.comments.nodes // [])
        | map(
            . as $comment
            | extract_bool("all_checks_green"; $comment.body) as $all_green
            | extract_bool("has_pending_checks"; $comment.body) as $pending
            | extract_bool("has_actionable_feedback"; $comment.body) as $feedback
            | extract_status($comment.body) as $status
            | select($all_green != null and $pending != null and $feedback != null and $status != null)
            | merge_ready($all_green; $pending; $feedback; $status) as $ready
            | {
                case_id: "",
                observed: {
                  all_checks_green: $all_green,
                  has_pending_checks: $pending,
                  has_actionable_feedback: $feedback,
                  merge_state_status: $status
                },
                expected: {
                  merge_ready: $ready,
                  required_missing_items: (if $ready then [] else missing_items($all_green; $pending; $feedback; $status) end)
                },
                source: {
                  sampled_identifier: ($issue.identifier // null),
                  sampled_state: ($issue.state.name // "Unknown"),
                  sampled_comment_created_at: ($comment.createdAt // null),
                  sampled_excerpt: (($comment.body // "") | normalize_text | .[0:220]),
                  evidence_channel: "issue_comment"
                }
              }
          )
      )
    | add
    | unique_by(
        .source.sampled_identifier,
        .observed.all_checks_green,
        .observed.has_pending_checks,
        .observed.has_actionable_feedback,
        .observed.merge_state_status
      )
  ) as $all_cases
  | ($all_cases | map(select(.expected.merge_ready == true)) | .[0:10]) as $ready_cases
  | ($all_cases | map(select(.expected.merge_ready == false)) | .[0:14]) as $not_ready_cases
  | ($ready_cases + $not_ready_cases) as $cases
  | {
      ticket: "PARITY-06",
      generated_at: (now | todateiso8601),
      scope: {
        team_key: "LET",
        decision_surface: ["merge_ready", "not_ready"],
        observed_fields: [
          "all_checks_green",
          "has_pending_checks",
          "has_actionable_feedback",
          "merge_state_status"
        ]
      },
      source: {
        comments_filter: "comments contains \"merge_state_status\"",
        sampled_issue_count: ((.data.issues.nodes // []) | length),
        sampled_case_count: ($cases | length),
        sampled_merge_ready_count: ($ready_cases | length),
        sampled_not_ready_count: ($not_ready_cases | length)
      },
      cases: (
        $cases
        | to_entries
        | map(.value + {case_id: ("LIVE-" + ((.key + 1) | tostring))})
      )
    }
' "$clean_response" >"$OUT_FILE"

case_count=$(jq '.cases | length' "$OUT_FILE")
ready_count=$(jq '[.cases[] | select(.expected.merge_ready == true)] | length' "$OUT_FILE")
not_ready_count=$(jq '[.cases[] | select(.expected.merge_ready == false)] | length' "$OUT_FILE")

if [ "$case_count" -eq 0 ]; then
  echo "No PARITY-06 live cases were produced." >&2
  exit 1
fi

if [ "$ready_count" -eq 0 ]; then
  echo "PARITY-06 live fixture missing merge-ready cases." >&2
  exit 1
fi

if [ "$not_ready_count" -eq 0 ]; then
  echo "PARITY-06 live fixture missing not-ready cases." >&2
  exit 1
fi

hash=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
echo "Generated $OUT_FILE"
echo "SHA256 $hash"
