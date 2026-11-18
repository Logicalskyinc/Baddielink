import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:4173/index.html");

  const result = await page.evaluate(async () => {
    if (typeof navigator.storage?.getDirectory !== "function") {
      throw new Error("OPFS is unavailable in this browser context.");
    }
    const worker = new Worker("/opfs-journal-worker.js");
    const request = (action, payload = {}) => new Promise((resolve, reject) => {
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
    const name = `baddielink-opfs-journal-${crypto.randomUUID()}.bin`;
    const bytes = value => new TextEncoder().encode(value);
    const text = value => new TextDecoder().decode(new Uint8Array(value));
    try {
      await request("open", { name });
      await request("commit", { generation: 1, bytes: bytes("checkpoint-one").buffer });
      await request("stage", { generation: 2, bytes: bytes("uncommitted-checkpoint").buffer });
      const afterStage = await request("recover");
      if (afterStage.generation !== 1 || text(afterStage.bytes) !== "checkpoint-one") {
        throw new Error("Recovery accepted an uncommitted staged generation.");
      }

      await request("append-torn-tail", { bytes: new Uint8Array([0x42, 0x4c, 0x4a]).buffer });
      const afterTornTail = await request("recover");
      if (afterTornTail.generation !== 1 || text(afterTornTail.bytes) !== "checkpoint-one" ||
          !afterTornTail.repairedIncompleteTail) {
        throw new Error("Recovery did not detect and repair the incomplete trailing frame.");
      }

      await request("commit", { generation: 3, bytes: bytes("checkpoint-three").buffer });
      const final = await request("recover");
      if (final.generation !== 3 || text(final.bytes) !== "checkpoint-three") {
        throw new Error("A new committed generation could not be written after tail repair.");
      }

      await request("close");
      await request("open", { name });
      const reopened = await request("recover");
      if (reopened.generation !== 3 || text(reopened.bytes) !== "checkpoint-three") {
        throw new Error("Committed checkpoint did not survive close/reopen.");
      }

      let staleGenerationRejected = false;
      try {
        await request("commit", { generation: 2, bytes: bytes("stale").buffer });
      } catch (error) {
        staleGenerationRejected = /increase monotonically/.test(error.message);
      }
      if (!staleGenerationRejected) throw new Error("A stale generation was accepted.");

      return {
        uncommittedStageIgnored: true,
        tornTailDetectedAndRepaired: true,
        commitAfterRepair: true,
        latestGeneration: reopened.generation,
        persistedAfterReopen: true,
        staleGenerationRejected
      };
    } finally {
      try { await request("close"); } catch {}
      worker.terminate();
      const root = await navigator.storage.getDirectory();
      await root.removeEntry(name).catch(() => {});
    }
  });

  console.log("PASS: uncommitted journal data is ignored.");
  console.log("PASS: incomplete trailing frame is detected and truncated.");
  console.log("PASS: a new commit succeeds after tail repair.");
  console.log("PASS: stale generations are rejected.");
  console.log("PASS: latest committed generation survives close/reopen.");
  console.log(JSON.stringify(result));
} finally {
  await browser.close();
}
