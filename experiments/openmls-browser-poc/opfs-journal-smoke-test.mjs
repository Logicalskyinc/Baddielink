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
        else reject(Object.assign(new Error(data.error), { name: data.errorName, commitMayHaveSucceeded: data.commitMayHaveSucceeded }));
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

      // Failures before the commit marker must leave generation 3 authoritative.
      for (const faultAt of ["before-data-write", "after-data-flush", "before-commit-marker"]) {
        let rejected = false;
        try {
          await request("commit", { generation: 4, bytes: bytes("candidate-four").buffer, faultAt });
        } catch (error) {
          rejected = /Injected failure/.test(error.message) && error.commitMayHaveSucceeded === false;
        }
        if (!rejected) throw new Error(`Failure injection did not fail safely at ${faultAt}.`);
        const recovered = await request("recover");
        if (recovered.generation !== 3 || text(recovered.bytes) !== "checkpoint-three") {
          throw new Error(`Uncommitted candidate became visible after ${faultAt}.`);
        }
      }

      // Once the commit marker is flushed, an acknowledgement/read-back failure is
      // ambiguous to the caller: recovery must reveal whether generation 4 committed.
      let postMarkerGeneration = 4;
      for (const faultAt of ["after-commit-marker", "during-readback"]) {
        const generation = postMarkerGeneration++;
        const payload = `candidate-${generation}`;
        let rejected = false;
        try {
          await request("commit", { generation, bytes: bytes(payload).buffer, faultAt });
        } catch (error) {
          rejected = /Injected failure/.test(error.message) && error.commitMayHaveSucceeded === true;
        }
        if (!rejected) throw new Error(`Post-marker failure was not reported as ambiguous at ${faultAt}.`);
        const recovered = await request("recover");
        if (recovered.generation !== generation || text(recovered.bytes) !== payload) {
          throw new Error(`Committed generation could not be reconciled after ${faultAt}.`);
        }
      }

      const sizeBeforeCorruption = (await request("stat")).size;
      await request("append-corrupt-frame", { bytes: new Uint8Array(14).fill(0).buffer });
      const sizeAfterCorruption = (await request("stat")).size;
      let malformedFrameRejected = false;
      try {
        await request("recover");
      } catch (error) {
        malformedFrameRejected = /corruption/.test(error.message);
      }
      if (!malformedFrameRejected) throw new Error("A malformed complete frame was not rejected.");
      const sizeAfterFailedRecovery = (await request("stat")).size;
      if (sizeAfterFailedRecovery !== sizeAfterCorruption || sizeAfterCorruption <= sizeBeforeCorruption) {
        throw new Error("Fail-closed recovery modified the corrupted journal.");
      }

      return {
        uncommittedStageIgnored: true,
        tornTailDetectedAndRepaired: true,
        commitAfterRepair: true,
        latestGeneration: reopened.generation,
        persistedAfterReopen: true,
        staleGenerationRejected,
        malformedFrameRejected,
        corruptedJournalLeftUntouched: sizeAfterFailedRecovery === sizeAfterCorruption
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
  console.log("PASS: pre-marker failures preserve the previous committed generation.");
  console.log("PASS: post-marker failures report ambiguous outcome and reconcile from recovery.");
  console.log("PASS: malformed complete frame is rejected without truncating the journal.");
  console.log(JSON.stringify(result));
} finally {
  await browser.close();
}
