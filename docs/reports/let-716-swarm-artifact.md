# LET-716: поддерживающий swarm-артефакт

plan_revision: `let-716-plan-r1`
artifact_revision: `let-716-plan-r1`

## Спецификация документа

Целевой документ: `docs/reports/let-716-swarm-artifact.md`.

Назначение: поддержать, но не заменить, канонический short-plan LET-716. Этот артефакт описывает расширенное обоснование для E2E-проверки цепочки Symphony skills `research-mode -> plan-mode -> execute-mode` и runtime handoff contract.

Границы:
- в скоупе: маршрут стадий, двухслойный planning contract, минимальный контур реализации, validation plan, fail-closed риски, требования к evidence artifacts;
- вне скоупа этого файла: изменение продуктового кода, изменение workflow semantics, изменение canonical task-spec, изменение Linear state machine. Execution stage может включать scoped code/config/workflow-contract changes только если это требуется short-plan; этот supporting artifact сам такие изменения не выполняет и не расширяет их скоуп.

Критерии готовности документа:
- артефакт явно подчинен short-plan и не переопределяет `docs/policy/project-contract.md`;
- `plan_revision` и `artifact_revision` указаны и совпадают;
- semantic consistency check между short-plan и этим артефактом проверена отдельно от равенства revision-полей;
- перечислены validation commands и handoff negative/positive paths;
- указано, какие артефакты должны быть загружены в Linear attachments перед handoff;
- prerequisite/capability gate сформулирован до execution, а не только как реакция на failure;
- unresolved risks сформулированы как fail-closed условия, а не как скрытые допущения.

## Роль артефакта в двухслойном контракте

Канонический слой для LET-716: short-plan в описании Linear issue. Он остается SSOT для problem statement, scope, Acceptance Matrix, Proof Mapping, routing metadata и handoff criteria.

Поддерживающий слой: этот swarm-артефакт. Он раскрывает reasoning и проверочные контуры, но не может:
- менять state transitions;
- добавлять новые обязательные acceptance items без отражения в short-plan;
- ослаблять fail-closed требования;
- заменять workpad, handoff manifest или Linear attachments.

Если short-plan и этот файл расходятся, short-plan и `docs/policy/project-contract.md` считаются авторитетными. Расхождение классифицируется как `blocking divergence` до исправления.

Перед handoff нужно выполнить semantic consistency check: сверить, что short-plan и этот артефакт совпадают по `plan_revision`, `artifact_revision`, `artifact_path`, Acceptance Matrix IDs AM-1..AM-5, Proof Mapping intent, scope boundaries и handoff semantics. Равенство `plan_revision` и `artifact_revision` является обязательным, но недостаточным доказательством консистентности.

## Термины и уровни статуса

Канонические контрактные термины берутся из `docs/policy/project-contract.md`: `Acceptance Matrix`, `Proof Mapping`, `blocking divergence`, `Checkpoint`, `checkpoint_type`, `risk_level`, `cheap gate`, `final gate`, `In Review`, `Blocked`, `plan_revision`, `artifact_path`, `artifact_revision`, `provisional`, `review-ready`, `invalid`.

Термины в этом supporting artifact:
- `short-plan`: канонический reviewer-facing план в Linear issue; он остается SSOT.
- `linked swarm artifact`: этот файл `docs/reports/let-716-swarm-artifact.md`; он additive/subordinate и не заменяет short-plan.
- `proof artifact`: durable validation/runtime output, например log bundle или JSON manifest.
- `handoff manifest`: machine-readable proof artifact для `symphony_handoff_check`.
- `Linear attachment`: загруженное в Linear durable evidence; raw transient upload URL не считается final evidence.
- `semantic consistency check`: описательная проверка соответствия short-plan и linked swarm artifact; это не новое поле project contract.
- `capability interface`: описательное имя внешней/локальной возможности, нужной для acceptance proof; это не новый tracker state.

