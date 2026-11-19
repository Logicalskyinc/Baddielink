import init, {
  CandidateGroupOperation,
  Group,
  Identity,
  KeyPackage,
  Provider,
  RatchetTree
} from "./openmls_wasm.js";

const DB_NAME = "baddielink-mls-runtime-v1";
const KEY_STORE = "device-keys";
const JOURNAL_WORKER_URL = "./opfs-journal-worker.js";

let provider = null;
let identity = null;
let group = null;
let metadata = null;
let encryptionKey = null;
let journal = null;
let generation = null;
let ready = false;
let queue = Promise.resolve();
let journalSequence = 0;
const journalPending = new Map();

function validateIdentifier(value, label) {
  if (typeof value !== "string" || !/^[a-zA-Z0-9_-]{1,64}$/.test(value)) {
    throw new Error(`Invalid ${label}.`);
  }
  return value;
}

function openKeyDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => {
      if (!request.result.objectStoreNames.contains(KEY_STORE)) {
        request.result.createObjectStore(KEY_STORE);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error || new Error("Could not open device-key database."));
  });
}

async function readKeyRecord(db, keyId) {
  return new Promise((resolve, reject) => {
    const request = db.transaction(KEY_STORE, "readonly").objectStore(KEY_STORE).get(keyId);
    request.onsuccess = () => resolve(request.result || null);
    request.onerror = () => reject(request.error || new Error("Could not read device-key record."));
  });
}

async function writeKeyRecord(db, keyId, record) {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(KEY_STORE, "readwrite");
    tx.objectStore(KEY_STORE).put(record, keyId);
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error || new Error("Could not store device-key record."));
    tx.onabort = () => reject(tx.error || new Error("Device-key transaction was aborted."));
  });
}

async function makeJournalName(accountId, deviceId) {
  const input = new TextEncoder().encode(`baddielink|runtime|v1|${accountId}|${deviceId}`);
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", input));
  const suffix = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
  return `baddielink-mls-${suffix}.journal`;
}

function startJournalWorker() {
  if (journal) return;
  journal = new Worker(new URL(JOURNAL_WORKER_URL, import.meta.url), { type: "module" });
  journal.addEventListener("message", ({ data }) => {
    const pending = journalPending.get(data.id);
    if (!pending) return;
    journalPending.delete(data.id);
    if (data.ok) {
      pending.resolve(data);
    } else {
      const error = new Error(data.error || "OPFS journal operation failed.");
      error.name = data.errorName || "Error";
      error.commitMayHaveSucceeded = data.commitMayHaveSucceeded === true;
      pending.reject(error);
    }
  });
  journal.addEventListener("error", event => {
    for (const pending of journalPending.values()) pending.reject(new Error(event.message || "OPFS journal worker failed."));
    journalPending.clear();
    ready = false;
  });
}

function journalRequest(action, payload = {}) {
  if (!journal) throw new Error("OPFS journal worker is not running.");
  const id = `journal-${++journalSequence}`;
  return new Promise((resolve, reject) => {
    journalPending.set(id, { resolve, reject });
    journal.postMessage({ id, action, ...payload });
  });
}

function aadBytes() {
  return new TextEncoder().encode(
    `baddielink|runtime|v1|${metadata.accountId}|${metadata.deviceId}`
  );
}

function bytesToBase64(bytes) {
  const input = new Uint8Array(bytes);
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < input.length; offset += chunkSize) {
    binary += String.fromCharCode(...input.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

function base64ToBytes(value) {
  const binary = atob(value);
  const output = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index++) output[index] = binary.charCodeAt(index);
  return output;
}

async function encryptSnapshot(snapshotBytes, groupId = null) {
  const payload = new TextEncoder().encode(JSON.stringify({
    version: 1,
    groupId,
    providerSnapshot: bytesToBase64(snapshotBytes)
  }));
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: aadBytes(), tagLength: 128 },
    encryptionKey,
    payload
  );
  const ciphertext = new Uint8Array(encrypted);
  const envelope = new Uint8Array(1 + iv.byteLength + ciphertext.byteLength);
  envelope[0] = 1;
  envelope.set(iv, 1);
  envelope.set(ciphertext, 13);
  return envelope;
}

