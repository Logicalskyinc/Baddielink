import init, { opfs_bridge_read, opfs_bridge_write } from "./openmls_wasm.js";
async function openFile(name, create) {
  const root = await navigator.storage.getDirectory();
  const file = await root.getFileHandle(name, { create });
  return file.createSyncAccessHandle();
}
function installBridge(handle) {
  globalThis.__baddielinkOpfsWrite = (input) => {
    const view = input instanceof Uint8Array ? input : new Uint8Array(input);
    handle.truncate(0);
    let offset = 0;
    while (offset < view.byteLength) {
      const written = handle.write(view.subarray(offset), { at: offset });
      if (written <= 0) throw new Error("OPFS write made no progress.");
      offset += written;
    }
    handle.flush();
  };
  globalThis.__baddielinkOpfsReadAll = () => {
    const size = handle.getSize();
    const output = new Uint8Array(size);
    let offset = 0;
    while (offset < size) {
      const read = handle.read(output.subarray(offset), { at: offset });
      if (read <= 0) throw new Error("OPFS read was incomplete.");
      offset += read;
    }
    return output;
  };
}
self.onmessage = async ({ data }) => {
  const { id, action, name, bytes } = data;
  let handle = null;
  try {
    if (action !== "write" && action !== "read") throw new Error("Unsupported OPFS bridge action.");
    handle = await openFile(name, action === "write");
    installBridge(handle);
    await init();
    if (action === "write") {
      opfs_bridge_write(new Uint8Array(bytes));
      self.postMessage({ id, ok: true, written: bytes.byteLength });
    } else {
      const output = opfs_bridge_read();
      self.postMessage({ id, ok: true, bytes: output.buffer }, [output.buffer]);
    }
  } catch (error) {
    self.postMessage({ id, ok: false, error: error?.message ?? String(error) });
  } finally {
    if (handle) {
      try { handle.flush(); } catch {}
      try { handle.close(); } catch {}
    }
  }
};
