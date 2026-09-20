# CI Supply-Chain Contract

Trusted evidence and content-pack builds are part of the Evidence Plane supply chain. Their executable dependencies must therefore be reproducible and reviewable.

## Immutable remote Actions

Every remote `uses:` reference in `.github/workflows/` must use a full 40-character Git commit SHA.

Current verified pins:

- `actions/checkout` v4 tag resolved from the official `actions/checkout` repository to `11d5960a326750d5838078e36cf38b85af677262`.
- `actions/setup-python` v5 tag resolved from the official `actions/setup-python` repository to `a26af69be951a213d495a4c3e4e4022e16d87065`.

Human-readable version comments may remain beside the SHA, but tags/branches are not executable trust anchors.

`tests/test_ci_workflows.py` rejects future movable remote Action references. Local repository actions may use `./...`. Container actions, if introduced, must use an immutable `sha256` digest.

## Generated-pack commits

GitHub documents that events produced with a repository `GITHUB_TOKEN` normally do not trigger another workflow run. Therefore the Quran pack publisher cannot treat a later `push` workflow as its post-commit verifier.

The publisher must:

1. validate the Source Vault and schemas;
2. run the full unit suite;
3. build and validate the candidate pack;
4. create the generated pack commit;
5. rerun Source Vault, pack, schema and unit validation against that exact committed tree;
6. require a clean working tree after validation;
7. only then push the commit.

This keeps the generated commit inside the same explicit trust boundary without adding a second credential merely to force recursive workflow execution.

## Updating a pin

When an Action version is intentionally updated:

1. resolve the desired tag/release in the Action's official repository;
2. record the exact full commit SHA;
3. review the upstream release/commit and update the SHA plus human-readable version comment;
4. run the foundation suite;
5. record any material trust change in the research/architecture log.

Do not replace a full SHA with a tag for convenience.
