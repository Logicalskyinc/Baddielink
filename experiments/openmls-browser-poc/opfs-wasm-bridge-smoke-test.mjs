import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:4173/index.html");

  const result = await page.evaluate(async () => {
    const worker = new Worker("/opfs-wasm-bridge-worker.js", { type: "module" });
    const request = (action, payload = {}) => new Promise((resolve, reject) => {
      const id = crypto.randomUUID();
      const listener = ({ data }) => {
        if (data.id !== id) return;
        worker.removeEventListener("message", listener);
        if (data.ok) resolve(data);
        else reject(new Error(data.error));
      };
      worker.addEventListener("message", listener);
      worker.postMessage({ id, action, ...payload });
    });

    const name = `baddielink-wasm-opfs-bridge-${crypto.randomUUID()}.bin`;
    const input = Uint8Array.from([
      0, 1, 2, 3, 127, 128, 200, 254, 255,
      ...new TextEncoder().encode("OpenMLS synchronous storage bridge probe")
    ]);
    try {
      const response = await request("roundtrip", {
        name,
        bytes: input.buffer.slice(0)
      });
      const output = new Uint8Array(response.bytes);
      if (output.length !== input.length ||
          !output.every((byte, index) => byte === input[index])) {
        throw new Error("WASM -> synchronous OPFS -> WASM byte comparison failed.");
      }
      await request("close");
      return { byteLength: output.length, exactBinaryRoundTrip: true, workerHosted: true };
    } finally {
      try { await request("close"); } catch {}
      worker.terminate();
      const root = await navigator.storage.getDirectory();
      await root.removeEntry(name).catch(() => {});
    }
  });

  console.log("PASS: Rust WASM called the OPFS synchronous bridge.");
  console.log("PASS: binary bytes round-tripped exactly through FileSystemSyncAccessHandle.");
  console.log(JSON.stringify(result));
} finally {
  await browser.close();
}
