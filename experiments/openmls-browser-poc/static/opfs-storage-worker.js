let accessHandle = null;
let fileName = null;

self.onmessage = async ({ data }) => {
  const { id, action, name, bytes } = data;
  try {
    if (action === "open") {
      if (accessHandle) throw new Error("A file handle is already open in this worker.");
      const root = await navigator.storage.getDirectory();
      const file = await root.getFileHandle(name, { create: true });
      accessHandle = await file.createSyncAccessHandle();
      fileName = name;
      self.postMessage({ id, ok: true, name: fileName });
      return;
    }

    if (action === "write") {
      if (!accessHandle) throw new Error("No OPFS access handle is open.");
      const input = new Uint8Array(bytes);
      const written = accessHandle.write(input, { at: 0 });
      if (written !== input.byteLength) throw new Error("OPFS write was incomplete.");
      accessHandle.truncate(input.byteLength);
      accessHandle.flush();
      self.postMessage({ id, ok: true, written });
      return;
    }

    if (action === "read") {
      if (!accessHandle) throw new Error("No OPFS access handle is open.");
      const length = accessHandle.getSize();
      const output = new Uint8Array(length);
      const read = accessHandle.read(output, { at: 0 });
      if (read !== length) throw new Error("OPFS read was incomplete.");
      self.postMessage({ id, ok: true, bytes: output.buffer }, [output.buffer]);
      return;
    }

    if (action === "close") {
      if (accessHandle) accessHandle.close();
      accessHandle = null;
      const closedName = fileName;
      fileName = null;
      self.postMessage({ id, ok: true, name: closedName });
      return;
    }

    throw new Error(`Unsupported OPFS worker action: ${action}`);
  } catch (error) {
    self.postMessage({
      id,
      ok: false,
      error: error?.message ?? String(error),
      errorName: error?.name ?? "Error",
    });
  }
};
