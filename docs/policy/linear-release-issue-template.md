# Linear Release Issue Template

Use one Linear `release issue` per production promotion.

## Required fields

- `approval_state`: `pending`, `approved`, or `rejected`
- `release_contract_artifact`: URL or identifier for `production-image-contract.json`
- `git_sha`: immutable commit SHA from the release contract
- `image_tag`: immutable image tag from the release contract
- `image_digest`: immutable image digest from the release contract
- `rollback_reference`: prior approved release issue + contract used for rollback

## Required links

- `staging_run_url`: workflow run URL for staging deploy
- `production_run_url`: workflow run URL for production deploy (fill after promotion)

## Description template

```markdown
## Release Contract
- approval_state:
- release_contract_artifact:
- git_sha:
- image_tag:
- image_digest:

## Promotion Evidence
- staging_run_url:
- production_run_url:

## Rollback
- rollback_reference:
- rollback_result:
```

## State policy

- Production deploy is allowed only when `approval_state=approved` and the tuple (`git_sha`, `image_tag`, `image_digest`) matches `release_contract_artifact`.
