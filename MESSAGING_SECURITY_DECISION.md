# BaddieLink Messaging Privacy and E2EE

**Status:** Architecture requirements agreed; cryptographic protocol selection pending a browser proof of concept.  
**Branch:** `feat/profile-reputation-events`  
**Scope:** Direct messages, community discussions, private salons, and room-level identity controls.

## Product guarantee we intend to make

BaddieLink's target is end-to-end encryption (E2EE): message content is encrypted on the sender's device and decrypted only on authorized recipient devices. BaddieLink's application servers, database operators, and moderators must not have a server-side decryption key or an administrative backdoor to private message contents.

This is a release requirement, not a claim that the current product already provides E2EE. The existing direct-message database table has a plaintext `body` column. The database currently contains **zero direct-message rows**, and the current Messages interface contains demonstration conversations rather than a working chat implementation. We can therefore design the first real messaging release to be encrypted from its first persisted message.

The E2EE claim must not appear in marketing, onboarding, or settings until the client encryption flow, key lifecycle, device handling, and access-control tests pass.

## Scope and visibility

- **One-to-one messages:** encrypted for the two participants' authorized devices.
- **Private salons:** encrypted for active members' authorized devices.
- **Private communities:** encrypted for active members' authorized devices.
- **Public communities:** message content can still be E2EE from BaddieLink, but the community is not confidential. Any eligible member who joins can decrypt and may copy or share content. The UI must clearly label public visibility.
- **Attachments:** must be encrypted on the client before upload. A private storage bucket or signed URL alone is not E2EE.
- **System events:** membership changes and other control events must use authenticated protocol messages or contain only non-sensitive metadata. They must not introduce plaintext message content.

## Data BaddieLink may still process

E2EE protects message content, not all metadata. The service may still process account IDs, device public keys, conversation or space IDs, membership and role state, timestamps, delivery/read state, message sizes, IP/network information, and abuse reports submitted by users. The privacy notice must explain this distinction.

Message content, decrypted attachment contents, encryption private keys, and recovery secrets must not be written to server logs, analytics, crash reports, push-notification payloads, or admin dashboards. Push notifications should use generic text by default.

## Cryptographic requirements

1. Use a maintained, independently reviewed protocol implementation. Do not invent a key exchange, ratchet, group key rotation, or recovery scheme using raw Web Crypto primitives.
2. Generate private identity and session keys on user devices. Store only public key material and opaque encrypted protocol messages server-side.
3. Support device registration, device revocation, key rotation, and secure device linking. A newly added device must not silently gain access to old conversation history.
4. Membership additions and removals in group spaces must update the cryptographic group state. Removed members must not decrypt future messages.
5. Define backup and recovery behavior explicitly. If a user loses all authorized devices and has no recovery secret, old messages may be unrecoverable. Do not add server-side key escrow.
6. Verify identity changes with safety-number or equivalent key-transparency warnings so users can detect unexpected key replacement.
7. Encrypt attachments before they leave the device and keep attachment keys inside the encrypted message payload.
8. Do not ship the E2EE claim until independent security review and tests cover key compromise, replay, device removal, group membership changes, account recovery, and multi-device behavior.

## Protocol evaluation

- **MLS (RFC 9420) / OpenMLS:** a strong candidate for both two-person and group conversations. OpenMLS documents WebAssembly support, but its current project documentation lists WASM among targets that are built but not tested. A browser proof of concept and compatibility/performance testing are mandatory before selection.
- **Signal libsignal:** provides TypeScript APIs and the Signal Protocol, but Signal's upstream project explicitly says use outside Signal is unsupported and APIs may change without notice. Do not adopt it as a production dependency without resolving that support and maintenance risk.

No protocol is selected by this document. The next technical gate is a small browser/WASM proof of concept that demonstrates persistent encrypted client state, message encryption/decryption, multi-device behavior, group membership changes, and recovery. Compare maintenance, licensing, bundle size, mobile-browser support, and operational complexity before choosing.

## Realtime and authorization

- Persist encrypted messages in PostgreSQL; use Supabase Realtime only to distribute ciphertext and non-sensitive presence/typing metadata.
- Use private Realtime channels and membership-based RLS policies for both receiving and broadcasting.
- The client must set `config: { private: true }` when joining a private channel.
- Before release, verify the Supabase Realtime setting **Allow public access to channels** is disabled. A migration cannot change this dashboard-level setting.
- Supabase caches channel authorization for the connection. Removing a member from a database membership row does not necessarily terminate an already-authorized socket immediately. Membership removal must also rotate the group cryptographic epoch, force/revoke affected sessions or channel connections as appropriate, and ensure that any remaining broadcast contains ciphertext only.
- Database RLS must independently restrict message reads and writes to active participants. A hidden UI control is never an authorization boundary.

## Moderation and reporting

Moderators can manage memberships, remove content references, suspend spaces, and review metadata. They cannot silently decrypt private messages.

A member may report a message by explicitly choosing to submit the selected message and confirming the report. The client may then attach the user-selected decrypted excerpt (and relevant context) to the report record. This is a user-initiated disclosure, not routine platform access. The UI must tell the reporter exactly what content is being shared.

## Personal chat settings

Each user gets their own settings per direct conversation:

- Private contact nickname, visible only to the user who set it.
- Mute and notification preferences.
- Pin and archive state.
- Optional chat appearance/theme.
- Read-receipt and online-status controls, with clear explanations of metadata exposure.

These preferences must be scoped to the current user and conversation. A nickname must never overwrite the other member's profile name or be visible to that member.

For salons and communities, a member may optionally choose a room-specific display alias. BaddieLink retains the real account identity for safety, abuse investigations, and authorized moderation. The interface must distinguish the public alias from the account identity.

## Delivery plan

1. **Architecture gate:** complete the browser cryptographic proof of concept and select the protocol. No production encryption claim.
2. **Database foundation:** add encrypted message envelopes, device/key-package records, spaces, memberships, personal conversation preferences, RLS, private Realtime authorization, and indexes in a reviewed migration.
3. **Direct chat:** implement encrypted one-to-one conversations and per-conversation settings.
4. **Communities and salons:** implement discovery, public join, private join requests, owner/moderator permissions, encrypted group messaging, and room aliases.
5. **Moderation:** implement user-submitted message reports, member removal, space suspension, and audit records without server-side decryption.
6. **Verification:** test unauthorized reads/writes, blocked users, membership revocation, key changes, lost devices, message replay, group rotations, attachments, notification payloads, and multi-device synchronization.
7. **Launch communication:** publish the E2EE guarantee only after the implementation and security review are complete.

## Current verified state

- The existing Messages UI contains fictional demonstration conversations; it is not a working chat feature.
- The existing `public.messages` table has a plaintext `body` column.
- The current database contains zero rows in `public.messages` and zero rows in `public.matches`.
- RLS is enabled on `realtime.messages`, but no Realtime authorization policies were found.
- No tables are currently listed in the `supabase_realtime` publication.
- No live database changes, migrations, deployments, or billing changes were made while preparing this decision.
