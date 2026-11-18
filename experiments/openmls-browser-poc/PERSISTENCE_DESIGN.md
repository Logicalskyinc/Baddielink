# E2EE client-state persistence investigation

**Status:** Investigation only. The browser snapshot harness is experimental; no production persistence implementation is approved or wired into BaddieLink.

## Current implementation and evidence

- The Rust `Provider` implements `OpenMlsProvider` and owns `RustCrypto` plus OpenMLS `MemoryStorage`.
- The provider exposes snapshot export/import for the isolated experiment. This serializes the complete in-memory storage map; it does not make the underlying storage provider persistent.
- The browser harness wraps snapshot bytes with AES-256-GCM and stores the encrypted checkpoint and non-extractable Web Crypto key in IndexedDB.
- Chromium CI run #29 passed tests for page reload and group restoration, queued-message decryption, tampered ciphertext rejection, wrong-key rejection, account/device AAD mismatch rejection, and aborted IndexedDB transaction preservation.
- A separate Web Locks helper and contention smoke test were added afterward. They are not considered verified until their CI run passes.
- The current lock helper is not yet called by every MLS operation. It coordinates same-origin tabs only, not independent devices or browser profiles.
- Chromium CI run #33 passed the same-origin Web Locks contention test: three operations on one account/device/group were serialized, and a failed operation released the lock.
- Chromium CI run #38 passed the OPFS worker primitive test: a dedicated worker acquired a synchronous access handle, a second worker was denied concurrent access to the same file, flushed bytes were read back, and the file remained readable after close/reopen.
- The current Web Locks helper is not yet called by every MLS operation. It coordinates same-origin tabs only, not independent devices or browser profiles.
- **Correction to the earlier investigation:** `openmls_traits` 0.6.0 does expose an `async` feature. OpenMLS 0.9 documents async storage mode, and its storage futures are `Send`. This means async mode must be evaluated rather than dismissed. It does not prove a browser IndexedDB adapter will work: JavaScript IndexedDB promises are not generally `Send`, and OpenMLS warns that its async operations are not cancellation-safe.
- The OPFS test is a browser storage primitive test only, not an OpenMLS provider.

## Security constraints

1. **Storage integrity is critical.** OpenMLS assumes persisted state is trusted. A backend must authenticate records and reject tampering, incomplete state, unsupported versions, and account/device/group mismatches.
2. **Deletion semantics matter.** OpenMLS deletes consumed key material to support forward secrecy. A backend must honor deletes and avoid stale copies or backup paths that restore deleted secrets.
3. **Async mode needs a real WASM compatibility proof.** The `async` feature exists in the pinned traits line and OpenMLS 0.9 documents it. Its storage methods return `Send` futures, while browser IndexedDB APIs are promise-based and typically `!Send`. Compile a minimal adapter against the exact locked versions and `wasm32-unknown-unknown`; do not assume the type contract is satisfiable.
4. **Async operations are not cancellation-safe.** OpenMLS documents that group state may be updated in memory before multiple storage writes complete. Every operation needs transaction rollback on error/cancellation and a reload of the group from committed storage.
5. **OPFS is a candidate, not a complete answer.** `FileSystemSyncAccessHandle` provides synchronous read/write from a dedicated worker and exclusive access to a file. This could fit a synchronous storage trait without blocking the page thread, but it does not by itself provide multi-record transactions, revision checks, authenticated encryption, or safe crash recovery. A journal/commit protocol and failure tests are still required.
6. **Browser storage is not a secure vault.** A non-extractable Web Crypto key limits raw-key export but does not stop same-origin JavaScript from invoking cryptographic operations. XSS and compromised browser profiles remain in scope.
7. **Fail closed.** If a record cannot be authenticated, decrypted, or loaded completely, discard the in-memory group and recover from the last committed checkpoint or require rejoin. Never silently create a new group state under an existing conversation identity.
8. **No server-side private state.** MLS private state and device storage keys remain on the device. Do not upload provider snapshots or private keys to Supabase.

## Candidate implementation direction

- Keep the existing snapshot harness as a test fixture, not the production backend.
- Run a minimal async-mode WASM compatibility probe first. Test whether the exact pinned OpenMLS storage future types can be satisfied by a browser-backed store. If IndexedDB futures cannot meet the `Send` bound, do not force them through an unsafe blocking bridge.
- In parallel, evaluate an OPFS-backed synchronous provider running wholly inside a dedicated worker. The Rust MLS runtime and its storage calls must execute in that worker; the main thread must not block waiting for OPFS.
- Implement a transactional/journaled commit protocol with schema version, account/device/group binding, monotonic revisions, authenticated records, and recovery markers before storing real MLS state.
- Store records per account/device/group with schema version, monotonically increasing revision, authenticated metadata, and encrypted value.
- Use an IndexedDB transaction to atomically commit the full state transition. Compare the expected revision before writing; reject stale writers.
- Serialize all state-changing operations per device/group. Web Locks may coordinate same-origin tabs, but correctness must also rely on storage revision checks because locks do not span devices or browser profiles.
- On failed/interrupted MLS operations, do not continue using the mutated in-memory group. Reload from the last successfully committed transaction.
- Verify deletion and rotation remove obsolete key material from all reachable storage records. Do not claim secure deletion from browser storage without examining IndexedDB/backup semantics.
- Keep message history separate from the MLS state store and encrypt message content and attachments client-side.

## Required prototype tests

1. Compile a minimal OpenMLS async-mode storage probe for the exact locked crate versions on native and `wasm32-unknown-unknown`; record whether the `Send` requirement is compatible with the chosen browser APIs.
2. Validate OPFS synchronous access in a dedicated worker and compile a WASM-host adapter against the exact pinned OpenMLS traits API.
3. Create two independent providers, establish a group, persist all required records, destroy in-memory objects, then restore and decrypt a queued message.
4. Reject tampered records, wrong keys, wrong account/device/group binding, unsupported versions, missing records, and stale revisions.
5. Race two tabs attempting to update the same group. Exactly one revision transition must commit; the other must reload/retry or fail safely.
6. Simulate transaction abort, quota exhaustion, browser termination, and operation cancellation. No partial state may be treated as committed.
7. Verify consumed key material is deleted and cannot be recovered from stale snapshots.
8. Repeat in Chromium, Firefox, and iOS Safari.
9. Test separate devices, device revocation, and MLS epoch rotation.

## Immediate next step

Build the minimal async-mode compatibility probe for the pinned dependency graph. Compare it with the OPFS worker architecture before selecting the persistent storage provider.

## References

- OpenMLS async mode and cancellation warning: https://latest.openmls.tech/doc/openmls/index.html
- OpenMLS traits 0.6.0 crate/features: https://docs.rs/crate/openmls_traits/0.6.0
- OpenMLS persistence guide: https://book.openmls.tech/user_manual/persistence.html
- OpenMLS storage provider trait: https://docs.rs/openmls_traits/0.6.0/openmls_traits/storage/trait.StorageProvider.html
- OpenMLS provider trait: https://docs.rs/openmls_traits/0.6.0/openmls_traits/trait.OpenMlsProvider.html
- OpenMLS 0.9 release notes: https://github.com/openmls/openmls/releases
