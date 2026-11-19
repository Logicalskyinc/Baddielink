mod opfs_bridge;
mod candidate_operations;
mod utils;

use js_sys::Uint8Array;
use openmls::{
    credentials::{BasicCredential, CredentialWithKey},
    framing::{MlsMessageBodyIn, MlsMessageIn, MlsMessageOut},
    group::{GroupId, MlsGroup, MlsGroupJoinConfig, StagedWelcome},
    key_packages::KeyPackage as OpenMlsKeyPackage,
    prelude::{LeafNodeIndex, SignatureScheme},
    treesync::RatchetTreeIn,
};
use openmls_basic_credential::SignatureKeyPair;
use openmls_memory_storage::MemoryStorage;
use openmls_rust_crypto::RustCrypto;
use openmls_traits::{types::Ciphersuite, OpenMlsProvider};
use tls_codec::{Deserialize, Serialize};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    fn alert(s: &str);

    // Use `js_namespace` here to bind `console.log(..)` instead of just
    // `log(..)`
    #[wasm_bindgen(js_namespace = console)]
    fn log(s: &str);
}

/// The ciphersuite used here. Fixed in order to reduce the binary size.
static CIPHERSUITE: Ciphersuite = Ciphersuite::MLS_128_DHKEMX25519_CHACHA20POLY1305_SHA256_Ed25519;

#[wasm_bindgen]
pub struct Provider {
    crypto: RustCrypto,
    storage: MemoryStorage,
}

impl Default for Provider {
    fn default() -> Self {
        Self { crypto: RustCrypto::default(), storage: MemoryStorage::default() }
    }
}

impl OpenMlsProvider for Provider {
    type CryptoProvider = RustCrypto;
    type RandProvider = RustCrypto;
    type StorageProvider = MemoryStorage;
    fn storage(&self) -> &Self::StorageProvider { &self.storage }
    fn crypto(&self) -> &Self::CryptoProvider { &self.crypto }
    fn rand(&self) -> &Self::RandProvider { &self.crypto }
}

impl AsRef<Provider> for Provider {
    fn as_ref(&self) -> &Provider { self }
}
impl AsMut<Provider> for Provider {
    fn as_mut(&mut self) -> &mut Provider { self }
}

#[cfg(test)]
impl Provider {
    // Test-only checkpoint: snapshots contain private MLS key material and
    // must not be persisted without authenticated encryption and device-key management.
    fn snapshot_for_test(&self) -> Vec<u8> {
        let values = self.storage.values.read().expect("MLS storage lock poisoned");
        let mut encoded = Vec::new();
        ciborium::ser::into_writer(&*values, &mut encoded)
            .expect("MLS storage snapshot serialization failed");
        encoded
    }

    fn restore_for_test(snapshot: &[u8]) -> Self {
        let values: std::collections::HashMap<Vec<u8>, Vec<u8>> =
            ciborium::de::from_reader(snapshot).expect("MLS storage snapshot deserialization failed");
        let storage = MemoryStorage::default();
        *storage.values.write().expect("MLS storage lock poisoned") = values;
        Self { crypto: RustCrypto::default(), storage }
    }
}

#[wasm_bindgen]
impl Provider {
    #[wasm_bindgen(constructor)]
    pub fn new() -> Self { Self::default() }

    /// Export raw OpenMLS storage bytes. The caller MUST encrypt these bytes
    /// with an authenticated, device-bound key before writing them to storage.
    /// This method is intended for the isolated persistence experiment.
    pub fn export_snapshot_bytes(&self) -> Result<Vec<u8>, JsError> {
        let values = self.storage.values.read()
            .map_err(|_| JsError::new("MLS storage lock is poisoned."))?;
        let mut encoded = Vec::new();
        ciborium::ser::into_writer(&*values, &mut encoded)
            .map_err(|e| JsError::new(&format!("MLS snapshot serialization failed: {e}")))?;
        Ok(encoded)
    }