Статусы разных уровней нельзя смешивать:
- planning lifecycle: `provisional`, `review-ready`, `invalid`;
- fail-closed reason: `blocking divergence`;
- execution handoff classification: `checkpoint_type` = `human-verify`, `decision`, `human-action`;
- tracker state: `In Review`, `Blocked`;
- evidence lifecycle in workpad: `current`, `superseded`, `invalidated`.

## Swarm-синтез

Moderator framing: LET-716 проверяет не отдельный skill, а сквозной контракт оркестрации: intake routing, Spec Prep research, Spec Prep planning with swarm-assisted artifact, execution readiness, runtime proof, PR/handoff proof и classified checkpoint.

Критик по контрактам: главный риск не в отсутствии отдельной команды, а в том, что evidence может стать непроверяемым: stale token, не загруженный artifact, несовпадающие revision-поля или workpad-only proof без durable attachment.

Критик по runtime: negative path должен быть настоящим fail-closed сигналом. Успешный тест только positive path не подтверждает безопасность handoff contract.

Исполнитель: минимальный scoped-change должен быть локальным для runtime/contract проверки и не должен расширять архитектуру сверх Acceptance Matrix. Если существующие проверки уже покрывают часть поведения, изменение должно добавлять только недостающий proof или guard.

Евангелист по процессу: двухслойный planning path полезен только если artifact помогает reviewer понимать план, но short-plan остается компактным и исполнимым. Поэтому artifact должен быть durable, uploaded и revision-aligned.

Синтез: LET-716 считается успешным только при проверяемой цепочке: research нормализует риск, plan формирует short-plan и linked artifact, execute реализует минимальный guard/proof, handoff negative path блокирует stale/missing evidence, positive path проходит на fresh token, а workpad содержит machine-readable `Execution Evidence`.

## Prerequisite/capability gate

Перед execution stage нужно подтвердить, что доступны обязательные capability interfaces:
- `runtime_smoke`: локальный запуск `make symphony-runtime-smoke SCENARIO=all`;
- `repo_validation`: локальный запуск `make symphony-validate`;
- `handoff_check`: локальный `symphony_handoff_check` или эквивалентный repo-owned wrapper, который пишет machine-readable manifest;
- `artifact_upload`: возможность загрузить durable artifacts в Linear attachments;
- `github_pr_publication`: возможность опубликовать PR, связать его с Linear issue и поставить label `symphony`;
- `github_checks`: возможность получить compact PR snapshot и дождаться CI checks.

Порядок проверки:
1. Выполнить `make symphony-preflight`.
2. Если short-plan объявляет `Required capabilities`, выполнить `make symphony-acceptance-preflight`.
3. До первого review-ready handoff записать в workpad, какие capability interfaces подтверждены, какие недоступны и какой blocker classification применяется.

Недоступность `runtime_smoke`, `artifact_upload`, `handoff_check`, `github_pr_publication` или `github_checks` после preflight является `human-action` blocker, если без нее невозможно закрыть обязательный Acceptance Matrix item. Недоступность не должна превращаться в silent skip или ослабление AM-1..AM-5.

## Канонический порядок gate

Этот порядок является hard gate sequence для execution/review-ready handoff. Шаги нельзя считать взаимозаменяемыми; более поздний green signal не закрывает пропущенный ранний gate.

1. Spec Prep artifact gate:
   - short-plan содержит `plan_revision: let-716-plan-r1`, `artifact_path: docs/reports/let-716-swarm-artifact.md`, `artifact_revision: let-716-plan-r1`;
   - linked swarm artifact file существует;
   - semantic consistency check между short-plan и linked swarm artifact пройден;
   - linked swarm artifact загружен в Linear attachments, а selected attachment title/id/url записаны в workpad artifact manifest.
2. Execution prerequisite gate:
   - `make symphony-preflight` выполнен;
   - capability interfaces из `Prerequisite/capability gate` подтверждены или зафиксирован classified blocker.
3. Implementation gate:
   - минимальный scoped-change выполнен после research evidence по runtime handoff path;
   - временные proof edits удалены;
   - workpad `Execution Evidence` заполнен для текущего proof attempt.
4. `cheap gate`:
   - targeted handoff/runtime tests для измененного поведения выполнены;
   - AM-5 negative assertions проверены или явно mapped к manifest checks.
