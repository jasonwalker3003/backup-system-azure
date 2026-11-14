# Requirements: Automatic Backup System

## 1. Business context

A 10-person accounting firm keeps client files on office PCs. Backups are copied to a USB drive "when someone remembers". A single ransomware infection, failed disk or accidentally deleted folder could lose years of client records, and with them the firm's reputation and regulatory standing.

The firm wants backups that happen automatically, can be restored quickly, survive a ransomware attack and cost very little.

## 2. Stakeholders

| Stakeholder | What they care about |
| --- | --- |
| Partners (business owners) | Client data is never lost; cost stays low; they can prove to regulators that records are protected |
| Office staff | Backups happen without them doing anything; deleted or overwritten files can be got back quickly |
| IT support (operator) | Failures are noticed without checking manually; restores are simple; nothing to babysit |

## 3. Functional requirements

What the system must do.

| ID | Requirement |
| --- | --- |
| FR-1 | Back up the documents, photos and database export folders automatically every night |
| FR-2 | Upload only new or changed files, so nightly runs stay fast |
| FR-3 | Keep files in the backup even if they are deleted from the PC |
| FR-4 | Restore any file as it was on any day in the last 90 days |
| FR-5 | Recover files that were overwritten or deleted, including in the backup itself |
| FR-6 | Notify IT support when a night's backup did not happen or did not complete |
| FR-7 | Record each successful run (time, machine, files uploaded) for audit |

## 4. Non-functional requirements

The constraints the system must work within.

| ID | Requirement | Target | How it is met |
| --- | --- | --- | --- |
| NFR-1 | Recovery point objective (RPO): most data that can be lost | 24 hours | Backup runs nightly at 02:00 |
| NFR-2 | Recovery time objective (RTO): time to restore one folder | Under 1 hour | AzCopy download from Blob Storage |
| NFR-3 | Ransomware resistance | Backups cannot be deleted or overwritten in place, even with stolen credentials | Backup identity has no delete permission; each saved version is immutable for its retention period |
| NFR-4 | Retention | 90 days of versions, current files for 1 year | Versioning plus lifecycle rules |
| NFR-5 | Cost | Under £1 a month for a few GB | Lifecycle tiering: Hot → Cool after 30 days → Archive after 90 days |
| NFR-6 | Detection | A missed backup is reported within 24 hours | Heartbeat report after each successful run; alert when none arrives |
| NFR-7 | Security | No secrets in code; least privilege everywhere | Secret held only on the PC (`chmod 600`); custom no-delete role; pipeline uses OIDC with Contributor only |
| NFR-8 | Operability | No manual steps in normal running | Windows Task Scheduler runs the backup; alerting is automatic |
| NFR-9 | Repeatability | All cloud infrastructure can be rebuilt from the repository | Terraform, deployed through GitHub Actions |
| NFR-10 | Data location | Data stays in the UK | Storage account in UK South |

## 5. Constraints and assumptions

- The office has one PC that holds the files and is normally on overnight.
- Internet upload speed is sufficient for nightly changes (a few hundred MB at most).
- The firm uses Microsoft 365, so Azure fits its existing identity and billing.
- Budget is minimal: no backup appliance or third-party backup licence.
- In this lab, immutability retention is 1 day so the environment can be torn down. Production would use 30 days or more, with the policy locked.

## 6. Out of scope

- Backing up Microsoft 365 data (mailboxes, OneDrive, SharePoint)
- Full disk or system image backups of the PC
- Disaster recovery of the PC itself (rebuilding the operating system and applications)
- Backups to a second Azure region (noted as a production improvement)

## 7. Design summary

Using receive → process → store:

- **Receive:** the office PC pushes files to Azure at 02:00. Nothing in Azure connects into the office network.
- **Process:** `azcopy sync` compares each local folder with its container and uploads only new or changed files. Deleted local files are kept in the backup.
- **Store:** Azure Blob Storage with versioning, 14-day soft delete, version-level immutability and lifecycle tiering. A heartbeat report is written to the `reports` container after each successful run.

Monitoring: blob write logs go to Log Analytics. An alert emails IT support when no heartbeat has arrived within 24 hours.

## 8. Key decisions

Each decision has its own record in [`docs/decisions/`](decisions/).

1. **Version-level immutability, not container-level.** Container-level retention would block overwrites, so changed files could not be backed up again. Version-level protects each saved version while still accepting new ones.
2. **The backup identity cannot delete.** A custom role allows read, write and add only. Stolen credentials cannot destroy the backups.
3. **Alert on a missing heartbeat, not a daily success email.** Daily success emails get ignored. One alert on absence covers "PC was off", "script failed" and "credentials expired".
4. **People grant permissions; the pipeline does not.** The pipeline identity has Contributor, which cannot assign roles. Role assignments are made by an administrator.

## 9. Acceptance criteria

The system is accepted when each of these has been demonstrated and recorded.

| Test | Requirement | Pass condition | Result |
| --- | --- | --- | --- |
| First backup uploads all files | FR-1 | 26 test files appear in the correct containers | |
| Unchanged files are skipped | FR-2 | Second run uploads only the changed database export | |
| Overwritten file restored | FR-4, FR-5 | Previous version downloaded and matches the original | |
| Delete with backup credentials refused | NFR-3 | AzCopy delete returns 403 `AuthorizationPermissionMismatch` | |
| Delete of a locked version refused | NFR-3 | Admin delete refused: blob is immutable due to policy | |
| Full folder restore time | NFR-2 | Documents folder restored in under 1 hour | ___ seconds |
| Missed backup detected | FR-6, NFR-6 | Alert email received when no heartbeat arrives within the window | Detected in ___ |
| Lifecycle rules in place | NFR-4, NFR-5 | Cool at 30 days, Archive at 90, delete at 365 | |
| Infrastructure rebuildable | NFR-9 | `terraform plan` in CI shows no changes | |