    /// Restore a provider from decrypted snapshot bytes. The caller must
    /// authenticate and decrypt the snapshot before invoking this method.
    pub fn from_snapshot_bytes(snapshot: &[u8]) -> Result<Provider, JsError> {
        let values: std::collections::HashMap<Vec<u8>, Vec<u8>> =
            ciborium::de::from_reader(snapshot)
                .map_err(|e| JsError::new(&format!("MLS snapshot is invalid: {e}")))?;
        let storage = MemoryStorage::default();
        *storage.values.write()
            .map_err(|_| JsError::new("MLS storage lock is poisoned."))? = values;
        Ok(Provider { crypto: RustCrypto::default(), storage })
    }
}

#[wasm_bindgen]
pub fn greet() {
    alert("Hello, openmls!");
}

#[wasm_bindgen]
pub struct Identity {
    credential_with_key: CredentialWithKey,
    keypair: openmls_basic_credential::SignatureKeyPair,
}

#[wasm_bindgen]
impl Identity {
    #[wasm_bindgen(constructor)]
    pub fn new(provider: &Provider, name: &str) -> Result<Identity, JsError> {
        let signature_scheme = SignatureScheme::ED25519;
        let identity = name.bytes().collect();
        let credential = BasicCredential::new(identity);
        let keypair = SignatureKeyPair::new(signature_scheme)?;

        keypair.store(provider.storage())?;

        let credential_with_key = CredentialWithKey {
            credential: credential.into(),
            signature_key: keypair.public().into(),
        };

        Ok(Identity {
            credential_with_key,
            keypair,
        })
    }

    pub fn key_package(&self, provider: &Provider) -> Result<KeyPackage, JsError> {
        let bundle = OpenMlsKeyPackage::builder()
            .build(
                CIPHERSUITE,
                provider,
                &self.keypair,
                self.credential_with_key.clone(),
            )
            .map_err(|e| JsError::new(&format!("Key package creation failed: {e}")))?;
        Ok(KeyPackage(bundle.key_package().clone()))
    }
}

#[wasm_bindgen]
pub struct Group {
    mls_group: MlsGroup,
}

#[wasm_bindgen]
pub struct AddMessages {
    proposal: Uint8Array,
    commit: Uint8Array,
    welcome: Uint8Array,
}

#[cfg(test)]
#[allow(dead_code)]
struct NativeAddMessages {
    proposal: Vec<u8>,
    commit: Vec<u8>,
    welcome: Vec<u8>,
}

#[wasm_bindgen]
impl AddMessages {
    #[wasm_bindgen(getter)]
    pub fn proposal(&self) -> Uint8Array {
        self.proposal.clone()
    }
    #[wasm_bindgen(getter)]
    pub fn commit(&self) -> Uint8Array {
        self.commit.clone()
    }
    #[wasm_bindgen(getter)]
    pub fn welcome(&self) -> Uint8Array {
        self.welcome.clone()
    }
}

#[wasm_bindgen]
impl Group {
    /// Reload a previously persisted group from the provider's restored storage.
    pub fn load(provider: &Provider, group_id: &str) -> Result<Group, JsError> {
        let group_id = GroupId::from_slice(group_id.as_bytes());
        let mls_group = MlsGroup::load(provider.storage(), &group_id)
            .map_err(|e| JsError::new(&format!("MLS group load failed: {e}")))?
            .ok_or_else(|| JsError::new("MLS group was not found in restored storage."))?;
        Ok(Group { mls_group })
    }

