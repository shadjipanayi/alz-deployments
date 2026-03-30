# Changelog

All notable changes to this repository are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this repository
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Every entry traces to a change request (`CR-####`) and a pull request. This file is a controlled
audit artefact — it is updated in the same pull request as the change it describes.

---

## [Unreleased]

Nothing currently unreleased.

---

## [1.3.1] — 2026-08-19

### Added

- Optional parameterised network security group rules permitting ports 11000–11999 from the
  application subnet to the SQL Managed Instance subnet, supporting the `Redirect` connection type
  for workloads whose concurrency exceeds proxy gateway throughput (CR-0189, PR #41)

### Changed

- Migration readiness checks now assert client connectivity at production concurrency before a
  cutover may proceed. The wave Go/No-Go checklist grows from eleven criteria to twelve
  (CR-0188, PR #41)

### Fixed

- Convention scan no longer reports a false positive on Azure built-in role definition identifiers
  in `identity.bicep` (DEF-0039, PR #44)

---

## [1.3.0] — 2026-07-15

### Added

- `scripts/Invoke-Rollback.ps1` — controlled rollback driver with explicit modes for template
  redeployment, parameter revert, virtual machine failback and database re-pointing, each behind a
  confirmation gate (CR-0189, PR #41)
- Concurrent connection profiling added to the Phase 1 assessment activity set in
  `docs/Deployment_Methodology.md` (CR-0190, PR #38)

### Changed

- `deploy-prod.yml` restructured into two stages. An unattended preview stage publishes the what-if
  output to the run summary; the deployment stage is then held until two named reviewers approve.
  Approvers now read the change impact before approving rather than after (CR-0051, PR #34)
- Authorisation preflight added: change request format, release tag format, tag-not-branch
  enforcement, and an explicit `DEPLOY` confirmation string (CR-0051, PR #34)
- Deployment evidence bundles now include a SHA-256 manifest covering every file, so a bundle
  presented at audit can be proven identical to the one produced on the day (CR-0051, PR #34)

---

## [1.2.0] — 2026-06-10

### Added

- `bicep/sql-managed-instance.bicep` — Azure SQL Managed Instance with private-only networking,
  Microsoft Entra group administrator, auditing streamed to Log Analytics, Microsoft Defender for
  SQL, and per-database short-term and long-term retention (CR-0038, PR #28)
- Managed database collection driven by the `sqlDatabases` parameter, with retention values set from
  the customer records retention obligation rather than a template default (CR-0038, PR #28)
- Post-deployment verification group H — instance state, public data endpoint, minimum TLS version,
  managed database presence and diagnostic settings (CR-0038, PR #28)

### Security

- Public data endpoint hard-coded to `false` rather than parameterised, so that a customer parameter
  file cannot expose a database to the internet without architecture review. The same control is
  enforced independently at runtime by `deny-sqlmi-public-endpoint` (CR-0038, PR #28)
- Minimum TLS version pinned to 1.2 (CR-0038, PR #28)

---

## [1.1.1] — 2026-05-06

Emergency release. See CR-0044 and the post-implementation review dated 2026-05-11.

### Fixed

- Managed instance diagnostic setting restored to `categoryGroup: allLogs`. Release 1.1.0 narrowed it
  to an explicit category list that omitted `SQLSecurityAuditEvents`, leaving auditing enabled on the
  instance but with no destination, so audit records were discarded silently. Detected by
  `post-deployment-checks.ps1` during a development deployment, not by a customer (DEF-0023, PR #23)

### Added

- Verification group H now asserts that at least one diagnostic setting exists on the managed
  instance. The regression was possible because nothing asserted the outcome (CR-0044, PR #23)

---

## [1.1.0] — 2026-04-29

### Added

- `bicep/governance.bicep` — three custom policy definitions, a migration governance initiative and a
  subscription-scope assignment (CR-0027, PR #19)
  - `deny-missing-provenance-tags` (Deny) — blocks resources created outside the pipeline
  - `deny-sqlmi-public-endpoint` (Deny)
  - `audit-vm-without-backup` (AuditIfNotExists)
  - Azure built-in allowed-location policies for resources and resource groups (Deny)
- Non-compliance messages naming the violated control and citing the document that explains it
  (CR-0027, PR #19)
- Post-deployment verification group G — policy assignment presence and enforcement mode
  (CR-0027, PR #19)
- Customer configurations for Contoso Manufacturing and Northwind Financial Services
  (CR-0030, CR-0031, PR #16, PR #17)

### Changed

- Policy effects are declared literally rather than through template parameters. A parameterised
  effect would allow a parameter file change to downgrade an enforced control without architecture
  review, and Bicep's escaping of strings beginning with `[` causes parameterised policy rules to
  compile into expressions that never evaluate (CR-0027, PR #19)

### Notes

The assignment was deployed with `enforcementMode: DoNotEnforce` for 14 days as a condition of CAB
approval, then promoted to `Default` under CR-0033 on 2026-05-08 once the compliance report showed no
unexpected non-compliance.

---

## [1.0.0] — 2026-03-27

Audit baseline for the Microsoft Advanced Specialization *Infrastructure and Database Migration to
Microsoft Azure*, Control 3.1 Repeatable Deployment. Promotes the completed build-out from `develop`
to `main` and retires `develop` in favour of trunk-based development with release tags (CR-0022,
PR #15).

### Added

- `bicep/main.bicep` — subscription-scope orchestrator creating four purpose-scoped resource groups
  and coordinating all modules with provenance tagging (CR-0011, PR #3)
- `bicep/networking.bicep` — virtual network, application, data, SQL Managed Instance,
  private-endpoint and Bastion subnets, network security groups, SQL Managed Instance route table,
  optional hub peering (CR-0014, PR #7)
- `bicep/identity.bicep` — user-assigned managed identity, RBAC-enabled Key Vault with soft delete
  and purge protection, scoped role assignments for platform, database and audit groups
  (CR-0014, PR #7)
- `bicep/monitoring.bicep` — Log Analytics workspace, action group, service-health, resource-health
  and deployment-failure alerts, migration audit saved searches, Recovery Services Vault with virtual
  machine and SQL backup policies (CR-0021, PR #12)
- `.github/workflows/validate.yml` — pull request quality gate covering change request traceability,
  Bicep build and lint, secret and convention scan, PSRule for Azure, Azure Resource Manager
  validation, and what-if preview with automatic pull request commenting (CR-0021, PR #12)
- `.github/workflows/deploy-dev.yml` — gated non-production deployment with post-deployment
  verification and evidence capture (CR-0021, PR #12)
- `.github/pull_request_template.md`, `.github/ISSUE_TEMPLATE/change-request.yml`,
  `.github/ISSUE_TEMPLATE/deployment-request.yml`, `.github/CODEOWNERS` (CR-0002, PR #1)
- `scripts/validate.ps1`, `scripts/deploy.ps1`, `scripts/post-deployment-checks.ps1` — local parity
  of the pipeline gates and objective post-deployment verification (CR-0021, PR #12)
- `docs/Deployment_Methodology.md`, `docs/Architecture.md`, `docs/Naming_Standards.md`,
  `docs/Change_Management.md`, `docs/Audit_Evidence_Guide.md` (CR-0022, PR #15)
- `ps-rule.yaml` — PSRule for Azure baseline with documented, justified rule exclusions
  (CR-0021, PR #12)

### Changed

- Branching model moved from `main` plus `develop` to trunk-based with release tags. `develop` is
  archived read-only rather than deleted, so that the build-out history remains inspectable, and is
  permanently blocked from merging to `main` (CR-0022, PR #15)

### Security

- Secretless deployment established: GitHub OIDC federation to Microsoft Entra workload identity. No
  client secret or certificate is issued to any deployment principal (CR-0018)
- Branch protection on `main`: two required approvals, Code Owner review, signed commits, linear
  history, force-push and deletion blocked, and **administrator bypass disabled** (CR-0022)
- Key Vault soft delete and purge protection enabled and non-parameterised (CR-0014, PR #7)

---

## Release policy

| Version part | Increment when |
|---|---|
| **Major** | A breaking parameter or behaviour change, a resource replacement risk, or a removal |
| **Minor** | A new optional parameter, a new capability, or a new supported resource |
| **Patch** | A defect fix, documentation correction, or non-behavioural refactor |

Releases are cut by tagging `main`. Customers pin a release tag; upgrades are planned changes with
their own change request. See [docs/Change_Management.md](docs/Change_Management.md) §5.

[Unreleased]: https://github.com/example-partner/alz-deployments/compare/v1.3.1...HEAD
[1.3.1]: https://github.com/example-partner/alz-deployments/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/example-partner/alz-deployments/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/example-partner/alz-deployments/compare/v1.1.1...v1.2.0
[1.1.1]: https://github.com/example-partner/alz-deployments/compare/v1.1.0...v1.1.1
[1.1.0]: https://github.com/example-partner/alz-deployments/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/example-partner/alz-deployments/releases/tag/v1.0.0
