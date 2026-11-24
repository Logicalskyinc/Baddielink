# MLS mutation boundary audit

**Scope:** The current experimental WASM wrapper in `src/lib.rs`, pinned to OpenMLS 0.9.2 / `openmls_traits` 0.6.0.
**Status:** Code-path inventory and transaction design input. No transaction wrapper is implemented by this document.

## Why this audit is required

A durable provider cannot be added safely by persisting the storage map after an arbitrary UI action. OpenMLS mutates both provider-backed records and in-memory `MlsGroup` state. Some wrapper methods perform more than one mutation before returning. If persistence fails after the Rust call, the caller must not continue using that mutated group/provider pair.

The current browser harness proves that a serialized MemoryStorage snapshot can survive a page reload. It does not make each MLS operation atomic with its durable checkpoint.

## Current mutating entry points

| Wrapper entry point | Mutations / risk | Transaction requirement |
|---|---|---|
| `Identity::new` | Creates a signature key pair and stores it through `keypair.store(provider.storage())`. | Candidate provider; publish identity and provider only after checkpoint commit. |
| `Identity::key_package` | OpenMLS KeyPackage builder may store a generated KeyPackage in provider storage. | Candidate provider; returned package must not be published if its storage checkpoint fails. |
| `Group::create_new` | Group builder writes initial group state into provider storage. | Candidate provider and newly created group must be published together after commit. |
| `Group::join` | Welcome processing and `into_group` write group state and consume/derive key material. | Candidate provider; do not expose joined group until checkpoint is committed. |
| `Group::propose_and_commit_add` | Calls `propose_add_member`, then `commit_to_pending_proposals`, then serializes proposal/commit/welcome. A later error can occur after earlier state changes. | One high-level transaction across both OpenMLS calls and output serialization. |
| `Group::remove_member` | Calls `remove_members`, which stages a membership Commit and mutates group/provider state; then serializes it. | Candidate group/provider and commit bytes published together. |
| `Group::merge_pending_commit` | Merges pending commit and advances local group state/epoch. | Candidate group/provider; commit checkpoint before exposing new epoch. |
| `Group::create_message` | Creates an MLS message and advances sending ratchet state. | Candidate group/provider; do not return ciphertext as successfully sent until the corresponding state checkpoint is committed. |
| `Group::process_message` | Processes private/public messages; may advance receive ratchets, store proposals, merge staged commits, or merge own pending commits. | Candidate group/provider; ciphertext processing and any resulting state transition are one transaction. |

Read-only methods include `Group::is_active`, `Group::export_ratchet_tree`, and `Group::export_key` as currently implemented. Their behavior should be re-audited if OpenMLS APIs or wrapper semantics change.

## Existing API shape is not transaction-safe

The current methods mutate `&mut Group` and accept a separate `Provider` reference. This makes it possible for the group object and provider storage to become inconsistent after an error or failed durable write. Merely calling `export_snapshot_bytes()` after these methods is insufficient: the in-memory objects have already advanced, and a failed checkpoint cannot roll them back.

A viable candidate-state API must make the old committed pair remain usable until the new pair is durably committed:

1. Read the last authenticated, committed provider snapshot and its monotonic generation.
2. Restore a candidate provider from that snapshot.
3. Load the target group from the candidate provider. Do not mutate the currently published group object.
4. Run exactly one high-level MLS operation against the candidate group/provider pair.
5. Serialize the operation result before attempting durable commit. Any error discards the candidate pair.
6. Encrypt/authenticate the complete candidate provider snapshot with account/device/store-generation metadata.
7. Stage and verify the new OPFS journal generation, then publish its commit marker.
8. Only after durable commit succeeds may the caller replace its live provider/group handles and expose generated ciphertext, Commit, Welcome, or membership changes.
9. On any persistence failure, discard candidate objects and continue only from the previous committed generation.

## Additional design constraints

- Group identity must be bound to the transaction. The group ID loaded from storage must match the requested conversation-to-MLS-group mapping.
- Provider snapshot and group object are one logical state. Do not checkpoint a new provider snapshot while retaining an old in-memory group, or vice versa.
- A multi-step wrapper such as `propose_and_commit_add` must have one high-level commit boundary. Per-method or per-storage-key writes are not sufficient.
- A successful `create_message` return must mean the sending ratchet checkpoint is durable. Otherwise a crash/retry can reuse stale state or lose the ciphertext/state pairing.
- A successful `process_message` return must mean receive-ratchet and any epoch/proposal changes are durable. Duplicate/replay behavior must be tested against the committed state after restart.
- The current `Identity` holds a signature key pair in memory. Restored operations must reconstruct identity material from the candidate provider and validate that the key belongs to the credential used by the group.
- The browser UI must not treat a message as sent, a member as removed, or a new epoch as active until the worker confirms durable commit.
- Never return raw provider snapshots to the main page in a production design. Encryption and OPFS persistence should stay within the worker boundary.
- This wrapper audit does not solve device-key provisioning, recovery, multi-device synchronization, key transparency, or secure deletion.

## Implementation sequence

1. Refactor the Rust API into candidate operations that return candidate provider/group handles plus serialized result values without mutating the published pair.
2. Add native failure-injection tests proving the old pair remains usable after an MLS operation error.
3. Add worker-level tests that fail persistence before write, after stage, after flush, during read-back verification, and before commit publication.
4. Verify that a failed durable commit never publishes ciphertext or membership/epoch state and that the next operation reloads the last committed generation.
5. Only then connect candidate snapshots to the authenticated OPFS journal and run abrupt worker termination/restart tests.
6. Re-run replay, membership removal, epoch rotation, multi-device, and recovery tests against the durable candidate-operation path.

## Explicit non-goals

This audit does not authorize production integration, deployment, Supabase changes, or activation of private messaging. It is not evidence that operation-level atomicity has been implemented.
