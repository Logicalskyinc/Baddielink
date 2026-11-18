//! Candidate-state MLS operations.
//!
//! Each operation restores a private provider/group pair from the last committed
//! provider snapshot. The live pair is never mutated. The worker must durably
//! commit the candidate snapshot before calling commit_into() and publishing
//! result_bytes(). This is an experimental first slice, not a complete transaction layer.

use super::{Group, Identity, Provider};
use tls_codec::Serialize;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
pub struct CandidateGroupOperation {
    provider: Option<Provider>,
    group: Option<Group>,
    result: Vec<u8>,
    committed: bool,
}

#[wasm_bindgen]
impl CandidateGroupOperation {
    /// Create an application message using a forked provider and a freshly
    /// loaded group. The original provider and group are not mutated.
    ///
    /// The returned object is uncommitted. The worker must persist
    /// snapshot_bytes() before installing the candidate pair.
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
            committed: false,
        })
    }

    /// Return the full candidate provider snapshot. It contains private MLS
    /// key material. In the browser architecture this method may only be
    /// called by the dedicated runtime worker, never by the page.
    pub fn snapshot_bytes(&self) -> Result<Vec<u8>, JsError> {
        if self.committed {
            return Err(JsError::new("Candidate state was already committed."));
        }
        self.provider
            .as_ref()
            .ok_or_else(|| JsError::new("Candidate provider is unavailable."))?
            .export_snapshot_bytes()
    }

    /// Atomically replace the live provider and group pair after the caller
    /// has durably committed snapshot_bytes(). There is deliberately no API
    /// to take either handle independently.
    pub fn commit_into(
        &mut self,
        committed_provider: &mut Provider,
        committed_group: &mut Group,
    ) -> Result<(), JsError> {
        if self.committed {
            return Err(JsError::new("Candidate state was already committed."));
        }
        if self.provider.is_none() || self.group.is_none() {
            return Err(JsError::new("Candidate provider/group pair is incomplete."));
        }

        // Both handles are checked before either is moved. No fallible work
        // remains between taking the pair and replacing the live pair.
        let candidate_provider = self.provider.take()
            .ok_or_else(|| JsError::new("Candidate provider is unavailable."))?;
        let candidate_group = self.group.take()
            .ok_or_else(|| JsError::new("Candidate group is unavailable."))?;

        *committed_provider = candidate_provider;
        *committed_group = candidate_group;
        self.committed = true;
        Ok(())
    }

    /// The ciphertext is publishable only after commit_into() succeeds.
    pub fn result_bytes(&self) -> Result<Vec<u8>, JsError> {
        if !self.committed {
            return Err(JsError::new("Candidate result cannot be published before durable commit."));
        }
        Ok(self.result.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use openmls::framing::{MlsMessageBodyIn, MlsMessageIn, ProcessedMessageContent};
    use tls_codec::Deserialize;

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
    fn candidate_send_requires_commit_and_replaces_provider_group_together() {
        let (mut alice_provider, alice, mut alice_group, bob_provider, mut bob_group) =
            create_alice_bob();
        let committed_before = alice_provider.export_snapshot_bytes().unwrap();
        let committed_epoch = alice_group.mls_group.epoch();

        let mut candidate = CandidateGroupOperation::create_message(
            &alice_provider,
            "candidate-group",
            &alice,
            b"candidate transaction message",
        )
        .unwrap();

        assert!(
            candidate.result_bytes().is_err(),
            "candidate ciphertext must not be available before durable commit"
        );

        // Candidate work must not mutate the live provider or group.
        assert_eq!(
            committed_before,
            alice_provider.export_snapshot_bytes().unwrap()
        );
        assert_eq!(committed_epoch, alice_group.mls_group.epoch());

        // Simulate the persistence layer validating the exact snapshot it
        // intends to commit before the live pair is replaced.
        let candidate_snapshot = candidate.snapshot_bytes().unwrap();
        let restored_provider = Provider::from_snapshot_bytes(&candidate_snapshot).unwrap();
        let _restored_group = Group::load(&restored_provider, "candidate-group").unwrap();

        candidate.commit_into(&mut alice_provider, &mut alice_group).unwrap();
        assert!(candidate.snapshot_bytes().is_err());
        assert!(candidate.commit_into(&mut alice_provider, &mut alice_group).is_err());

        let first_result = candidate.result_bytes().unwrap();
        let mut first_bytes = first_result.as_slice();
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

        // The installed provider/group pair can continue sending. This checks
        // that the sending ratchet state moved together with the provider.
        let second = alice_group
            .mls_group
            .create_message(
                alice_provider.as_ref(),
                &alice.keypair,
                b"message after candidate commit",
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
                assert_eq!(message.into_bytes(), b"message after candidate commit");
            }
            other => panic!("expected application content, got {other:?}"),
        }
    }
}