    pub fn create_new(provider: &Provider, founder: &Identity, group_id: &str) -> Result<Group, JsError> {
        let group_id_bytes = group_id.bytes().collect::<Vec<_>>();

        let mls_group = MlsGroup::builder()
            .ciphersuite(CIPHERSUITE)
            .with_group_id(GroupId::from_slice(&group_id_bytes))
            .build(
                provider,
                &founder.keypair,
                founder.credential_with_key.clone(),
            )
            .map_err(|e| JsError::new(&format!("MLS group creation failed: {e}")))?;

        Ok(Group { mls_group })
    }
    pub fn join(
        provider: &Provider,
        mut welcome: &[u8],
        ratchet_tree: RatchetTree,
    ) -> Result<Group, JsError> {
        let welcome = match MlsMessageIn::tls_deserialize(&mut welcome)?.extract() {
            MlsMessageBodyIn::Welcome(welcome) => Ok(welcome),
            other => Err(openmls::error::ErrorString::from(format!(
                "expected a message of type welcome, got {other:?}",
            ))),
        }?;
        let config = MlsGroupJoinConfig::builder().build();
        let mls_group =
            StagedWelcome::new_from_welcome(provider, &config, welcome, Some(ratchet_tree.0))?
                .into_group(provider)?;

        Ok(Group { mls_group })
    }

    pub fn export_ratchet_tree(&self) -> RatchetTree {
        RatchetTree(self.mls_group.export_ratchet_tree().into())
    }

    pub fn propose_and_commit_add(
        &mut self,
        provider: &Provider,
        sender: &Identity,
        new_member: &KeyPackage,
    ) -> Result<AddMessages, JsError> {
        // Use OpenMLS' atomic membership API. A proposal created with
        // propose_add_member() is not automatically queued locally or delivered
        // to existing members. A Commit that references that proposal would
        // therefore be rejected by recipients that never received it.
        let (commit_msg, welcome_msg, _group_info) = self
            .mls_group
            .add_members(
                provider.as_ref(),
                &sender.keypair,
                std::slice::from_ref(&new_member.0),
            )
            .map_err(|e| JsError::new(&format!("add_members failed: {e}")))?;

        let proposal = Uint8Array::new_with_length(0);
        let commit = mls_message_to_uint8array(&commit_msg)?;
        let welcome = mls_message_to_uint8array(&welcome_msg)?;

        Ok(AddMessages {
            proposal,
            commit,
            welcome,
        })
    }

    /// Remove a member by its BasicCredential identity and return the serialized Commit.
    /// Resolving the credential inside the current group avoids trusting a caller-supplied
    /// leaf index that may be stale after prior membership changes. Duplicate identities
    /// are rejected so a caller can never accidentally remove an arbitrary matching leaf.
    pub fn remove_member_by_identity(
        &mut self,
        provider: &Provider,
        sender: &Identity,
        member_identity: &str,
    ) -> Result<Vec<u8>, JsError> {
        let member_index = self
            .find_unique_member_index_by_identity(member_identity)
            .map_err(JsError::new)?;

        let (commit, _welcome, _group_info) = self.mls_group.remove_members(
            provider,
            &sender.keypair,
            &[member_index],
        ).map_err(|e| JsError::new(&format!("MLS member removal failed: {e}")))?;

        let mut serialized = Vec::new();
        commit.tls_serialize(&mut serialized)
            .map_err(|e| JsError::new(&format!("MLS removal Commit serialization failed: {e}")))?;
        Ok(serialized)
    }

    pub fn is_active(&self) -> bool {
        self.mls_group.is_active()
    }

    pub fn merge_pending_commit(&mut self, provider: &mut Provider) -> Result<(), JsError> {
        self.mls_group
            .merge_pending_commit(provider.as_mut())
            .map_err(|e| JsError::new(&format!("merge_pending_commit failed: {e}")))
    }

    pub fn create_message(
        &mut self,
        provider: &Provider,
        sender: &Identity,
        msg: &[u8],
    ) -> Result<Vec<u8>, JsError> {
        let msg_out = &self
            .mls_group
            .create_message(provider.as_ref(), &sender.keypair, msg)?;
        let mut serialized = vec![];
        msg_out.tls_serialize(&mut serialized)?;
        Ok(serialized)
    }