async function decryptSnapshot(envelopeBytes) {
  const envelope = new Uint8Array(envelopeBytes);
  if (envelope.byteLength < 29 || envelope[0] !== 1) {
    throw new Error("Encrypted MLS snapshot envelope is invalid.");
  }
  const iv = envelope.slice(1, 13);
  const ciphertext = envelope.slice(13);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv, additionalData: aadBytes(), tagLength: 128 },
    encryptionKey,
    ciphertext
  );
  let payload;
  try {
    payload = JSON.parse(new TextDecoder().decode(plaintext));
  } catch {
    throw new Error("Authenticated MLS snapshot metadata is malformed.");
  }
  if (payload.version !== 1 ||
      !(payload.groupId === null || (typeof payload.groupId === "string" && /^[a-zA-Z0-9_-]{1,64}$/.test(payload.groupId))) ||
      typeof payload.providerSnapshot !== "string") {
    throw new Error("Authenticated MLS snapshot metadata is invalid.");
  }
  return {
    groupId: payload.groupId,
    providerSnapshot: base64ToBytes(payload.providerSnapshot)
  };
}

function bytesEqual(left, right) {
  const a = new Uint8Array(left);
  const b = new Uint8Array(right);
  return a.byteLength === b.byteLength && a.every((byte, index) => byte === b[index]);
}

async function commitEnvelope(envelope, faultAt = null) {
  const nextGeneration = (generation ?? 0) + 1;
  const bytes = envelope.slice().buffer;
  try {
    await journalRequest("commit", {
      generation: nextGeneration,
      bytes,
      ...(faultAt ? { faultAt } : {})
    });
    return nextGeneration;
  } catch (commitError) {
    // The commit marker may have reached durable storage even if the worker
    // reported an error. Recovery is authoritative, never the error flag.
    let recovered;
    try {
      recovered = await journalRequest("recover");
    } catch (recoveryError) {
      ready = false;
      throw new Error(`Journal commit outcome is unknown and recovery failed: ${recoveryError.message}`);
    }
    if (recovered.generation === nextGeneration && recovered.bytes &&
        bytesEqual(recovered.bytes, envelope)) {
      return nextGeneration;
    }
    throw commitError;
  }
}

async function restoreFromSnapshot(snapshotBytes, record) {
  const restoredProvider = Provider.from_snapshot_bytes(new Uint8Array(snapshotBytes));
  const restoredIdentity = Identity.restore(
    restoredProvider,
    record.identityName,
    new Uint8Array(record.publicKey)
  );
  const restoredGroup = record.groupId
    ? Group.load(restoredProvider, record.groupId)
    : null;
  provider = restoredProvider;
  identity = restoredIdentity;
  group = restoredGroup;
}

