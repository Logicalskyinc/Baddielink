# E2EE client-state persistence investigation

**Status:** Investigation only. The browser snapshot harness is experimental; no production persistence implementation is approved or wired into BaddieLink.

## Current implementation and evidence

- The Rust `Provider` implements `OpenMlsProvider` and owns `RustCrypto` plus OpenMLS `MemoryStorage`.
- The provider exposes snapshot export/import for the isolated experiment. This serializes the complete in-memory storage map; it does not make the underlying storage provider persistent.
- The browser harness wraps snapshot bytes with AES-256-GCM and stores the encrypted checkpoint and non-extractable Web Crypto key in IndexedDB.
- Chromium CI run #29 passed tests for page reload and group restoration, queued-message decryption, tampered ciphertext rejection, wrong-key rejection, account/device AAD mismatch rejection, and aborted IndexedDB transaction preservation.
- A separate Web Locks helper and contention smoke test were added afterward. They are not considered verified until their CI run passes.
- The current lock helper is not yet called by every MLS operation. It coordinates same-origin tabs only, not independent devices or browser profiles.
- The exact `openmls_traits` 0.6.0 storage trait source exposes synchronous `Result`-returning methods, and that crate's published feature list does not include an `async` feature. Generic OpenMLS async-mode documentation must not be assumed to apply to this pinned traits version without a version-specific compile proof.
- A dedicated-worker OPFS spike has been added: it tests synchronous access handles, exclusive file ownership across workers, flush/read-back, and persistence after close/reopen. This is a browser storage primitive test only, not an OpenMLS provider.

## Security constraints

1. **Storage integrity is critical.** OpenMLS assumes persisted state is trusted. A backend must authenticate records and reject tampering, incomplete state, unsupported versions, and account/device/group mismatches.
2. **Deletion semantics matter.** OpenMLS deletes consumed key material to support forward secrecy. A backend must honor deletes and avoid stale copies or backup paths that restore deleted secrets.
3. **The pinned storage contract is synchronous.** The exact `openmls_traits` 0.6.0 API is synchronous. IndexedDB is asynchronous, so a direct adapter would require an unsafe blocking bridge or a different architecture. Do not rely on generic async-mode documentation unless the exact pinned crate versions prove it compiles and run under WASM.
4. **OPFS is a candidate, not a complete answer.** `FileSystemSyncAccessHandle` provides synchronous read/write from a dedicated worker and exclusive access to a file. This could fit a synchronous storage trait without blocking the page thread, but it does not by itself provide multi-record transactions, revision checks, authenticated encryption, or safe crash recovery. A journal/commit protocol and failure tests are still required.
5. **Browser storage is not a secure vault.** A non-extractable Web Crypto key limits raw-key export but does not stop same-origin JavaScript from invoking cryptographic operations. XSS and compromised browser profiles remain in scope.
6. **Fail closed.** If a record cannot be authenticated, decrypted, or loaded completely, discard the in-memory group and recover from the last committed checkpoint or require rejoin. Never silently create a new group state under an existing conversation identity.
7. **No server-side private state.** MLS private state and device storage keys remain on the device. Do not upload provider snapshots or private keys to Supabase.

## Candidate implementation direction

- Keep the existing snapshot harness as a test fixture, not the production backend.
- Validate the dedicated-worker OPFS primitive test in Chromium. Then implement a small WASM worker-host storage adapter only if the sync OpenMLS provider can call it safely; design a journaled, authenticated commit protocol before storing real MLS state.
- Store records per account/device/group with schema version, monotonically increasing revision, authenticated metadata, and encrypted value.
- Use an IndexedDB transaction to atomically commit the full state transition. Compare the expected revision before writing; reject stale writers.
- Serialize all state-changing operations per device/group. Web Locks may coordinate same-origin tabs, but correctness must also rely on storage revision checks because locks do not span devices or browser profiles.
- On failed/interrupted MLS operations, do not continue using the mutated in-memory group. Reload from the last successfully committed transaction.
- Verify deletion and rotation remove obsolete key material from all reachable storage records. Do not claim secure deletion from browser storage without examining IndexedDB/backup semantics.
- Keep message history separate from the MLS state store and encrypt message content and attachments client-side.

## Required prototype tests

1. Validate synchronous OPFS access in a dedicated worker and compile a WASM-host adapter against the exact pinned OpenMLS traits API.
2. Create two independent providers, establish a group, persist all required records, destroy in-memory objects, then restore and decrypt a queued message.
3. Reject tampered records, wrong keys, wrong account/device/group binding, unsupported versions, missing records, and stale revisions.
4. Race two tabs attempting to update the same group. Exactly one revision transition must commit; the other must reload/retry or fail safely.
5. Simulate transaction abort, quota exhaustion, browser termination, and operation cancellation. No partial state may be treated as committed.
6. Verify consumed key material is deleted and cannot be recovered from stale snapshots.
7. Repeat in Chromium, Firefox, and iOS Safari.
8. Test separate devices, device revocation, and MLS epoch rotation.

## Immediate next step

Validate the newly added same-origin Web Locks contention test. Then prototype the OpenMLS async storage trait on WASM before committing to an IndexedDB storage-provider design.

## References

- OpenMLS persistence guide: https://book.openmls.tech/user_manual/persistence.html
- OpenMLS storage provider trait: https://docs.rs/openmls_traits/0.6.0/openmls_traits/storage/trait.StorageProvider.html
- OpenMLS provider trait: https://docs.rs/openmls_traits/0.6.0/openmls_traits/trait.OpenMlsProvider.html
- OpenMLS 0.9 release notes: https://github.com/openmls/openmls/releases
