---
tracker:
  kind: linear
  team_key: "LET"
  assignee: "4eb8c4a3-8050-4af2-aa2b-da38d903c941"
  active_states:
    - Todo
    - Planning
    - In Progress
    - Merging
    - Rework
  manual_intervention_state: Blocked
  terminal_states:
    - Closed
    - Cancelled
    - Canceled
    - Duplicate
    - Done
polling:
  interval_ms: 5000
workspace:
  root: $SYMPHONY_WORKSPACE_ROOT
hooks:
  timeout_ms: 600000
  after_create: |
    export GIT_TERMINAL_PROMPT=0
    extract_symphony_marker() {
      marker_name=$1
      printf '%s\n' "${SYMPHONY_ISSUE_DESCRIPTION:-}" | awk -v marker="$marker_name" '
        BEGIN { in_section = 0 }
        /^[[:space:]]*##[[:space:]]+Symphony[[:space:]]*$/ {
          in_section = 1
          next
        }
        in_section && /^[[:space:]]*##[[:space:]]+/ { exit }
        in_section {
          prefix = "^[[:space:]]*" marker ":[[:space:]]*"
          if ($0 ~ prefix) {
            line = $0
            sub(prefix, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (length(line) == 0) {
              print "__EMPTY__"
            } else {
              print line
            }
          }
        }
      '
    }
    resolve_repo_url() {
      case "$1" in
        maximlafe/lead_status) printf '%s\n' "https://github.com/maximlafe/lead_status.git" ;;
        maximlafe/symphony) printf '%s\n' "https://github.com/maximlafe/symphony.git" ;;
        maximlafe/tg_live_export) printf '%s\n' "https://github.com/maximlafe/tg_live_export.git" ;;
        *) return 1 ;;
      esac
    }
    resolve_repo_labels() {
      printf '%s\n' "${SYMPHONY_ISSUE_LABELS:-}" | awk '
        {
          label = tolower($0)
          if (label == "repo:lead_status") {
            print "maximlafe/lead_status"
          } else if (label == "repo:symphony") {
            print "maximlafe/symphony"
          } else if (label == "repo:tg_live_export") {
            print "maximlafe/tg_live_export"
          }
        }
      '
    }
    resolve_project_repository() {
      project_slug=$1
      project_name=$2
      case "$project_slug" in
        symphony-bd5bc5b51675) printf '%s\n' "maximlafe/symphony"; return 0 ;;
        a6212aeb565c|telegram-full-export-v2-a6212aeb565c) printf '%s\n' "maximlafe/tg_live_export"; return 0 ;;
        dfbe2b1b972e|master-komand-dfbe2b1b972e|8209c2018e76|izvlechenie-zadach-8209c2018e76) printf '%s\n' "maximlafe/lead_status"; return 0 ;;
        448570ee6438|platforma-i-integraciya-448570ee6438) return 2 ;;
      esac
      case "$project_name" in
        "Symphony") printf '%s\n' "maximlafe/symphony" ;;
        "Telegram Full Export v2") printf '%s\n' "maximlafe/tg_live_export" ;;
        "Мастер команд"|"Извлечение задач") printf '%s\n' "maximlafe/lead_status" ;;
        "Платформа и интеграция") return 2 ;;
        *) return 1 ;;
      esac
    }
    detect_repo_default_branch() {
      branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
      if [ -z "$branch" ]; then
        branch=$(git branch --show-current 2>/dev/null)
      fi
      if [ -z "$branch" ]; then
        branch=main
      fi
      printf '%s\n' "$branch"
    }
    append_note() {
      if [ -z "${setup_note:-}" ]; then
        setup_note=$1
      else
        setup_note=$(printf '%s\n%s' "$setup_note" "$1")
      fi
    }
    summarize_bootstrap_failure() {
      failure_log=$1
      awk '
        NF {
          last=$0
          if ($0 !~ /^make(\[[0-9]+\])?: \*\*\* / && $0 !~ /^make(\[[0-9]+\])?: (Entering|Leaving) directory/ && $0 !~ /^Makefile:[0-9]+: warning:/ && $0 !~ /^Cloning into /) {
            preferred=$0
          }
        }
        END {
          if (preferred != "") {
            print preferred
          } else {
            print last
          }
        }
      ' "$failure_log"
    }
    write_bootstrap_blocker() {
      failure_log=$1
      failure_summary=$(summarize_bootstrap_failure "$failure_log")
      if printf '%s' "$failure_summary" | grep -Fq "No rule to make target" &&
         printf '%s' "$failure_summary" | grep -Fq "symphony-bootstrap"; then
        printf "Base branch '%s' in %s does not define make symphony-bootstrap.\n" "$base_branch" "$source_repository" > .symphony-base-branch-error
      else
        if [ -z "$failure_summary" ]; then
          failure_summary="unknown bootstrap failure"
        fi
        printf "Base branch '%s' in %s failed make symphony-bootstrap: %s\n" "$base_branch" "$source_repository" "$failure_summary" > .symphony-base-branch-error
      fi
    }
    if [ -z "${GH_TOKEN:-}" ]; then
      echo "GH_TOKEN is required for unattended GitHub clone/push access." >&2
      exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
      echo "`gh` is required for unattended GitHub clone/push access." >&2
      exit 1
    fi
    gh auth status >/dev/null 2>&1 || {
      echo "GitHub auth is unavailable. Export GH_TOKEN in /etc/symphony/symphony.env." >&2
      exit 1
    }
    gh auth setup-git >/dev/null 2>&1 || {
      echo "Failed to configure git credentials via gh auth setup-git." >&2
      exit 1
    }
    issue_project_slug=${SYMPHONY_ISSUE_PROJECT_SLUG:-}
    issue_project_name=${SYMPHONY_ISSUE_PROJECT_NAME:-}
    if [ -n "$issue_project_name" ]; then
      project_display=$issue_project_name
    elif [ -n "$issue_project_slug" ]; then
      project_display=$issue_project_slug
    else
      project_display=unknown-project
    fi
    repo_labels=$(resolve_repo_labels)
    repo_label_count=$(printf '%s\n' "$repo_labels" | sed '/^$/d' | wc -l | tr -d ' ')
    requested_base_branches=$(extract_symphony_marker "Base branch")
    base_branch_marker_count=$(printf '%s\n' "$requested_base_branches" | sed '/^$/d' | wc -l | tr -d ' ')
    repo_override=
    resolved_project_repository=
    source_repository=
    source_repo_url=
    requested_base_branch=
    base_branch=
    base_branch_error=
    setup_note=
    rm -f .symphony-base-branch-error .symphony-base-branch-note .symphony-source-repository
    if [ "$repo_label_count" -gt 1 ]; then
      base_branch_error="Multiple repo:* labels found on the Linear issue."
    elif [ "$repo_label_count" -eq 1 ]; then
      repo_override=$repo_labels
    fi
    if [ -z "$base_branch_error" ]; then
      resolved_project_repository=$(resolve_project_repository "$issue_project_slug" "$issue_project_name")
      project_resolution_status=$?

      case "$project_resolution_status" in
        0)
          if [ -n "$repo_override" ] && [ "$repo_override" != "$resolved_project_repository" ]; then
            base_branch_error="Project '$project_display' routes to '$resolved_project_repository'; repo label points to '$repo_override'."
          else
            source_repository=$resolved_project_repository
          fi
          ;;
        2)
          if [ -n "$repo_override" ]; then
            source_repository=$repo_override
          else
            base_branch_error="Project '$project_display' requires one repo label: repo:lead_status, repo:symphony, or repo:tg_live_export."
          fi
          ;;
        *)
          base_branch_error="Project '$project_display' is not mapped to a repository for this workflow."
          ;;
      esac
    fi
    if [ -z "$base_branch_error" ]; then
      source_repo_url=$(resolve_repo_url "$source_repository") || {
        base_branch_error="Repository '$source_repository' is not in the allowlist."
      }
    fi
    if [ -z "$base_branch_error" ] && [ "$base_branch_marker_count" -gt 1 ]; then
      base_branch_error="Multiple Base branch: lines found in ## Symphony."
    elif [ -z "$base_branch_error" ] && [ "$base_branch_marker_count" -eq 1 ]; then
      requested_base_branch=$requested_base_branches
      if [ "$requested_base_branch" = "__EMPTY__" ] || printf '%s' "$requested_base_branch" | grep -Eq '[[:space:]]'; then
        base_branch_error="Base branch: in ## Symphony is empty or contains whitespace."
      fi
    fi
    if [ -n "$base_branch_error" ]; then
      printf '%s\n' "$base_branch_error" > .symphony-base-branch-error
      exit 0
    fi
    if [ -n "$requested_base_branch" ]; then
      if git ls-remote --exit-code --heads "$source_repo_url" "$requested_base_branch" >/dev/null 2>&1; then
        git clone --depth 1 --single-branch --branch "$requested_base_branch" "$source_repo_url" .
        base_branch=$requested_base_branch
      else
        printf "Branch '%s' from Base branch: was not found in origin for %s.\n" "$requested_base_branch" "$source_repository" > .symphony-base-branch-error
        exit 0
      fi
    fi
    if [ -z "$base_branch" ]; then
      git clone --depth 1 "$source_repo_url" .
      base_branch=$(detect_repo_default_branch)
      append_note "Base branch marker is missing; using the repository default branch $base_branch."
    fi
    printf '%s\n' "$source_repository" > .symphony-source-repository
    printf '%s\n' "$base_branch" > .symphony-base-branch
    if [ -n "$setup_note" ]; then
      printf '%s\n' "$setup_note" > .symphony-base-branch-note
    fi
    rm -f .symphony-bootstrap-error.log
    if ! make -n symphony-bootstrap > .symphony-bootstrap-error.log 2>&1; then
      write_bootstrap_blocker .symphony-bootstrap-error.log
      exit 0
    fi
    if ! make symphony-bootstrap > .symphony-bootstrap-error.log 2>&1; then
      write_bootstrap_blocker .symphony-bootstrap-error.log
      exit 0
    fi
    rm -f .symphony-bootstrap-error.log
  before_run: |
    extract_symphony_marker() {
      marker_name=$1
      printf '%s\n' "${SYMPHONY_ISSUE_DESCRIPTION:-}" | awk -v marker="$marker_name" '
        BEGIN { in_section = 0 }
        /^[[:space:]]*##[[:space:]]+Symphony[[:space:]]*$/ {
          in_section = 1
          next
        }
        in_section && /^[[:space:]]*##[[:space:]]+/ { exit }
        in_section {
          prefix = "^[[:space:]]*" marker ":[[:space:]]*"
          if ($0 ~ prefix) {
            line = $0
            sub(prefix, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (length(line) == 0) {
              print "__EMPTY__"
            } else {
              print line
            }
          }
        }
      '
    }
    resolve_repo_url() {
      case "$1" in
        maximlafe/lead_status) printf '%s\n' "https://github.com/maximlafe/lead_status.git" ;;
        maximlafe/symphony) printf '%s\n' "https://github.com/maximlafe/symphony.git" ;;
        maximlafe/tg_live_export) printf '%s\n' "https://github.com/maximlafe/tg_live_export.git" ;;
        *) return 1 ;;
      esac
    }
    resolve_repo_labels() {
      printf '%s\n' "${SYMPHONY_ISSUE_LABELS:-}" | awk '
        {
          label = tolower($0)
          if (label == "repo:lead_status") {
            print "maximlafe/lead_status"
          } else if (label == "repo:symphony") {
            print "maximlafe/symphony"
          } else if (label == "repo:tg_live_export") {
            print "maximlafe/tg_live_export"
          }
        }
      '
    }
    resolve_project_repository() {
      project_slug=$1
      project_name=$2
      case "$project_slug" in
        symphony-bd5bc5b51675) printf '%s\n' "maximlafe/symphony"; return 0 ;;
        a6212aeb565c|telegram-full-export-v2-a6212aeb565c) printf '%s\n' "maximlafe/tg_live_export"; return 0 ;;
        dfbe2b1b972e|master-komand-dfbe2b1b972e|8209c2018e76|izvlechenie-zadach-8209c2018e76) printf '%s\n' "maximlafe/lead_status"; return 0 ;;
        448570ee6438|platforma-i-integraciya-448570ee6438) return 2 ;;
      esac
      case "$project_name" in
        "Symphony") printf '%s\n' "maximlafe/symphony" ;;
        "Telegram Full Export v2") printf '%s\n' "maximlafe/tg_live_export" ;;
        "Мастер команд"|"Извлечение задач") printf '%s\n' "maximlafe/lead_status" ;;
        "Платформа и интеграция") return 2 ;;
        *) return 1 ;;
      esac
    }
    detect_repo_default_branch() {
      previous_base_branch=$(cat .symphony-base-branch 2>/dev/null || true)
      branch=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')
      if [ -z "$branch" ] && [ -n "$previous_base_branch" ]; then
        branch=$previous_base_branch
      fi
      if [ -z "$branch" ]; then
        branch=main
      fi
      printf '%s\n' "$branch"
    }
    resolve_current_repository() {
      previous_repository=$(cat .symphony-source-repository 2>/dev/null || true)
      if [ -n "$previous_repository" ]; then
        printf '%s\n' "$previous_repository"
        return 0
      fi
      git remote get-url origin 2>/dev/null | sed -E \
        -e 's#^git@github.com:##' \
        -e 's#^ssh://git@github.com/##' \
        -e 's#^https?://([^@/]+@)?github.com/##' \
        -e 's#\.git$##'
    }
    append_note() {
      if [ -z "${setup_note:-}" ]; then
        setup_note=$1
      else
        setup_note=$(printf '%s\n%s' "$setup_note" "$1")
      fi
    }
    issue_project_slug=${SYMPHONY_ISSUE_PROJECT_SLUG:-}
    issue_project_name=${SYMPHONY_ISSUE_PROJECT_NAME:-}
    if [ -n "$issue_project_name" ]; then
      project_display=$issue_project_name
    elif [ -n "$issue_project_slug" ]; then
      project_display=$issue_project_slug
    else
      project_display=unknown-project
    fi
    repo_labels=$(resolve_repo_labels)
    repo_label_count=$(printf '%s\n' "$repo_labels" | sed '/^$/d' | wc -l | tr -d ' ')
    requested_base_branches=$(extract_symphony_marker "Base branch")
    base_branch_marker_count=$(printf '%s\n' "$requested_base_branches" | sed '/^$/d' | wc -l | tr -d ' ')
    repo_override=
    resolved_project_repository=
    source_repository=
    source_repo_url=
    requested_base_branch=
    previous_base_branch=
    base_branch=
    base_branch_error=
    current_repository=
    setup_note=
    rm -f .symphony-base-branch-error .symphony-base-branch-note
    current_repository=$(resolve_current_repository)
    previous_base_branch=$(cat .symphony-base-branch 2>/dev/null || true)
    if [ "$repo_label_count" -gt 1 ]; then
      base_branch_error="Multiple repo:* labels found on the Linear issue."
    elif [ "$repo_label_count" -eq 1 ]; then
      repo_override=$repo_labels
    fi
    if [ -z "$base_branch_error" ]; then
      resolved_project_repository=$(resolve_project_repository "$issue_project_slug" "$issue_project_name")
      project_resolution_status=$?

      case "$project_resolution_status" in
        0)
          if [ -n "$repo_override" ] && [ "$repo_override" != "$resolved_project_repository" ]; then
            base_branch_error="Project '$project_display' routes to '$resolved_project_repository'; repo label points to '$repo_override'."
          else
            source_repository=$resolved_project_repository
          fi
          ;;
        2)
          if [ -n "$repo_override" ]; then
            source_repository=$repo_override
          elif [ -n "$current_repository" ]; then
            source_repository=$current_repository
            append_note "Repo label is missing; reusing the bound repository $current_repository."
          else
            base_branch_error="Project '$project_display' requires one repo label: repo:lead_status, repo:symphony, or repo:tg_live_export."
          fi
          ;;
        *)
          base_branch_error="Project '$project_display' is not mapped to a repository for this workflow."
          ;;
      esac
    fi
    if [ -z "$base_branch_error" ] && [ -n "$current_repository" ] && [ "$current_repository" != "$source_repository" ]; then
      base_branch_error="Workspace is already bound to '$current_repository' but the ticket routes to '$source_repository'. A fresh workspace is required."
    fi
    if [ -z "$base_branch_error" ]; then
      source_repo_url=$(resolve_repo_url "$source_repository") || {
        base_branch_error="Repository '$source_repository' is not in the allowlist."
      }
    fi
    if [ -z "$base_branch_error" ] && [ "$base_branch_marker_count" -gt 1 ]; then
      base_branch_error="Multiple Base branch: lines found in ## Symphony."
    elif [ -z "$base_branch_error" ] && [ "$base_branch_marker_count" -eq 1 ]; then
      requested_base_branch=$requested_base_branches
      if [ "$requested_base_branch" = "__EMPTY__" ] || printf '%s' "$requested_base_branch" | grep -Eq '[[:space:]]'; then
        base_branch_error="Base branch: in ## Symphony is empty or contains whitespace."
      elif git ls-remote --exit-code --heads origin "$requested_base_branch" >/dev/null 2>&1; then
        base_branch=$requested_base_branch
      else
        base_branch_error="Branch '$requested_base_branch' from Base branch: was not found in origin for $source_repository."
      fi
    elif [ -n "$previous_base_branch" ]; then
      base_branch=$previous_base_branch
    fi
    if [ -n "$base_branch_error" ]; then
      printf '%s\n' "$base_branch_error" > .symphony-base-branch-error
      exit 0
    fi
    if [ -z "$base_branch" ]; then
      base_branch=$(detect_repo_default_branch)
      append_note "Base branch marker is missing; using the repository default branch $base_branch."
    fi
    printf '%s\n' "$source_repository" > .symphony-source-repository
    printf '%s\n' "$base_branch" > .symphony-base-branch
    if [ -n "$setup_note" ]; then
      printf '%s\n' "$setup_note" > .symphony-base-branch-note
    fi
  before_remove: |
    branch=$(git branch --show-current 2>/dev/null)
    if [ -n "$branch" ] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh pr list --head "$branch" --state open --json number --jq '.[].number' | while read -r pr; do
        [ -n "$pr" ] && gh pr close "$pr" --comment "Closing because the Linear issue for branch $branch entered a terminal state without merge."
      done
    fi
