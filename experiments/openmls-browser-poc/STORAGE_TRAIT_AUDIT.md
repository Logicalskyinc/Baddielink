# OpenMLS 0.9.2 StorageProvider trait audit

**Scope:** `openmls_traits::storage::StorageProvider` from upstream tag `v0.9.2`.
**Source file:** https://github.com/openmls/openmls/blob/v0.9.2/traits/src/storage.rs
**Source blob:** `d94671079ccabdd5865d17a00baab54a560bd874`
**Status:** API inventory only. No persistent provider is implemented by this audit.

## Findings

The pinned provider contract declares 72 methods when feature-gated declarations and the default `version()` method are counted. The methods are generic over OpenMLS storage traits and return typed values; a custom implementation must preserve serialization, absence, list ordering, and deletion behavior. This is not a simple byte-store interface.

The existing BaddieLink prototype still declares `type StorageProvider = MemoryStorage`. The OPFS bridge proves a synchronous Rust/WASM-to-worker-file round trip, but it is not connected to this trait.

## Method inventory

### Group state writes and proposal queue

- `write_mls_join_config`
- `append_own_leaf_node`
- `queue_proposal`
- `write_tree`
- `write_interim_transcript_hash`
- `write_context`
- `write_confirmation_tag`
- `write_group_state`
- `write_message_secrets`
- `write_resumption_psk_store`
- `write_own_leaf_index`
- `write_group_epoch_secrets`

### Crypto-object writes

- `write_signature_key_pair`
- `write_encryption_key_pair`
- `write_encryption_epoch_key_pairs`
- `write_key_package`
- `write_psk`

### Group state reads and proposal queue

- `mls_group_join_config`
- `own_leaf_nodes`
- `queued_proposal_refs`
- `queued_proposals`
- `tree`
- `group_context`
- `interim_transcript_hash`
- `confirmation_tag`
- `group_state`
- `message_secrets`
- `resumption_psk_store`
- `own_leaf_index`
- `group_epoch_secrets`

### Crypto-object reads

- `signature_key_pair`
- `encryption_key_pair`
- `encryption_epoch_key_pairs`
- `key_package`
- `psk`

### Deletion and queue maintenance

- `remove_proposal`
- `delete_own_leaf_nodes`
- `delete_group_config`
- `delete_tree`
- `delete_confirmation_tag`
- `delete_group_state`
- `delete_context`
- `delete_interim_transcript_hash`
- `delete_message_secrets`
- `delete_all_resumption_psk_secrets`
- `delete_own_leaf_index`
- `delete_group_epoch_secrets`
- `clear_proposal_queue`
- `delete_signature_key_pair`
- `delete_encryption_key_pair`
- `delete_encryption_epoch_key_pairs`
- `delete_key_package`
- `delete_psk`

### Feature-gated extension methods

The source also declares extension methods behind Cargo features. These must be included if the corresponding feature is enabled in the product build:

- `write_application_export_tree`
- `application_export_tree`
- `delete_application_export_tree`
- `write_vc_emulation_epoch_state`
- `vc_emulation_epoch_state`
- `delete_vc_emulation_state_if_unreferenced`
- `write_vc_emulation_bindings`
- `vc_emulation_bindings`
- `delete_vc_emulation_bindings`
- `write_registered_vc_emulation_epoch`
- `registered_vc_emulation_epoch`
- `delete_registered_vc_emulation_epoch`
- `write_vc_operation_tree`
- `vc_operation_tree`
- `write_retained_key_package_material_batch`
- `retained_key_package_material`
- `has_retained_key_package_material_for_epoch`
- `delete_retained_key_package_material`

The trait's `version()` method is also part of the declaration surface.

## Implementation constraints

1. Preserve `Ok(None)` versus `Err`: absence is not storage failure.
2. List getters must return an empty vector when no records exist, not fail.
3. Preserve proposal queue semantics and ordering expected by OpenMLS.
4. Implement all delete methods. Stale key material must not reappear after recovery, compaction, or fallback to an older journal generation.
5. Batch methods documented as atomic must be committed atomically by the provider/application transaction boundary.
6. Keep the full provider state encrypted and authenticated before writing it to OPFS. A checksum alone is not authentication.
7. On failed MLS mutations, discard the in-memory candidate state and reload the last committed provider generation before accepting another operation.
8. Pin the trait version and explicitly audit any Cargo feature that changes the trait surface.

## Recommended next implementation step

Before writing the provider, produce a compile-time adapter spike that implements the exact pinned trait against an in-memory map and has contract tests for absent values, list behavior, queue ordering, batch atomicity, and deletion. Only after that compiles and passes should the backend be switched to the synchronous worker-owned OPFS bridge.

Do not call this provider production-ready until it is connected to authenticated OPFS persistence and passes crash-recovery, deletion, stale-revision, quota, and cross-browser tests.
