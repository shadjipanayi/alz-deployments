# Security Policy

**Owner:** Cloud Security Lead · **Last reviewed:** 2026-03-30 · **Review cadence:** Quarterly

---

## 1. Supported versions

| Version | Supported | Notes |
|---|---|---|
| `1.x` | Yes | Current release line; receives fixes and security updates |
| `0.x` | No | Pre-baseline development releases; must not be used for customer delivery |

---

## 2. Reporting a vulnerability

**Do not open a public GitHub issue for a security finding.**

Email `cloud-security@partner.example` with the subject prefix `[SECURITY]`. Include the affected
file or workflow, the impact, and reproduction steps.

| Severity | Definition | Acknowledgement | Target remediation |
|---|---|---|---|
| Critical | Exposed credential, privilege escalation path, or a template that provisions a publicly reachable data service | 4 hours | 24 hours |
| High | Missing encryption, missing network isolation, over-privileged role assignment | 1 working day | 5 working days |
| Medium | Weak default, missing diagnostic logging, outdated API version with a known issue | 2 working days | 20 working days |
| Low | Documentation or hardening improvement | 5 working days | Next scheduled release |

A confirmed Critical or High finding is handled as an **emergency change** under
[docs/Change_Management.md](docs/Change_Management.md), including a post-implementation review.

---

## 3. Secrets policy

This repository contains **no secrets**, and none may ever be committed.

| Secret type | Where it lives | How it reaches Azure |
|---|---|---|
| SQL Managed Instance administrator password | Customer bootstrap Key Vault | Key Vault reference inside the parameter file; resolved by Azure Resource Manager at deployment time |
| Azure deployment credentials | None — no credentials exist | GitHub OIDC token federated to a Microsoft Entra workload identity |
| Customer tenant and subscription identifiers | GitHub Environment variables | Injected at runtime by the workflow |
| TLS certificates, connection strings | Customer Key Vault | Referenced by the workload at runtime, never by this repository |

### 3.1 Controls

- `validate.ps1` and `validate.yml` run a pattern-based secret scan over every changed file and fail
  the build on a match.
- GitHub secret scanning with push protection is enabled at the organisation level.
- `.gitignore` excludes local parameter overrides, `*.env`, and `*.secret.*` files.
- Any credential believed to have been committed is treated as compromised: it is rotated
  immediately, and the exposure is recorded as a Critical finding regardless of repository
  visibility.

---

## 4. Identity model

| Principal | Federated subject | Azure scope | Roles |
|---|---|---|---|
| `spn-iac-validate` | `repo:<org>/alz-deployments:pull_request` | Target subscription | Reader (what-if and validation only) |
| `spn-iac-dev` | `repo:<org>/alz-deployments:environment:development` | Customer development subscription | Contributor, User Access Administrator |
| `spn-iac-prod` | `repo:<org>/alz-deployments:environment:production` | Customer production subscription | Contributor, User Access Administrator, Resource Policy Contributor |

`User Access Administrator` is required because `identity.bicep` creates role assignments and
`governance.bicep` creates policy assignments. This elevation is deliberate, documented, scoped to a
single subscription, and reviewed at each quarterly access review. No principal holds `Owner`.

No long-lived client secrets or certificates are issued to any of these principals.

---

## 5. Security controls enforced by the templates

| Control | Implementation |
|---|---|
| No public database endpoint | `sql-managed-instance.bicep` sets `publicDataEndpointEnabled: false`; `governance.bicep` denies any attempt to enable it |
| Minimum TLS version | SQL Managed Instance pinned to TLS 1.2 |
| Encryption at rest | Transparent Data Encryption enabled; Key Vault purge protection and soft delete enabled |
| Network isolation | SQL Managed Instance deployed into a delegated, NSG-protected, route-controlled subnet; private endpoint subnet provided for PaaS services |
| Least privilege | Key Vault uses RBAC authorisation; role assignments are scoped to the vault, not the subscription |
| Auditing | SQL Managed Instance auditing streams to Log Analytics; diagnostic settings applied to the virtual network, Key Vault, and Recovery Services Vault |
| Threat protection | Microsoft Defender for SQL enabled on the managed instance |
| Backup immutability | Recovery Services Vault soft delete and enhanced security enabled |
| Provenance | Deployment tags are mandatory and enforced by a deny policy |

---

## 6. Dependency and supply chain

- GitHub Actions are pinned to a major version tag from verified publishers only.
- Dependabot monitors action versions weekly; updates follow the standard pull request process.
- Bicep API versions are reviewed quarterly by Platform Engineering and updated via a normal change.

---

## Change history

| Date | Version | Author | Summary |
|---|---|---|---|
| 2026-03-30 | 1.0.0 | Cloud Security Lead | Initial security policy for the audit baseline |
