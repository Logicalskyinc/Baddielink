import { chromium } from "playwright";
const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:4173/index.html");
  const result = await page.evaluate(async () => {
    const name = `baddielink-wasm-opfs-restart-${crypto.randomUUID()}.bin`;
    const input = Uint8Array.from([0,1,2,3,127,128,200,254,255,...new TextEncoder().encode("OpenMLS worker restart persistence probe")]);
    const requestInFreshWorker = (action, payload = {}) => new Promise((resolve, reject) => {
      const worker = new Worker("/opfs-wasm-bridge-worker.js", { type: "module" });
      const id = crypto.randomUUID();
      const timeout = setTimeout(() => { worker.terminate(); reject(new Error(`Timed out during OPFS ${action}.`)); }, 10000);
      worker.addEventListener("message", ({ data }) => {
        if (data.id !== id) return;
        clearTimeout(timeout);
        worker.terminate();
        if (data.ok) resolve(data); else reject(new Error(data.error));
      });
      worker.postMessage({ id, action, name, ...payload });
    });
    try {
      await requestInFreshWorker("write", { bytes: input.buffer.slice(0) });
      const read = await requestInFreshWorker("read");
      const output = new Uint8Array(read.bytes);
      if (output.length !== input.length || !output.every((byte, index) => byte === input[index])) {
        throw new Error("WASM -> OPFS -> fresh WASM worker byte comparison failed.");
      }
      return { byteLength: output.length, exactBinaryMatch: true, separateWorkerInstances: true, fileClosedBetweenOperations: true };
    } finally {
      const root = await navigator.storage.getDirectory();
      await root.removeEntry(name).catch(() => {});
    }
  });
  console.log("PASS: Rust WASM wrote bytes through OPFS.");
  console.log("PASS: a fresh worker and fresh WASM instance read the same bytes.");
  console.log("PASS: the OPFS handle was closed between write and read.");
  console.log(JSON.stringify(result));
} finally { await browser.close(); }
