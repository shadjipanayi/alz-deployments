# Contributing

All changes to this repository are treated as changes to customer production infrastructure.
This document is a **control**, not a suggestion. Deviating from it is a non-conformance that must
be raised as a defect.

---

## 1. Before you start

1. A **Change Request** issue must exist and be approved. Use the
   [Change Request form](.github/ISSUE_TEMPLATE/change-request.yml). No CR, no branch.
2. Read [docs/Change_Management.md](docs/Change_Management.md) for the approval matrix that applies
   to your change class.
3. Confirm you are not inside a customer freeze window (recorded on the customer's parameter file
   and the engagement change log).

---

## 2. Branch naming

| Change type | Pattern | Example |
|---|---|---|
| New capability | `feature/CR-<id>-<slug>` | `feature/CR-0142-sqlmi-ltr-policy` |
| Defect fix | `fix/CR-<id>-<slug>` | `fix/CR-0150-nsg-priority` |
| Production hotfix | `hotfix/CR-<id>-<slug>` | `hotfix/CR-0151-backup-retention` |
| Customer configuration | `customer/<code>/CR-<id>-<slug>` | `customer/ctso/CR-0161-wave3-params` |
| Documentation only | `docs/CR-<id>-<slug>` | `docs/CR-0155-rollback-runbook` |

The change request ID in the branch name is validated by `validate.yml`. A branch without a valid
CR reference cannot be merged.

Maximum branch lifetime is **five working days** (24 hours for hotfix). Long-lived branches produce
divergent, unreviewable history and are closed by the Platform Engineering Lead.

---

## 3. Commit convention

Conventional Commits with a mandatory change-request trailer:

```text
<type>(<scope>): <subject>

<body explaining why, not what>

CR: CR-0142
Refs: #87
```

| Field | Allowed values |
|---|---|
| `type` | `feat`, `fix`, `docs`, `refactor`, `test`, `chore`, `ci`, `perf`, `revert`, `security` |
| `scope` | `bicep`, `parameters`, `workflows`, `scripts`, `docs`, `examples`, `customer/<code>` |

Breaking changes require `!` after the scope **and** a `BREAKING CHANGE:` footer.

All commits must be **signed**. Unsigned commits are rejected by branch protection.

---

## 4. Required local checks

Run these before opening a pull request. They are the same checks CI runs, so a clean local run
means a clean pipeline.

```powershell
# Compile and lint every template, scan for secrets, validate every parameter file
./scripts/validate.ps1 -All

# Validate and preview a specific customer environment
./scripts/validate.ps1 -ParameterFile ./parameters/customer-a-dev.json -SubscriptionId <guid>
```

---

## 5. Pull request process

1. Open the PR as a **draft** as soon as the branch exists, so reviewers see direction early.
2. Complete **every** field of [the pull request template](.github/pull_request_template.md).
   Incomplete templates are closed without review.
3. Attach the `what-if` output. `validate.yml` posts it automatically as a comment — confirm it
   matches your expectation and explicitly acknowledge any `Delete` operations.
4. Mark ready for review. CODEOWNERS are assigned automatically.
5. Obtain the required approvals (see below).
6. Resolve every conversation. Unresolved conversations block merge.
7. Squash merge with a Conventional Commit title and the `CR:` trailer.

### 5.1 Approvals required

| Risk | Reviewers | Additional gate |
|---|---|---|
| Low — documentation, examples, dev parameters | 1 CODEOWNER | — |
| Medium — template change with no production impact | 2, including a CODEOWNER | Clean `validate.yml` run |
| High — networking, identity, policy, SQL MI, production parameters | 2, including the Principal Azure Architect **and** the Cloud Security Lead | CAB approval recorded on the CR; what-if reviewed in the CAB call |
| Emergency | 1 named emergency approver | Retrospective second approval within 24 hours, CAB within 24 hours, post-implementation review within 5 working days |

### 5.2 Review SLA

| Risk | First response | Decision |
|---|---|---|
| Low | 1 working day | 2 working days |
| Medium | 4 working hours | 1 working day |
| High | 4 working hours | 2 working days (CAB dependent) |
| Emergency | 30 minutes | 1 hour |

---

## 6. Definition of Done

A change is not done until **all** of the following are true:

- [ ] Change Request issue exists, is approved, and is linked from the PR
- [ ] Templates compile with zero Bicep lint errors
- [ ] PSRule for Azure reports no failures at the configured baseline
- [ ] No secret, subscription ID, tenant ID, or customer name appears in a template
- [ ] Every parameter file affected by the change validates successfully
- [ ] `what-if` reviewed and any destructive operation explicitly justified
- [ ] Rollback plan documented in the PR and technically verified
- [ ] Documentation updated (`docs/`, module comments, `CHANGELOG.md`)
- [ ] Two approvals obtained, including the relevant CODEOWNER
- [ ] Deployed and verified in `dev` with `post-deployment-checks.ps1` passing
- [ ] Evidence artefact produced by the workflow run

---

## 7. Prohibited practices

These are auditable non-conformances:

- Committing directly to `main`
- Force-pushing or rewriting history on `main`
- Approving your own change, or merging without a second independent reviewer
- Using administrator privileges to bypass branch protection
- Committing any secret, connection string, certificate, or key — in any form, including in history
- Hard-coding a subscription ID, tenant ID, object ID, or customer name in a `bicep/` template
- Deploying to `test` or `prod` from a workstation instead of the pipeline
- Merging with failing checks or unresolved conversations
- Editing Azure resources in the portal within a managed scope — this creates drift and breaks the
  repeatability claim

---

## 8. Template authoring standards

| Standard | Requirement |
|---|---|
| Scope declaration | Every template declares `targetScope` explicitly |
| Metadata | Every template opens with `metadata name`, `description`, and `owner` |
| Parameter documentation | Every parameter carries `@description`; constrained values use `@allowed`; strings use `@minLength`/`@maxLength` |
| Secrets | Any credential parameter is decorated `@secure()` and is never output |
| Outputs | Templates output the resource IDs downstream modules need — never a secret |
| Naming | All names are derived from `docs/Naming_Standards.md`, never hard-coded |
| Tagging | Every taggable resource receives the merged tag object passed from `main.bicep` |
| API versions | Pinned explicitly; reviewed quarterly against the current provider versions |
| Idempotency | Re-running a deployment with unchanged parameters must produce a no-op what-if |

---

## 9. Getting help

| Topic | Contact |
|---|---|
| Template or pipeline problem | `platform-engineering@partner.example` |
| SQL Managed Instance or database cutover | `data-migration@partner.example` |
| Policy, identity, or secret question | `cloud-security@partner.example` |
| Change or release scheduling | `delivery@partner.example` |

---

## Change history

| Date | Version | Author | Summary |
|---|---|---|---|
| 2026-09-28 | 1.0.0 | Governance and Compliance Manager | Initial contribution control for the audit baseline |
