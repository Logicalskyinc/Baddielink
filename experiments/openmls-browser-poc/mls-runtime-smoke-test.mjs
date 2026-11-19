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
    const charlie = {
      accountId: "runtime-charlie-account",
      deviceId: "runtime-charlie-device",
      identityName: "runtime-charlie"
    };

    function startRuntime() {
      const worker = new Worker(workerUrl, { type: "module" });
      let sequence = 0;
      const pending = new Map();
      function rejectPending(error) {
        for (const request of pending.values()) {
          clearTimeout(request.timer);
          request.reject(error);
        }
        pending.clear();
      }
      worker.addEventListener("message", ({ data }) => {
        const request = pending.get(data.id);
        if (!request) return;
        pending.delete(data.id);
        clearTimeout(request.timer);
        if (data.ok) request.resolve(data);
        else request.reject(Object.assign(
          new Error(`${data.action || "MLS action"}: ${data.error}`),
          { name: data.errorName || "Error" }
        ));
      });
      worker.addEventListener("error", event => {
        rejectPending(new Error(event.message || "MLS worker failed."));
      });
      worker.addEventListener("messageerror", () => {
        rejectPending(new Error("MLS worker response could not be deserialized."));
      });
      return {
        worker,
        request(action, payload = {}) {
          const id = `runtime-${++sequence}`;
          return new Promise((resolve, reject) => {
            const timer = setTimeout(() => {
              pending.delete(id);
              reject(new Error(`${action}: worker response timed out after 20 seconds.`));
            }, 20000);
            pending.set(id, { resolve, reject, timer });
            try {
              worker.postMessage({ id, action, ...payload });
            } catch (error) {
              clearTimeout(timer);
              pending.delete(id);
              reject(error);
            }
          });
        },
        terminate() {
          worker.terminate();
          rejectPending(new Error("MLS worker terminated before the request completed."));
        }
      };
    }

    const encode = value => new TextEncoder().encode(value);
    const decode = value => new TextDecoder().decode(value);
    const aliceArgs = { ...alice, groupId, role: "founder" };
    const bobArgs = { ...bob, role: "member" };
    const charlieArgs = { ...charlie, role: "member" };
    let aliceWorker = startRuntime();
    let bobWorker = startRuntime();
    let charlieWorker = startRuntime();

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

      let membershipWriteRejected = false;
      try {
        await aliceWorker.request("add-member", {
          keyPackage: keyPackage.keyPackage,
          faultAt: "before-data-write"
        });
      } catch (error) {
        membershipWriteRejected = /Injected failure/.test(error.message);
      }
      if (!membershipWriteRejected) {
        throw new Error("Pre-commit membership persistence failure did not reject add-member.");
      }

      // A fresh founder worker must recover the old group, not the uncommitted
      // candidate. Retrying the same KeyPackage must remain valid.
      aliceWorker.terminate();
      aliceWorker = startRuntime();
      const aliceAfterRejectedAdd = await aliceWorker.request("initialize", aliceArgs);
      if (!aliceAfterRejectedAdd.restored || aliceAfterRejectedAdd.generation !== 1) {
        throw new Error("Rejected membership change altered the recovered founder state.");
      }

      const added = await aliceWorker.request("add-member", {
        keyPackage: keyPackage.keyPackage
      });
      if (!added.commit || !added.welcome || !added.ratchetTree || added.generation !== 2) {
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

      // Exercise an ambiguous outcome after commit-marker publication begins.
      // The worker must recover the exact committed candidate before it can
      // return Charlie's Welcome data to the caller.
      const charlieInit = await charlieWorker.request("initialize", charlieArgs);
      if (!charlieInit.ready || charlieInit.groupId !== null) {
        throw new Error("Second recipient identity-only initialization failed.");
      }
      const charlieKeyPackage = await charlieWorker.request("create-key-package");
      const charlieAdded = await aliceWorker.request("add-member", {
        keyPackage: charlieKeyPackage.keyPackage,
        faultAt: "after-commit-marker"
      });
      if (!charlieAdded.commit || !charlieAdded.welcome || !charlieAdded.ratchetTree || charlieAdded.generation !== 3) {
        throw new Error("Ambiguous membership commit was not recovered before Welcome publication.");
      }
      const bobProcessedMembershipCommit = await bobWorker.request("receive", {
        ciphertext: charlieAdded.commit
      });
      if (new Uint8Array(bobProcessedMembershipCommit.plaintext).byteLength !== 0 ||
          bobProcessedMembershipCommit.generation !== 4) {
        throw new Error("Existing recipient did not process and persist the membership Commit.");
      }
      const charlieJoined = await charlieWorker.request("join", {
        groupId,
        welcome: charlieAdded.welcome,
        ratchetTree: charlieAdded.ratchetTree
      });
      if (!charlieJoined.joined || charlieJoined.generation !== 3) {
        throw new Error("Second recipient did not join the recovered MLS group.");
      }

      const firstSent = await aliceWorker.request("send", {
        plaintext: encode("hello from founder").buffer
      });
      if (!firstSent.ciphertext || firstSent.generation !== 4) {
        throw new Error("Founder did not commit first group message.");
      }
      const firstReceived = await bobWorker.request("receive", {
        ciphertext: firstSent.ciphertext
      });
      if (decode(firstReceived.plaintext) !== "hello from founder" || firstReceived.generation !== 5) {
        throw new Error("Recipient failed to decrypt and commit first group message.");
      }
      const charlieReceived = await charlieWorker.request("receive", {
        ciphertext: firstSent.ciphertext
      });
      if (decode(charlieReceived.plaintext) !== "hello from founder" || charlieReceived.generation !== 4) {
        throw new Error("Second recipient could not process the committed three-member epoch.");
      }

      // Restart the recipient after its receive state has been durably committed.
      // The member starts with no trusted group ID; the authenticated snapshot
      // must supply the group binding during recovery.
      bobWorker.terminate();
      bobWorker = startRuntime();
      const bobRestored = await bobWorker.request("initialize", bobArgs);
      if (!bobRestored.ready || !bobRestored.restored ||
          bobRestored.generation !== 5 || bobRestored.groupId !== groupId) {
        throw new Error("Recipient worker restart did not restore its authenticated group state.");
      }

      aliceWorker.terminate();
      aliceWorker = startRuntime();
      const aliceRestored = await aliceWorker.request("initialize", aliceArgs);
      if (!aliceRestored.ready || !aliceRestored.restored || aliceRestored.generation !== 4) {
        throw new Error("Founder worker restart did not restore the committed three-member group.");
      }

      const secondSent = await aliceWorker.request("send", {
        plaintext: encode("message after founder restart").buffer
      });
      if (!secondSent.ciphertext || secondSent.generation !== 5) {
        throw new Error("Restored founder did not commit the next group message.");
      }
      const secondReceived = await bobWorker.request("receive", {
        ciphertext: secondSent.ciphertext
      });
      if (decode(secondReceived.plaintext) !== "message after founder restart" ||
          secondReceived.generation !== 6) {
        throw new Error("Recipient could not decrypt the message sent after founder restart.");
      }
      const charlieSecondReceived = await charlieWorker.request("receive", {
        ciphertext: secondSent.ciphertext
      });
      if (decode(charlieSecondReceived.plaintext) !== "message after founder restart" ||
          charlieSecondReceived.generation !== 5) {
        throw new Error("Second recipient could not process the post-restart epoch message.");
      }

      // Unknown identities must fail closed and must not publish a candidate
      // state or prevent a subsequent valid membership change.
      let unknownMemberRemovalRejected = false;
      try {
        await aliceWorker.request("remove-member", { memberIdentity: "not-a-member" });
      } catch {
        unknownMemberRemovalRejected = true;
      }
      if (!unknownMemberRemovalRejected) {
        throw new Error("Founder accepted a removal request for an unknown identity.");
      }

      const removal = await aliceWorker.request("remove-member", {
        memberIdentity: bob.identityName
      });
      if (!removal.commit || removal.generation !== 6) {
        throw new Error("Founder did not durably commit Bob's removal.");
      }
      const charlieProcessedRemoval = await charlieWorker.request("receive", {
        ciphertext: removal.commit
      });
      if (new Uint8Array(charlieProcessedRemoval.plaintext).byteLength !== 0 ||
          charlieProcessedRemoval.generation !== 6) {
        throw new Error("Remaining member did not process and persist the removal Commit.");
      }

      // The same removal Commit must not be replayable after it has been
      // applied. A duplicate must fail without advancing the recipient state.
      let removalReplayRejected = false;
      try {
        await charlieWorker.request("receive", { ciphertext: removal.commit });
      } catch {
        removalReplayRejected = true;
      }
      if (!removalReplayRejected) {
        throw new Error("Remaining member accepted a replayed removal Commit.");
      }

      // Both remaining participants must recover the new epoch after worker
      // termination, not merely continue using their in-memory state.
      aliceWorker.terminate();
      aliceWorker = startRuntime();
      const aliceAfterRemovalRestart = await aliceWorker.request("initialize", aliceArgs);
      if (!aliceAfterRemovalRestart.ready || !aliceAfterRemovalRestart.restored ||
          aliceAfterRemovalRestart.generation !== 6) {
        throw new Error("Founder did not restore the committed post-removal epoch.");
      }

      charlieWorker.terminate();
      charlieWorker = startRuntime();
      const charlieAfterRemovalRestart = await charlieWorker.request("initialize", charlieArgs);
      if (!charlieAfterRemovalRestart.ready || !charlieAfterRemovalRestart.restored ||
          charlieAfterRemovalRestart.generation !== 6 ||
          charlieAfterRemovalRestart.groupId !== groupId) {
        throw new Error("Remaining member did not restore the authenticated post-removal epoch.");
      }

      // A removed participant may still hold a stale local epoch and create
      // ciphertext locally. The remaining group must reject it.
      const staleBobMessage = await bobWorker.request("send", {
        plaintext: encode("message from removed member").buffer
      });
      if (!staleBobMessage.ciphertext || staleBobMessage.generation !== 7) {
        throw new Error("Removed member stale-state test could not create its old-epoch message.");
      }
      let staleMessageRejected = false;
      try {
        await aliceWorker.request("receive", { ciphertext: staleBobMessage.ciphertext });
      } catch (error) {
        staleMessageRejected = true;
      }
      if (!staleMessageRejected) {
        throw new Error("Remaining group accepted an application message from the removed member's old epoch.");
      }

      const postRemovalSent = await aliceWorker.request("send", {
        plaintext: encode("message after member removal").buffer
      });
      if (!postRemovalSent.ciphertext || postRemovalSent.generation !== 7) {
        throw new Error("Founder failed to send in the rotated post-removal epoch.");
      }
      const charliePostRemoval = await charlieWorker.request("receive", {
        ciphertext: postRemovalSent.ciphertext
      });
      if (decode(charliePostRemoval.plaintext) !== "message after member removal" ||
          charliePostRemoval.generation !== 7) {
        throw new Error("Remaining member failed to decrypt in the rotated post-removal epoch.");
      }
      let removedMemberRejectedNewEpoch = false;
      try {
        await bobWorker.request("receive", { ciphertext: postRemovalSent.ciphertext });
      } catch (error) {
        removedMemberRejectedNewEpoch = true;
      }
      if (!removedMemberRejectedNewEpoch) {
        throw new Error("Removed member decrypted an application message from the post-removal epoch.");
      }

      const rawCiphertext = decode(new Uint8Array(postRemovalSent.ciphertext));
      if (rawCiphertext.includes("message after member removal")) {
        throw new Error("Worker returned plaintext instead of MLS ciphertext.");
      }

      return {
        failedWriteDidNotPublish: true,
        recipientIdentityInitializedWithoutGroup: true,
        keyPackageIssued: true,
        preCommitMembershipFailureDidNotPublishWelcome: true,
        rejectedMembershipStateDidNotSurviveRestart: true,
        memberAdditionAndWelcomeCommitted: true,
        existingMemberProcessedMembershipCommit: true,
        ambiguousMembershipCommitRecoveredBeforeWelcome: true,
        secondRecipientJoined: true,
        threeMemberMessageDecrypted: true,
        founderRestartRestoredGroup: true,
        postRestartMessageDecrypted: true,
        plaintextNotPresentInCiphertext: true,
        memberRemovalCommitted: true,
        unknownMemberRemovalRejected: true,
        remainingMemberProcessedRemovalCommit: true,
        replayedRemovalCommitRejected: true,
        founderRestartRestoredPostRemovalEpoch: true,
        remainingMemberRestartRestoredPostRemovalEpoch: true,
        staleEpochMessageRejected: true,
        postRemovalEpochMessageDecrypted: true,
        removedMemberRejectedNewEpoch: true,
        aliceFinalGeneration: postRemovalSent.generation,
        bobFinalGeneration: staleBobMessage.generation,
        charlieFinalGeneration: charliePostRemoval.generation
      };
    } finally {
      aliceWorker.terminate();
      bobWorker.terminate();
      charlieWorker.terminate();
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
        store.delete(`${charlie.accountId}|${charlie.deviceId}`);
        tx.oncomplete = resolve;
        tx.onerror = () => reject(tx.error);
      });
      db.close();

      const root = await navigator.storage.getDirectory();
      for (const participant of [alice, bob, charlie]) {
        const digest = new Uint8Array(await crypto.subtle.digest(
          "SHA-256",
          encode(`baddielink|runtime|v1|${participant.accountId}|${participant.deviceId}`)
        ));
        const suffix = Array.from(digest, byte => byte.toString(16).padStart(2, "0")).join("");
        await root.removeEntry(`baddielink-mls-${suffix}.journal`).catch(() => {});
      }
    }
  });

  console.log("PASS: worker-owned three-member MLS lifecycle and member removal.");
  console.log(JSON.stringify(result));
  await context.close();
} finally {
  await browser.close();
}
