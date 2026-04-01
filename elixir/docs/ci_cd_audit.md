# Аудит CI/CD и production-hardening для `maximlafe/symphony`

## Что усилено

- CI bootstrap унифицирован через локальный action `setup-elixir` и reusable workflow
  `_elixir-command`.
- Для workflow-ов добавлены explicit `permissions`, `concurrency`, `timeout-minutes`,
  path-filters и диагностические артефакты.
- Введён отдельный `actionlint` workflow для валидации GitHub Actions.
- Production image теперь собирается с `MIX_ENV=prod`, проходит startup smoke в CI и публикует
  `production-image-contract.json` с `tag` и `digest`.
- Deploy отделён в отдельный workflow `deploy-production` с `production` environment gate и
  digest-pinned rollout через SSH + Docker Compose.
- Production runtime contract вынесен в env-backed Compose/runtime файлы без repo-hardcoded путей,
  имён контейнеров и пользовательских директорий.

## Остаточные риски

- Required reviewers и environment secrets для GitHub Environment `production` остаются внешней
  настройкой GitHub и должны совпадать с репозиторным runbook.
- Runtime smoke в CI проверяет запуск и `/api/v1/state`, но не исполняет реальный Linear/Codex
  end-to-end сценарий.
- Rollback опирается на сохранённые workflow artifacts и digest-pinned contract, а не на внешний
  release registry UI.

## Приоритизированный backlog

1. Добавить отдельный post-deploy synthetic smoke за reverse-proxy URL, если production host
   доступен из GitHub Actions runner.
2. Зафиксировать policy для GHCR retention и очистки устаревших immutable tags.
3. Если в Symphony появятся реальные migrations/stateful stores, заполнить
   `SYMPHONY_DEPLOY_PRE_UP_COMMAND` обязательной схемой upgrade/rollback и отдельным smoke для неё.

