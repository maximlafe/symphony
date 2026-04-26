#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_FILE=${1:-"$REPO_ROOT/elixir/test/fixtures/parity/parity_03_resume_legacy_live_sanitized.json"}

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "LINEAR_API_KEY is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

query_payload() {
  jq -n '
    {
      query: "query Parity03LegacyResume($teamKey: String!, $needle: String!, $first: Int!, $commentsFirst: Int!, $attachmentsFirst: Int!) { issues(first: $first, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $needle } } }) { nodes { id identifier state { name } comments(first: $commentsFirst) { nodes { id body createdAt } } attachments(first: $attachmentsFirst) { nodes { id title createdAt } } } } }",
      variables: {
        teamKey: "LET",
        needle: "resume_mode",
        first: 50,
        commentsFirst: 120,
        attachmentsFirst: 20
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
  echo "Failed to query Linear legacy resume traces after retries." >&2
  exit 1
fi

sanitize_raw_json "$raw_response" "$clean_response"

if jq -e '.errors and (.errors | length > 0)' "$clean_response" >/dev/null; then
  echo "Linear legacy resume query returned errors:" >&2
  jq '.errors' "$clean_response" >&2
  exit 1
fi

jq '
  def normalize_text:
    (if . == null then "" else tostring end)
    | gsub("\\s+"; " ")
    | gsub("^\\s+|\\s+$"; "");

  def extract_resume_mode($body):
    (
      try (
        ($body // "")
        | capture("(?im)resume_mode\\s*[:=]\\s*`?(?<value>resume_checkpoint|fallback_reread)`?")
        | .value
      ) catch null
    );

  def fallback_hint($body):
    ($body // "") as $text
    | if $text | test("(?i)(missing|отсутствуют)[^\\n\\r`]*`?workpad_ref`?") then
        "missing `workpad_ref` in resume checkpoint"
      elif $text | test("(?i)(missing|отсутствуют)[^\\n\\r`]*`?workpad_digest`?") then
        "missing `workpad_digest` in resume checkpoint"
      elif $text | test("(?i)workspace is unavailable for retry checkpoint capture") then
        "workspace is unavailable for retry checkpoint capture"
      elif $text | test("(?i)resume checkpoint capture failed") then
        "resume checkpoint capture failed: boom"
      elif $text | test("(?i)mismatch") then
        "resume checkpoint `head` mismatch: expected `abc`, current `def`"
      else
        "resume checkpoint is unavailable"
      end;

  def fallback_code($reason):
    ($reason | ascii_downcase) as $r
    | if $r | startswith("resume checkpoint is unavailable") then
        "resume_checkpoint_unavailable"
      elif $r | startswith("workspace is unavailable for retry checkpoint capture") then
        "workspace_unavailable"
      elif $r | startswith("resume checkpoint capture failed") then
        "checkpoint_capture_failed"
      elif $r | contains(" mismatch:") then
        "checkpoint_mismatch"
      elif $r | startswith("missing ") then
        "checkpoint_missing_required_field"
      else
        "checkpoint_not_ready"
      end;

  def redacted_excerpt($mode; $body):
    if $mode == "resume_checkpoint" then
      "resume_mode=resume_checkpoint"
    else
      "resume_mode=fallback_reread; fallback_hint=" + fallback_hint($body)
    end;

  (.data.issues.nodes // []) as $issue_nodes
  | (
      $issue_nodes
      | map(
          . as $issue
          | ($issue.comments.nodes // [])
          | map(
              (.body // "") as $body
              | {
                  issue_identifier: ($issue.identifier // null),
                  issue_state: ($issue.state.name // "Unknown"),
                  created_at: (.createdAt // null),
                  resume_mode: extract_resume_mode($body),
                  body: $body,
                  attachment_count: (($issue.attachments.nodes // []) | length)
                }
            )
        )
      | add
      | map(select(.resume_mode != null))
      | sort_by(.issue_identifier, .created_at)
      | .[0:20]
    ) as $samples
  | {
      ticket: "PARITY-03",
      generated_at: (now | todateiso8601),
      scope: {
        team_key: "LET",
        resume_modes: ["resume_checkpoint", "fallback_reread"]
      },
      source: {
        resume_filter: "comments contains \"resume_mode\"",
        sampled_issue_count: (($samples | map(.issue_identifier) | unique) | length),
        sampled_trace_count: ($samples | length)
      },
      cases: (
        $samples
        | to_entries
        | map(
            .key as $idx
            | .value as $sample
            | ($sample.resume_mode) as $mode
            | (if $mode == "fallback_reread" then fallback_hint($sample.body) else null end) as $fallback_hint
            | (if $mode == "fallback_reread" then fallback_code($fallback_hint) else null end) as $fallback_code
            | {
                case_id: ("LIVE-" + (($idx + 1) | tostring)),
                checkpoint_input: (
                  if $mode == "resume_checkpoint" then
                    {
                      "resume_mode": "resume_checkpoint"
                    }
                  else
                    {
                      "resume_mode": "fallback_reread",
                      "resume_ready": false,
                      "fallback_reasons": [$fallback_hint]
                    }
                  end
                ),
                expected: {
                  resume_mode: "fallback_reread",
                  resume_fallback_reason: (
                    if $mode == "resume_checkpoint" then
                      "checkpoint_missing_required_field"
                    else
                      $fallback_code
                    end
                  ),
                  resume_ready: false,
                  ambiguous_recovery: false
                },
                source: {
                  sampled_identifier: $sample.issue_identifier,
                  sampled_state: $sample.issue_state,
                  sampled_created_at: $sample.created_at,
                  sampled_attachment_count: $sample.attachment_count,
                  observed_resume_mode: $mode,
                  sampled_trace_excerpt: redacted_excerpt($mode; $sample.body) | normalize_text
                }
              }
          )
      )
    }
' "$clean_response" >"$OUT_FILE"

hash=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
echo "Generated $OUT_FILE"
echo "SHA256 $hash"
