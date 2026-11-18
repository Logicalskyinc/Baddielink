import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const context = await browser.newContext();
  const page = await context.newPage();
  await page.goto("http://127.0.0.1:4173/index.html");

  const result = await page.evaluate(async () => {
    const workerUrl = "/mls-runtime-worker.js";
    const groupId = "runtime-two-member-group";
    const alice = {
      accountId: "runtime-alice-account",
      deviceId: "runtime-alice-device",
      identityName: "runtime-alice"
    };
    const bob = {
      accountId: "runtime-bob-account",
      deviceId: "runtime-bob-device",
      identityName: "runtime-bob"
    };

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
    const decode = value => new TextDecoder().decode(value);
    const aliceArgs = { ...alice, groupId, role: "founder" };
    const bobArgs = { ...bob, role: "member" };
    let aliceWorker = startRuntime();
    let bobWorker = startRuntime();

    try {
      const aliceInit = await aliceWorker.request("initialize", aliceArgs);
      if (!aliceInit.ready || aliceInit.restored || aliceInit.generation !== 1) {
        throw new Error("Founder initialization did not commit generation 1.");
      }

      let failedBeforeCommit = false;
      try {
        await aliceWorker.request("send", {
          plaintext: encode("must-not-be-published").buffer,
          faultAt: "before-data-write"
        });
      } catch (error) {
        failedBeforeCommit = /Injected failure/.test(error.message);
      }
      if (!failedBeforeCommit) throw new Error("Injected pre-commit failure did not reject send.");

      const bobInit = await bobWorker.request("initialize", bobArgs);
      if (!bobInit.ready || bobInit.restored || bobInit.groupId !== null) {
        throw new Error("Member identity-only initialization did not succeed.");
      }

      const keyPackage = await bobWorker.request("create-key-package");
      if (!keyPackage.keyPackage) throw new Error("Recipient KeyPackage was not returned.");

      const added = await aliceWorker.request("add-member", {
        keyPackage: keyPackage.keyPackage
      });
      if (!added.welcome || !added.ratchetTree || added.generation !== 2) {
        throw new Error("Founder did not commit the member addition and return Welcome data.");
      }

      const joined = await bobWorker.request("join", {
        groupId,
        welcome: added.welcome,
        ratchetTree: added.ratchetTree
      });
      if (!joined.joined || joined.generation !== 3) {
        throw new Error("Recipient did not join and commit the MLS group.");
      }

      const firstSent = await aliceWorker.request("send", {
        plaintext: encode("hello from founder").buffer
      });
      if (!firstSent.ciphertext || firstSent.generation !== 3) {
        throw new Error("Founder did not commit first group message.");
      }
      const firstReceived = await bobWorker.request("receive", {
        ciphertext: firstSent.ciphertext
      });
      if (decode(firstReceived.plaintext) !== "hello from founder" || firstReceived.generation !== 4) {
        throw new Error("Recipient failed to decrypt and commit first group message.");
      }

      aliceWorker.terminate();
      aliceWorker = startRuntime();
      const aliceRestored = await aliceWorker.request("initialize", aliceArgs);
      if (!aliceRestored.ready || !aliceRestored.restored || aliceRestored.generation !== 3) {
        throw new Error("Founder worker restart did not restore the committed two-member group.");
      }

      const secondSent = await aliceWorker.request("send", {
        plaintext: encode("message after founder restart").buffer
      });
      if (!secondSent.ciphertext || secondSent.generation !== 4) {
        throw new Error("Restored founder did not commit the next group message.");
      }
      const secondReceived = await bobWorker.request("receive", {
        ciphertext: secondSent.ciphertext
      });
      if (decode(secondReceived.plaintext) !== "message after founder restart" ||
          secondReceived.generation !== 5) {
        throw new Error("Recipient could not decrypt the message sent after founder restart.");
      }

      const rawCiphertext = decode(new Uint8Array(secondSent.ciphertext));
      if (rawCiphertext.includes("message after founder restart")) {
        throw new Error("Worker returned plaintext instead of MLS ciphertext.");
      }

      return {
        failedWriteDidNotPublish: true,
        recipientIdentityInitializedWithoutGroup: true,
        keyPackageIssued: true,
        memberAdditionAndWelcomeCommitted: true,
        recipientJoined: true,
        twoMemberMessageDecrypted: true,
        founderRestartRestoredGroup: true,
        postRestartMessageDecrypted: true,
        plaintextNotPresentInCiphertext: true,
        aliceFinalGeneration: secondSent.generation,
        bobFinalGeneration: secondReceived.generation
      };
    } finally {
      aliceWorker.terminate();
      bobWorker.terminate();
      const db = await new Promise((resolve, reject) => {
        const request = indexedDB.open("baddielink-mls-runtime-v1", 1);
        request.onsuccess = () => resolve(request.result);
        request.onerror = () => reject(request.error);
      });
      await new Promise((resolve, reject) => {
        const tx = db.transaction("device-keys", "readwrite");
        const store = tx.objectStore("device-keys");
        store.delete(`${alice.accountId}|${alice.deviceId}`);
        store.delete(`${bob.accountId}|${bob.deviceId}`);
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
      });
      db.close();

      const root = await navigator.storage.getDirectory();
      for (const participant of [alice, bob]) {
        const digest = new Uint8Array(await crypto.subtle.digest(
          "SHA-256",
          encode(`baddielink|runtime|v1|${participant.accountId}|${participant.deviceId}`)
        ));
        const suffix = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
        await root.removeEntry(`baddielink-mls-${suffix}.journal`).catch(() => {});
      }
    }
  });

  console.log("PASS: worker-owned two-member MLS lifecycle.");
  console.log(JSON.stringify(result));
  await context.close();
} finally {
  await browser.close();
}
