# BaddieLink E2EE implementation and validation plan

**Status:** Active engineering work. E2EE is not enabled in production.
**Branch:** `feat/e2ee-browser-validation`
**Protocol candidate:** MLS / OpenMLS, pending a successful browser build and security review.
**Production boundary:** No changes to production messaging, Realtime, or message storage are included in this phase.

## 1. Security contract

BaddieLink must encrypt message content on authorized sender devices and decrypt it only on authorized recipient devices. The server stores and routes opaque ciphertext and protocol control messages. It must not receive private message keys or plaintext message bodies.

This guarantee does not hide metadata such as account/device identifiers, space membership, timestamps, delivery state, message sizes, IP/network information, or content a user explicitly submits in a report.

No plaintext fallback is permitted. If a device cannot establish a valid cryptographic group state, sending must fail closed and explain that secure messaging is unavailable.

## 2. Repository audit findings (2026-11-18)

The existing `experiments/openmls-browser-poc` is a demonstration scaffold, not a production client:

- The Rust source contains panic paths (`unwrap`) and unimplemented MLS message branches (`todo!`).
- The provider uses OpenMLS's in-memory storage. Reloading the page loses protocol state.
- The harness creates several identities in one browser process; it does not represent independent devices, accounts, browsers, or real network delivery.
- It tests add-member flow and application-message encryption/decryption, but does not test member removal, stale epochs, replay handling, persistence, multi-device linking, secure recovery, attachments, or key transparency.
- The crate dependency declarations are not exact pins and there is no committed Cargo lockfile. Reproducible dependency resolution and supply-chain review are outstanding.
- The sample is not wired into the BaddieLink application and must remain isolated from real user data.

These findings prohibit a production E2EE claim and prohibit enabling private Salon messaging.

## 3. Protocol validation gates

### Gate A: reproducible browser build

- Pin exact compatible Rust crate versions and commit the generated lockfile.
- Build for `wasm32-unknown-unknown` using a documented Rust toolchain and `wasm-pack`.
- Eliminate unsafe panic paths and unimplemented message branches from every path reachable by untrusted network input.
- Add explicit error handling for malformed, unsupported, duplicate, and out-of-order MLS messages.
- Run the browser harness in Chromium and Firefox.
- Run the harness on iOS Safari and Android Chrome, including reload and background/resume behavior.
- Record WASM size, startup latency, memory use, and performance on representative low-end mobile hardware.

**Pass condition:** reproducible build plus browser test evidence on desktop and target mobile browsers. A successful native Rust build alone is insufficient.

### Gate B: durable per-device state

- Use a supported persistent OpenMLS storage provider or a carefully reviewed storage adapter.
- Encrypt persisted private protocol state with a per-device key protected by platform secure storage where available.
- Never store plaintext private keys in localStorage, IndexedDB without encryption, Supabase, logs, or analytics.
- Define behavior when secure storage is unavailable; fail closed rather than silently weakening protection.
- Verify crash-safe transactions and recovery after reload, browser restart, storage quota errors, and interrupted commits.

**Pass condition:** two independent browser/device contexts retain correct MLS state through reload and recover without key reuse or epoch rollback.

### Gate C: device identity and lifecycle

- Bind each registered device to an authenticated account using server-verified identity, not user-editable metadata.
- Publish signed public key packages only. Private signing keys and MLS private state remain on device.
- Support device revocation and explicit device linking.
- A newly linked device must not silently decrypt historical messages. History transfer requires a separate, explicit, end-to-end authenticated device-to-device flow or remains unavailable.
- Warn users when identity keys change unexpectedly; define safety-number or key-transparency verification.

**Pass condition:** revoked devices cannot decrypt future epochs; new devices cannot silently access prior history; key-change warnings are testable.

### Gate D: group membership and forward security