async function initialize(data) {
  if (ready) throw new Error("MLS runtime is already initialized.");
  await init();
  metadata = {
    accountId: validateIdentifier(data.accountId, "account identifier"),
    deviceId: validateIdentifier(data.deviceId, "device identifier"),
    identityName: validateIdentifier(data.identityName, "identity name"),
    role: data.role === "member" ? "member" : "founder",
    groupId: data.role === "member" ? null : validateIdentifier(data.groupId, "group identifier")
  };
  const identityName = metadata.identityName;
  const groupId = metadata.groupId;
  const db = await openKeyDatabase();
  const keyId = `${metadata.accountId}|${metadata.deviceId}`;
  let keyRecord = await readKeyRecord(db, keyId);

  startJournalWorker();
  const journalName = await makeJournalName(metadata.accountId, metadata.deviceId);
  await journalRequest("open", { name: journalName });
  const recovered = await journalRequest("recover");

  if (recovered.generation !== null) {
    if (!keyRecord || !keyRecord.key) {
      throw new Error("Committed MLS state exists but its device encryption key is missing. Recovery is unavailable.");
    }
    if (keyRecord.identityName !== identityName) {
      throw new Error("Requested identity does not match the persisted device record.");
    }
    encryptionKey = keyRecord.key;
    const snapshotRecord = await decryptSnapshot(recovered.bytes);
    if (metadata.role === "founder" && snapshotRecord.groupId !== groupId) {
      throw new Error("Committed MLS group does not match the requested founder group.");
    }
    metadata.groupId = snapshotRecord.groupId;
    await restoreFromSnapshot(snapshotRecord.providerSnapshot, {
      ...keyRecord,
      groupId: snapshotRecord.groupId
    });
    generation = recovered.generation;
    ready = true;
    return {
      ready: true,
      restored: true,
      generation,
      publicKey: Array.from(keyRecord.publicKey),
      groupId: metadata.groupId
    };
  }

  // A fresh device key is non-extractable. It is stored as a CryptoKey by
  // IndexedDB; this browser prototype does not provide hardware-backed key
  // isolation from same-origin JavaScript.
  encryptionKey = await crypto.subtle.generateKey(
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  );
  provider = new Provider();
  identity = new Identity(provider, identityName);
  group = metadata.role === "founder" ? Group.create_new(provider, identity, groupId) : null;
  const publicKey = Array.from(identity.public_key_bytes());
  keyRecord = { key: encryptionKey, identityName, groupId, publicKey };
  await writeKeyRecord(db, keyId, keyRecord);

  const snapshot = provider.export_snapshot_bytes();
  const envelope = await encryptSnapshot(snapshot, metadata.groupId);
  generation = await commitEnvelope(envelope);
  ready = true;
  return { ready: true, restored: false, generation, publicKey, groupId };
}

async function sendMessage(data) {
  if (!ready || !provider || !identity || !group) {
    throw new Error("MLS runtime is not initialized.");
  }
  if (!(data.plaintext instanceof ArrayBuffer) && !ArrayBuffer.isView(data.plaintext)) {
    throw new Error("Plaintext must be supplied as bytes.");
  }
  const plaintext = data.plaintext instanceof ArrayBuffer
    ? new Uint8Array(data.plaintext)
    : new Uint8Array(data.plaintext.buffer, data.plaintext.byteOffset, data.plaintext.byteLength);

  const candidate = CandidateGroupOperation.create_message(
    provider,
    metadata.groupId,
    identity,
    plaintext
  );
  const candidateSnapshot = candidate.snapshot_bytes();
  const envelope = await encryptSnapshot(candidateSnapshot, metadata.groupId);
  const committedGeneration = await commitEnvelope(envelope, data.faultAt || null);

  // No ciphertext leaves this worker until OPFS recovery confirms the exact
  // encrypted snapshot generation. The candidate pair is then installed.
  candidate.commit_into(provider, group);
  const ciphertext = new Uint8Array(candidate.result_bytes());
  generation = committedGeneration;
  const output = ciphertext.slice();
  return { generation, ciphertext: output.buffer };
}


async function persistCandidate(
  candidateProvider, candidateGroup, candidateIdentity, faultAt = null,
  nextGroupId = metadata.groupId
) {
  const snapshot = candidateProvider.export_snapshot_bytes();
  const envelope = await encryptSnapshot(snapshot, nextGroupId);
  const committedGeneration = await commitEnvelope(envelope, faultAt);
  // Publish the candidate state in this worker only after journal recovery
  // confirms the exact encrypted generation.
  provider = candidateProvider;
  group = candidateGroup;
  identity = candidateIdentity;
  metadata.groupId = nextGroupId;
  generation = committedGeneration;
  return committedGeneration;
}

