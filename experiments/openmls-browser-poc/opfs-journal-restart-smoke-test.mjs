import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:4173/index.html");

  const result = await page.evaluate(async () => {
    if (typeof navigator.storage?.getDirectory !== "function") {
      throw new Error("OPFS is unavailable in this browser context.");
    }

    const name = `baddielink-opfs-worker-restart-${crypto.randomUUID()}.bin`;
    const encode = value => new TextEncoder().encode(value).buffer;
    const decode = value => new TextDecoder().decode(new Uint8Array(value));

    function createWorker() {
      const worker = new Worker("/opfs-journal-worker.js");
      let nextId = 0;
      const pending = new Map();
      worker.addEventListener("message", ({ data }) => {
        const waiter = pending.get(data.id);
        if (!waiter) return;
        pending.delete(data.id);
        if (data.ok) waiter.resolve(data);
        else waiter.reject(Object.assign(new Error(data.error), { name: data.errorName }));
      });
      return {
        worker,
        request(action, payload = {}) {
          const id = ++nextId;
          return new Promise((resolve, reject) => {
            pending.set(id, { resolve, reject });
            worker.postMessage({ id, action, ...payload });
          });
        },
        terminate() {
          for (const waiter of pending.values()) waiter.reject(new Error("Worker terminated."));
          pending.clear();
          worker.terminate();
        }
      };
    }

    let first = createWorker();
    let second = null;
    let third = null;
    try {
      await first.request("open", { name });
      await first.request("commit", { generation: 1, bytes: encode("checkpoint-before-worker-termination") });

      // Terminate without a graceful close to model a crashed/restarted runtime.
      first.terminate();
      first = null;
      await new Promise(resolve => setTimeout(resolve, 150));

      second = createWorker();
      await second.request("open", { name });
      const recovered = await second.request("recover");
      if (recovered.generation !== 1 ||
          decode(recovered.bytes) !== "checkpoint-before-worker-termination") {
        throw new Error("A fresh worker did not recover the last committed generation.");
      }

      await second.request("commit", {
        generation: 2,
        bytes: encode("checkpoint-written-after-worker-restart")
      });
      second.terminate();
      second = null;
      await new Promise(resolve => setTimeout(resolve, 150));

      third = createWorker();
      await third.request("open", { name });
      const recoveredAgain = await third.request("recover");
      if (recoveredAgain.generation !== 2 ||
          decode(recoveredAgain.bytes) !== "checkpoint-written-after-worker-restart") {
        throw new Error("The new worker's committed generation did not survive another restart.");
      }

      return {
        recoveredAfterAbruptTermination: true,
        committedAfterRestart: true,
        recoveredSecondGenerationAfterRestart: true,
        generation: recoveredAgain.generation
      };
    } finally {
      if (first) first.terminate();
      if (second) {
        try { await second.request("close"); } catch {}
        second.terminate();
      }
      if (third) {
        try { await third.request("close"); } catch {}
        third.terminate();
      }
      const root = await navigator.storage.getDirectory();
      await root.removeEntry(name).catch(() => {});
    }
  });

  console.log("PASS: committed OPFS journal state recovered in a fresh worker after abrupt termination.");
  console.log("PASS: a fresh worker committed the next generation.");
  console.log("PASS: the second generation survived another worker restart.");
  console.log(JSON.stringify(result));
} finally {
  await browser.close();
}