- Every Salon membership change must be reflected in MLS group state.
- New members receive only the current group state and future messages unless an explicit secure history-sharing mechanism is designed.
- Removed members must not decrypt messages from epochs after removal.
- Membership removal must rotate the MLS epoch and revoke stale Realtime access as far as the service allows.
- The server must validate that ciphertext is associated with the correct space and sender device, while clients validate MLS epochs and protocol state.
- Reject replayed messages, stale commits, invalid senders, malformed envelopes, and conflicting concurrent commits.

**Pass condition:** tests prove removed-member exclusion, stale-epoch rejection, replay rejection, and correct behavior under concurrent membership changes.

### Gate E: encrypted delivery and storage

- Persist only serialized MLS ciphertext/control envelopes and non-sensitive routing metadata.
- Do not reuse `public.messages.body` for Salon or private-community messages.
- Realtime broadcasts carry ciphertext only. Use private channels and membership-based authorization.
- Do not put plaintext, keys, or decrypted previews in push payloads, server logs, telemetry, crash reports, admin screens, or error messages.
- Encrypt attachments on-device; upload ciphertext only and carry attachment keys inside encrypted MLS application data.
- Reports may include message excerpts only after an explicit user action and confirmation.

**Pass condition:** database inspection, Realtime inspection, notification inspection, and log inspection show no plaintext or private keys.

### Gate F: recovery and multi-device behavior

- Document the account/device recovery model before implementation.
- Do not create server-side key escrow or admin decryption.
- If all authorized devices and any user-held recovery secret are lost, old messages may be unrecoverable.
- Test device loss, revocation, re-enrollment, multiple active devices, and synchronization races.
- Define backup format, encryption, key derivation, user-facing warnings, and recovery abuse protections before shipping.

**Pass condition:** documented recovery tests demonstrate that recovery does not give BaddieLink the ability to decrypt user content.

### Gate G: independent review and release

- Complete threat modeling and independent cryptographic/security review.
- Test malformed inputs, downgrade attempts, replay, identity substitution, concurrent commits, device revocation, compromised devices, and authorization bypass.
- Review dependency provenance, license compatibility, maintenance status, and update policy.
- Confirm Supabase Realtime public-channel access is disabled in project settings.
- Publish accurate privacy copy describing both content protection and exposed metadata.
- Enable messaging only after every gate is signed off.

## 4. Production rollout sequence

1. Validate and select the MLS implementation.
2. Design the device/key-package schema and ciphertext envelope contract.
3. Add reviewed database migrations and RLS for device records, key packages, encrypted envelopes, and per-user preferences.
4. Implement client-side MLS state and encrypted delivery.
5. Add Salon messaging behind a server-controlled feature flag that defaults off.
6. Complete authorization, cryptographic, mobile-browser, and recovery tests.
7. Obtain independent review.
8. Enable for a small opt-in test cohort, monitor only non-content metadata, and retain a kill switch that disables sending without decrypting content.
9. Expand only after the cohort passes the defined reliability and security criteria.

## 5. Explicit non-goals for this phase

- No plaintext chat fallback.
- No admin decryption, key escrow, or server-side content scanning.
- No production feature flag enabling messaging.
- No changes to the existing plaintext direct-message table.
- No production Supabase schema or Realtime configuration changes until the client protocol and envelope design are reviewed.
- No marketing claim that BaddieLink messaging is E2EE until the complete release gate passes.

## 6. Current checklist

- [x] Audit existing OpenMLS scaffold and document concrete blockers.
- [x] Create an isolated E2EE engineering branch.
- [ ] Reproducible WASM build and committed dependency lockfile.
- [ ] Browser tests on Chromium and Firefox.
- [ ] iOS Safari and Android Chrome validation.
- [ ] Durable encrypted MLS state.
- [ ] Device registration, linking, and revocation.
- [ ] Group removal, epoch rotation, and replay tests.
- [ ] Encrypted message envelope and attachment design.
- [ ] Production schema/RLS review.
- [ ] Independent security review.
- [ ] Controlled production rollout.