    pub fn process_message(
        &mut self,
        provider: &mut Provider,
        mut msg: &[u8],
    ) -> Result<Vec<u8>, JsError> {
        let msg = MlsMessageIn::tls_deserialize(&mut msg)?;

        let msg = match msg.extract() {
            openmls::framing::MlsMessageBodyIn::PublicMessage(msg) => {
                self.mls_group.process_message(provider.as_ref(), msg)?
            }

            openmls::framing::MlsMessageBodyIn::PrivateMessage(msg) => {
                self.mls_group.process_message(provider.as_ref(), msg)?
            }
            openmls::framing::MlsMessageBodyIn::Welcome(_) => {
                return Err(JsError::new("Welcome messages must be processed through the join flow."));
            }
            openmls::framing::MlsMessageBodyIn::GroupInfo(_) => {
                return Err(JsError::new("Standalone GroupInfo messages are not accepted by this API."));
            }
            openmls::framing::MlsMessageBodyIn::KeyPackage(_) => {
                return Err(JsError::new("KeyPackage messages are not accepted by the group message API."));
            }
            #[cfg(feature = "targeted-messages-draft")]
            openmls::framing::MlsMessageBodyIn::TargetedMessage(_) => {
                return Err(JsError::new("Targeted MLS messages are not supported by this prototype."));
            }
        };

        match msg.into_content() {
            openmls::framing::ProcessedMessageContent::ApplicationMessage(app_msg) => {
                Ok(app_msg.into_bytes())
            }
            openmls::framing::ProcessedMessageContent::ProposalMessage(proposal)
            | openmls::framing::ProcessedMessageContent::ExternalJoinProposalMessage(proposal) => {
                self.mls_group
                    .store_pending_proposal(provider.storage(), *proposal)?;
                Ok(vec![])
            }
            openmls::framing::ProcessedMessageContent::StagedCommitMessage(staged_commit) => {
                self.mls_group
                    .merge_staged_commit(provider.as_mut(), *staged_commit)?;
                Ok(vec![])
            }
            openmls::framing::ProcessedMessageContent::OwnPendingCommit => {
                self.mls_group.merge_pending_commit(provider.as_mut())?;
                Ok(vec![])
            }
            // Own PrivateMessages echoed by the DS cannot be decrypted, so skip
            // them.
            openmls::framing::ProcessedMessageContent::OwnPrivateMessage => Ok(vec![]),
            #[cfg(feature = "extensions-draft")]
            openmls::framing::ProcessedMessageContent::UnresolvedAppDataCommit(_) => {
                return Err(JsError::new("AppDataUpdate proposals are not supported by this prototype."));
            }
        }
    }

    pub fn export_key(
        &self,
        provider: &Provider,
        label: &str,
        context: &[u8],
        key_length: usize,
    ) -> Result<Vec<u8>, JsError> {
        self.mls_group
            .export_secret(provider.as_ref().crypto(), label, context, key_length)
            .map(|secret| secret.as_slice().to_vec())
            .map_err(|e| {
                println!("export key error: {e}");
                e.into()
            })
    }
}

impl Group {
    fn find_unique_member_index_by_identity(
        &self,
        member_identity: &str,
    ) -> Result<LeafNodeIndex, &'static str> {
        let mut matches = self.mls_group.members().filter(|member| {
            member.credential.serialized_content() == member_identity.as_bytes()
        });
        let member_index = matches
            .next()
            .map(|member| member.index)
            .ok_or("Requested MLS member identity was not found.")?;
        if matches.next().is_some() {
            return Err("MLS member identity is ambiguous; refusing to remove a member.");
        }
        Ok(member_index)
    }
}

