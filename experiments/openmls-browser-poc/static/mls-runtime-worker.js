import init, {
  CandidateGroupOperation,
  Group,
  Identity,
  Provider
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

async function encryptSnapshot(snapshotBytes) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv, additionalData: aadBytes(), tagLength: 128 },
    encryptionKey,
    snapshotBytes
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
  return crypto.subtle.decrypt(
    { name: "AES-GCM", iv, additionalData: aadBytes(), tagLength: 128 },
    encryptionKey,
    ciphertext
  );
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
  const restoredGroup = Group.load(restoredProvider, record.groupId);
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
    groupId: validateIdentifier(data.groupId, "group identifier")
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
    if (keyRecord.identityName !== identityName || keyRecord.groupId !== groupId) {
      throw new Error("Requested identity or group does not match the persisted device record.");
    }
    encryptionKey = keyRecord.key;
    const snapshot = await decryptSnapshot(recovered.bytes);
    await restoreFromSnapshot(snapshot, keyRecord);
    generation = recovered.generation;
    ready = true;
    return {
      ready: true,
      restored: true,
      generation,
      publicKey: Array.from(keyRecord.publicKey),
      groupId: keyRecord.groupId
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
  group = Group.create_new(provider, identity, groupId);
  const publicKey = Array.from(identity.public_key_bytes());
  keyRecord = { key: encryptionKey, identityName, groupId, publicKey };
  await writeKeyRecord(db, keyId, keyRecord);

  const snapshot = provider.export_snapshot_bytes();
  const envelope = await encryptSnapshot(snapshot);
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
  const envelope = await encryptSnapshot(candidateSnapshot);
  const committedGeneration = await commitEnvelope(envelope, data.faultAt || null);

  // No ciphertext leaves this worker until OPFS recovery confirms the exact
  // encrypted snapshot generation. The candidate pair is then installed.
  candidate.commit_into(provider, group);
  const ciphertext = new Uint8Array(candidate.result_bytes());
  generation = committedGeneration;
  const output = ciphertext.slice();
  return { generation, ciphertext: output.buffer };
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
