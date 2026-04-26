#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_FILE=${1:-"$REPO_ROOT/elixir/test/fixtures/parity/parity_05_finalizer_semantics_live_sanitized.json"}

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "LINEAR_API_KEY is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

query_payload() {
  jq -n '
    {
      query: "query Parity05FinalizerSemantics($teamKey: String!, $finalizerNeedle: String!, $actionNeedle: String!, $mergeNeedle: String!, $first: Int!, $commentsFirst: Int!) { finalizerIssues: issues(first: $first, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $finalizerNeedle } } }) { nodes { id identifier state { name } comments(first: $commentsFirst) { nodes { id createdAt body } } } } actionIssues: issues(first: $first, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $actionNeedle } } }) { nodes { id identifier state { name } comments(first: $commentsFirst) { nodes { id createdAt body } } } } mergeIssues: issues(first: $first, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $mergeNeedle } } }) { nodes { id identifier state { name } comments(first: $commentsFirst) { nodes { id createdAt body } } } } }",
      variables: {
        teamKey: "LET",
        finalizerNeedle: "controller_finalizer",
        actionNeedle: "action_required",
        mergeNeedle: "PR смержен",
        first: 120,
        commentsFirst: 240
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
  echo "Failed to query Linear finalizer semantics traces after retries." >&2
  exit 1
fi

sanitize_raw_json "$raw_response" "$clean_response"

if jq -e '.errors and (.errors | length > 0)' "$clean_response" >/dev/null; then
  echo "Linear finalizer semantics query returned errors:" >&2
  jq '.errors' "$clean_response" >&2
  exit 1
fi

jq '
  def normalize_text:
    (if . == null then "" else tostring end)
    | gsub("[\r\n\t]+"; " ")
    | gsub("\\s+"; " ")
    | gsub("^\\s+|\\s+$"; "");

  def infer_case($body):
    ($body // "") as $raw
    | ($raw | ascii_downcase) as $lower
    | if ($lower | test("pull request checks failed")) then
        {
          outcome: "fallback",
          controller_status: "action_required",
          reason: "pull request checks failed",
          reason_mode: "canonical"
        }
      elif ($lower | test("pull request checks are still pending")) then
        {
          outcome: "retry",
          controller_status: "waiting",
          reason: "pull request checks are still pending",
          reason_mode: "canonical"
        }
      elif ($lower | test("pull request has actionable feedback")) then
        {
          outcome: "fallback",
          controller_status: "action_required",
          reason: "pull request has actionable feedback",
          reason_mode: "canonical"
        }
      elif ($lower | test("symphony_handoff_check failed")) then
        {
          outcome: "fallback",
          controller_status: "action_required",
          reason: "symphony_handoff_check failed",
          reason_mode: "canonical"
        }
      elif ($lower | test("required proof checks are missing before handoff")) then
        {
          outcome: "fallback",
          controller_status: "action_required",
          reason: "required proof checks are missing before handoff",
          reason_mode: "canonical"
        }
      elif ($lower | test("failed to transition issue state")) then
        {
          outcome: "retry",
          controller_status: "waiting",
          reason: "failed to transition issue state",
          reason_mode: "canonical"
        }
      elif ($lower | test("controller finalizer completed successfully")) then
        {
          outcome: "ok",
          controller_status: "succeeded",
          reason: "controller finalizer completed successfully",
          reason_mode: "canonical"
        }
      elif ($lower | test("controller_finalizer\\.status=action_required")) or (($lower | test("action_required")) and ($lower | test("fallback"))) then
        {
          outcome: "fallback",
          controller_status: "action_required",
          reason: "controller_finalizer.status=action_required",
          reason_mode: "status_inferred"
        }
      elif ($lower | test("controller_finalizer\\.status=waiting")) then
        {
          outcome: "retry",
          controller_status: "waiting",
          reason: "controller_finalizer.status=waiting",
          reason_mode: "status_inferred"
        }
      elif ($lower | test("controller_finalizer\\.status=not_applicable")) then
        {
          outcome: "not_applicable",
          controller_status: "not_applicable",
          reason: "controller finalizer prerequisites are not satisfied",
          reason_mode: "status_inferred"
        }
      elif ($lower | test("merge commit")) or ($lower | test("squash-merge")) then
        {
          outcome: "ok",
          controller_status: "succeeded",
          reason: "merge commit observed in live task report",
          reason_mode: "merge_inferred"
        }
      else
        null
      end;

  (
    (
      ((.data.finalizerIssues.nodes // []) +
      (.data.actionIssues.nodes // []) +
      (.data.mergeIssues.nodes // []))
      | unique_by(.identifier)
    )
    | map(
        . as $issue
        | ($issue.comments.nodes // [])
        | map(
            . as $comment
            | infer_case($comment.body) as $decision
            | select($decision != null)
            | {
                case_id: "",
                observed: {
                  reason: $decision.reason,
                  status: $decision.controller_status,
                  reason_mode: $decision.reason_mode
                },
                expected: (
                  if $decision.reason_mode == "canonical" then
                    {
                      outcome: $decision.outcome,
                      controller_status: $decision.controller_status,
                      reason: $decision.reason
                    }
                  else
                    {
                      outcome: $decision.outcome,
                      controller_status: $decision.controller_status
                    }
                  end
                ),
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
    | unique_by(.source.sampled_identifier, .expected.outcome, .observed.reason)
  ) as $all_cases
  | ($all_cases | map(select(.expected.outcome == "fallback")) | .[0:6]) as $fallback
  | ($all_cases | map(select(.expected.outcome == "retry")) | .[0:4]) as $retry
  | ($all_cases | map(select(.expected.outcome == "ok")) | .[0:6]) as $ok
  | ($all_cases | map(select(.expected.outcome == "not_applicable")) | .[0:2]) as $not_applicable
  | ($fallback + $retry + $ok + $not_applicable) as $cases
  | {
      ticket: "PARITY-05",
      generated_at: (now | todateiso8601),
      scope: {
        team_key: "LET",
        decision_surface: ["ok", "retry", "fallback", "not_applicable"],
        live_signal_surface: [
          "canonical_reason",
          "controller_finalizer.status",
          "merge_commit_summary"
        ]
      },
      source: {
        comments_filter: [
          "comments contains \"controller_finalizer\"",
          "comments contains \"action_required\"",
          "comments contains \"PR смержен\""
        ],
        sampled_issue_count: (
          ((.data.finalizerIssues.nodes // []) +
          (.data.actionIssues.nodes // []) +
          (.data.mergeIssues.nodes // []))
          | unique_by(.identifier)
          | length
        ),
        sampled_case_count: ($cases | length),
        sampled_fallback_count: ($fallback | length),
        sampled_retry_count: ($retry | length),
        sampled_ok_count: ($ok | length),
        sampled_not_applicable_count: ($not_applicable | length)
      },
      cases: (
        $cases
        | to_entries
        | map(.value + {case_id: ("LIVE-" + ((.key + 1) | tostring))})
      )
    }
' "$clean_response" >"$OUT_FILE"

fallback_count=$(jq '[.cases[] | select(.expected.outcome == "fallback")] | length' "$OUT_FILE")
ok_count=$(jq '[.cases[] | select(.expected.outcome == "ok")] | length' "$OUT_FILE")
case_count=$(jq '.cases | length' "$OUT_FILE")

if [ "$case_count" -eq 0 ]; then
  echo "No PARITY-05 live cases were produced." >&2
  exit 1
fi

if [ "$fallback_count" -eq 0 ]; then
  echo "PARITY-05 live fixture missing fallback cases." >&2
  exit 1
fi

if [ "$ok_count" -eq 0 ]; then
  echo "PARITY-05 live fixture missing ok cases." >&2
  exit 1
fi

hash=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
echo "Generated $OUT_FILE"
echo "SHA256 $hash"