#[cfg(test)]
impl Group {
    fn native_propose_and_commit_add(
        &mut self,
        provider: &Provider,
        sender: &Identity,
        new_member: &KeyPackage,
    ) -> Result<NativeAddMessages, JsError> {
        let (proposal_msg, _proposal_ref) =
            self.mls_group
                .propose_add_member(provider.as_ref(), &sender.keypair, &new_member.0)?;

        let (commit_msg, welcome_msg, _group_info) = self
            .mls_group
            .commit_to_pending_proposals(provider.as_ref(), &sender.keypair)?;

        let welcome_msg = welcome_msg.ok_or(NoWelcomeError)?;

        let proposal = mls_message_to_u8vec(&proposal_msg);
        let commit = mls_message_to_u8vec(&commit_msg);
        let welcome = mls_message_to_u8vec(&welcome_msg);

        Ok(NativeAddMessages {
            proposal,
            commit,
            welcome,
        })
    }

    fn native_remove_member(
        &mut self,
        provider: &Provider,
        sender: &Identity,
        member_index: LeafNodeIndex,
    ) -> Result<Vec<u8>, JsError> {
        let (commit, _welcome, _group_info) = self.mls_group.remove_members(
            provider,
            &sender.keypair,
            &[member_index],
        )?;
        let mut serialized = Vec::new();
        commit.tls_serialize(&mut serialized)?;
        Ok(serialized)
    }

    fn native_join(provider: &Provider, mut welcome: &[u8], ratchet_tree: RatchetTree) -> Group {
        let welcome = match MlsMessageIn::tls_deserialize(&mut welcome)
            .expect("could not deserialize Welcome message")
            .extract()
        {
            MlsMessageBodyIn::Welcome(welcome) => welcome,
            _ => panic!("expected a message of type welcome"),
        };
        let config = MlsGroupJoinConfig::builder().build();
        let mls_group = StagedWelcome::new_from_welcome(
            provider.as_ref(),
            &config,
            welcome,
            Some(ratchet_tree.0),
        )
        .unwrap()
        .into_group(provider.as_ref())
        .unwrap();

        Group { mls_group }
    }
}

#[wasm_bindgen]
#[derive(Debug)]
pub struct NoWelcomeError;

impl std::fmt::Display for NoWelcomeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "no welcome")
    }
}

impl std::error::Error for NoWelcomeError {}

#[wasm_bindgen]
pub struct KeyPackage(OpenMlsKeyPackage);

#[wasm_bindgen]
impl KeyPackage {
    /// Serialize this KeyPackage to bytes
    #[wasm_bindgen]
    pub fn to_bytes(&self) -> Result<Vec<u8>, JsError> {
        self.0
            .tls_serialize_detached()
            .map_err(|e| JsError::new(&format!("KeyPackage serialization failed: {e}")))
    }

    /// Deserialize a KeyPackage from bytes
    #[wasm_bindgen]
    pub fn from_bytes(bytes: &[u8]) -> Result<KeyPackage, JsError> {
        let mut s = bytes;
        let kp_in = openmls::key_packages::KeyPackageIn::tls_deserialize(&mut s)
            .map_err(|e| JsError::new(&format!("KeyPackage deserialization error: {e}")))?;
        let kp = kp_in
            .validate(
                &openmls_rust_crypto::RustCrypto::default(),
                openmls::prelude::ProtocolVersion::Mls10,
            )
            .map_err(|e| JsError::new(&format!("KeyPackage validation error: {e}")))?;
        Ok(KeyPackage(kp))
    }
}

#[wasm_bindgen]
pub struct RatchetTree(RatchetTreeIn);

#[wasm_bindgen]
impl RatchetTree {
    /// Serialize this RatchetTree to bytes
    #[wasm_bindgen]
    pub fn to_bytes(&self) -> Result<Vec<u8>, JsError> {
        self.0
            .tls_serialize_detached()
            .map_err(|e| JsError::new(&format!("RatchetTree serialization failed: {e}")))
    }

