# E2EE client-state persistence investigation

**Status:** Investigation only. The browser snapshot harness is experimental; no production persistence implementation is approved or wired into BaddieLink.

## Current implementation and evidence

- The Rust `Provider` implements `OpenMlsProvider` and owns `RustCrypto` plus OpenMLS `MemoryStorage`.
- The provider exposes snapshot export/import for the isolated experiment. This serializes the complete in-memory storage map; it does not make the underlying storage provider persistent.
- The browser harness wraps snapshot bytes with AES-256-GCM and stores the encrypted checkpoint and non-extractable Web Crypto key in IndexedDB.
- Chromium CI run #29 passed tests for page reload and group restoration, queued-message decryption, tampered ciphertext rejection, wrong-key rejection, account/device AAD mismatch rejection, and aborted IndexedDB transaction preservation.
- The current lock helper is not yet called by every MLS operation. It coordinates same-origin tabs only, not independent devices or browser profiles.
- Chromium CI run #33 passed the same-origin Web Locks contention test: three operations on one account/device/group were serialized, and a failed operation released the lock.
- Chromium CI run #38 passed the OPFS worker primitive test: a dedicated worker acquired a synchronous access handle, a second worker was denied concurrent access to the same file, flushed bytes were read back, and the file remained readable after close/reopen.
- The current Web Locks helper is not yet called by every MLS operation. It coordinates same-origin tabs only, not independent devices or browser profiles.
- **Version-specific correction:** the released `openmls` 0.9.2 and `openmls_traits` 0.6.0 manifests do **not** expose an `async` feature. The async-mode documentation describes the newer development line, not the exact released dependency set in this branch. Do not enable an unreleased feature or infer support from `latest` documentation.
- The OPFS test is a browser storage primitive test only, not an OpenMLS provider.

## Security constraints

1. **Storage integrity is critical.** OpenMLS assumes persisted state is trusted. A backend must authenticate records and reject tampering, incomplete state, unsupported versions, and account/device/group mismatches.
2. **Deletion semantics matter.** OpenMLS deletes consumed key material to support forward secrecy. A backend must honor deletes and avoid stale copies or backup paths that restore deleted secrets.
3. **The released storage API is synchronous.** The exact v0.9.2 / traits v0.6.0 manifests expose the synchronous storage contract. IndexedDB is asynchronous, so a direct adapter is not viable without a bridge that would block or otherwise violate the browser execution model.
4. **OPFS is a candidate, not a complete answer.** `FileSystemSyncAccessHandle` provides synchronous read/write from a dedicated worker and exclusive access to a file. This could fit a synchronous storage trait without blocking the page thread, but it does not by itself provide multi-record transactions, revision checks, authenticated encryption, or safe crash recovery. A journal/commit protocol and failure tests are still required.
6. **Browser storage is not a secure vault.** A non-extractable Web Crypto key limits raw-key export but does not stop same-origin JavaScript from invoking cryptographic operations. XSS and compromised browser profiles remain in scope.
7. **Fail closed.** If a record cannot be authenticated, decrypted, or loaded completely, discard the in-memory group and recover from the last committed checkpoint or require rejoin. Never silently create a new group state under an existing conversation identity.
8. **No server-side private state.** MLS private state and device storage keys remain on the device. Do not upload provider snapshots or private keys to Supabase.

## Candidate implementation direction

- Keep the existing snapshot harness as a test fixture, not the production backend.
- Keep the released v0.9.2 synchronous API as the current baseline. Re-evaluate async storage only if a future stable OpenMLS release includes the feature and its exact crate manifests.
- Prototype an OPFS-backed synchronous provider running wholly inside a dedicated worker. The Rust MLS runtime and its storage calls must execute in that worker; the main thread must not block waiting for OPFS.
- Implement a transactional/journaled commit protocol with schema version, account/device/group binding, monotonic revisions, authenticated records, and recovery markers before storing real MLS state.
- Store records per account/device/group with schema version, monotonically increasing revision, authenticated metadata, and encrypted value.
- Use an IndexedDB transaction to atomically commit the full state transition. Compare the expected revision before writing; reject stale writers.
- Serialize all state-changing operations per device/group. Web Locks may coordinate same-origin tabs, but correctness must also rely on storage revision checks because locks do not span devices or browser profiles.
- On failed/interrupted MLS operations, do not continue using the mutated in-memory group. Reload from the last successfully committed transaction.
- Verify deletion and rotation remove obsolete key material from all reachable storage records. Do not claim secure deletion from browser storage without examining IndexedDB/backup semantics.
- Keep message history separate from the MLS state store and encrypt message content and attachments client-side.

## Required prototype tests

1. Pin and record the exact released OpenMLS dependency graph used by CI.
2. Implement a minimal OPFS-backed storage provider against the synchronous v0.9.2 `StorageProvider` trait, with the WASM MLS runtime executing inside a dedicated worker.
3. Create two independent providers, establish a group, persist all required records, destroy in-memory objects, then restore and decrypt a queued message.
4. Reject tampered records, wrong keys, wrong account/device/group binding, unsupported versions, missing records, and stale revisions.
5. Race two tabs attempting to update the same group. Exactly one revision transition must commit; the other must reload/retry or fail safely.
6. Simulate transaction abort, quota exhaustion, browser termination, and operation cancellation. No partial state may be treated as committed.
7. Verify consumed key material is deleted and cannot be recovered from stale snapshots.
8. Repeat in Chromium, Firefox, and iOS Safari.
9. Test separate devices, device revocation, and MLS epoch rotation.

## Immediate next step

Build the smallest compiling OPFS-backed storage-provider slice against the exact v0.9.2 synchronous trait, then expand it method-by-method with persistence and failure tests.

## References

- OpenMLS v0.9.2 manifest: https://github.com/openmls/openmls/blob/v0.9.2/openmls/Cargo.toml
- OpenMLS traits v0.6.0 manifest: https://github.com/openmls/openmls/blob/v0.9.2/traits/Cargo.toml
- OpenMLS traits 0.6.0 crate/features: https://docs.rs/crate/openmls_traits/0.6.0
- OpenMLS persistence guide: https://book.openmls.tech/user_manual/persistence.html
- OpenMLS storage provider trait: https://docs.rs/openmls_traits/0.6.0/openmls_traits/storage/trait.StorageProvider.html
- OpenMLS provider trait: https://docs.rs/openmls_traits/0.6.0/openmls_traits/trait.OpenMlsProvider.html
- OpenMLS 0.9 release notes: https://github.com/openmls/openmls/releases
