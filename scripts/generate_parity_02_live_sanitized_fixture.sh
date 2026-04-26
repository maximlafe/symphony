#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_FILE=${1:-"$REPO_ROOT/elixir/test/fixtures/parity/parity_02_issue_trace_live_sanitized.json"}

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "LINEAR_API_KEY is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

query_payload() {
  local needle="$1"
  jq -n \
    --arg needle "$needle" \
    '{
      query: "query Parity02IssueTrace($teamKey: String!, $needle: String!, $first: Int!, $commentsFirst: Int!, $attachmentsFirst: Int!) { issues(first: $first, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $needle } } }) { nodes { id identifier state { name } comments(first: $commentsFirst) { nodes { id body createdAt user { name displayName email } } } attachments(first: $attachmentsFirst) { nodes { id title subtitle url createdAt } } updatedAt } } }",
      variables: {
        teamKey: "LET",
        needle: $needle,
        first: 40,
        commentsFirst: 80,
        attachmentsFirst: 30
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

workpad_raw=$(mktemp)
handoff_raw=$(mktemp)
workpad_clean=$(mktemp)
handoff_clean=$(mktemp)

trap 'rm -f "$workpad_raw" "$handoff_raw" "$workpad_clean" "$handoff_clean"' EXIT

if ! linear_query_with_retry "$(query_payload "Codex Workpad")" "$workpad_raw"; then
  echo "Failed to query Linear workpad trace slice after retries." >&2
  exit 1
fi

if ! linear_query_with_retry "$(query_payload "selected_action")" "$handoff_raw"; then
  echo "Failed to query Linear handoff trace slice after retries." >&2
  exit 1
fi

sanitize_raw_json "$workpad_raw" "$workpad_clean"
sanitize_raw_json "$handoff_raw" "$handoff_clean"

if jq -e '.errors and (.errors | length > 0)' "$workpad_clean" >/dev/null; then
  echo "Linear workpad trace query returned errors:" >&2
  jq '.errors' "$workpad_clean" >&2
  exit 1
fi

if jq -e '.errors and (.errors | length > 0)' "$handoff_clean" >/dev/null; then
  echo "Linear handoff trace query returned errors:" >&2
  jq '.errors' "$handoff_clean" >&2
  exit 1
fi

jq -n \
  --slurpfile workpad "$workpad_clean" \
  --slurpfile handoff "$handoff_clean" \
  '
  def trim_or_null:
    (if . == null then null else (tostring | gsub("^\\s+|\\s+$"; "")) end)
    | if . == "" then null else . end;

  def has_workpad_signal($body):
    ($body // "") | test("(?i)(codex workpad|рабочий журнал codex)");

  def has_handoff_decision_signal($body):
    ($body // "") | test("(?i)selected_action\\s*:");

  def has_handoff_milestone_signal($body):
    ($body // "") | test("(?i)symphony milestone") and (($body // "") | test("(?i)handoff-ready"));

  def extract_selected_action($body):
    (
      [($body // "") | capture("(?im)selected_action\\s*:\\s*`?(?<value>[^`\\n\\r]+)`?") | .value]
      | .[0]
    )
    | trim_or_null;

  def extract_checkpoint_type($body):
    (
      [($body // "") | capture("(?im)checkpoint_type\\s*:\\s*`?(?<value>[^`\\n\\r]+)`?") | .value]
      | .[0]
    )
    | trim_or_null;

  def extract_milestone($body):
    if (($body // "") | test("(?i)handoff-ready")) then "handoff-ready" else null end;

  def redact_comment_body($body):
    if has_handoff_decision_signal($body) then
      (
        "selected_action: " + ((extract_selected_action($body) // "unknown")) + "\n" +
        "checkpoint_type: " + ((extract_checkpoint_type($body) // "unknown"))
      )
    elif has_handoff_milestone_signal($body) then
      "### Symphony milestone\n- milestone: handoff-ready"
    elif has_workpad_signal($body) then
      "## Codex Workpad\n[redacted]"
    else
      "[redacted trace comment]"
    end;

  def comment_channel($body):
    if has_handoff_decision_signal($body) then "handoff_decision_comment"
    elif has_handoff_milestone_signal($body) then "handoff_milestone_comment"
    elif has_workpad_signal($body) then "workpad_comment"
    else "comment"
    end;

  def normalize_comment($comment):
    ($comment.body // "") as $body
    | {
        channel: comment_channel($body),
        created_at: ($comment.createdAt // null),
        author: "operator",
        body: redact_comment_body($body),
        selected_action: extract_selected_action($body),
        checkpoint_type: extract_checkpoint_type($body),
        milestone: extract_milestone($body)
      };

  def normalize_attachment($attachment):
    {
      title: ($attachment.title // ""),
      subtitle: ($attachment.subtitle // ""),
      url: ($attachment.url // null),
      created_at: ($attachment.createdAt // null)
    };

  def build_case($issue; $prefix; $idx; $requires_workpad; $requires_handoff_decision):
    ($issue.comments.nodes // []) as $comments
    | ($issue.attachments.nodes // []) as $attachments
    | {
        case_id: ($prefix + "-" + (($idx + 1) | tostring)),
        trace_kind: (if $requires_handoff_decision then "handoff" else "workpad" end),
        issue: {
          id: ("live-issue-" + (($idx + 1) | tostring)),
          identifier: ($prefix + "-" + (($idx + 1) | tostring)),
          state: ($issue.state.name // "Unknown")
        },
        comments: ($comments | map(normalize_comment(.))),
        attachments: ($attachments | map(normalize_attachment(.))),
        expected: {
          requires_workpad_signal: $requires_workpad,
          requires_artifact_signal: (($attachments | length) > 0),
          requires_handoff_decision: $requires_handoff_decision,
          requires_handoff_milestone: (
            [$comments[]? | .body // "" | has_handoff_milestone_signal(.)] | any
          ),
          requires_valid_timing: true
        },
        source: {
          sampled_identifier: ($issue.identifier // null),
          sampled_comment_count: ($comments | length),
          sampled_attachment_count: ($attachments | length)
        }
      };

  ($workpad[0].data.issues.nodes // []) as $workpad_nodes_raw
  | ($handoff[0].data.issues.nodes // []) as $handoff_nodes_raw
  | (
      $workpad_nodes_raw
      | map(
          select(
            (
              [(.comments.nodes[]? | .body // "" | has_workpad_signal(.))] | any
            ) and (
              ((.attachments.nodes // []) | length) > 0
            )
          )
        )
      | sort_by(.identifier)
      | .[0:12]
    ) as $workpad_nodes
  | (
      $handoff_nodes_raw
      | map(
          select(
            [(.comments.nodes[]? | .body // "" | has_handoff_decision_signal(.))] | any
          )
        )
      | sort_by(.identifier)
      | .[0:12]
    ) as $handoff_nodes
  | {
      ticket: "PARITY-02",
      generated_at: (now | todateiso8601),
      scope: {
        team_key: "LET",
        trace_channels: [
          "workpad_comment",
          "artifact_attachment",
          "handoff_decision_comment",
          "handoff_milestone_comment",
          "trace_timing"
        ]
      },
      source: {
        workpad_filter: "comments contains \"Codex Workpad\"",
        handoff_filter: "comments contains \"selected_action\"",
        workpad_sampled_issue_count: ($workpad_nodes | length),
        handoff_sampled_issue_count: ($handoff_nodes | length)
      },
      cases: (
        ($workpad_nodes
          | to_entries
          | map(build_case(.value; "LIVE-WORKPAD"; .key; true; false)))
        +
        ($handoff_nodes
          | to_entries
          | map(build_case(.value; "LIVE-HANDOFF"; .key; false; true)))
      )
    }
  ' >"$OUT_FILE"

hash=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
echo "Generated $OUT_FILE"
echo "SHA256 $hash"
