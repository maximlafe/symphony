---
name: linear
description: |
  Linear GraphQL patterns for Symphony agents. Use `linear_graphql` for all
  operations — comments, state transitions, PR attachments, file uploads, and
  issue creation. Never use schema introspection.
---

# Linear GraphQL

All Linear operations go through the `linear_graphql` client tool exposed by
Symphony's app server. It handles auth automatically.

```json
{
  "query": "query or mutation document",
  "variables": { "optional": "graphql variables" }
}
```

One operation per tool call. A top-level `errors` array means the operation
failed even if the tool call completed.

## Workpad

Maintain a local `workpad.md` in your workspace. Edit freely (zero API cost),
then sync to Linear at milestones — bootstrap create, plan finalized,
implementation done, validation complete. Do not sync after every small change.

Treat `.workpad-id` as the single source of truth for the live workpad comment
ID.

**Live workpad sync** — when `sync_workpad` is available, always use it for the
live workpad. Pass an absolute `file_path` to the local `workpad.md`; relative
paths may fail depending on the tool runner's cwd. Do not send live workpad
bodies through inline `commentCreate`/`commentUpdate`; reserve raw comment
mutations for stage-start comments and other non-workpad comments.

**First sync** — create the live workpad from the local file:

```json
{
  "issue_id": "LET-123",
  "file_path": "/abs/path/to/workpad.md"
}
```

Write the returned `comment.id` to `.workpad-id` so subsequent syncs can update
the same live workpad comment.

**Subsequent syncs** — read `.workpad-id`, update the same live workpad in
place:

```json
{
  "issue_id": "LET-123",
  "comment_id": "<comment-id>",
  "file_path": "/abs/path/to/workpad.md"
}
```

Only if `sync_workpad` is unavailable in-session may you fall back to raw
GraphQL `commentCreate`/`commentUpdate` for the live workpad.

## Query an issue

The orchestrator injects issue context (identifier, title, description, state,
labels, URL) into your prompt at startup. You usually do not need to re-read.

When you do, use the narrowest lookup for what you have:

```graphql
# By ticket key (e.g. MT-686)
query($key: String!) {
  issue(id: $key) {
    id identifier title url description
    state { id name type }
    project { id name }
  }
}
```

For comments and attachments:

```graphql
query($id: String!) {
  issue(id: $id) {
    comments(first: 50) { nodes { id body user { name } createdAt } }
    attachments(first: 20) { nodes { url title sourceType } }
  }
}
```

## Editing issue descriptions

Before any `issueUpdate` that changes `description`, fetch the current issue
body plus attachments first.

- Treat user-uploaded files, screenshots, and inline media in the description
  as canonical task input, not formatting noise.
- Never delete, relocate, or rewrite away an existing upload or embed while
  normalizing the issue description.
- If the description contains uploads or embeds that cannot be preserved
  verbatim in the rewritten body, do not mutate `description`; keep the added
  structure in the workpad or a separate comment instead.

## State transitions

Fetch team states first, then move with the exact `stateId`:

```graphql
query($id: String!) {
  issue(id: $id) {
    team { states { nodes { id name } } }
  }
}
```

```graphql
mutation($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue { state { name } }
  }
}
```

## Attach a PR or URL

```graphql
# GitHub PR (preferred for PRs)
mutation($issueId: String!, $url: String!, $title: String) {
  attachmentLinkGitHubPR(issueId: $issueId, url: $url, title: $title, linkKind: links) {
    success
  }
}

# Plain URL
mutation($issueId: String!, $url: String!, $title: String) {
  attachmentLinkURL(issueId: $issueId, url: $url, title: $title) {
    success
  }
}
```

## File upload

When `linear_upload_issue_attachment` is available in-session, prefer it for any
durable review artifact produced in the workspace: screenshots, recordings,
runtime evidence, exports (`csv`, `json`, `jsonl`, `html`, `md`, `txt`,
`xlsx`, `parquet`), and machine-readable validation outputs that support the
handoff.

```json
{
  "issue_id": "LET-123",
  "file_path": "/abs/path/to/runtime-evidence.json",
  "title": "LET-123 runtime evidence",
  "subtitle": "health + dashboard proof",
  "metadata": {
    "artifact_type": "runtime_evidence",
    "claim": "service responds after the change"
  }
}
```

The tool performs the full server-side flow: request `fileUpload`, `PUT` the
local file bytes, and finish with `attachmentCreate` so the artifact appears in
the issue's standard attachments UI.

In the handoff workpad/comment:

- List each uploaded attachment title and what claim it proves.
- Say which expected artifacts were not produced and why.
- Do not leave a raw `uploads.linear.app` or storage URL as the only evidence path.

Only if `linear_upload_issue_attachment` is unavailable, fall back to the
manual GraphQL upload flow below.

Three manual steps:

1. Get upload URL:

```graphql
mutation($filename: String!, $contentType: String!, $size: Int!) {
  fileUpload(filename: $filename, contentType: $contentType, size: $size) {
    success
    uploadFile { uploadUrl assetUrl headers { key value } }
  }
}
```

2. PUT file bytes to `uploadUrl` with the returned headers (use `curl`).
3. Create an issue attachment from the resulting `assetUrl`:

```graphql
mutation($input: AttachmentCreateInput!) {
  attachmentCreate(input: $input) {
    success
    attachment { id title url }
  }
}
```

Use input fields such as `issueId`, `title`, `subtitle`, `url`, and optional
`metadata`. Reference the resulting attachment in comments/workpad; do not rely
on the raw upload URL as the only handoff path.

## Issue creation

Resolve project slug to IDs first:

```graphql
query($slug: String!) {
  projects(filter: { slugId: { eq: $slug } }) {
    nodes { id teams { nodes { id key states { nodes { id name } } } } }
  }
}
```

Then create:

```graphql
mutation($input: IssueCreateInput!) {
  issueCreate(input: $input) {
    success
    issue { identifier url }
  }
}
```

`$input` fields: `title`, `teamId`, `projectId`, and optionally `description`,
`priority` (0–4), `stateId`. For relations, follow up with:

```graphql
mutation($input: IssueRelationCreateInput!) {
  issueRelationCreate(input: $input) { success }
}
```

Input: `issueId`, `relatedIssueId`, `type` (`blocks` or `related`).

## Rules

- **No introspection.** Never use `__type` or `__schema` queries. They return
  the entire Linear schema (~200K chars) and waste the context window. Every
  pattern you need is documented above.
- Keep queries narrowly scoped — ask only for fields you need.
- Sync the workpad at milestones, not after every change.
- Use `sync_workpad` for live workpad create/update whenever the tool is
  available.
- Use `linear_upload_issue_attachment` for durable evidence whenever the task
  produced review-relevant files inside the workspace.
- Never inline the live workpad body into `commentCreate`/`commentUpdate` when
  `sync_workpad` is available.
- For state transitions, always fetch team states first — never hardcode state IDs.
- Prefer `attachmentLinkGitHubPR` over generic URL attachment for GitHub PRs.