    /// Deserialize a RatchetTree from bytes
    #[wasm_bindgen]
    pub fn from_bytes(bytes: &[u8]) -> Result<RatchetTree, JsError> {
        let mut s = bytes;
        let tree = RatchetTreeIn::tls_deserialize(&mut s)
            .map_err(|e| JsError::new(&format!("RatchetTree deserialization error: {e}")))?;
        Ok(RatchetTree(tree))
    }
}

fn mls_message_to_uint8array(msg: &MlsMessageOut) -> Result<Uint8Array, JsError> {
    // see https://github.com/rustwasm/wasm-bindgen/issues/1619#issuecomment-505065294

    let mut serialized = vec![];
    msg.tls_serialize(&mut serialized)
        .map_err(|e| JsError::new(&format!("MLS message serialization failed: {e}")))?;

    Ok(unsafe { Uint8Array::new(&Uint8Array::view(&serialized)) })
}

#[cfg(test)]
fn mls_message_to_u8vec(msg: &MlsMessageOut) -> Vec<u8> {
    // see https://github.com/rustwasm/wasm-bindgen/issues/1619#issuecomment-505065294

    let mut serialized = vec![];
    msg.tls_serialize(&mut serialized).unwrap();
    serialized
}

#[cfg(test)]
mod tests {
    use super::*;

    fn js_error_to_string(e: JsError) -> String {
        let v: JsValue = e.into();
        v.as_string().unwrap()
    }

    fn create_group_alice_and_bob() -> (Provider, Identity, Group, Provider, Identity, Group) {
        let mut alice_provider = Provider::new();
        let bob_provider = Provider::new();

        let alice = Identity::new(&alice_provider, "alice")
            .map_err(js_error_to_string)
            .unwrap();
        let bob = Identity::new(&bob_provider, "bob")
            .map_err(js_error_to_string)
            .unwrap();

        let mut chess_club_alice = Group::create_new(&alice_provider, &alice, "chess club").unwrap();

        let bob_key_pkg = bob.key_package(&bob_provider).unwrap();

        let add_msgs = chess_club_alice
            .native_propose_and_commit_add(&alice_provider, &alice, &bob_key_pkg)
            .map_err(js_error_to_string)
            .unwrap();

        chess_club_alice
            .merge_pending_commit(&mut alice_provider)
            .map_err(js_error_to_string)
            .unwrap();

        let ratchet_tree = chess_club_alice.export_ratchet_tree();

        let chess_club_bob = Group::native_join(&bob_provider, &add_msgs.welcome, ratchet_tree);

        (
            alice_provider,
            alice,
            chess_club_alice,
            bob_provider,
            bob,
            chess_club_bob,
        )
    }

    #[test]
    fn basic() {
        let (alice_provider, _, chess_club_alice, bob_provider, _, chess_club_bob) =
            create_group_alice_and_bob();

        let bob_exported_key = chess_club_bob
            .export_key(&bob_provider, "chess_key", &[0x30], 32)
            .map_err(js_error_to_string)
            .unwrap();
        let alice_exported_key = chess_club_alice
            .export_key(&alice_provider, "chess_key", &[0x30], 32)
            .map_err(js_error_to_string)
            .unwrap();

        assert_eq!(bob_exported_key, alice_exported_key);
    }

    #[test]
    fn duplicate_member_identity_is_rejected_for_removal() {
        let (mut alice_provider, alice, mut alice_group, _bob_provider, _bob, _bob_group) =
            create_group_alice_and_bob();

        let duplicate_provider = Provider::new();
        let duplicate_bob = Identity::new(&duplicate_provider, "bob")
            .map_err(js_error_to_string)
            .unwrap();
        let duplicate_key_package = duplicate_bob.key_package(&duplicate_provider).unwrap();
        alice_group
            .native_propose_and_commit_add(
                &alice_provider,
                &alice,
                &duplicate_key_package,
            )
            .map_err(js_error_to_string)
            .unwrap();
        alice_group
            .merge_pending_commit(&mut alice_provider)
            .map_err(js_error_to_string)
            .unwrap();

        let result = alice_group.find_unique_member_index_by_identity("bob");
        assert!(matches!(
            result,
            Err("MLS member identity is ambiguous; refusing to remove a member.")
        ));
    }