agent:
  max_concurrent_agents: 1
  max_turns: 20
codex:
  command: codex --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh --model gpt-5.3-codex app-server
  approval_policy: never
  thread_sandbox: danger-full-access
  turn_sandbox_policy:
    type: dangerFullAccess
  accounts:
    - id: "furrow.03-offline@icloud.com"
      codex_home: /root/.codex-furrow
    - id: "rebeccakirby3711@outlook.com"
      codex_home: /root/.codex-rebecca
    - id: Deborah
      codex_home: /root/.codex-deborah
    - id: "kjfdn41739@outlook.com"
      codex_home: /root/.codex-kjfdn41739
    - id: "xvnza54743@outlook.com"
      codex_home: /root/.codex-xvnza54743
  minimum_remaining_percent: 5
  monitored_windows_mins: [300, 10080]
server:
  host: "0.0.0.0"
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% if attempt %}
Continuation context:

- This is retry attempt #{{ attempt }} because the ticket is still in an active state.
- Resume from the current workspace state instead of restarting from scratch.
- Do not repeat already-completed investigation or validation unless needed for new code changes.
- Treat every retry as a context-budgeted continuation: prefer the current diff, `workpad.md`, and compact tool summaries over rereading full history.
- If available context is already low (`low-context`), finish at most one atomic action, sync the workpad, and prepare a classified checkpoint instead of starting a broad new investigation.
- Do not spend the remaining context budget restating prior work or retrying the same failing path without a materially new signal.
- Do not end the turn while the issue remains in an active state unless you are blocked by missing required permissions/secrets or are making a classified `decision`/`human-action` handoff because further autonomous progress is no longer justified.
  {% endif %}

