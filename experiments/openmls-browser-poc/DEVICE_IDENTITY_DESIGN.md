# MLS Device Identity and Revocation Design

**Status:** Design gate for the isolated `feat/e2ee-browser-validation` branch. No production integration is authorized.

## Why this gate exists

The browser worker currently accepts `accountId`, `deviceId`, and `identityName` from its caller. The Rust wrapper turns `identityName` directly into an OpenMLS BasicCredential identity. The worker's IndexedDB and OPFS names are partitioned by account and device IDs, but those caller-provided values are not authenticated by a registration authority.

That means local storage partitioning is not proof of account ownership, device ownership, or authorization to add/remove an MLS member. Do not treat it as such.

The duplicate-identity removal guard is necessary, but it does not solve this identity-binding problem.

## Required identity model

1. Every registered device gets its own independent MLS signing key pair and its own unique, opaque device credential identifier.
2. The credential identifier must be random and non-meaningful. Do not put a username, email, phone number, account ID, or human-readable device label in the MLS credential identity. Group members can inspect credential identities.
3. The identifier is stable for that device registration and distinct across devices belonging to the same account.
4. A trusted registration authority must authenticate the account session, verify possession of the device signing key, and issue a cryptographically verifiable binding between:
   - opaque device credential identifier;
   - account identifier;
   - device registration identifier;
   - MLS signing public key;
   - registration status and relevant validity/revocation metadata.
5. MLS KeyPackages and credentials must be validated against that binding before they are accepted into a group. Merely trusting caller-supplied metadata or a BasicCredential string is insufficient.
6. The exact OpenMLS credential type and validation mechanism remain to be selected and implemented. A server-signed device certificate/custom credential validation path must be evaluated against the pinned OpenMLS release before coding.

## Separate operations

### Revoke one device

- Authenticate and authorize the revocation against the account's registered device roster.
- Identify the exact opaque credential identifier for that device.
- Commit an MLS membership change that removes only that device's leaf.
- Other devices owned by the same account remain members.
- Reject messages from the revoked device's stale epoch after the remaining members process the Commit.
- Device revocation must not be implemented as removal by username or account ID.

### Remove an account from a private room

- Resolve the account to its complete set of currently active, room-member device credential identifiers using an authenticated roster.
- Verify that the caller is authorized to remove that account from the room.
- Remove every matching device leaf in one coherent MLS membership transition where supported by the pinned OpenMLS API.
- Do not silently remove an arbitrary first match. If the roster and group membership disagree, fail closed and surface a reconciliation error.
- Verify that no registered device for the removed account can decrypt messages in the new epoch.

### Register a new device

- Generate a new device-specific key pair and opaque credential identifier.
- Authenticate the account and prove possession of the corresponding private key.
- Validate the registration binding before issuing/accepting a KeyPackage.
- Join at the current group epoch through an authorized invitation/Welcome flow.
- Do not provide historical group messages or old epoch secrets by default. Any history-sharing feature would require a separate explicit, audited design.

## Required browser integration tests

The next identity test fixture should use two devices for one account, with different opaque credential identifiers:

1. Register phone and tablet devices under the same test account.
2. Assert their MLS credential identities and signing public keys are distinct.
3. Add both devices to the same private group.
4. Revoke the phone device; assert the tablet remains active and decrypts a post-revocation message.
5. Assert the revoked phone cannot send accepted messages or decrypt post-revocation messages.
6. Remove the account from the group; assert the tablet is also removed and no account device remains active in the new epoch.
7. Register a third device for the account and join it after the group has advanced; assert it cannot decrypt messages sent before its join.
8. Tamper with, expire, or revoke the server-signed registration binding; assert KeyPackage admission fails closed.
9. Attempt to reuse another device's opaque credential identifier with a different signing key; assert registration/credential validation fails.

## Security boundaries and non-goals

- A dedicated worker isolates normal page message flow; it is not a security boundary against malicious same-origin JavaScript or XSS.
- Non-extractable Web Crypto keys stored in same-origin IndexedDB are not hardware-backed device identity.
- The current worker arguments are test inputs, not authenticated claims.
- The current BasicCredential wrapper does not implement the registration authority or server-signed account/device binding.
- This design does not authorize a server to decrypt messages. The server may authenticate registrations and coordinate delivery/membership metadata without holding MLS private keys or plaintext.
- No account/device registration API, Supabase schema, Render service, or production storage change is included in this design note.

## Exit criteria

Do not mark multi-device identity complete until the credential binding is cryptographically validated, the two-device revocation/removal tests pass in Chromium, negative registration tests fail closed, and the design has been reviewed against the exact pinned OpenMLS version.
