# OPFS-backed OpenMLS provider spike

**Decision status:** Candidate architecture only. No production provider is implemented.

## Why this direction

The branch pins OpenMLS 0.9.2 / `openmls_traits` 0.6.0. Their released manifests expose the synchronous `StorageProvider` contract; the async feature discussed in newer documentation is not part of these released manifests. A direct IndexedDB adapter therefore does not fit the pinned trait.

The Chromium OPFS test already proves that a dedicated worker can acquire a synchronous access handle, perform read/write/flush, exclude a second writer, and read the file after close/reopen. It does not prove the storage provider.

## Proposed execution boundary

- Instantiate the WASM OpenMLS runtime inside a dedicated Web Worker.
- The worker owns the OpenMLS provider and all group objects for that device.
- The worker owns OPFS `FileSystemSyncAccessHandle` instances. No main-thread synchronous storage bridge.
- The page communicates with the worker through request/response messages. Every mutation request has a unique request ID and a group scope.
- Serialize mutations per group inside the worker. Retain the existing Web Locks helper only as a cross-tab coordination layer; it is not a substitute for storage revision checks.

## Storage model to prototype

Start with one encrypted provider-store image per account/device namespace, not one OPFS file per individual MLS field. The OpenMLS trait is granular, but a single logical provider store simplifies loading, integrity validation, and snapshot recovery.

- Encode records using the same versioned key and value serialization conventions as the pinned OpenMLS MemoryStorage implementation, unless a compatibility review justifies a deliberate format change.
- Add a BaddieLink envelope containing format version, account ID, device ID, store generation, payload length, and authenticated ciphertext.
- Use an authenticated-encryption scheme. Do not write plaintext MLS private state to OPFS.
- Derive a per-device storage key from a separately managed device root key. Bootstrap/unlock the root key before constructing the Rust provider; do not assume a non-extractable Web Crypto key can be synchronously invoked from the Rust StorageProvider methods.
- Keep the root key out of Supabase and server logs. Document what happens if browser storage is cleared or the device key is lost.

## Crash consistency and transaction boundary

A simple in-place file overwrite is not sufficient. The prototype must use a recoverable two-generation journal:

1. Read and authenticate the currently committed generation.
2. Apply an MLS operation to a candidate in-memory store state while retaining the prior committed state.
3. Write the candidate generation to the inactive slot with a new monotonic generation number and authenticated metadata.
4. Flush the complete candidate record.
5. Validate the written record by reading and authenticating it.
6. Publish the new generation as committed only after validation. On startup, choose the highest fully valid committed generation; ignore incomplete/uncommitted slots.
7. If an MLS operation fails, discard the mutated in-memory group/provider state and reload from the last committed generation before accepting another operation.

Important limitation: OpenMLS storage methods are granular and do not expose one universal transaction callback on the `StorageProvider` trait. The application wrapper must define the high-level MLS operation boundary and commit/rollback the candidate store around every mutating OpenMLS call. Do not persist each trait write immediately and assume that multiple writes form one atomic MLS state transition.

The two-slot protocol itself needs a precise commit-marker design and crash injection tests before implementation. Do not assume OPFS flush alone provides an atomic multi-record transaction.

## Required test sequence

1. Build the worker-hosted WASM runtime and prove all MLS calls execute in the worker.
2. Implement a minimal encrypted record store and two-generation journal without OpenMLS; test torn/incomplete slot recovery.
3. Implement a minimal subset of the pinned `StorageProvider` contract and compile it for `wasm32-unknown-unknown`.
4. Expand trait coverage until every required storage method is implemented, including list append/remove and deletion semantics.
5. Establish a two-member MLS group, mutate it, commit, terminate the worker, reopen the store, restore the provider/group, and decrypt a queued message.
6. Inject failures before write, during write, after flush, during validation, and before commit publication. Confirm recovery always chooses the last valid committed generation.
7. Verify stale generation rejection, account/device/group binding, ciphertext tampering rejection, and unsupported format rejection.
8. Verify key-package, PSK, signature-key, encryption-key, and group-secret deletion semantics. Ensure old journal slots cannot resurrect deleted secrets after compaction/rotation.
9. Test two tabs racing the same group and verify exactly one committed generation wins.
10. Test quota exhaustion, OPFS eviction/unavailability, browser termination, and device-key loss. Fail closed; never silently create a new group under an existing conversation ID.
11. Repeat on Chromium, Firefox, and iOS Safari before selecting it for production.

## Explicit non-goals

- This file does not authorize production integration, deployment, Supabase schema changes, or activation of private messaging.
- This spike does not claim secure deletion from flash storage or browser backups.
- This spike does not solve independent-device synchronization, device revocation, recovery, attachments, key transparency, or server delivery.
