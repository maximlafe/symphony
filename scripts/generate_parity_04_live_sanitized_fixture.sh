#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_FILE=${1:-"$REPO_ROOT/elixir/test/fixtures/parity/parity_04_pr_evidence_live_sanitized.json"}
REPO_HINT=${SYMPHONY_GITHUB_REPO:-maximlafe/symphony}

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "LINEAR_API_KEY is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

query_payload() {
  jq -n '
    {
      query: "query Parity04PrEvidence($teamKey: String!, $needle: String!, $commentFirst: Int!, $branchFirst: Int!, $commentsFirst: Int!, $attachmentsFirst: Int!) { commentIssues: issues(first: $commentFirst, filter: { team: { key: { eq: $teamKey } }, comments: { body: { containsIgnoreCase: $needle } } }) { nodes { id identifier state { name } branchName comments(first: $commentsFirst) { nodes { id body createdAt } } attachments(first: $attachmentsFirst) { nodes { id title subtitle url createdAt } } } } branchIssues: issues(first: $branchFirst, filter: { team: { key: { eq: $teamKey } } }) { nodes { id identifier state { name } branchName comments(first: 20) { nodes { body createdAt } } attachments(first: 20) { nodes { title subtitle url createdAt } } } } }",
      variables: {
        teamKey: "LET",
        needle: "/pull/",
        commentFirst: 80,
        branchFirst: 120,
        commentsFirst: 80,
        attachmentsFirst: 40
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
comment_cases_file=$(mktemp)
attachment_cases_file=$(mktemp)
branch_cases_file=$(mktemp)
trap 'rm -f "$raw_response" "$clean_response" "$comment_cases_file" "$attachment_cases_file" "$branch_cases_file"' EXIT

if ! linear_query_with_retry "$(query_payload)" "$raw_response"; then
  echo "Failed to query Linear PR evidence traces after retries." >&2
  exit 1
fi

sanitize_raw_json "$raw_response" "$clean_response"

if jq -e '.errors and (.errors | length > 0)' "$clean_response" >/dev/null; then
  echo "Linear PR evidence query returned errors:" >&2
  jq '.errors' "$clean_response" >&2
  exit 1
fi

jq '
  def pr_url($text):
    (
      try (
        ($text // "")
        | capture("https://github\\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/pull/(?<number>[0-9]+)")
        | "https://github.com/\(.owner)/\(.repo)/pull/\(.number)"
      ) catch null
    );

  def repo_from_url($url):
    (
      try (
        ($url // "")
        | capture("^https://github\\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/pull/[0-9]+$")
        | "\(.owner)/\(.repo)"
      ) catch null
    );

  def pr_number_from_url($url):
    (
      try (
        ($url // "")
        | capture("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/(?<number>[0-9]+)$")
        | (.number | tonumber)
      ) catch null
    );

  (
    (.data.commentIssues.nodes // [])
    | map(
        . as $issue
        | ($issue.comments.nodes // [])
        | map(
            . as $comment
            | pr_url($comment.body) as $url
            | select($url != null)
            | {
                case_id: "",
                input: {
                  repo: repo_from_url($url),
                  issue_comments: [
                    {body: ("PR evidence: " + $url)}
                  ]
                },
                expected: {
                  source: "issue_comment",
                  repo: repo_from_url($url),
                  pr_number: pr_number_from_url($url),
                  url: $url
                },
                source: {
                  sampled_identifier: ($issue.identifier // null),
                  sampled_state: ($issue.state.name // "Unknown"),
                  sampled_branch_name: ($issue.branchName // null),
                  sampled_comment_created_at: ($comment.createdAt // null),
                  evidence_channel: "comment"
                }
              }
          )
      )
    | add
    | unique_by(.expected.url)
    | .[0:12]
    | to_entries
    | map(.value + {case_id: ("LIVE-COMMENT-" + ((.key + 1) | tostring))})
  )
' "$clean_response" >"$comment_cases_file"

jq '
  def pr_url($text):
    (
      try (
        ($text // "")
        | capture("https://github\\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/pull/(?<number>[0-9]+)")
        | "https://github.com/\(.owner)/\(.repo)/pull/\(.number)"
      ) catch null
    );

  def repo_from_url($url):
    (
      try (
        ($url // "")
        | capture("^https://github\\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/pull/[0-9]+$")
        | "\(.owner)/\(.repo)"
      ) catch null
    );

  def pr_number_from_url($url):
    (
      try (
        ($url // "")
        | capture("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/(?<number>[0-9]+)$")
        | (.number | tonumber)
      ) catch null
    );

  (
    (.data.commentIssues.nodes // [])
    | map(
        . as $issue
        | ($issue.attachments.nodes // [])
        | map(
            . as $attachment
            | pr_url($attachment.url) as $url
            | select($url != null)
            | {
                case_id: "",
                input: {
                  repo: repo_from_url($url),
                  issue_attachments: [
                    {title: "PR evidence attachment", url: $url}
                  ]
                },
                expected: {
                  source: "issue_attachment",
                  repo: repo_from_url($url),
                  pr_number: pr_number_from_url($url),
                  url: $url
                },
                source: {
                  sampled_identifier: ($issue.identifier // null),
                  sampled_state: ($issue.state.name // "Unknown"),
                  sampled_branch_name: ($issue.branchName // null),
                  sampled_attachment_created_at: ($attachment.createdAt // null),
                  evidence_channel: "attachment"
                }
              }
          )
      )
    | add
    | unique_by(.expected.url)
    | .[0:12]
    | to_entries
    | map(.value + {case_id: ("LIVE-ATTACHMENT-" + ((.key + 1) | tostring))})
  )
' "$clean_response" >"$attachment_cases_file"

echo '[]' >"$branch_cases_file"

while IFS=$'\t' read -r sampled_identifier branch_name; do
  [ -n "$sampled_identifier" ] || continue
  [ -n "$branch_name" ] || continue

  pr_json=$(gh pr list --repo "$REPO_HINT" --head "$branch_name" --state all --json number,url 2>/dev/null || true)

  if ! echo "$pr_json" | jq -e 'type == "array" and (length > 0) and (.[] | .url | test("/pull/"))' >/dev/null 2>&1; then
    continue
  fi

  first_pr=$(echo "$pr_json" | jq '.[0]')
  pr_number=$(echo "$first_pr" | jq '.number')
  pr_url=$(echo "$first_pr" | jq -r '.url')

  branch_cases=$(jq -n \
    --argjson existing "$(cat "$branch_cases_file")" \
    --arg sampled_identifier "$sampled_identifier" \
    --arg branch_name "$branch_name" \
    --arg repo "$REPO_HINT" \
    --arg url "$pr_url" \
    --argjson number "$pr_number" '
      $existing as $arr
      | $arr + [
          {
            case_id: ("LIVE-BRANCH-" + (($arr | length) + 1 | tostring)),
            input: {
              repo: $repo,
              issue_branch_name: $branch_name
            },
            lookup_result: {
              number: $number,
              url: $url
            },
            expected: {
              source: "branch_lookup",
              repo: $repo,
              pr_number: $number,
              url: $url
            },
            source: {
              sampled_identifier: $sampled_identifier,
              sampled_branch_name: $branch_name,
              evidence_channel: "branch_lookup",
              lookup_origin: "github_head_lookup"
            }
          }
        ]
    ')

  echo "$branch_cases" >"$branch_cases_file"
done < <(
  jq -r '
    (.data.branchIssues.nodes // [])
    | map(select((.branchName // "") != ""))
    | unique_by(.branchName)
    | .[0:30]
    | .[]
    | [.identifier, .branchName]
    | @tsv
  ' "$clean_response"
)

comment_count=$(jq 'length' "$comment_cases_file")
attachment_count=$(jq 'length' "$attachment_cases_file")
branch_count=$(jq 'length' "$branch_cases_file")

if [ "$branch_count" -eq 0 ]; then
  jq '
    def pr_url($text):
      (
        try (
          ($text // "")
          | capture("https://github\\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/pull/(?<number>[0-9]+)")
          | "https://github.com/\(.owner)/\(.repo)/pull/\(.number)"
        ) catch null
      );

    def repo_from_url($url):
      (
        try (
          ($url // "")
          | capture("^https://github\\.com/(?<owner>[A-Za-z0-9_.-]+)/(?<repo>[A-Za-z0-9_.-]+)/pull/[0-9]+$")
          | "\(.owner)/\(.repo)"
        ) catch null
      );

    def pr_number_from_url($url):
      (
        try (
          ($url // "")
          | capture("^https://github\\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/(?<number>[0-9]+)$")
          | (.number | tonumber)
        ) catch null
      );

    (
      (.data.commentIssues.nodes // [])
      | map(
          . as $issue
          | select(($issue.branchName // "") != "")
          | (
              [($issue.comments.nodes[]?.body // "" | pr_url(.))] +
              [($issue.attachments.nodes[]?.url // "" | pr_url(.))]
            ) as $urls
          | ($urls | map(select(. != null)) | .[0]) as $url
          | select($url != null)
          | {
              case_id: "",
              input: {
                repo: repo_from_url($url),
                issue_branch_name: $issue.branchName
              },
              lookup_result: {
                number: pr_number_from_url($url),
                url: $url
              },
              expected: {
                source: "branch_lookup",
                repo: repo_from_url($url),
                pr_number: pr_number_from_url($url),
                url: $url
              },
              source: {
                sampled_identifier: ($issue.identifier // null),
                sampled_branch_name: $issue.branchName,
                evidence_channel: "branch_lookup",
                lookup_origin: "issue_trace_url_fallback"
              }
            }
        )
      | unique_by(.source.sampled_branch_name, .expected.url)
      | .[0:12]
      | to_entries
      | map(.value + {case_id: ("LIVE-BRANCH-" + ((.key + 1) | tostring))})
    )
  ' "$clean_response" >"$branch_cases_file"

  branch_count=$(jq 'length' "$branch_cases_file")
fi

if [ "$comment_count" -eq 0 ]; then
  echo "No live comment PR evidence cases found." >&2
  exit 1
fi

if [ "$attachment_count" -eq 0 ]; then
  echo "No live attachment PR evidence cases found." >&2
  exit 1
fi

if [ "$branch_count" -eq 0 ]; then
  echo "No live branch lookup PR evidence cases found." >&2
  exit 1
fi

jq -n \
  --arg repo "$REPO_HINT" \
  --slurpfile raw_payload "$clean_response" \
  --slurpfile comment_cases "$comment_cases_file" \
  --slurpfile attachment_cases "$attachment_cases_file" \
  --slurpfile branch_cases "$branch_cases_file" \
  '
    ($raw_payload[0] // {}) as $raw
    | ($comment_cases[0] // []) as $comment
    | ($attachment_cases[0] // []) as $attachment
    | ($branch_cases[0] // []) as $branch
    | {
        ticket: "PARITY-04",
        generated_at: (now | todateiso8601),
        scope: {
          team_key: "LET",
          sources: [
            "workspace_checkpoint",
            "workpad",
            "issue_comment",
            "issue_attachment",
            "branch_lookup"
          ],
          live_required_sources: [
            "issue_comment",
            "issue_attachment",
            "branch_lookup"
          ]
        },
        source: {
          team_key: "LET",
          comments_filter: "comments contains \"/pull/\"",
          github_repo_for_branch_lookup: $repo,
          sampled_comment_issue_count: (($raw.data.commentIssues.nodes // []) | length),
          sampled_branch_issue_count: (($raw.data.branchIssues.nodes // []) | length),
          sampled_comment_case_count: ($comment | length),
          sampled_attachment_case_count: ($attachment | length),
          sampled_branch_case_count: ($branch | length)
        },
        cases: ($comment + $attachment + $branch)
      }
  ' >"$OUT_FILE"

hash=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
echo "Generated $OUT_FILE"
echo "SHA256 $hash"