    #[test]
    fn remove_member_rotates_epoch_and_evicts_removed_member() {
        let (
            mut alice_provider,
            alice,
            mut alice_group,
            mut bob_provider,
            bob,
            mut bob_group,
        ) = create_group_alice_and_bob();

        let previous_epoch = alice_group.mls_group.epoch();
        let previous_export = alice_group
            .export_key(&alice_provider, "removal_check", &[0x41], 32)
            .map_err(js_error_to_string)
            .unwrap();

        // Bob's own leaf index is the index Alice must remove from this group.
        let bob_leaf_index = bob_group.mls_group.own_leaf_index();
        let removal_commit = alice_group
            .native_remove_member(&alice_provider, &alice, bob_leaf_index)
            .map_err(js_error_to_string)
            .unwrap();

        alice_group
            .merge_pending_commit(&mut alice_provider)
            .map_err(js_error_to_string)
            .unwrap();
        // The removed member can authenticate and stage the Commit, but
        // merging it must evict its own leaf and deactivate the local group.
        let mut removal_commit_bytes = removal_commit.as_slice();
        let removal_message =
            MlsMessageIn::tls_deserialize(&mut removal_commit_bytes).unwrap();
        match removal_message.extract() {
            MlsMessageBodyIn::PrivateMessage(private_message) => {
                let processed = bob_group
                    .mls_group
                    .process_message(bob_provider.as_ref(), private_message)
                    .unwrap();
                match processed.into_content() {
                    openmls::framing::ProcessedMessageContent::StagedCommitMessage(staged) => {
                        bob_group
                            .mls_group
                            .merge_staged_commit(bob_provider.as_mut(), *staged)
                            .unwrap();
                    }
                    other => panic!("expected a staged removal Commit, got {other:?}"),
                }
            }
            other => panic!("expected a private removal Commit, got {other:?}"),
        }

        assert_ne!(alice_group.mls_group.epoch(), previous_epoch);
        assert_eq!(bob_group.mls_group.epoch(), alice_group.mls_group.epoch());
        assert!(!bob_group.mls_group.is_active(), "removed member remained active after merging the Commit");

        let current_export = alice_group
            .export_key(&alice_provider, "removal_check", &[0x41], 32)
            .map_err(js_error_to_string)
            .unwrap();
        assert_ne!(previous_export, current_export);

        // OpenMLS marks the removed member's local group as inactive.
        // Sending from that evicted group must fail closed.
        let stale_send = bob_group
            .mls_group
            .create_message(bob_provider.as_ref(), &bob.keypair, b"stale epoch");
        assert!(
            stale_send.is_err(),
            "removed member was able to send from an evicted group"
        );

        let post_removal_message = alice_group
            .create_message(&alice_provider, &alice, b"new epoch only")
            .map_err(js_error_to_string)
            .unwrap();
        let mut post_removal_bytes = post_removal_message.as_slice();
        let post_removal_message =
            MlsMessageIn::tls_deserialize(&mut post_removal_bytes).unwrap();
        match post_removal_message.extract() {
            MlsMessageBodyIn::PrivateMessage(private_message) => {
                let result = bob_group
                    .mls_group
                    .process_message(bob_provider.as_ref(), private_message);
                assert!(result.is_err(), "removed member accepted a post-removal message");
            }
            other => panic!("expected a private post-removal message, got {other:?}"),
        }
    }

