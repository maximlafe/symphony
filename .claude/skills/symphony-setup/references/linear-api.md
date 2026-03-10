# Linear GraphQL API Reference

Direct API access via `curl` + `LINEAR_API_KEY`. Use during setup when Symphony isn't running yet.

## Base request pattern

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Content-Type: application/json" \
  -H "Authorization: $LINEAR_API_KEY" \
  -d '{"query": "<GRAPHQL_QUERY>", "variables": {}}'
```

Parse responses with `jq`. All responses are `{"data": {...}}` on success, `{"errors": [...]}` on failure.

## Setup operations

### List projects

Find the project slug for WORKFLOW.md configuration.

```graphql
{
  projects(first: 50) {
    nodes {
      name
      slugId
      url
      state
    }
  }
}
```

The `slugId` is what goes in `tracker.project_slug`.

### List teams

```graphql
{
  teams(first: 10) {
    nodes {
      id
      name
      key
    }
  }
}
```

### Check workflow states for a team

Verify custom states (Rework, Human Review, Merging) exist. Use the team `id` from above.

```graphql
query TeamStates($teamId: String!) {
  team(id: $teamId) {
    states {
      nodes {
        id
        name
        type
      }
    }
  }
}
```

Required custom states and their expected types:
- **Rework** — type: `started`
- **Human Review** — type: `started`
- **Merging** — type: `started`

If any are missing, the user needs to add them in Linear: Team Settings → Workflow.

### Create a test issue

Push a simple test ticket to verify the full pipeline.

```graphql
mutation CreateIssue($teamId: String!, $title: String!, $description: String!, $projectId: String!) {
  issueCreate(input: {
    teamId: $teamId
    title: $title
    description: $description
    projectId: $projectId
  }) {
    success
    issue {
      id
      identifier
      url
    }
  }
}
```

### Move issue to a state

```graphql
mutation MoveIssue($issueId: String!, $stateId: String!) {
  issueUpdate(id: $issueId, input: { stateId: $stateId }) {
    success
    issue {
      identifier
      state { name }
    }
  }
}
```

## Tips

- Always request only the fields you need — keeps responses small.
- Use `jq` for parsing: `curl ... | jq '.data.projects.nodes[] | {name, slugId}'`
- The API rate limit is generous (1,500 req/hr for personal keys). Setup queries won't come close.
