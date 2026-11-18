import init, { opfs_bridge_roundtrip } from "./openmls_wasm.js";

let handle = null;
let fileName = null;

self.onmessage = async ({ data }) => {
  const { id, action, name, bytes } = data;
  try {
    if (action === "roundtrip") {
      if (handle) throw new Error("OPFS bridge worker is already initialized.");
      const root = await navigator.storage.getDirectory();
      const file = await root.getFileHandle(name, { create: true });
      handle = await file.createSyncAccessHandle();
      fileName = name;

      globalThis.__baddielinkOpfsWrite = (input) => {
        const view = input instanceof Uint8Array ? input : new Uint8Array(input);
        handle.truncate(0);
        let offset = 0;
        while (offset < view.byteLength) {
          const written = handle.write(view.subarray(offset), { at: offset });
          if (written <= 0) throw new Error("OPFS bridge write made no progress.");
          offset += written;
        }
        handle.flush();
      };

      globalThis.__baddielinkOpfsRead = (length) => {
        const output = new Uint8Array(length);
        let offset = 0;
        while (offset < length) {
          const read = handle.read(output.subarray(offset), { at: offset });
          if (read <= 0) throw new Error("OPFS bridge read was incomplete.");
          offset += read;
        }
        return output;
      };

      await init();
      const input = new Uint8Array(bytes);
      const output = opfs_bridge_roundtrip(input);
      if (output.length !== input.length) throw new Error("WASM/OPFS bridge returned an unexpected byte length.");
      self.postMessage({ id, ok: true, bytes: output.buffer }, [output.buffer]);
      return;
    }
    if (action === "close") {
      if (handle) {
        handle.flush();
        handle.close();
        handle = null;
      }
      const closedName = fileName;
      fileName = null;
      self.postMessage({ id, ok: true, name: closedName });
      return;
    }
    throw new Error("Unsupported OPFS bridge action.");
  } catch (error) {
    self.postMessage({ id, ok: false, error: error?.message ?? String(error) });
  }
};
