# E2EE client-state persistence investigation

**Status:** Design investigation. No persistence implementation is approved or wired into the application.

## Current verified state

- The browser proof of concept wraps `OpenMlsRustCrypto`.
- `OpenMlsRustCrypto` constructs and owns an in-memory `MemoryStorage`; its storage field is private.
- OpenMLS writes group state and key material through its `StorageProvider` abstraction. A group can later be restored with `MlsGroup::load` when the same provider contains its complete state.
- The prototype's current provider is process-local, so a browser reload loses the MLS state.
- The current experiment has no account/device-bound storage, encryption-at-rest, recovery, or browser reload test.

## Constraints that affect the design

1. **The storage provider is security-critical.** OpenMLS assumes persisted state is trusted. An attacker able to modify it can violate invariants that OpenMLS does not re-check on load. The persistence layer must provide authenticated integrity, not just encryption.
2. **Deletion semantics matter.** OpenMLS deletes consumed key material to support forward secrecy. A storage backend must honor delete operations and must not retain stale copies or backups that defeat deletion.
3. **The synchronous API is a browser integration constraint.** The default OpenMLS storage trait is synchronous. IndexedDB is asynchronous. The optional OpenMLS async storage mode must be evaluated on `wasm32` before adopting IndexedDB; its future and cancellation requirements need explicit handling.
4. **Browser storage is not automatically a secure vault.** IndexedDB/localStorage alone do not protect key material from same-origin script execution, browser-profile compromise, or unsafe backups. A non-extractable WebCrypto key helps constrain raw-key export but does not prevent same-origin code from asking the browser to use it.
5. **No plaintext fallback.** If storage cannot be authenticated, decrypted, or loaded completely, the client must fail closed and require recovery/rejoin. It must not silently create a new group state under the same conversation identity.

## Candidate architecture to evaluate

- Replace the opaque `OpenMlsRustCrypto` wrapper with a provider that explicitly owns the RustCrypto implementation and a storage provider, while continuing to implement the OpenMLS provider trait.
- Keep MLS state local to each registered device. Never upload MLS private state or storage snapshots to Supabase.
- Evaluate an IndexedDB-backed storage provider using OpenMLS's async feature first. If that is not viable on the target WASM/browser toolchain, evaluate a narrowly scoped synchronous adapter only after its transaction, quota, integrity, and deletion behavior are demonstrated.
- Authenticate and encrypt persisted records with a per-device storage key protected by a browser/platform credential mechanism. The key lifecycle, same-origin threat model, and recovery behavior must be explicit before real keys are stored.
- Version the local storage schema and bind records to the authenticated account, device identifier, MLS group identifier, and storage format version.
- Serialize storage operations per device/group. An interrupted or failed MLS operation must not leave memory and persisted state diverged; discard the in-memory group and reload from the last committed transaction.
- Do not persist plaintext chat messages as part of the MLS state store. Message history is a separate encrypted application-data layer.

## Required prototype tests

1. Create two independent providers and establish a group.
2. Persist the complete provider state using the candidate backend.
3. Destroy the in-memory provider and group objects.
4. Recreate the provider from persisted, authenticated state and load the group with `MlsGroup::load`.
5. Verify the restored participant can decrypt a message from another participant.
6. Verify a tampered record, wrong device key, wrong account binding, unsupported storage version, and incomplete snapshot all fail closed.
7. Verify deleting/rotating MLS secrets actually removes the corresponding stored values and that no snapshot/backup path restores deleted secrets.
8. Simulate interrupted writes and quota/storage errors; verify no partial state is treated as valid.
9. Repeat in Chromium, Firefox, and iOS Safari before selecting the production backend.

## Immediate next step

Build a small provider/storage spike on the isolated branch. First confirm whether the OpenMLS async storage trait and its dependencies compile and run under the current WASM target. Do not add Supabase tables, production feature flags, or production UI integration during this investigation.

## References

- OpenMLS persistence guide: https://book.openmls.tech/user_manual/persistence.html
- OpenMLS storage provider trait: https://docs.rs/openmls_traits/0.6.0/openmls_traits/storage/trait.StorageProvider.html
- OpenMLS provider trait: https://docs.rs/openmls_traits/0.6.0/openmls_traits/trait.OpenMlsProvider.html
- OpenMLS 0.9 release notes: https://github.com/openmls/openmls/releases