    #[test]
    fn rejects_replayed_application_message() {
        let (_alice_provider, alice, mut alice_group, mut bob_provider, _bob, mut bob_group) =
            create_group_alice_and_bob();

        let plaintext = b"replay protection check";
        let encrypted = alice_group
            .create_message(&_alice_provider, &alice, plaintext)
            .map_err(js_error_to_string)
            .unwrap();

        // Exercise OpenMLS directly here. The browser-facing wrapper maps
        // errors to JsError, which is only callable on wasm32 targets.
        let mut first_bytes = encrypted.as_slice();
        let first_message = MlsMessageIn::tls_deserialize(&mut first_bytes).unwrap();
        let first_private = match first_message.extract() {
            MlsMessageBodyIn::PrivateMessage(message) => message,
            other => panic!("expected a private application message, got {other:?}"),
        };
        let first_delivery = bob_group
            .mls_group
            .process_message(bob_provider.as_ref(), first_private)
            .unwrap();
        match first_delivery.into_content() {
            openmls::framing::ProcessedMessageContent::ApplicationMessage(message) => {
                assert_eq!(message.into_bytes(), plaintext);
            }
            other => panic!("expected application plaintext, got {other:?}"),
        }

        // Deserialize the exact same ciphertext again and pass it directly to
        // OpenMLS. The replay must be rejected by the MLS ratchet state.
        let mut replay_bytes = encrypted.as_slice();
        let replay_message = MlsMessageIn::tls_deserialize(&mut replay_bytes).unwrap();
        let replay_private = match replay_message.extract() {
            MlsMessageBodyIn::PrivateMessage(message) => message,
            other => panic!("expected a replayed private message, got {other:?}"),
        };
        let replay_result = bob_group
            .mls_group
            .process_message(bob_provider.as_ref(), replay_private);
        assert!(
            replay_result.is_err(),
            "OpenMLS accepted an already-processed application message"
        );
    }

    #[test]
    fn provider_snapshot_restores_group_and_message_processing() {
        let (alice_provider, alice, mut alice_group, bob_provider, _bob, bob_group) =
            create_group_alice_and_bob();
        let group_id = GroupId::from_slice(b"chess club");
        let snapshot = bob_provider.snapshot_for_test();

        // Simulate a full process restart before restoring the provider/group.
        drop(bob_group);
        drop(bob_provider);

        let restored_provider = Provider::restore_for_test(&snapshot);
        let mut restored_group = MlsGroup::load(restored_provider.storage(), &group_id)
            .expect("restored MLS group load failed")
            .expect("restored MLS group was missing");

        let plaintext = b"message after provider restart";
        let encrypted = alice_group
            .create_message(&alice_provider, &alice, plaintext)
            .expect("Alice message creation failed");
        let mut encrypted_bytes = encrypted.as_slice();
        let message = MlsMessageIn::tls_deserialize(&mut encrypted_bytes)
            .expect("message deserialization failed");
        let private_message = match message.extract() {
            MlsMessageBodyIn::PrivateMessage(message) => message,
            other => panic!("expected a private application message, got {other:?}"),
        };

        let processed = restored_group
            .process_message(&restored_provider, private_message)
            .expect("restored group failed to process message");
        match processed.into_content() {
            openmls::framing::ProcessedMessageContent::ApplicationMessage(message) => {
                assert_eq!(message.into_bytes(), plaintext);
            }
            other => panic!("expected application plaintext after restore, got {other:?}"),
        }
    }

    #[test]
    fn create_message() {
        let (alice_provider, alice, mut chess_club_alice, mut bob_provider, _, mut chess_club_bob) =
            create_group_alice_and_bob();

        let alice_msg = "hello, bob!".as_bytes();
        let msg_out = chess_club_alice
            .create_message(&alice_provider, &alice, alice_msg)
            .map_err(js_error_to_string)
            .unwrap();

        let bob_msg = chess_club_bob
            .process_message(&mut bob_provider, &msg_out)
            .map_err(js_error_to_string)
            .unwrap();

        assert_eq!(alice_msg, bob_msg);
    }
}