Issue context:
Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:
{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

Instructions:

1. This is an unattended orchestration session. Never ask a human to perform follow-up actions.
2. Only stop early for a true blocker or an explicitly classified handoff that the workflow allows (`decision` or `human-action`). If you stop, record it in the workpad and move the issue according to workflow.
3. Final message must report completed actions and blockers only. Do not include "next steps for user".
4. Work only in the provided repository copy. Do not touch any other path.
5. Everything written to Linear must be in Russian.
6. Every timestamp written to Linear must use Moscow time in the format `DD.MM.YYYY HH:MM MSK`.
7. Use the compact runtime tools when available:
   - `linear_graphql` for narrowly scoped Linear reads/writes.
   - `sync_workpad` for the live workpad comment; do not inline the workpad body into raw `commentCreate`/`commentUpdate` when `sync_workpad` is available.
   - `github_pr_snapshot` for compact PR status/feedback summaries.
   - `github_wait_for_checks` for CI waits outside the model loop.
8. For Team Master UI/backend/runtime work, use the repo-local `launch-app` skill for live verification after the validation matrix passes.

## Operating rules

- Start by determining the current state, then follow the matching flow.
- Keep the issue description as the canonical task-spec and exactly one persistent workpad comment as the implementation plan and execution log.
- Use local `workpad.md` as the working copy and sync the live workpad only at bootstrap, meaningful milestones, and final handoff.
- Before each automated stage (`Planning`, `In Progress`, `Rework`, `Merging`), post one separate top-level stage-start comment before the first live workpad sync of that stage.
- Before any Git sync or branch decision, treat `.symphony-source-repository` and `.symphony-base-branch` as the authoritative workspace routing metadata when those files exist.
- If `.symphony-base-branch-note` exists, translate it into Russian in `Заметки` once and continue without asking a human; the note may describe repo-label fallback for an already bound workspace or default base-branch fallback chosen for this ticket.
- If `.symphony-base-branch-error` exists, treat it as a routing/configuration blocker: translate the message into Russian in the workpad, fill `Checkpoint` with `checkpoint_type: human-action`, a justified `risk_level`, and a short `summary`, then move the issue to `Blocked` and stop.
- Treat any ticket-authored `Validation`, `Test Plan`, or `Testing` section as mandatory acceptance input.
- Run `make symphony-preflight` before treating auth/env/tooling gaps as blockers, and use the validation matrix below instead of ad-hoc test selection.
- Do not reread skill bodies in straightforward runs unless the workflow does not cover the needed behavior.
- Move state only when the matching quality bar is satisfied.

## Status map

- `Backlog` -> вне этого workflow; не изменяй.
- `Todo` -> сразу переводи в `Planning`.
- `Planning` -> приведи issue description к русскому task-spec и подготовь детальный русский workpad; продуктовый код не меняй.
- `Plan Review` -> человеческий гейт для плана; не кодируй.
- `In Progress` -> активная реализация.
- `In Review` -> `checkpoint_type: human-verify`; PR приложен и провалидирован, ждём человеческий тест/ревью.
- `Merging` -> одобрено человеком; используй `land` skill и не вызывай `gh pr merge` напрямую.
- `Rework` -> новый заход после review feedback с новой веткой и новым PR.
- `Blocked` -> `checkpoint_type: decision` или `human-action`; автономный прогресс упёрся во внешний выбор или ручное действие.
- `Done` -> терминальное состояние.

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID and read the current state.
2. Inspect only the minimal local repo state needed for routing (`branch`, `HEAD`, `git status` only when needed).
3. Route to the matching flow:
   - `Backlog` -> stop and wait for a human move to `Todo`.
   - `Todo` -> move to `Planning`, post the `Planning` start comment, bootstrap the workpad, then start planning.
   - `Planning` -> continue planning.
   - `Plan Review` -> wait and poll; do not code or change the repo.
   - `In Progress` -> continue execution with minimal recovery when possible.
   - `In Review` -> wait and poll for review decisions.
   - `Merging` -> post the `Merging` start comment, then use the `land` skill.
   - `Rework` -> run the rework flow.
   - `Blocked` -> wait and poll for human unblock action; do not code or change the repo.
   - `Done` -> do nothing and shut down.
4. Query GitHub for an existing PR only when at least one reuse signal exists:
   - current branch is not the configured base branch from `.symphony-base-branch`;
   - the issue already references a PR in links, attachments, or comments;
   - the current state is `In Progress`, `In Review`, `Rework`, or `Merging`.
   - For fresh `Todo` or `Planning` runs on the configured base branch with no PR signal, skip branch PR lookup and do not log placeholder notes.
5. Minimal recovery for straightforward `In Progress` runs:
   - if `.workpad-id` exists and the issue is already in `In Progress`, read only the current state, the issue-description task-spec, the live workpad, the current branch/HEAD, and the PR link or attachment if present;
   - reread full comment/history context only for missing workpad, state/content mismatch, `Rework`, missing PR context, or real ambiguity.
6. If the existing branch PR is already closed or merged, do not reuse that branch. Create a fresh branch from `origin/<configured base branch>` and continue as a new attempt.

## Step 1: Planning phase (Todo or Planning -> Plan Review)

1. If arriving from `Todo`, the issue should already be in `Planning` and the separate planning start comment should already exist before workpad bootstrap begins.
2. Ensure exactly one separate top-level stage-start comment exists for the current automated stage:
   - `Planning` -> `Начал планирование задачи: <DD.MM.YYYY HH:MM MSK>`
   - `In Progress` -> `Начал выполнение задачи: <DD.MM.YYYY HH:MM MSK>`
   - `Rework` -> `Начал доработку задачи: <DD.MM.YYYY HH:MM MSK>`
   - `Merging` -> `Начал слияние задачи: <DD.MM.YYYY HH:MM MSK>`
3. Find or create a single persistent workpad comment:
   - search active comments for `## Рабочий журнал Codex`;
   - reuse legacy `## Codex Workpad` if it already exists and rename it on the next sync;
   - ignore resolved comments;
   - persist the comment ID in `.workpad-id`.
4. `Planning` is analysis-only:
   - if `.symphony-base-branch-error` exists, translate its message into Russian in `Заметки`, fill `Checkpoint` with `checkpoint_type: human-action`, a justified `risk_level`, and a short `summary`, sync the workpad once, move the issue to `Blocked`, and stop;
   - if `.symphony-base-branch-note` exists, translate it into Russian in `Заметки` once before continuing;
   - do not edit product code, commit, or push;
   - read the issue body, only the relevant comments and PR context, and inspect the codebase;
   - capture a reproduction or investigation signal only when it materially sharpens the plan.
5. Keep local `workpad.md` as the planning source of truth:
   - bootstrap the live workpad once if missing;
   - after bootstrap, keep planning edits local until the final plan is ready;
   - sync the live workpad at most one final time before `Plan Review`;
   - always pass the absolute path to local `workpad.md` when calling `sync_workpad`.
6. Update the issue-description task-spec only when required sections are missing or the task contract materially changed:
   - use canonical Russian headings `Проблема`, `Цель`, `Скоуп`, `Критерии приемки`;
   - add `Вне скоупа`, `Зависимости`, `Заметки` only when they materially help the task contract;
   - preserve all material user facts, constraints, and acceptance intent, but allow full reformatting into the canonical sections;
   - preserve user-uploaded files, screenshots, and inline media verbatim; if the current description contains uploads or embeds that would be dropped by normalization, do not rewrite the description and keep the extra structure in the workpad instead;
   - do not write checklists, managed markers, or workpad-style progress notes into the description.
7. Maintain the Russian workpad with a compact environment stamp, hierarchical plan, `Критерии приемки`, `Проверка`, and `Заметки`.
8. Before moving to `Plan Review`, do one final planning handoff:
   - ensure the task-spec issue description is current;
   - ensure the final local `workpad.md` is synced exactly once;
   - do not fill the classified `Checkpoint` section for this planning-only gate; `Plan Review` is an unclassified review of the plan, not an execution handoff;
   - record notes such as `на этапе Planning продуктовые файлы не изменялись` locally before that final sync, not through an extra sync cycle.
9. Move the issue to `Plan Review`.
10. Do not begin implementation until a human moves the issue to `In Progress`.

## Validation preflight

Run `make symphony-preflight` once per run before treating auth/env/tooling gaps as blockers. If it fails, record the exact failing check and whether it blocks the ticket's required validation.

## Validation matrix

- Backend-only changes: run targeted pytest for the touched modules and at least `make test-unit`.
- Stateful, `task_v3`, database, or schema changes: run targeted pytest, `poetry run pytest tests/integration/test_task_v3_stateful_repeatability.py -v -m integration`, and `poetry run alembic upgrade head`.
- Hosted UI or frontend changes: run `make team-master-ui-e2e`; if the change is app-touching, use the `launch-app` skill, verify `/health` and `/api/dashboard`, and capture runtime evidence.
- Repo-wide infra or runtime changes: run `make test` plus the relevant targeted smoke checks.
- Ticket-authored validation or test-plan steps are mandatory on top of this matrix.
- Only move to `Blocked` when the task requires a matrix item that still cannot run after `make symphony-preflight` identifies the missing capability.

## PR feedback and checks protocol (required before In Review)

1. Identify the PR number from issue links or attachments.
2. Run `github_pr_snapshot` once with default summary output.
3. Only if the summary shows reviews, top-level comments, inline comments, or actionable feedback:
   - run `github_pr_snapshot` with `include_feedback_details: true`;
   - treat every actionable item as blocking until code/docs/tests are updated or an explicit justified pushback reply is posted;
   - reflect each feedback item and its resolution status in the workpad;
   - rerun the required validation after feedback-driven changes.
4. Use `github_wait_for_checks` to wait for CI outside the model loop.
5. When checks complete, run `github_pr_snapshot` again.
6. If checks are not green or actionable feedback remains, continue the fix/validate loop.
7. Do not fetch full GitHub feedback payloads when the summary snapshot shows no review activity.

## Blocked-access escape hatch

Use this only when completion is blocked by missing required tools or missing auth/permissions that cannot be resolved in-session.

- GitHub is not a valid blocker by default; try fallback publish/review strategies first.
- Use `Blocked` only when no further autonomous progress is possible because of an external limitation.
- Run `make symphony-preflight` before using this escape hatch.
- Before moving to `Blocked`, record a concise Russian blocker brief in the workpad with what is missing, why it blocks acceptance, and the exact human unblock action.

## Step 2: Execution phase (In Progress -> In Review or Blocked)

1. On entry to `In Progress`, first create the separate top-level comment `Начал выполнение задачи: <DD.MM.YYYY HH:MM MSK>` before any repo-changing command or the first live workpad sync of that stage.
2. Recover from the existing task-spec description and workpad using the minimal-recovery rules unless the issue requires a full reread.
3. Run the `pull` skill against the configured base branch from `.symphony-base-branch` before code edits, then record the result in `Заметки` with merge source, outcome (`clean` or `conflicts resolved`), and resulting short SHA.
4. Use the issue description as the canonical task contract and local `workpad.md` as the implementation plan and detailed execution log.
5. Implement against the checklist, keep completed items checked, and sync the live workpad only after meaningful milestones or before final handoff.
   - фиксируй повторные попытки исправить один и тот же сигнал в workpad и соблюдай лимит auto-fix attempts ниже;
6. Run the required validation for the scope:
   - run `make symphony-preflight` before concluding that auth/env/tooling is missing for the current task;
   - apply the validation matrix above instead of picking tests heuristically;
   - execute every ticket-provided validation/test-plan requirement when present;
   - prefer targeted proof for the changed behavior;
   - revert every temporary proof edit before commit or push;
   - if app-touching, capture runtime evidence and upload it to Linear.
7. Before every `git push`, rerun the required validation and confirm it passes.
8. Attach the PR URL to the issue and ensure the GitHub PR has label `symphony`.
9. Merge latest `origin/<configured base branch>` into the branch before final handoff, resolve conflicts, and rerun required validation.
10. Before moving to `In Review`, use the compact PR/check flow:
   - run the PR feedback and checks protocol above;
   - if checks are green and no actionable feedback remains, first rewrite every final checklist item so it is already true before the state transition (for example, `PR checks зелёные; задача готова к переводу в In Review` instead of `задача переведена в In Review`), затем заполни `Checkpoint` с `checkpoint_type: human-verify`, обоснованным `risk_level` и однострочным `summary`, закрой все выполненные parent/child checkboxes, финализируй local `workpad.md`, один раз синхронизируй live workpad, при необходимости один раз обнови task-spec description и только потом переводи issue в `In Review`;
   - do not repeat label or attachment checks in the same run unless the PR changed.
11. If PR publication or handoff is blocked by missing required non-GitHub tools/auth/permissions after all fallbacks, заполни `Checkpoint` с `checkpoint_type: human-action`, подходящим `risk_level` и blocker summary, затем переводи issue в `Blocked` с blocker brief и явным unblock action.

## Step 3: In Review and merge handling

1. `In Review` используй только для `checkpoint_type: human-verify`; `decision` и `human-action` должны ждать в `Blocked`.
2. В `In Review` не кодируй и не меняй содержимое тикета.
3. Poll for updates as needed.
4. If review feedback requires changes, move the issue to `Rework` and follow the rework flow.
5. If approved, a human moves the issue to `Merging`.
6. In `Merging`, first create the separate top-level comment `Начал слияние задачи: <DD.MM.YYYY HH:MM MSK>`, then use the `land` skill until the PR is merged.
7. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a fresh attempt, not incremental patching on top of stale execution state.
2. First create the separate top-level comment `Начал доработку задачи: <DD.MM.YYYY HH:MM MSK>`.
3. Re-read the issue body task-spec, human comments, and PR feedback; explicitly identify what changes this attempt.
4. Close the existing PR tied to the issue.
5. Remove the existing `## Рабочий журнал Codex` comment.
6. Create a fresh branch from `origin/<configured base branch>`.
7. Create a new bootstrap `## Рабочий журнал Codex` comment.
8. Refresh the task-spec description if the task contract changed for the new attempt, then rewrite the new workpad in Russian.
9. Execute the normal flow again and return the issue to `In Review`.

## Completion bar before Plan Review

- The issue description contains an up-to-date Russian task-spec with `Проблема`, `Цель`, `Скоуп`, and `Критерии приемки`.
- The workpad comment exists and mirrors the detailed plan in Russian.
- Required `Критерии приемки` and `Проверка` checklists are explicit and reviewable.
- Any important reproduction or investigation signal is recorded in the workpad.
- No product code changes, commits, or PR publication happened during `Planning`.
- `Plan Review` does not require a classified `Checkpoint`; classified checkpoints begin with execution handoffs to `In Review` or `Blocked`.

## Completion bar before In Review

- The workpad accurately reflects the completed plan, acceptance criteria, validation, and handoff notes.
- В workpad заполнен классифицированный `Checkpoint` с `checkpoint_type: human-verify` и обоснованным `risk_level`.
- Every final checklist item in the workpad is phrased as a pre-transition fact or readiness statement, so it can be truthfully checked before the move to `In Review`.
- The Russian task-spec description reflects the delivered scope.
- Required validation/tests are green for the latest commit.
- Actionable PR feedback is resolved.
- PR checks are green.
- The PR is pushed, linked on the issue, and labeled `symphony`.
- Runtime evidence is uploaded when the change is app-touching.

## Protocol for classified checkpoints

Используй этот протокол для execution-handoff: когда переводишь задачу в `In Review` или `Blocked`, либо останавливаешь автономный прогресс во время реализации.

- `Plan Review` сюда не относится: это отдельный planning-only human gate без `Checkpoint`.

- Перед финальным `sync_workpad` добавь компактный checkpoint в локальный `workpad.md`.
- В checkpoint обязательно укажи:
  - `checkpoint_type`: ровно один из `human-verify`, `decision`, `human-action`
  - `risk_level`: ровно один из `low`, `medium`, `high`
  - `summary`: краткая, опирающаяся на факты причина текущего handoff
- `human-verify`:
  - используй, когда реализация готова к человеческому тесту/ревью и не требует дополнительного выбора или внешнего действия;
  - это единственный обычный handoff для перевода в `In Review`.
- `decision`:
  - используй, когда дальше нужен продуктовый/технический выбор, конфликтуют требования, или после повторных попыток остаётся несколько правдоподобных направлений;
  - зафиксируй варианты, свою рекомендацию и цену неверного выбора;
  - переводи задачу в `Blocked`, а не в обычный `In Review`.
- `human-action`:
  - используй, когда нужен внешний ручной шаг: доступ, секрет, рестарт сервиса, deploy gate, правка внешнего состояния или недостающий ввод;
  - зафиксируй точное действие и почему агент не может выполнить его сам;
  - переводи задачу в `Blocked`.
- Классифицируй риск консервативно:
  - `low` для локального обратимого изменения с сильным набором доказательств;
  - `medium` для изменений в нескольких местах или неполной верификации;
  - `high` для destructive/data correctness/auth-security риска или заметной неопределённости по пользовательскому эффекту.
- Не вставляй в checkpoint большие сырые логи. Кратко перескажи сигнал и опирайся на compact tools (`github_pr_snapshot`, `sync_workpad`).

## Auto-fix loop discipline

- Считай одну auto-fix attempt каждый раз, когда меняешь код или конфиг, чтобы исправить один и тот же failing signal после уже полученного reproducer, CI failure или review feedback.
- Лимит: максимум 2 auto-fix attempts на один distinct root cause или failing signal.
- Если вторая попытка не дала явного результата, прекращай спекулятивный цикл, один раз синхронизируй workpad и переходи к классифицированному handoff.
- Используй `checkpoint_type: decision`, когда осталось несколько правдоподобных фиксов, `checkpoint_type: human-action`, когда прогресс упёрся во внешнюю зависимость, и `checkpoint_type: human-verify` только когда реализация уже готова и осталось человеческое подтверждение.
- Материально новый failure mode сбрасывает счётчик; blind reruns и косметические переписывания не сбрасывают.

## Guardrails

- If issue state is `Backlog`, do not modify it.
- If state is terminal (`Done`), do nothing and shut down.
- Preserve all material user-authored facts and constraints when normalizing the issue description; full reformatting into canonical sections is allowed.
- Preserve user-uploaded files, screenshots, and inline media in the issue description; never let task-spec normalization remove or relocate them.
- Никогда не делай unclassified execution handoff: для переходов в `In Review` или `Blocked` всегда указывай и `checkpoint_type`, и `risk_level`.
- Use exactly one persistent workpad comment and sync it via `sync_workpad` whenever available.
- Pass the absolute path to local `workpad.md` when calling `sync_workpad`.
- Stage-start announcements must be separate top-level comments and must be posted before the first live workpad sync of that stage.
- Never inline the live workpad body into raw `commentCreate` or `commentUpdate` when `sync_workpad` is available.
- При low-context предпочитай классифицированный checkpoint широкому reread.
- После 2 неуспешных auto-fix attempts по одному сигналу не начинай третью спекулятивную правку.
- Temporary proof edits are allowed only for local verification and must be reverted before commit.
- Out-of-scope improvements go to a separate Backlog issue instead of expanding current scope.
- Treat the completion bars for `Plan Review` and `In Review` as hard gates.
- In `Plan Review`, `In Review`, and `Blocked`, do not change the repo.

## Task-spec issue description

Use this structure when creating a new issue description or normalizing an existing one:

````md
## Проблема

Коротко опиши, что сейчас не так и почему это важно.

## Цель

Коротко опиши желаемый результат.

## Скоуп

- Основная граница 1
- Основная граница 2

## Критерии приемки

- Критерий 1
- Критерий 2

## Вне скоупа

- Добавляй только если есть явные non-goals

## Зависимости

- Добавляй только если есть внешние или межтасковые зависимости

## Заметки

- Добавляй только если нужны rollout/context notes
````

Do not use checkboxes, managed markers, or progress logs in the issue description.

## Workpad template

Use this exact structure for the persistent workpad comment and keep it updated in place throughout execution:

````md
## Рабочий журнал Codex

```text
<hostname>:<abs-path>@<short-sha>
```

### План

- [ ] 1\. Основной шаг
  - [ ] 1.1 Подшаг
  - [ ] 1.2 Подшаг
- [ ] 2\. Основной шаг

### Критерии приемки

- [ ] Критерий 1
- [ ] Критерий 2

### Проверка

- [ ] целевая проверка: `<command>`

### Checkpoint

- `checkpoint_type`: `<human-verify|decision|human-action>` (заполняй только при handoff)
- `risk_level`: `<low|medium|high>` (заполняй только при handoff)
- `summary`: <кратко и по фактам, почему сейчас нужен handoff>

### Заметки

- <короткая заметка с временем по Москве>

### Неясности

- <добавляй только если что-то действительно было неясно>
````

For the final handoff to `In Review`, phrase checklist items so they are true before the state change. Good: `PR checks зелёные; задача готова к переводу в In Review`. Bad: `Задача переведена в In Review`.
