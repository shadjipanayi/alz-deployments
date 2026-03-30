<!--
  Pull request template - Azure Migration Deployment Factory

  Owner:           Governance and Compliance Manager
  Audit relevance: Primary evidence for Control 3.1. Every field below becomes part of the change
                   record for the deployment that this pull request authorises.

  Complete EVERY section. Pull requests with an incomplete template are closed without review.
  Do not delete sections. Mark a section "Not applicable" with a one-line justification instead.
-->

## 1. Linked change request

<!-- A change request issue must exist and be approved before this pull request is opened. -->

Closes CR-

| Field | Value |
|---|---|
| Change request | `CR-` |
| Change class | Standard / Normal / Major / Emergency |
| Customer(s) affected | |
| Environment(s) affected | dev / tst / uat / prd |
| Customer change board reference | <!-- Production only. State "Not applicable" for non-production. --> |
| Requested deployment window | |

## 2. Summary of change

<!-- What changes and, more importantly, WHY. Two to five sentences. -->

## 3. Scope and blast radius

- [ ] Template change (`bicep/`) — affects every customer on the next release
- [ ] Customer configuration change (`parameters/`) — affects only the named customer
- [ ] Pipeline change (`.github/workflows/`) — affects how all deployments are executed
- [ ] Script change (`scripts/`)
- [ ] Documentation change (`docs/`, `examples/`, `README.md`)

**Risk rating:** Low / Medium / High

**Justification for the risk rating:**

**Semantic version impact:** Major / Minor / Patch — and why:

## 4. What-if review

<!--
  `validate.yml` posts the what-if preview as a comment on this pull request.
  Confirm you have read it and summarise the material changes below.
-->

- [ ] I have reviewed the what-if output posted by the validation workflow
- [ ] The what-if output matches my expectation
- [ ] There are **no** `Delete` operations, **or** every `Delete` is justified below

**Summary of resources created / modified / deleted:**

| Operation | Resource type | Count | Justification (deletes and replacements only) |
|---|---|---|---|
| Create | | | |
| Modify | | | |
| Delete | | | |

> Tag-only differences on `SourceCommit`, `DeploymentId` and `DeployedUtc` are expected on every
> deployment and do not require justification. All other differences do.

## 5. Testing evidence

- [ ] `./scripts/validate.ps1` run locally and clean
- [ ] Bicep templates compile with zero lint errors
- [ ] PSRule for Azure reports no failures at the configured baseline
- [ ] Secret scan clean — no credential, subscription ID, tenant ID or object ID added to `bicep/`
- [ ] Every affected parameter file validates against the template
- [ ] Deployed to a development subscription and verified
- [ ] `./scripts/post-deployment-checks.ps1` passed

**Development deployment run URL:**

**Post-deployment check result:** Pass / Pass with warnings / Not yet run

## 6. Security review

- [ ] No new publicly reachable endpoint is introduced
- [ ] No new role assignment is introduced, **or** the new assignment is least-privilege and listed below
- [ ] No secret is introduced into source control in any form
- [ ] Network isolation, TLS and encryption settings are unchanged or strengthened
- [ ] Diagnostic logging is unchanged or extended

**New or changed permissions:**

## 7. Rollback plan

<!--
  "Redeploy the previous release tag" is only acceptable if you have confirmed the previous tag
  deploys cleanly against the current estate. State explicitly how the change is reversed and how
  long reversal takes.
-->

| Field | Value |
|---|---|
| Rollback method | |
| Estimated rollback duration | |
| Data loss risk on rollback | None / Describe |
| Rollback tested | Yes — where / No — why not |
| Rollback decision authority | |

## 8. Documentation

- [ ] `CHANGELOG.md` updated under `Unreleased`
- [ ] `docs/` updated where behaviour, architecture or process changed
- [ ] Template `metadata description` and parameter `@description` values are accurate
- [ ] Architecture diagram regenerated if the topology changed
- [ ] `examples/` updated if the change alters the documented customer outcome

## 9. Customer impact and communication

| Field | Value |
|---|---|
| Customer-visible downtime | None / Duration and window |
| Customer notification sent | Yes — date / Not required — why |
| Customer sign-off required | Yes / No |
| Application or database cutover involved | Yes — link the wave record / No |

---

## Reviewer checklist

<!-- Completed by the reviewers, not the author. -->

- [ ] The linked change request exists, is approved, and matches the scope of this pull request
- [ ] The change is the minimum necessary to achieve the stated outcome
- [ ] No customer-specific value has leaked into a `bicep/` template
- [ ] No hard-coded subscription ID, tenant ID, object ID or secret is present
- [ ] The what-if output has been independently reviewed
- [ ] Naming and tagging conform to `docs/Naming_Standards.md`
- [ ] The rollback plan is credible and proportionate to the risk
- [ ] Documentation and `CHANGELOG.md` are accurate and complete
- [ ] Required approvals for the stated risk rating have been obtained
  (see `CONTRIBUTING.md` section 5.1)
