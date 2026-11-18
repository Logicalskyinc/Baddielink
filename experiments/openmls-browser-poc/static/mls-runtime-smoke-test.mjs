import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("http://127.0.0.1:4173/index.html");

  const result = await page.evaluate(async () => {
    const workerUrl = "/mls-runtime-worker.js";
    const accountId = "runtime-test-account";
    const deviceId = "runtime-test-device";
    const identityName = "runtime-test-identity";
    const groupId = "runtime-test-group";

    function startRuntime() {
      const worker = new Worker(workerUrl, { type: "module" });
      let sequence = 0;
      const pending = new Map();
      worker.addEventListener("message", ({ data }) => {
        const request = pending.get(data.id);
        if (!request) return;
        pending.delete(data.id);
        if (data.ok) request.resolve(data);
        else request.reject(Object.assign(new Error(data.error), { name: data.errorName }));
      });
      worker.addEventListener("error", event => {
        for (const request of pending.values()) request.reject(new Error(event.message || "MLS worker failed."));
        pending.clear();
      });
      return {
        worker,
        request(action, payload = {}) {
          const id = `runtime-${++sequence}`;
          return new Promise((resolve, reject) => {
            pending.set(id, { resolve, reject });
            worker.postMessage({ id, action, ...payload });
          });
        },
        terminate() { worker.terminate(); }
      };
    }

    const encode = value => new TextEncoder().encode(value);
    const first = startRuntime();
    try {
      const initialized = await first.request("initialize", {
        accountId, deviceId, identityName, groupId
      });
      if (!initialized.ready || initialized.restored || initialized.generation !== 1) {
        throw new Error("Fresh worker initialization did not commit generation 1.");
      }

      let failedBeforeCommit = false;
      try {
        await first.request("send", {
          plaintext: encode("must-not-be-published").buffer,
          faultAt: "before-data-write"
        });
      } catch (error) {
        failedBeforeCommit = /Injected failure/.test(error.message);
      }
      if (!failedBeforeCommit) throw new Error("Injected pre-commit failure did not reject send.");

      const sent = await first.request("send", {
        plaintext: encode("first worker-owned message").buffer
      });
      if (!sent.ciphertext || sent.generation !== 2) {
        throw new Error("First committed send did not return ciphertext at generation 2.");
      }
      const ciphertext = new Uint8Array(sent.ciphertext);
      if (new TextDecoder().decode(ciphertext).includes("first worker-owned message")) {
        throw new Error("Worker returned plaintext instead of MLS ciphertext.");
      }
      first.terminate();

      // Abruptly terminate the runtime worker. The next worker must recover
      // the encrypted provider snapshot and signing identity from durable state.
      const second = startRuntime();
      try {
        const restored = await second.request("initialize", {
          accountId, deviceId, identityName, groupId
        });
        if (!restored.ready || !restored.restored || restored.generation !== 2) {
          throw new Error("Restarted worker did not restore generation 2.");
        }
        const secondSent = await second.request("send", {
          plaintext: encode("message after worker restart").buffer
        });
        if (!secondSent.ciphertext || secondSent.generation !== 3) {
          throw new Error("Restored worker did not commit generation 3.");
        }
        if (new TextDecoder().decode(new Uint8Array(secondSent.ciphertext)).includes("message after worker restart")) {
          throw new Error("Restored worker returned plaintext instead of MLS ciphertext.");
        }
        return {
          freshInitializationCommitted: true,
          failedWriteDidNotPublish: true,
          nextSendRecoveredFromPreviousCommittedState: true,
          firstSendCommittedGeneration: sent.generation,
          abruptWorkerRestartRecovered: true,
          restoredSendCommittedGeneration: secondSent.generation,
          ciphertextReturnedWithoutPlaintext: true
        };
      } finally {
        second.terminate();
      }
    } finally {
      first.terminate();
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open("baddielink-mls-runtime-v1", 1);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      await new Promise((resolve, reject) => {
        const tx = db.transaction("device-keys", "readwrite");
        tx.objectStore("device-keys").delete(`${accountId}|${deviceId}`);
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
      });
      db.close();
      const digest = new Uint8Array(await crypto.subtle.digest(
        "SHA-256",
        encode(`baddielink|runtime|v1|${accountId}|${deviceId}`)
      ));
      const suffix = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
      const root = await navigator.storage.getDirectory();
      await root.removeEntry(`baddielink-mls-${suffix}.journal`).catch(() => {});
    }
  });

  console.log("PASS: fresh worker commits an encrypted provider snapshot.");
  console.log("PASS: failed pre-commit send returns no ciphertext.");
  console.log("PASS: a later send succeeds from the last committed state.");
  console.log("PASS: abrupt runtime-worker restart restores provider and identity.");
  console.log("PASS: restored runtime commits the next message generation.");
  console.log(JSON.stringify(result));
  await context.close();
} finally {
  await browser.close();
}
