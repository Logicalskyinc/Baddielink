# OpenMLS browser proof of concept

**Status:** Experimental scaffold only. Not integrated into BaddieLink and not approved for production use.

This isolated crate evaluates the OpenMLS Messaging Layer Security (MLS) implementation in BaddieLink's browser-first frontend through WebAssembly. The wrapper is adapted from upstream OpenMLS revision `bcde2afd3d1fb6045753b544ea290605081abe20`; see `NOTICE.md` and `LICENSE`.

## Current verified scope

- OpenMLS group creation, invitation, membership updates, message encryption/decryption, member removal, and replay rejection have native/browser validation coverage.
- A native provider snapshot can be exported and restored for the experiment.
- The browser harness encrypts provider snapshots with AES-256-GCM and stores the encrypted checkpoint and non-extractable Web Crypto key in IndexedDB.
- Chromium validation has covered reload/restore, queued-message decryption after reload, tampered ciphertext rejection, wrong-key rejection, account/device AAD mismatch rejection, and aborted-transaction preservation of the previous checkpoint.
- Chromium CI run #33 verified same-origin Web Locks serialization and lock release after an operation failure.
- Chromium CI run #38 verified dedicated-worker OPFS synchronous access, exclusive file access, flush/read-back, and persistence after close/reopen.
- The OPFS and Web Locks tests validate browser primitives only. Neither is integrated with the OpenMLS provider.

The snapshot test is an experimental persistence envelope around OpenMLS `MemoryStorage`. It is **not** an IndexedDB-backed OpenMLS `StorageProvider`.

## Run locally

Prerequisites:
- Rust toolchain compatible with OpenMLS 0.9.x.
- `wasm32-unknown-unknown` Rust target.
- `wasm-pack`.
- Node.js and Playwright with Chromium for browser smoke tests.

From this directory:

```sh
rustup target add wasm32-unknown-unknown
cargo install wasm-pack
./build.sh
```

Serve the generated `pkg/` directory over localhost and open `/index.html`. Do not use a `file://` URL.

## Security and architecture limitations

- The current Rust provider still uses process-local `MemoryStorage`. Reload persistence works by serializing and restoring the entire provider snapshot, not by using a persistent OpenMLS storage backend.
- The snapshot contains private MLS state. AES-GCM protects its integrity/confidentiality at rest in the test harness, but storing a non-extractable Web Crypto key in the same browser origin does not protect against malicious same-origin JavaScript, XSS, malware, or browser-profile compromise.
- The Web Locks helper is not yet wired around every MLS state mutation. It coordinates tabs in one origin only; it does not coordinate independent devices or browser profiles. Unsupported Web Locks must fail closed rather than run concurrent mutations.
- The exact released OpenMLS 0.9.2 and `openmls_traits` 0.6.0 manifests in this branch do not expose an async storage feature. Async-mode documentation from the development branch must not be treated as part of these released dependencies.
- OPFS synchronous access has been tested in a dedicated worker. An append-only journal primitive now tests data/commit frames, recovery from uncommitted staged data, incomplete trailing frames, and close/reopen persistence. It is not yet connected to OpenMLS, and its SHA-256 marker is not a substitute for authenticated encryption.
- The prototype does not implement a delivery service, production account/device binding, key transparency, secure recovery, offline delivery, attachment encryption, push handling, or complete membership-revocation UX.
- It does not implement a persistent OpenMLS `StorageProvider`, transactional key deletion, rollback-safe async storage, or production key lifecycle.
- No message content or private MLS state should be sent to Supabase from this experiment.

## Required gates before production

1. Pin and record the exact released OpenMLS dependency graph used by CI.
2. Implement a dedicated-worker OPFS-backed synchronous storage provider.
3. Implement authenticated records, revision checks, atomic commit/recovery, and actual deletion semantics.
4. Test interrupted operations, quota failures, stale revisions, incomplete records, and recovery from the last committed state.
5. Integrate serialization around every MLS mutation.
6. Test separate browser profiles, independent devices, device revocation, and MLS epoch rotation.
7. Test Chromium, Firefox, and iOS Safari.
8. Implement and test recovery, attachment encryption, key transparency, and safety warnings.
9. Complete an independent security review before any production E2EE claim.

Do not add this experiment to the production page or deploy it.