5. `final gate`:
   - `make symphony-runtime-smoke SCENARIO=all`;
   - `make symphony-validate`;
   - negative handoff-check manifest создан и показывает fail-closed blocking result;
   - positive handoff-check manifest создан и показывает pass на fresh token.
6. Publish/PR gate:
   - branch опубликована;
   - PR связан с Linear и имеет label `symphony`;
   - compact PR snapshot получен.
7. CI/review-signal gate:
   - PR checks green;
   - actionable feedback отсутствует или закрыт;
   - если после feedback/fix изменился shipped tree, вернуться к cheap validation gate и затем повторить final local gate.
8. Handoff freshness gate:
   - final proof, handoff manifests и workpad checkpoint относятся к текущим `HEAD` и `HEAD^{tree}`;
   - stale/superseded evidence помечен как invalidated;
   - workpad синхронизирован один раз перед переводом в `In Review`.

`review-ready` состояние запрещено, если любой gate выше отсутствует, выполнен после устаревшего tree, или не имеет durable evidence.

## Минимальный контур реализации

1. Подтвердить текущий runtime handoff path:
   - найти владельцев `symphony_handoff_check`, handoff manifest и validation gate;
   - зафиксировать, где проверяются `run_token`, revision pair, artifact file и consumed sections;
   - отделить подтвержденные факты от гипотез в workpad.

2. Нормализовать task-spec:
   - сохранить Acceptance Matrix AM-1..AM-5;
   - сохранить `Proof Mapping`;
   - добавить/сохранить machine-readable planning lines:
     - `plan_revision: let-716-plan-r1`;
     - `artifact_path: docs/reports/let-716-swarm-artifact.md`;
     - `artifact_revision: let-716-plan-r1`;
   - сохранить финальный `## Symphony` routing block.
   - выполнить semantic consistency check между short-plan и этим артефактом; зафиксировать результат в workpad как prerequisite для upload/review.

3. Проверить two-layer planning contract:
   - убедиться, что linked swarm artifact file существует;
   - загрузить этот файл в Linear attachments с title, совпадающим с filename или full path;
   - записать фактический attachment title и, если доступен, attachment id/url в workpad artifact manifest;
   - считать любое несовпадение revision/path/upload/recorded attachment identity как `blocking divergence`.

4. Реализовать минимальный scoped-change:
   - менять только код/тесты, необходимые для runtime handoff proof;
   - не переносить routing semantics из workflow в artifact;
   - не добавлять новый framework или широкую абстракцию без необходимости.

5. Заполнить `Execution Evidence` в workpad:
   - `status`;
   - `run_token`;
   - `artifact_file`;
   - `revision_pair.plan_revision`;
   - `revision_pair.artifact_revision`;
   - `consumed_sections`;
   - `note`.

## План валидации

Обязательные команды:
- `make symphony-preflight`;
- `make symphony-runtime-smoke SCENARIO=all`;
- `make symphony-validate`;
- локальный `symphony_handoff_check` в negative режиме;
- локальный `symphony_handoff_check` в positive режиме.

Интерфейс локального handoff-check:
- negative input: workpad/manifest state с missing или stale `run_token`, тем же `artifact_file`, тем же `revision_pair`, и явно ожидаемым blocking result;
- negative output: durable machine-readable manifest, например `.symphony/verification/let-716-handoff-negative.json`, где зафиксированы failure status, reason `blocking divergence` или эквивалентный fail-closed code, `git.head_sha`, `git.tree_sha`, `git.worktree_clean`;
- positive input: workpad/manifest state с fresh `run_token`, существующим `artifact_file`, совпадающим `revision_pair.plan_revision == revision_pair.artifact_revision == let-716-plan-r1`, заполненными `consumed_sections` и актуальным artifact manifest;
- positive output: durable machine-readable manifest, например `.symphony/verification/let-716-handoff-positive.json`, где зафиксированы pass status, validation gate fields, git identity и evidence digest;
- оба output-файла должны быть перечислены в workpad artifact manifest и загружены в Linear attachments до handoff.

