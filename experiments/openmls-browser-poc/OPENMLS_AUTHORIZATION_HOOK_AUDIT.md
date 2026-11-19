# OpenMLS 0.9.2 Credential Authorization Hook Audit

**Scope:** Source/API audit for the isolated browser E2EE proof of concept. This is not a production security review.

## Confirmed version and API surface

The prototype resolves OpenMLS 0.9.2. The following API behavior was checked against the OpenMLS 0.9.2 crate source/docs and the current branch's wrapper.

### 1. Adding a device locally: validate before MlsGroup::add_members

Current path:
- KeyPackage::from_bytes deserializes and calls OpenMLS KeyPackage validation.
- Worker addMember calls the Rust Group::propose_and_commit_add wrapper, which invokes MlsGroup::add_members.

Gap:
- OpenMLS validates MLS KeyPackage structure/signature/ciphersuite properties, but it does not authenticate the application account-to-device relationship. The MLS Authentication Service is an application responsibility.
- The current worker has no trusted registration binding to verify before committing the add.

Required flow:
1. Parse and validate the KeyPackage using OpenMLS.
2. Extract its BasicCredential identity and signature public key.
3. Verify a server-signed device registration statement against a pinned/trusted issuer key.
4. Check that the statement binds the exact credential identity, signature public key, account, device registration, status, and expiry.
5. Only then call MlsGroup::add_members.
6. Return Welcome data only after the candidate group state is durably committed.

Do not accept caller-provided account/device labels as the registration proof.

### 2. Joining from Welcome: inspect StagedWelcome before into_group

OpenMLS 0.9.2 exposes a two-phase Welcome flow:
- ProcessedWelcome::new_from_welcome
- ProcessedWelcome::into_staged_welcome
- inspect the resulting StagedWelcome
- StagedWelcome::into_group

The staged form exposes:
- welcome_sender() and welcome_sender_index()
- members(), including each member's leaf index, credential, encryption key, and signature key
- own_leaf_node() and group_context()

Current gap:
- The prototype wrapper calls StagedWelcome::new_from_welcome(...).into_group(...) in one method and returns only a joined group. The worker cannot authorize the sender or inspect the complete roster before the group is created.

Required flow:
1. Process and stage the Welcome.
2. Extract the sender and every member's credential and signature public key.
3. Verify each credential against a trusted registration binding and current revocation/status data.
4. Confirm that the joining device's own leaf matches the expected device registration and signing key.
5. Reject the Welcome if any required identity is unknown, invalid, expired, revoked, or ambiguous.
6. Only after authorization call into_group, then persist the candidate group state.

A Welcome's MLS cryptographic validity is not a substitute for account/device authorization.

### 3. Receiving standalone Add/Update proposals: authorize before storing

Current wrapper behavior in Group::process_message:
- Calls MlsGroup::process_message.
- For ProposalMessage and ExternalJoinProposalMessage, immediately calls store_pending_proposal.

Gap:
- A valid MLS proposal can be cryptographically authenticated and still be unauthorized by BaddieLink's account/device policy.
- The current wrapper stores it before the worker can verify the proposed credential.

Required flow:
1. Process the incoming message to obtain the verified proposal object.
2. If it is an Add proposal, inspect the KeyPackage leaf credential and signature public key.
3. If it is an Update proposal, inspect the replacement LeafNode credential and signature public key.
4. Verify the corresponding registration binding, status, expiry, and revocation state.
5. Store the pending proposal only after authorization succeeds.
6. If authorization fails, discard the proposal and do not let a later Commit reference it.

### 4. Receiving a Commit: inspect StagedCommit before merge

OpenMLS 0.9.2 exposes these StagedCommit accessors:
- add_proposals()
- update_proposals()
- remove_proposals()
- queued_proposals()

The Add and Update proposal accessors expose the validated proposal objects, from which the proposed credential and signing key can be inspected. The staged Commit can be merged only after the application approves its proposals.

Current gap:
- The current Rust Group::process_message immediately calls merge_staged_commit when it receives StagedCommitMessage.
- The worker's receiveMessage then persists the already-merged candidate and returns. There is no account/device authorization gate before the epoch transition.

Required flow:
1. Process the Commit and retain the resulting StagedCommit without merging it.
2. Enumerate all Add and Update proposals covered by the Commit, including referenced proposals already in the proposal store.
3. Verify every new/replacement credential against the trusted registration authority and current device status.
4. Apply BaddieLink policy to removals as well: verify the actor is authorized to remove the targeted device/account, and check that the target maps to the intended device(s).
5. Reject the staged Commit on any failed authorization check.
6. Only after all checks pass, call merge_staged_commit on the candidate group and persist the candidate atomically.
7. Do not publish resulting plaintext, epoch changes, or membership events before durable commit confirmation.

### 5. Local identity creation

Current Identity::new(provider, name) constructs a BasicCredential directly from caller-provided name bytes.

Required change before multi-device work:
- Replace human-readable names with random opaque device credential identifiers.
- Bind that identifier and the signing public key to a server-issued signed registration statement.
- Verify that statement on all admission/update paths above.
- Keep account and device mapping private to the authenticated application/registration service; do not encode account PII in a credential visible to group members.

## Architectural conclusion

There is no single OpenMLS callback that automatically validates BaddieLink account/device registration. The correct integration is an application-controlled gate at each boundary:

| Boundary | OpenMLS object to inspect | Required action before state mutation |
|---|---|---|
| Local Add | Validated KeyPackage | Verify signed device registration |
| Welcome join | StagedWelcome | Verify sender and every member in staged roster |
| Standalone Add/Update | Verified proposal | Verify proposed credential before queue storage |
| Incoming Commit | StagedCommit | Verify every Add/Update and removal policy before merge |

The current wrapper bypasses these gates by joining immediately, storing proposals immediately, and merging Commits immediately. Do not begin the two-device integration test by only changing identity strings; first refactor these wrappers to expose staged objects and enforce fail-closed authorization.

## Implementation sequence

1. Define and test a canonical signed device-registration statement and issuer-key trust configuration. Do not invent an unsigned JSON mapping.
2. Add a worker-side verifier for the statement, with deterministic test issuer keys. Production issuer-key distribution/rotation remains a separate reviewed design.
3. Refactor the Rust/WASM wrapper to expose staged Welcome, verified proposals, and staged Commits without merging or storing them prematurely.
4. Add negative tests for forged, expired, revoked, mismatched-key, mismatched-credential, and unknown-device registrations.
5. Add the two-device lifecycle: add both devices, revoke one device, remove the account, and test new-device no-history behavior.
6. Re-run the full browser/wasm/native CI workflow.

## Explicit limitations

- This audit does not implement an Authentication Service, registration endpoint, signed certificate format, issuer key distribution, or revocation feed.
- A public verification key embedded in client code is a trust anchor only if its private signing key is kept outside the client and key rotation is designed. Same-origin compromise remains in scope for the browser threat model.
- The dedicated worker is not a security boundary against malicious same-origin JavaScript.
- The current snapshot persistence is not a production OpenMLS StorageProvider.
- No Supabase, Render, production branch, or deployment changes are part of this work.