async function createKeyPackage(data) {
  if (!ready) throw new Error("MLS runtime is not initialized.");
  const candidateProvider = Provider.from_snapshot_bytes(provider.export_snapshot_bytes());
  const candidateIdentity = Identity.restore(
    candidateProvider, metadata.identityName, new Uint8Array(identity.public_key_bytes())
  );
  const keyPackage = candidateIdentity.key_package(candidateProvider);
  const bytes = new Uint8Array(keyPackage.to_bytes());
  const candidateGroup = metadata.groupId
    ? Group.load(candidateProvider, metadata.groupId)
    : null;
  await persistCandidate(candidateProvider, candidateGroup, candidateIdentity, data.faultAt || null);
  return { generation, keyPackage: bytes.buffer };
}

async function addMember(data) {
  if (!ready || !identity) throw new Error("MLS runtime is not initialized.");
  if (!data.keyPackage) throw new Error("KeyPackage bytes are required.");
  const candidateProvider = Provider.from_snapshot_bytes(provider.export_snapshot_bytes());
  const candidateIdentity = Identity.restore(
    candidateProvider, metadata.identityName, new Uint8Array(identity.public_key_bytes())
  );
  const candidateGroup = Group.load(candidateProvider, metadata.groupId);
  const keyPackage = KeyPackage.from_bytes(new Uint8Array(data.keyPackage));
  const addMessages = candidateGroup.propose_and_commit_add(
    candidateProvider, candidateIdentity, keyPackage
  );
  candidateGroup.merge_pending_commit(candidateProvider);
  const commit = new Uint8Array(addMessages.commit);
  const welcome = new Uint8Array(addMessages.welcome);
  const ratchetTree = new Uint8Array(candidateGroup.export_ratchet_tree().to_bytes());
  const committedGeneration = await persistCandidate(
    candidateProvider, candidateGroup, candidateIdentity, data.faultAt || null
  );
  return {
    generation: committedGeneration,
    commit: commit.buffer,
    welcome: welcome.buffer,
    ratchetTree: ratchetTree.buffer
  };
}

async function removeMember(data) {
  if (!ready || !identity || !group) {
    throw new Error("MLS runtime is not initialized or has not joined a group.");
  }
  if (typeof data.memberIdentity !== "string" || !/^[a-zA-Z0-9_-]{1,64}$/.test(data.memberIdentity)) {
    throw new Error("A valid MLS member identity is required.");
  }
  const candidateProvider = Provider.from_snapshot_bytes(provider.export_snapshot_bytes());
  const candidateIdentity = Identity.restore(
    candidateProvider, metadata.identityName, new Uint8Array(identity.public_key_bytes())
  );
  const candidateGroup = Group.load(candidateProvider, metadata.groupId);
  const commit = new Uint8Array(candidateGroup.remove_member_by_identity(
    candidateProvider, candidateIdentity, data.memberIdentity
  ));
  candidateGroup.merge_pending_commit(candidateProvider);
  const committedGeneration = await persistCandidate(
    candidateProvider, candidateGroup, candidateIdentity, data.faultAt || null
  );
  return { generation: committedGeneration, commit: commit.buffer };
}

async function joinGroup(data) {
  if (!ready || !identity) throw new Error("MLS runtime is not initialized.");
  if (group) throw new Error("This device is already joined to a group.");
  const nextGroupId = validateIdentifier(data.groupId, "group identifier");
  const candidateProvider = Provider.from_snapshot_bytes(provider.export_snapshot_bytes());
  const candidateIdentity = Identity.restore(
    candidateProvider, metadata.identityName, new Uint8Array(identity.public_key_bytes())
  );
  const welcome = new Uint8Array(data.welcome);
  const ratchetTree = RatchetTree.from_bytes(new Uint8Array(data.ratchetTree));
  const candidateGroup = Group.join(candidateProvider, candidateIdentity, welcome, ratchetTree);
  const committedGeneration = await persistCandidate(
    candidateProvider, candidateGroup, candidateIdentity, data.faultAt || null,
    nextGroupId
  );
  // The group identifier is authenticated inside the committed snapshot
  // envelope. IndexedDB metadata is deliberately not a second authority.
  return { generation: committedGeneration, joined: true };
}

