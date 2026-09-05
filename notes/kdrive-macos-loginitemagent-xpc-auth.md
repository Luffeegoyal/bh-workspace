# kDrive macOS — unauthenticated LoginItemAgent XPC exposes authenticated server GUI endpoint

Status: **strong candidate; static exploit chain complete, local runtime confirmation pending**

Affected released version inspected: **3.8.6**

Target: Infomaniak kDrive Desktop Client / YesWeHack

## Summary

The released macOS kDrive client uses a named LoginItemAgent Mach service to broker anonymous `NSXPCListenerEndpoint` objects for the kDrive server's GUI and Finder-extension IPC servers.

Neither the LoginItemAgent listener nor the returned GUI server listener authenticates callers. The LoginItemAgent also trusts a caller-supplied `processType` value instead of deriving identity from the XPC connection's audit token, PID/EUID, code-signing identity, team identifier, or entitlement.

An unsandboxed local process in the same macOS login session can therefore attempt to:

1. Connect to the hard-coded LoginItemAgent Mach service.
2. Call `serverGuiEndpoint` and receive the running victim kDrive server's anonymous GUI listener endpoint.
3. Connect to that endpoint.
4. Call the generic `processQuery` method with arbitrary kDrive `RequestNum` values.
5. Enumerate kDrive internal IDs through read-only jobs.
6. Invoke server jobs that make authenticated kDrive API requests using the victim's credentials stored by the kDrive server.

The strongest statically proven mutation is `NODE_CREATEMISSINGFOLDERS`, which reaches an authenticated `CreateDirJob` and POSTs a remote directory creation request without the IPC caller ever possessing the victim's kDrive token.

## Released 3.8.6 evidence

### 1. Hard-coded named Mach service

The macOS GUI `Info.plist` contains:

`864VDCS2QY.com.infomaniak.drive.desktopclient.LoginItemAgent`

The legitimate GUI connects with:

`NSXPCConnection(machServiceName: machServiceName, options: [])`

There is no application-level secret or caller credential exchanged.

### 2. LoginItemAgent accepts every connection

`extensions/MacOSX/kDriveFinderSync/LoginItemAgent/AppDelegate.m`

`listener:shouldAcceptNewConnection:`:

- sets the exported `XPCLoginItemProtocol`
- resumes the incoming connection
- calls the untrusted peer's `processType` method
- trusts the returned enum and records that connection as a server/client/Finder role
- returns `YES`

There is no audit-token, PID, EUID, code-signature, Team ID, or entitlement validation.

The exported protocol exposes:

- `serverExtEndpoint(callback)`
- `serverGuiEndpoint(callback)`
- the corresponding endpoint setters

### 3. GUI endpoint is returned to the caller

The legitimate macOS UI does exactly this:

`serverGuiEndpoint { endpoint in ... }`

then:

`NSXPCConnection(listenerEndpoint: endpoint)`

No second credential or nonce is required.

### 4. Returned GUI server endpoint also accepts every connection

`src/server/comm/guicommserver_mac.mm`

`GuiServer::listener:shouldAcceptNewConnection:` creates a new communication channel for every incoming connection, installs `XPCGuiProtocol`, resumes the connection, calls `newConnectionCbk`, and returns `YES`.

No peer validation exists.

### 5. Generic query forwarding

The exported GUI protocol contains:

`processQuery(NSData *query, callback)`

`GuiLocalEnd::processQuery` JSON-decodes attacker-provided input, supplies a request ID, puts the JSON into the server communication channel, and calls its ready-read callback.

The wire format used by the real GUI is JSON:

`{"id": <integer>, "num": <RequestNum>, "params": {...}}`

Response format is:

`{"code": ..., "cause": ..., "id": ..., "params": {...}}`

### 6. Read-only enumeration requires no pre-known identifiers

The GUI request surface includes:

- `USER_DBIDLIST`
- `ACCOUNT_INFOLIST`
- `DRIVE_INFOLIST`
- `SYNC_INFOLIST`

`USER_DBIDLIST` takes empty parameters and returns the local user DB IDs.

`DRIVE_INFOLIST` takes empty parameters and returns fields including:

- `DbId`
- `AccountDbId`
- real `DriveId`
- drive name

`SYNC_INFOLIST` takes empty parameters and returns fields including:

- sync `DbId`
- `DriveDbId`
- local path
- target path
- `TargetNodeId`

This is enough to derive the identifiers needed for controlled cloud operations rather than guessing them.

### 7. Authenticated cloud mutation through the unauthenticated IPC channel

`RequestNum::NODE_CREATEMISSINGFOLDERS` maps to `NodeCreateMissingFoldersJob`.

Its input is:

- `userDbId`
- `driveId`
- base64 `parentNodeId`
- base64 `relativePath`

The job calls:

`ServerRequests::createDir(userDbId, driveId, parentNodeId, folderName, ...)`

That constructs `CreateDirJob` with:

`AbstractTokenNetworkJob(ApiType::Drive, userDbId, ..., driveId)`

and POSTs:

`/drive/{driveId}/files/{parentNodeId}/directory`

The authentication token is loaded by the kDrive server; the XPC caller does not need to know or extract it.

## Attacker model

Do **not** overclaim cross-user access at this stage.

The strongest currently supported attacker model is:

- arbitrary **unsandboxed local process** in the same logged-in macOS user session
- kDrive 3.8.6 running and authenticated
- attacker does not possess the kDrive OAuth/access token

The security boundary is meaningful because the IPC converts local code with no kDrive credential into an authenticated kDrive API client capable of cloud-side actions.

Sandboxed apps may face Mach lookup restrictions, so do not claim arbitrary App Store sandboxed applications unless separately demonstrated.

## Current-code / duplicate check

Current `develop` still contains the unauthenticated LoginItemAgent / GUI-endpoint design.

Repository searches found no use of:

- `setConnectionCodeSigningRequirement`
- peer `effectiveUserIdentifier`
- peer `processIdentifier`
- audit-token validation

No matching public issue/PR for LoginItemAgent/XPC authentication was found in the checks performed so far.

Private YesWeHack duplicate status is unknowable.

## Safe runtime confirmation plan

First run **read-only only**:

1. Connect to named LoginItemAgent service.
2. Return an invalid/untracked `processType` value so the probe does not replace a legitimate role mapping.
3. Request `serverGuiEndpoint`.
4. Connect to the returned listener endpoint.
5. Send `USER_DBIDLIST`.
6. Send `DRIVE_INFOLIST`.
7. Send `SYNC_INFOLIST`.
8. Record only controlled/minimal output.

If those work from an independent unsigned/ad-hoc command-line process, the missing caller authentication is runtime-confirmed.

Only after that, if needed for impact, use one controlled canary folder under the researcher's own kDrive account with a distinctive name and immediately delete it through the normal owner interface. Do not mutate other users' data.

## Severity assessment

Static vulnerability confidence: **~90%+**.

Likely severity if runtime read-only endpoint access and one controlled cloud mutation are confirmed: **Medium**, potentially a strong Medium.

Do not call High merely because cloud actions are possible: the current attacker prerequisite is local code execution in the same user session.

The report should emphasize credential-boundary bypass (authenticated cloud actions without possession of the kDrive token), not local privilege escalation.
