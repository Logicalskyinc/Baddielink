import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  const browserErrors = [];
  page.on("console", (message) => {
    if (message.type() === "error") browserErrors.push(message.text());
  });
  page.on("pageerror", (error) => browserErrors.push(error.stack || error.message));

  await page.goto("http://127.0.0.1:4173/index.html");
  await page.waitForFunction(() => {
    const output = document.querySelector("#output")?.textContent ?? "";
    return output.includes("WebAssembly initialized.") ||
      output.includes("FAIL:");
  }, { timeout: 60_000 });

  const initialization = await page.locator("#output").innerText();
  if (initialization.includes("FAIL:")) {
    throw new Error("Browser initialization failed:\\n" + initialization);
  }

  const runButton = page.locator("#run");
  await runButton.waitFor({ state: "visible" });
  if (await runButton.isDisabled()) {
    throw new Error("Persistence test button remained disabled.");
  }

  await runButton.click();
  await page.waitForFunction(() => {
    const output = document.querySelector("#output")?.textContent ?? "";
    return output.includes("RESULT: browser reload persistence checks passed.") ||
      output.includes("FAIL:");
  }, { timeout: 60_000 });

  const output = await page.locator("#output").innerText();
  console.log(output);
  if (!output.includes("RESULT: browser reload persistence checks passed.")) {
    throw new Error("Browser reload persistence test failed. Browser errors: " +
      browserErrors.join("\\n"));
  }
} finally {
  await browser.close();
}
