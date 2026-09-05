# kDrive Desktop — public-link authorization candidate

Status: **client-side flaw confirmed; backend authorization bypass not yet live-confirmed**

Target: Infomaniak kDrive Desktop Client / YesWeHack

## Core hypothesis

A low-permission internal collaborator who can read a controlled shared node but is explicitly forbidden from turning it into a public share link may still be able to trigger the released desktop client's public-link creation request.

The decisive backend test is whether this succeeds when the exact node reports:

- `can_read = true`
- `can_write = false`
- `can_share = false`
- `can_become_sharelink = false`
- no pre-existing `sharelink`

Then issue exactly the request used by the released desktop client:

`POST https://api.kdrive.infomaniak.com/2/drive/{drive_id}/files/{node_id}/link?right=public`

A successful 2xx/result=success under that preflight is the security signal. A 401/403 means backend authorization is enforced and the candidate should be dropped as a bounty finding.

## Released desktop evidence (3.8.6)

### Windows Activities UI

The released Windows activity menu exposes **Copy share link** on synchronized non-deleted items without a permission/capability condition. The activity model does not carry `can_share` or `can_become_sharelink`.

The handler calls the server communication service directly, which reaches `SYNC_GETPUBLICLINKURL`.

### macOS Activities UI

`ActivitiesTableStatusView.swift` in tag 3.8.6 exposes **Copy share link** for every successfully synchronized non-deleted activity.

`copyShareLink()` directly calls:

`nodeURLGenerator.shareURL(for: context.node.remoteID, driveDbId: context.drive.dbId)`

`DriveNodeURLGenerator.shareURL()` directly calls:

`SyncJobs().getPublicLinkUrl(...)`

`SyncJobs.getPublicLinkUrl()` sends `RequestNum.SYNC_GETPUBLICLINKURL`.

No permission/capability check exists in this chain.

### Finder/Explorer extension permission model is ineffective

The extension attempts to consult `SyncPal::checkIfCanShareItem`, but the remote full-listing parser only loads `can_write`; it has no `can_share` column.

`SnapshotItem` defaults:

- `_canWrite = true`
- `_canShare = true`

Thus the share permission state can default to allowed rather than being populated from the backend.

The actual `COPY_PUBLIC_LINK` command handler performs no second permission check before calling `getPublicLinkUrl`.

## Exact released network request

`PostFileLinkJob` uses API v2 and builds:

`POST /drive/{driveId}/files/{nodeId}/link`

with query parameter:

`right=public`

Base URL for the Drive API is `https://api.kdrive.infomaniak.com/{version}`.

## Cross-client authorization evidence

Infomaniak's Android client models a dedicated backend capability:

`can_become_sharelink`

separate from ordinary:

`can_share`

The Android public-link action is enabled when `rights.canBecomeShareLink` is true (or an existing share link already exists), and Android uses the same v2 `.../files/{id}/link` route family for share-link creation.

The desktop repository has no `can_become_sharelink` implementation.

This makes `can_become_sharelink=false` the strongest precondition for the controlled backend verification.

## Safe verifier

Manual-only workflow:

`.github/workflows/kdrive-viewer-public-link-authz-probe.yml`

Current hardened workflow commit:

`5fd187bf194b2f23ce765a41bb9c5000fae3bc64`

Required secret/input:

- `KDRIVE_VIEW_TOKEN` — separate controlled low-permission principal
- controlled `drive_id`
- controlled fresh `node_id`
- confirmation `I_CONTROL_THIS_NODE`

The workflow does not print the returned public URL/token and stops unless all four capability conditions are explicit.

## Decision tree

### If POST returns 2xx + result=success

Candidate becomes a confirmed authorization bypass: a principal explicitly forbidden from creating a public link can expose the controlled node publicly.

Likely severity: genuine Medium unless broader impact is demonstrated. Do not inflate to High.

Immediately revoke the canary link from the owner account after preserving minimal evidence.

### If POST returns 401/403/access denied

Backend authorization is working. Drop the candidate as bounty-worthy; the remaining client UI/capability mismatch is likely UX/N/A.

### If link already exists or capabilities are missing

Inconclusive. Use a fresh controlled canary; do not infer vulnerability.

## Duplicate status

Public desktop-kDrive issue/PR searches for share-link permission/capability problems found no matching report. Private YesWeHack reports cannot be searched.
