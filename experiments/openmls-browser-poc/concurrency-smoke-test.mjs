import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto("http://127.0.0.1:4173/index.html");

  const result = await page.evaluate(async () => {
    const { withMlsGroupLock } = await import("/mls-lock.js");
    const scope = {
      accountId: "poc-account",
      deviceId: "poc-device",
      groupId: "poc-group",
    };
    let active = 0;
    let maxActive = 0;
    const completed = [];

    const jobs = [1, 2, 3].map((id) =>
      withMlsGroupLock(scope, async () => {
        active += 1;
        maxActive = Math.max(maxActive, active);
        await new Promise((resolve) => setTimeout(resolve, 40));
        completed.push(id);
        active -= 1;
        return id;
      })
    );

    const values = await Promise.all(jobs);
    if (maxActive !== 1) {
      throw new Error(`Same-group MLS mutations overlapped: max active=${maxActive}`);
    }
    if (values.slice().sort().join(",") !== "1,2,3") {
      throw new Error("A serialized MLS lock operation did not complete.");
    }

    let rejected = false;
    try {
      await withMlsGroupLock(scope, async () => {
        throw new Error("intentional lock-release test");
      });
    } catch (error) {
      rejected = error.message === "intentional lock-release test";
    }
    if (!rejected) throw new Error("Lock operation error was not propagated.");

    const afterFailure = await withMlsGroupLock(scope, async () => "lock released");
    if (afterFailure !== "lock released") {
      throw new Error("MLS lock was not released after an operation failed.");
    }

    return { maxActive, completed, afterFailure };
  });

  console.log("PASS: same account/device/group mutations were serialized.");
  console.log("PASS: lock released after operation failure.");
  console.log(JSON.stringify(result));
} finally {
  await browser.close();
}
