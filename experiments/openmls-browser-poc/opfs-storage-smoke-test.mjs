import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:4173/index.html");

  const result = await page.evaluate(async () => {
    if (typeof navigator.storage?.getDirectory !== "function") {
      throw new Error("OPFS is unavailable in this browser context.");
    }

    const createWorker = () => new Worker("/opfs-storage-worker.js");
    const request = (worker, action, payload = {}) =>
      new Promise((resolve, reject) => {
        const id = crypto.randomUUID();
        const onMessage = ({ data }) => {
          if (data.id !== id) return;
          worker.removeEventListener("message", onMessage);
          if (data.ok) resolve(data);
          else reject(Object.assign(new Error(data.error), { name: data.errorName }));
        };
        worker.addEventListener("message", onMessage);
        worker.postMessage({ id, action, ...payload });
      });

    const fileName = `baddielink-mls-opfs-poc-${crypto.randomUUID()}.bin`;
    const first = createWorker();
    const second = createWorker();

    try {
      await request(first, "open", { name: fileName });

      let exclusiveLockRejected = false;
      try {
        await request(second, "open", { name: fileName });
      } catch (error) {
        exclusiveLockRejected = error.name === "NoModificationAllowedError";
      }
      if (!exclusiveLockRejected) {
        throw new Error("A second worker unexpectedly acquired the same OPFS file.");
      }

      const payload = new TextEncoder().encode("baddielink-opfs-mls-storage-spike");
      await request(first, "write", { bytes: payload.buffer });
      const read = await request(first, "read");
      const decoded = new TextDecoder().decode(new Uint8Array(read.bytes));
      if (decoded !== "baddielink-opfs-mls-storage-spike") {
        throw new Error("OPFS worker read-back did not match the written bytes.");
      }

      await request(first, "close");
      await request(second, "open", { name: fileName });
      const restored = await request(second, "read");
      const restoredText = new TextDecoder().decode(new Uint8Array(restored.bytes));
      if (restoredText !== decoded) {
        throw new Error("OPFS contents did not persist after closing and reopening.");
      }

      return { exclusiveLockRejected, persistedAfterReopen: true, bytes: restored.bytes.byteLength };
    } finally {
      first.terminate();
      second.terminate();
      const root = await navigator.storage.getDirectory();
      await root.removeEntry(fileName).catch(() => {});
    }
  });

  console.log("PASS: OPFS synchronous access works in a dedicated worker.");
  console.log("PASS: a second worker cannot open the same file concurrently.");
  console.log("PASS: flushed bytes persist after closing and reopening.");
  console.log(JSON.stringify(result));
} finally {
  await browser.close();
}
