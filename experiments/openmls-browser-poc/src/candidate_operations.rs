//! Candidate-state MLS operations.
//!
//! Each operation restores a private provider/group pair from the last committed
//! provider snapshot. The live pair is never mutated. The caller must persist
//! `snapshot_bytes()` durably before taking and installing the candidate handles.
//! This module is an experimental first slice, not a complete transaction layer.

use super::{Group, GroupId, Identity, Provider};
use tls_codec::Serialize;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub struct CandidateGroupOperation {
    provider: Option<Provider>,
    group: Option<Group>,
    result: Vec<u8>,
}

#[wasm_bindgen]
impl CandidateGroupOperation {
    /// Create an application message using a forked provider and a freshly
    /// loaded group. The original provider and group are not mutated.
    ///
    /// The returned object is uncommitted. Persist `snapshot_bytes()` first;
    /// only then take the provider/group handles and make them live.
    pub fn create_message(
        committed_provider: &Provider,
        group_id: &str,
        sender: &Identity,
        plaintext: &[u8],
    ) -> Result<CandidateGroupOperation, JsError> {
        let snapshot = committed_provider.export_snapshot_bytes()?;
        let candidate_provider = Provider::from_snapshot_bytes(&snapshot)?;
        let mut candidate_group = Group::load(&candidate_provider, group_id)?;

        let message = candidate_group
            .mls_group
            .create_message(candidate_provider.as_ref(), &sender.keypair, plaintext)
            .map_err(|e| JsError::new(&format!("Candidate MLS message creation failed: {e}")))?;

        let mut result = Vec::new();
        message
            .tls_serialize(&mut result)
            .map_err(|e| JsError::new(&format!("Candidate MLS message serialization failed: {e}")))?;

        Ok(CandidateGroupOperation {
            provider: Some(candidate_provider),
            group: Some(candidate_group),
            result,
        })
    }

    /// Return the full candidate provider snapshot. It contains private MLS
    /// key material and must be authenticated/encrypted before durable storage.
    pub fn snapshot_bytes(&self) -> Result<Vec<u8>, JsError> {
        self.provider
            .as_ref()
            .ok_or_else(|| JsError::new("Candidate provider was already taken."))?
            .export_snapshot_bytes()
    }

    /// Return the operation result. Do not publish it until the snapshot commit succeeds.
    pub fn result_bytes(&self) -> Vec<u8> {
        self.result.clone()
    }

    /// Transfer the candidate provider after the caller has durably committed
    /// the snapshot. Calling this before persistence violates the API contract.
    pub fn take_provider(&mut self) -> Result<Provider, JsError> {
        self.provider
            .take()
            .ok_or_else(|| JsError::new("Candidate provider was already taken."))
    }

    /// Transfer the candidate group after the caller has durably committed
    /// the matching provider snapshot.
    pub fn take_group(&mut self) -> Result<Group, JsError> {
        self.group
            .take()
            .ok_or_else(|| JsError::new("Candidate group was already taken."))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls::framing::{MlsMessageBodyIn, MlsMessageIn, ProcessedMessageContent};

    fn create_alice_bob() -> (Provider, Identity, Group, Provider, Group) {
        let mut alice_provider = Provider::new();
        let bob_provider = Provider::new();
        let alice = Identity::new(&alice_provider, "alice").unwrap();
        let bob = Identity::new(&bob_provider, "bob").unwrap();
        let mut alice_group = Group::create_new(&alice_provider, &alice, "candidate-group").unwrap();
        let bob_key_package = bob.key_package(&bob_provider).unwrap();
        let add = alice_group
            .native_propose_and_commit_add(&alice_provider, &alice, &bob_key_package)
            .unwrap();
        alice_group.merge_pending_commit(&mut alice_provider).unwrap();
        let tree = alice_group.export_ratchet_tree();
        let bob_group = Group::native_join(&bob_provider, &add.welcome, tree);
        (alice_provider, alice, alice_group, bob_provider, bob_group)
    }

    #[test]
    fn candidate_send_does_not_mutate_committed_provider_and_restores() {
        let (alice_provider, alice, _alice_group, mut bob_provider, mut bob_group) =
            create_alice_bob();
        let committed_before = alice_provider.export_snapshot_bytes().unwrap();

        let candidate = CandidateGroupOperation::create_message(
            &alice_provider,
            "candidate-group",
            &alice,
            b"candidate transaction message",
        )
        .unwrap();

        // The source provider remains byte-for-byte unchanged while the
        // candidate owns the advanced sending ratchet state.
        assert_eq!(
            committed_before,
            alice_provider.export_snapshot_bytes().unwrap()
        );

        let candidate_snapshot = candidate.snapshot_bytes().unwrap();
        let candidate_provider = Provider::from_snapshot_bytes(&candidate_snapshot).unwrap();
        let mut candidate_group = Group::load(&candidate_provider, "candidate-group").unwrap();

        let mut first_bytes = candidate.result_bytes().as_slice();
        let first_message = MlsMessageIn::tls_deserialize(&mut first_bytes).unwrap();
        let first_private = match first_message.extract() {
            MlsMessageBodyIn::PrivateMessage(message) => message,
            other => panic!("expected private MLS application message, got {other:?}"),
        };
        let first_processed = bob_group
            .mls_group
            .process_message(bob_provider.as_ref(), first_private)
            .unwrap();
        match first_processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => {
                assert_eq!(message.into_bytes(), b"candidate transaction message");
            }
            other => panic!("expected application content, got {other:?}"),
        }

        // A second message from the restored candidate proves its provider
        // snapshot contains the advanced sender ratchet state.
        let second = candidate_group
            .mls_group
            .create_message(
                candidate_provider.as_ref(),
                &alice.keypair,
                b"message after candidate restore",
            )
            .unwrap();
        let second_bytes = second.tls_serialize_detached().unwrap();
        let mut second_input = second_bytes.as_slice();
        let second_message = MlsMessageIn::tls_deserialize(&mut second_input).unwrap();
        let second_private = match second_message.extract() {
            MlsMessageBodyIn::PrivateMessage(message) => message,
            other => panic!("expected private MLS application message, got {other:?}"),
        };
        let second_processed = bob_group
            .mls_group
            .process_message(bob_provider.as_ref(), second_private)
            .unwrap();
        match second_processed.into_content() {
            ProcessedMessageContent::ApplicationMessage(message) => {
                assert_eq!(message.into_bytes(), b"message after candidate restore");
            }
            other => panic!("expected application content, got {other:?}"),
        }
    }

    #[test]
    fn candidate_operation_rejects_missing_group_without_mutating_source() {
        let (alice_provider, alice, _alice_group, _bob_provider, _bob_group) =
            create_alice_bob();
        let committed_before = alice_provider.export_snapshot_bytes().unwrap();

        let result = CandidateGroupOperation::create_message(
            &alice_provider,
            "missing-group",
            &alice,
            b"must not be sent",
        );

        assert!(result.is_err());
        assert_eq!(
            committed_before,
            alice_provider.export_snapshot_bytes().unwrap()
        );
    }
}