async function receiveMessage(data) {
  if (!ready || !group) throw new Error("MLS runtime is not initialized or has not joined a group.");
  const candidateProvider = Provider.from_snapshot_bytes(provider.export_snapshot_bytes());
  const candidateIdentity = Identity.restore(
    candidateProvider, metadata.identityName, new Uint8Array(identity.public_key_bytes())
  );
  const candidateGroup = Group.load(candidateProvider, metadata.groupId);
  const plaintext = new Uint8Array(candidateGroup.process_message(
    candidateProvider, new Uint8Array(data.ciphertext)
  ));

  // process_message now retains authenticated MLS Commits for review instead
  // of merging them. Production WASM intentionally has no merge method until
  // an authenticated registration/roster authorization service is connected.
  // The explicit browser-test build has a test-only merge escape hatch so the
  // integration suite can continue exercising Welcome and membership flows.
  const stagedChanges = candidateGroup.pending_commit_add_update_bindings();
  if (stagedChanges.length > 0) {
    // Membership-changing Commits are accepted only in the isolated browser
    // test build. Production artifacts intentionally omit this escape hatch
    // until an authenticated device-registration/roster service is available.
    const mergeForBrowserTest = candidateGroup.merge_staged_commit_for_browser_test;
    if (typeof mergeForBrowserTest !== "function") {
      throw new Error(
        "MLS membership Commit rejected: authenticated device authorization is not configured."
      );
    }
    mergeForBrowserTest.call(candidateGroup, candidateProvider);
  } else {
    // Ordinary commits without membership changes remain usable in the
    // default build. The Rust method independently checks all three proposal
    // classes before merging; page-provided data cannot bypass that check.
    candidateGroup.merge_staged_commit_if_no_membership_change(candidateProvider);
  }

  const committedGeneration = await persistCandidate(
    candidateProvider, candidateGroup, candidateIdentity, data.faultAt || null
  );
  return { generation: committedGeneration, plaintext: plaintext.buffer };
}

async function handleMessage(data) {
  const id = data?.id;
  try {
    if (data.action === "initialize") {
      const result = await initialize(data);
      self.postMessage({ id, ok: true, ...result });
      return;
    }
    if (data.action === "send") {
      const result = await sendMessage(data);
      self.postMessage({ id, ok: true, ...result }, [result.ciphertext]);
      return;
    }
    if (data.action === "create-key-package") {
      const result = await createKeyPackage(data);
      self.postMessage({ id, ok: true, ...result }, [result.keyPackage]);
      return;
    }
    if (data.action === "add-member") {
      const result = await addMember(data);
      self.postMessage({ id, ok: true, ...result }, [result.commit, result.welcome, result.ratchetTree]);
      return;
    }
    if (data.action === "remove-member") {
      const result = await removeMember(data);
      self.postMessage({ id, ok: true, ...result }, [result.commit]);
      return;
    }
    if (data.action === "join") {
      const result = await joinGroup(data);
      self.postMessage({ id, ok: true, ...result });
      return;
    }
    if (data.action === "receive") {
      const result = await receiveMessage(data);
      self.postMessage({ id, ok: true, ...result }, [result.plaintext]);
      return;
    }
    if (data.action === "close") {
      ready = false;
      if (journal) {
        try { await journalRequest("close"); } finally {
          journal.terminate();
          journal = null;
        }
      }
      provider = null;
      identity = null;
      group = null;
      self.postMessage({ id, ok: true, closed: true });
      return;
    }
    throw new Error("Unsupported MLS runtime action.");
  } catch (error) {
    self.postMessage({
      id,
      ok: false,
      error: error?.message || String(error),
      errorName: error?.name || "Error"
    });
  }
}

self.onmessage = event => {
  queue = queue.then(() => handleMessage(event.data)).catch(error => {
    self.postMessage({
      id: event.data?.id,
      ok: false,
      error: error?.message || String(error),
      errorName: error?.name || "Error"
    });
  });
};