Targeted checks для AM-5 должны покрыть contract consistency между workflow, skills и `docs/policy/project-contract.md`. Минимально достаточный набор должен проверять:
- stage-routing для `mode:research`, `mode:plan`, execute-ready path;
- two-layer planning metadata;
- linked swarm artifact existence/revision/upload expectations;
- handoff manifest freshness;
- validation gate fields: `gate`, `change_classes`, `required_checks`, `passed_checks`, `git.head_sha`, `git.tree_sha`, `git.worktree_clean`;
- negative assertions: stale/missing `run_token` блокирует handoff;
- negative assertions: missing linked swarm artifact file или missing Linear attachment identity блокирует handoff;
- negative assertions: `artifact_revision != plan_revision` блокирует handoff;
- negative assertions: manifest с устаревшим `git.head_sha` или `git.tree_sha` не считается final proof.

Final gate перед handoff:
- validation proof должен соответствовать текущему `HEAD` и `HEAD^{tree}`;
- workspace должен быть clean для shipped paths;
- PR должен быть опубликован, связан с Linear и иметь label `symphony`;
- PR checks должны быть green;
- actionable PR feedback должен быть закрыт или обоснованно отклонен.

Invalidation/rerun rules:
- любое изменение shipped code/config/workflow-contract после `make symphony-runtime-smoke`, `make symphony-validate`, targeted tests или handoff-check manifests инвалидирует соответствующий proof;
- если `git rev-parse HEAD` или `git rev-parse HEAD^{tree}` отличается от записанного в proof manifest, final gate нужно повторить;
- workpad-only или attachment-only updates не требуют rerun runtime/tests, но требуют свежего handoff-check digest, если workpad content входит в consumed evidence;
- после PR feedback fix или auto-fix, который меняет shipped tree, нужно вернуться к cheap validation gate, затем повторить final local gate и publish/PR gate.

GitHub/PR interface failure behavior:
- если PR publication, label `symphony`, PR snapshot или CI wait недоступны из-за missing auth/tooling после `make symphony-preflight`, execution handoff должен идти в `Blocked` с `checkpoint_type: human-action`;
- если PR checks красные или actionable feedback остается unresolved, issue не готов к `In Review`; требуется fix/validate loop в пределах auto-fix discipline;
- если GitHub interface доступен, но transient command failed, это не blocker до повторной bounded проверки и фиксации конкретного failing signal.

Retry discipline:
- один failing signal допускает максимум две auto-fix попытки с кодовой или конфигурационной правкой;
- blind rerun без новой гипотезы или внешнего unblock signal не считается proof и не сбрасывает attempt counter;
- каждая попытка должна быть записана в workpad с failing signal, измененным scope и rerun command;
- после второй неуспешной попытки нужно остановить speculative fixes и перейти к classified `decision` или `human-action` blocker, в зависимости от причины.

## Fail-closed риски

- Missing `artifact_path`: `blocking divergence`; Spec Prep не `review-ready`.
- Missing linked swarm artifact file: `blocking divergence`; linked swarm artifact надо создать или исправить path.
- Missing Linear attachment: `blocking divergence`; локального файла недостаточно для acceptance proof.
- Missing recorded attachment identity in workpad artifact manifest: `blocking divergence`; upload без audit trail недостаточен для Proof Mapping.
- `artifact_revision != plan_revision`: `blocking divergence`; нужен regeneration или explicit repair.
- Semantic mismatch между short-plan и linked swarm artifact при равных revision-полях: `blocking divergence`; short-plan остается authoritative, linked swarm artifact нужно исправить.
- Stale/missing `run_token`: handoff должен блокироваться.
- Missing handoff-check input/output manifest for either negative or positive path: handoff должен блокироваться.
- Workpad `Execution Evidence` отсутствует или неполный: handoff должен блокироваться.
- Handoff manifest не совпадает с текущим `HEAD`/tree: final proof invalid, required rerun.
- Runtime smoke не запускался, но отмечен как passed: evidence invalid.
- Short-plan/linked swarm artifact divergence по acceptance или routing semantics: short-plan authoritative, linked swarm artifact надо исправить.
- Shipped tree изменился после validation или handoff manifest generation: affected proof считается stale и должен быть rerun.
- Partial Linear attachment upload или failed handoff manifest generation: workpad должен пометить evidence entry как `invalidated`/`superseded`; такой proof artifact нельзя использовать в Proof Mapping.
- Re-upload/regeneration evidence: новый proof artifact или handoff manifest должен получить новую workpad запись со статусом `current`, текущими `HEAD`/tree и ссылкой на superseded prior evidence.

