# Symphony

Fork of [openai/symphony](https://github.com/openai/symphony) with better defaults for production use and a complete onboarding flow. Push tickets to a Linear board, agents ship the code.

[![Symphony demo video preview](.github/media/symphony-demo-poster.jpg)](.github/media/symphony-demo.mp4)

## Quick start

If you have an AI coding agent, one command:

```
npx skills add odysseus0/symphony -s symphony-setup -y
```

Then ask your agent to set up Symphony for your repo.

## This Repo As A Target Repo

`maximlafe/symphony` is also configured as a standalone target repo for Symphony itself. The repo-local workflow lives at `elixir/WORKFLOW.md` and now points at the dedicated LetterL Linear project `Symphony` (`symphony-bd5bc5b51675`) instead of the shared platform bucket.

Fresh worker clones use the contract that lives in this repo:

- `.agents/skills/` contains the worker skills that workspace clones rely on.
- `make symphony-preflight` checks `codex`, `mise`, `gh auth status`, `LINEAR_API_KEY`, and non-interactive git access for the repo remote.
- `make symphony-bootstrap` configures GitHub git auth with `gh auth setup-git`, installs the pinned toolchain via `mise`, and runs `mix setup` in `elixir/`.
- `make symphony-dashboard-checks` runs the deterministic dashboard-focused test slice used for UI/runtime proof without invoking the real live e2e smoke.
- `make symphony-handoff-check` runs the repo-owned review-ready contract against the current workpad, issue attachments, and PR state.
- `make symphony-nginx-proxy-contract` validates the committed `stream.cash` nginx include without requiring a local `nginx` binary.
- `make symphony-nginx-proxy-smoke` replays the `/proxy/symphony/` plus websocket upgrade flow through a disposable local nginx runtime when `nginx` is installed or `NGINX_BIN` is set.
- `make symphony-validate` runs the main quality gate for this repo (`make -C elixir all`).
- `make symphony-live-e2e` runs the disposable live smoke test (`make -C elixir e2e`) when you explicitly want a real Linear/Codex end-to-end run.

That means a clean Symphony workspace no longer depends on hidden setup from other repos: the workflow, worker skills, bootstrap, and validation path all live here.

## Production CI/CD contract

The repo now ships a production-oriented CI/CD path:

- `.github/workflows/actionlint.yml` validates workflow syntax and semantics.
- `.github/workflows/release-image.yml` builds the production image, smoke-tests startup, and
  publishes a digest-pinned image contract on `main`.
- `.github/workflows/deploy-production.yml` downloads that contract and performs an environment-gated
  production deploy.
- The deployed runtime echoes `git_sha`, `image_tag`, and `image_digest` from that contract through
  `/api/v1/state`, so post-release proof can be closed on the public observability surface.
- `elixir/deploy/docker/README.md` documents the host env files, rollback flow, and deploy
  prerequisites.

## How it works

Symphony polls a Linear project or team for active tickets. Each ticket gets an isolated workspace clone and a Codex agent. The agent reads the ticket, writes a plan, implements, validates, and opens a PR. You review PRs and move tickets through states — the agents handle the rest.

The state machine lives in `WORKFLOW.md` — a markdown file with YAML frontmatter for config and a prompt body that defines agent behavior. Hot-reloads in under a second, no restart needed.

## What's different from upstream

- **Cheaper Linear calls** — agents no longer burn tokens on schema introspection before every GraphQL call, and workpad sync is a single dynamic tool instead of a hand-rolled mutation
- **Correct sandbox** — the workflow is git + GitHub PR centric. Upstream's default sandbox blocks `.git/` writes, which silently breaks the entire flow. Fixed.
- **Durable Linear attachments for handoff artifacts** — upstream references a GitHub media upload skill that doesn't ship. This repo now exposes a compact `linear_upload_issue_attachment` runtime tool so screenshots, recordings, runtime evidence, exports, and validation artifacts land in Linear issue attachments instead of expiring raw upload URLs
- **Multi-account Codex failover** — Symphony can rotate between multiple pre-authenticated `CODEX_HOME` directories and stop starting new work on an account when its 5-hour or weekly Codex budget is nearly exhausted
- **Classified workflow handoffs** — the default contract requires `checkpoint_type`/`risk_level`, low-context discipline, and a hard cap on speculative auto-fix loops so agents escalate cleanly instead of spinning
- **Setup skill** — auto-detects your repo, installs worker skills, creates Linear workflow states, and verifies everything before launch

## Manual setup

1. Build: `git clone https://github.com/odysseus0/symphony && cd symphony && make symphony-bootstrap && cd elixir && mise exec -- mix build`
2. Install skills: `npx skills add odysseus0/symphony -a codex -s linear land commit push pull debug --copy -y` and copy `elixir/WORKFLOW.md` to your repo
3. In `WORKFLOW.md`, set exactly one Linear polling scope: `tracker.project_slug` or `tracker.team_key`, plus `hooks.after_create` (clone your repo + setup commands). Hooks also receive issue metadata in env vars like `SYMPHONY_ISSUE_IDENTIFIER`, `SYMPHONY_ISSUE_DESCRIPTION`, `SYMPHONY_ISSUE_BRANCH_NAME`, `SYMPHONY_ISSUE_PROJECT_SLUG`, and `SYMPHONY_ISSUE_LABELS` if you need structured per-issue bootstrap behavior.
4. Add **Rework**, **In Review**, **Merging** as custom states in Linear (Team Settings → Workflow)
5. Commit, push, then: `mise exec -- ./bin/symphony /path/to/your-repo/WORKFLOW.md`

For this repository's own self-hosted target flow, use the repo root targets first:

```bash
make symphony-preflight
make symphony-bootstrap
make symphony-validate
cd elixir && mise exec -- ./bin/symphony ./WORKFLOW.md --port 4101
```

`make symphony-bootstrap` is the unattended repo-root bootstrap contract Symphony workers use in a
fresh clone. In this repo it configures git credentials through `gh`, prepares the pinned Elixir
toolchain through `mise`, and keeps the bootstrap path repo-owned instead of buried in shell
history.

For a host-level Docker deployment instead of an interactive local process, use the runbook in
`elixir/deploy/docker/README.md` and the digest-pinned image contract emitted by `release-image`.

**[Getting Started with OpenAI Symphony](https://x.com/odysseus0z/status/2031850264240800131)** — full walkthrough with context on why these defaults matter.

## License

[Apache License 2.0](LICENSE)
