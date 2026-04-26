#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
OUT_FILE=${1:-"$REPO_ROOT/elixir/test/fixtures/parity/parity_01_linear_routing_live_sanitized.json"}

if [ -z "${LINEAR_API_KEY:-}" ]; then
  echo "LINEAR_API_KEY is required." >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_FILE")"

GRAPHQL_QUERY='query SymphonyParity01LiveRouting($teamKey: String!, $stateNames: [String!]!, $first: Int!, $relationFirst: Int!) {
  issues(
    filter: {team: {key: {eq: $teamKey}}, state: {name: {in: $stateNames}}}
    first: $first
  ) {
    nodes {
      id
      identifier
      title
      priority
      project {
        slugId
        name
      }
      state {
        name
      }
      assignee {
        id
        email
        name
      }
      labels {
        nodes {
          name
        }
      }
      inverseRelations(first: $relationFirst) {
        nodes {
          type
          issue {
            id
            identifier
            state {
              name
            }
          }
        }
      }
      createdAt
      updatedAt
    }
  }
}'

payload=$(
  jq -n \
    --arg query "$GRAPHQL_QUERY" \
    '{
      query: $query,
      variables: {
        teamKey: "LET",
        stateNames: ["Todo", "Spec Prep", "In Progress", "Merging", "Rework", "Blocked"],
        first: 80,
        relationFirst: 20
      }
    }'
)

response=$(
  curl -sS --http1.1 https://api.linear.app/graphql \
    -H "Authorization: ${LINEAR_API_KEY}" \
    -H "Content-Type: application/json" \
    --data "$payload"
)

if echo "$response" | jq -e '.errors and (.errors | length > 0)' >/dev/null; then
  echo "$response" | jq '.errors' >&2
  exit 1
fi

echo "$response" \
  | jq '
    def n($v): ($v // "") | ascii_downcase;
    def is_terminal($s): ["closed","cancelled","canceled","duplicate","done"] | index(n($s)) != null;
    def is_active($s): ["todo","spec prep","in progress","merging","rework"] | index(n($s)) != null;
    def assigned_to_symphony($a):
      ($a != null) and (
        (($a.name // "") == "symphony") or
        (($a.id // "") == "symphony") or
        ((($a.email // "") | ascii_downcase) == "symphony")
      );
    def blocker_states($nodes):
      [($nodes // [])[] | select(n(.type) == "blocks") | (.issue.state.name // "Unknown")];
    def todo_blocked_non_terminal($state; $blockers):
      (n($state) == "todo") and ([ $blockers[] | select((is_terminal(.) | not)) ] | length > 0);
    def sanitize_labels($nodes):
      [($nodes // [])[] | .name // "" | ascii_downcase | select(length > 0) |
       (if startswith("repo:") then "repo:masked" else . end) | {name: .}];

    (.data.issues.nodes // []) as $nodes
    | {
        ticket: "PARITY-01",
        generated_at: (now | todateiso8601),
        assignee_filter: "symphony",
        scope: {
          team_key: "LET",
          active_states: ["Todo", "Spec Prep", "In Progress", "Merging", "Rework"],
          manual_intervention_state: "Blocked",
          terminal_states: ["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]
        },
        source: {
          team_key: "LET",
          state_names: ["Todo", "Spec Prep", "In Progress", "Merging", "Rework", "Blocked"],
          sampled_issue_count: ($nodes | length)
        },
        cases: (
          $nodes
          | to_entries
          | map(
              .key as $idx
              | .value as $n
              | ($n.state.name // "Unknown") as $state_name
              | (assigned_to_symphony($n.assignee)) as $assigned
              | (blocker_states($n.inverseRelations.nodes)) as $blockers
              | (is_active($state_name)) as $active
              | (todo_blocked_non_terminal($state_name; $blockers)) as $todo_blocked
              | {
                  case_id: ("LIVE-" + (($idx + 1) | tostring)),
                  issue: {
                    id: ("live-issue-" + (($idx + 1) | tostring)),
                    identifier: ("LIVE-" + (($idx + 1) | tostring)),
                    title: "Live sanitized routing sample",
                    description: null,
                    priority: ($n.priority // null),
                    project: {
                      slugId: ($n.project.slugId // null),
                      name: ($n.project.name // null)
                    },
                    state: { name: $state_name },
                    assignee: (
                      if $assigned then
                        {id: "symphony-id", email: "symphony@example.com", name: "symphony"}
                      elif $n.assignee != null then
                        {id: "other-id", email: "other@example.com", name: "other"}
                      else
                        null
                      end
                    ),
                    labels: { nodes: sanitize_labels($n.labels.nodes) },
                    inverseRelations: {
                      nodes: ($blockers | map({type: "blocks", issue: {id: "blocker", identifier: "BLOCKER", state: {name: .}}}))
                    },
                    createdAt: ($n.createdAt // null),
                    updatedAt: ($n.updatedAt // null)
                  },
                  expected: {
                    assigned_to_worker: $assigned,
                    dispatch_eligible: ($active and $assigned and (($todo_blocked | not)))
                  },
                  source: {
                    original_state: $state_name,
                    blockers_count: ($blockers | length),
                    has_assignee: ($n.assignee != null)
                  }
                }
            )
        )
      }
  ' >"$OUT_FILE"

hash=$(shasum -a 256 "$OUT_FILE" | awk '{print $1}')
echo "Generated $OUT_FILE"
echo "SHA256 $hash"