## Требования к evidence artifacts

Linear attachments перед review-ready handoff:
- `let-716-swarm-artifact.md` или `docs/reports/let-716-swarm-artifact.md` -> подтверждает linked swarm artifact для two-layer planning contract; фактический selected title и attachment id/url фиксируются в workpad artifact manifest;
- negative handoff manifest, например `.symphony/verification/let-716-handoff-negative.json` -> подтверждает AM-3, stale/missing token блокирует handoff;
- positive handoff manifest, например `.symphony/verification/let-716-handoff-positive.json` -> подтверждает AM-4, fresh token пропускает handoff;
- validation/runtime log bundle или отдельные durable artifacts -> подтверждают AM-1, AM-2, AM-5.

Workpad evidence:
- checklist Acceptance Matrix AM-1..AM-5;
- `Execution Evidence` с revision pair `let-716-plan-r1` / `let-716-plan-r1`;
- artifact manifest с claim для каждого загруженного вложения;
- artifact manifest с явным статусом `current`, `superseded` или `invalidated` для каждой evidence entry, если были rerun/failure attempts;
- classified `Checkpoint` только на execution handoff, с `checkpoint_type: human-verify` для In Review или `human-action`/`decision` для Blocked.

PR evidence:
- PR URL linked to Linear;
- label `symphony`;
- compact PR snapshot до handoff;
- green checks после ожидания CI;
- отсутствие unresolved actionable feedback.

## Dependency map

| Acceptance | Command or interface | Durable evidence | External/interface dependency |
| -- | -- | -- | -- |
| AM-1 Stage routing | `make symphony-runtime-smoke SCENARIO=all` | runtime smoke log or manifest | local runtime smoke capability |
| AM-2 Repo gate | `make symphony-validate` | validation log or manifest | repo validation tooling |
| AM-3 Fail-closed negative path | local `symphony_handoff_check` negative run | `.symphony/verification/let-716-handoff-negative.json` attachment | handoff-check tooling + Linear upload |
| AM-4 Positive path | local `symphony_handoff_check` positive run | `.symphony/verification/let-716-handoff-positive.json` attachment | handoff-check tooling + Linear upload |
| AM-5 Contract consistency | targeted handoff/runtime tests with negative assertions for stale token, missing artifact, revision mismatch, missing attachment identity, and stale git manifest | targeted test log or manifest | repo test tooling |
| Linked swarm artifact | semantic consistency check + Linear upload | selected attachment title/id recorded in workpad | Linear upload + short-plan availability |
| PR handoff | PR snapshot + CI wait | linked PR with `symphony` label and green checks | GitHub PR/check interfaces |

## Остаточные вопросы

- Конкретный минимальный кодовый diff должен определяться только после research evidence по текущему runtime handoff path.
- Если существующие tests уже покрывают часть AM-5, execution должен переиспользовать их и добавлять только недостающий proof.
- Если mandatory runtime smoke, handoff-check, GitHub PR/check interface или attachment upload недоступны после `make symphony-preflight`, это внешний `human-action` blocker, а не основание ослаблять Acceptance Matrix.

## Итоговая позиция

Рекомендованный путь LET-716: сохранить short-plan как единственный канонический план, использовать этот файл как linked supporting artifact, затем в execute stage доказать оба handoff пути: negative fail-closed и positive fresh-token pass. Review-ready состояние допустимо только при совпадающих revision-полях, пройденной semantic consistency check, записанной attachment identity, загруженных durable artifacts, зеленой validation matrix, зеленых PR checks и заполненном classified checkpoint.
