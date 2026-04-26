#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_FILE=${1:-"$REPO_ROOT/elixir/test/fixtures/parity/parity_07_runtime_recovery_live_sanitized.json"}

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "LINEAR_API_KEY is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

resume_query_payload() {
  jq -n '
    {
      query: "query Parity07Resume($teamKey: String!, $needle: String!, $first: Int!, $commentsFirst: Int!) { issues(first: $first, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $needle } } }) { nodes { id identifier state { name } comments(first: $commentsFirst) { nodes { id createdAt body } } } } }",
      variables: {
        teamKey: "LET",
        needle: "resume_mode",
        first: 120,
        commentsFirst: 250
      }
    }'
}

decision_query_payload() {
  jq -n '
    {
      query: "query Parity07Decision($teamKey: String!, $needle: String!, $first: Int!, $commentsFirst: Int!) { issues(first: $first, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $needle } } }) { nodes { id identifier state { name } comments(first: $commentsFirst) { nodes { id createdAt body } } } } }",
      variables: {
        teamKey: "LET",
        needle: "Retry/failover decision (auto-classified)",
        first: 120,
        commentsFirst: 250
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

raw_resume=$(mktemp)
raw_decision=$(mktemp)
clean_resume=$(mktemp)
clean_decision=$(mktemp)
trap 'rm -f "$raw_resume" "$raw_decision" "$clean_resume" "$clean_decision"' EXIT

if ! linear_query_with_retry "$(resume_query_payload)" "$raw_resume"; then
  echo "Failed to query Linear resume traces after retries." >&2
  exit 1
fi

if ! linear_query_with_retry "$(decision_query_payload)" "$raw_decision"; then
  echo "Failed to query Linear retry/failover traces after retries." >&2
  exit 1
fi

sanitize_raw_json "$raw_resume" "$clean_resume"
sanitize_raw_json "$raw_decision" "$clean_decision"

if jq -e '.errors and (.errors | length > 0)' "$clean_resume" >/dev/null; then
  echo "Linear resume query returned errors:" >&2
  jq '.errors' "$clean_resume" >&2
  exit 1
fi

if jq -e '.errors and (.errors | length > 0)' "$clean_decision" >/dev/null; then
  echo "Linear retry/failover query returned errors:" >&2
  jq '.errors' "$clean_decision" >&2
  exit 1
fi

jq -n \
  --slurpfile resume "$clean_resume" \
  --slurpfile decision "$clean_decision" '
  def normalize_text:
    (if . == null then "" else tostring end)
    | gsub("[\r\n\t]+"; " ")
    | gsub("\\s+"; " ")
    | gsub("^\\s+|\\s+$"; "");

  def extract_resume_mode($body):
    [($body // "")
      | capture("(?im)resume_mode\\s*[:=]\\s*`?(?<value>resume_checkpoint|fallback_reread)`?")?
      | .value][0];

  def extract_continuation_reason($body):
    [($body // "")
      | capture("(?im)continuation_reason\\s*[:=]\\s*`?(?<value>[a-zA-Z0-9_\\-]+)`?")?
      | .value][0];

  def extract_selected_rule($body):
    [($body // "")
      | capture("(?im)selected_rule\\s*:\\s*`?(?<value>[a-zA-Z0-9_\\-]+)`?")?
      | .value][0];

  def extract_selected_action($body):
    [($body // "")
      | capture("(?im)selected_action\\s*:\\s*`?(?<value>[a-zA-Z0-9_\\-]+)`?")?
      | .value][0];

  def resume_class($mode):
    if $mode == "resume_checkpoint" then
      "resume_checkpoint_recovery"
    elif $mode == "fallback_reread" then
      "fallback_reread_recovery"
    else
      "unknown"
    end;

  (
    ($resume[0].data.issues.nodes // [])
    | map(
        . as $issue
        | ($issue.comments.nodes // [])
        | map(
            (.body // "") as $body
            | extract_resume_mode($body) as $resume_mode
            | select($resume_mode != null)
            | {
                case_id: "",
                observed: {
                  resume_mode: $resume_mode,
                  continuation_reason: extract_continuation_reason($body),
                  selected_rule: null,
                  selected_action: null
                },
                expected: {
                  recovery_class: resume_class($resume_mode)
                },
                source: {
                  sampled_identifier: ($issue.identifier // null),
                  sampled_state: ($issue.state.name // "Unknown"),
                  sampled_created_at: (.createdAt // null),
                  sampled_excerpt: (($body | normalize_text) | .[0:220]),
                  evidence_channel: "resume_comment"
                }
              }
          )
      )
    | add
    | unique_by(.source.sampled_identifier, .observed.resume_mode)
    | .[0:14]
  ) as $resume_cases
  |
  (
    ($decision[0].data.issues.nodes // [])
    | map(
        . as $issue
        | ($issue.comments.nodes // [])
        | map(
            (.body // "") as $body
            | extract_selected_action($body) as $selected_action
            | select($selected_action == "stop_with_classified_handoff")
            | {
                case_id: "",
                observed: {
                  resume_mode: null,
                  continuation_reason: null,
                  selected_rule: extract_selected_rule($body),
                  selected_action: $selected_action
                },
                expected: {
                  recovery_class: "classified_handoff_stop"
                },
                source: {
                  sampled_identifier: ($issue.identifier // null),
                  sampled_state: ($issue.state.name // "Unknown"),
                  sampled_created_at: (.createdAt // null),
                  sampled_excerpt: (($body | normalize_text) | .[0:220]),
                  evidence_channel: "retry_decision_comment"
                }
              }
          )
      )
    | add
    | unique_by(.source.sampled_identifier, .observed.selected_rule, .observed.selected_action)
    | .[0:14]
  ) as $decision_cases
  |
  ($resume_cases + $decision_cases) as $cases
  |
  {
    ticket: "PARITY-07",
    generated_at: (now | todateiso8601),
    scope: {
      team_key: "LET",
      canonical_recovery_classes: [
        "resume_checkpoint_recovery",
        "fallback_reread_recovery",
        "classified_handoff_stop"
      ],
      observed_fields: [
        "resume_mode",
        "continuation_reason",
        "selected_rule",
        "selected_action"
      ]
    },
    source: {
      resume_filter: "comments contains \"resume_mode\"",
      retry_filter: "comments contains \"Retry/failover decision (auto-classified)\"",
      sampled_resume_issue_count: (($resume[0].data.issues.nodes // []) | length),
      sampled_retry_issue_count: (($decision[0].data.issues.nodes // []) | length),
      sampled_case_count: ($cases | length)
    },
    cases: (
      $cases
      | to_entries
      | map(.value + {case_id: ("LIVE-" + ((.key + 1) | tostring))})
    )
  }
' >"$OUT_FILE"

case_count=$(jq '.cases | length' "$OUT_FILE")
classified_count=$(jq '[.cases[] | select(.expected.recovery_class == "classified_handoff_stop")] | length' "$OUT_FILE")
resume_count=$(jq '[.cases[] | select(.expected.recovery_class == "resume_checkpoint_recovery" or .expected.recovery_class == "fallback_reread_recovery")] | length' "$OUT_FILE")
unknown_count=$(jq '[.cases[] | select(.expected.recovery_class == "unknown")] | length' "$OUT_FILE")

if [ "$case_count" -eq 0 ]; then
  echo "No PARITY-07 live cases were produced." >&2
  exit 1
fi

if [ "$classified_count" -eq 0 ]; then
  echo "PARITY-07 live fixture missing classified_handoff_stop cases." >&2
  exit 1
fi

if [ "$resume_count" -eq 0 ]; then
  echo "PARITY-07 live fixture missing resume-mode recovery cases." >&2
  exit 1
fi

if [ "$unknown_count" -ne 0 ]; then
  echo "PARITY-07 live fixture contains unknown recovery classes." >&2
  exit 1
fi

hash=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
echo "Generated $OUT_FILE"
echo "SHA256 $hash"
