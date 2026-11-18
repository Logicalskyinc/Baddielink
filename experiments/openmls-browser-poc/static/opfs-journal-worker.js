const MAGIC = [0x42, 0x4c, 0x4a, 0x31]; // BLJ1
const VERSION = 1;
const DATA = 1;
const COMMIT = 2;
const HEADER = 14;
const MAX_FRAME = 64 * 1024 * 1024;

let handle = null;
let activeName = null;

function encodeFrame(type, generation, payload) {
  const frame = new Uint8Array(HEADER + payload.byteLength);
  frame.set(MAGIC, 0);
  frame[4] = VERSION;
  frame[5] = type;
  const view = new DataView(frame.buffer);
  view.setUint32(6, generation, false);
  view.setUint32(10, payload.byteLength, false);
  frame.set(payload, HEADER);
  return frame;
}

function writeAll(bytes) {
  let offset = 0;
  while (offset < bytes.byteLength) {
    const written = handle.write(bytes.subarray(offset), { at: handle.getSize() });
    if (written <= 0) throw new Error("OPFS journal write made no progress.");
    offset += written;
  }
  handle.flush();
}

function readAll() {
  const size = handle.getSize();
  const bytes = new Uint8Array(size);
  let offset = 0;
  while (offset < size) {
    const read = handle.read(bytes.subarray(offset), { at: offset });
    if (read <= 0) throw new Error("OPFS journal read was incomplete.");
    offset += read;
  }
  return bytes;
}

function recoverFrames(bytes) {
  const dataByGeneration = new Map();
  const committed = new Map();
  let offset = 0;

  while (offset < bytes.byteLength) {
    if (bytes.byteLength - offset < HEADER) break; // incomplete trailing header
    const header = bytes.subarray(offset, offset + HEADER);
    if (!MAGIC.every((byte, i) => header[i] === byte) || header[4] !== VERSION) {
      throw new Error(`OPFS journal corruption at byte ${offset}.`);
    }
    const view = new DataView(header.buffer, header.byteOffset, header.byteLength);
    const type = header[5];
    const generation = view.getUint32(6, false);
    const length = view.getUint32(10, false);
    if (length > MAX_FRAME) throw new Error("OPFS journal frame exceeds the size limit.");
    if (bytes.byteLength - offset - HEADER < length) break; // incomplete trailing payload
    const payload = bytes.slice(offset + HEADER, offset + HEADER + length);
    offset += HEADER + length;

    if (type === DATA) {
      dataByGeneration.set(generation, payload);
    } else if (type === COMMIT) {
      if (payload.byteLength !== 32) throw new Error("Invalid OPFS journal commit marker.");
      const data = dataByGeneration.get(generation);
      if (!data) throw new Error("Commit marker references missing journal data.");
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", data));
      if (!digest.every((byte, i) => byte === payload[i])) {
        throw new Error("OPFS journal commit digest mismatch.");
      }
      committed.set(generation, data);
    } else {
      throw new Error("Unknown OPFS journal frame type.");
    }
  }

  if (committed.size === 0) return { generation: null, bytes: null };
  const generation = Math.max(...committed.keys());
  return { generation, bytes: committed.get(generation) };
}

self.onmessage = async ({ data }) => {
  const { id, action, name, generation, bytes } = data;
  try {
    if (action === "open") {
      if (handle) throw new Error("An OPFS journal is already open in this worker.");
      const root = await navigator.storage.getDirectory();
      const file = await root.getFileHandle(name, { create: true });
      handle = await file.createSyncAccessHandle();
      activeName = name;
      self.postMessage({ id, ok: true, name });
      return;
    }
    if (!handle) throw new Error("No OPFS journal is open.");

    if (action === "stage") {
      const payload = new Uint8Array(bytes);
      writeAll(encodeFrame(DATA, generation, payload));
      self.postMessage({ id, ok: true, staged: generation });
      return;
    }

    if (action === "commit") {
      const payload = new Uint8Array(bytes);
      const current = await recoverFrames(readAll());
      if (current.generation !== null && generation <= current.generation) {
        throw new Error("Journal generation must increase monotonically.");
      }
      writeAll(encodeFrame(DATA, generation, payload));
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", payload));
      writeAll(encodeFrame(COMMIT, generation, digest));
      const verified = await recoverFrames(readAll());
      if (verified.generation !== generation || !verified.bytes.every((byte, i) => byte === payload[i]) ||
          verified.bytes.byteLength !== payload.byteLength) {
        throw new Error("Committed journal generation failed read-back verification.");
      }
      self.postMessage({ id, ok: true, committed: generation });
      return;
    }

    if (action === "recover") {
      const result = await recoverFrames(readAll());
      const output = result.bytes;
      self.postMessage({
        id, ok: true, generation: result.generation,
        bytes: output ? output.buffer : null
      }, output ? [output.buffer] : []);
      return;
    }

    if (action === "append-torn-tail") {
      const tail = new Uint8Array(bytes);
      const written = handle.write(tail, { at: handle.getSize() });
      if (written !== tail.byteLength) throw new Error("Could not append complete test tail.");
      handle.flush();
      self.postMessage({ id, ok: true, written });
      return;
    }

    if (action === "close") {
      handle.flush();
      handle.close();
      handle = null;
      const closed = activeName;
      activeName = null;
      self.postMessage({ id, ok: true, name: closed });
      return;
    }
    throw new Error(`Unsupported journal action: ${action}`);
  } catch (error) {
    self.postMessage({ id, ok: false, error: error?.message ?? String(error), errorName: error?.name ?? "Error" });
  }
};
