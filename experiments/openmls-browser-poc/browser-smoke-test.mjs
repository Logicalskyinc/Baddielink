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
  const runButton = page.locator("#run");
  await runButton.waitFor({ state: "visible" });
  await page.waitForFunction(() => {
    const output = document.querySelector("#output")?.textContent ?? "";
    return output.includes("WebAssembly initialized.") ||
      output.includes("WebAssembly initialization failed:");
  }, { timeout: 60_000 });

  const initialization = await page.locator("#output").innerText();
  if (initialization.includes("initialization failed")) {
    throw new Error("Browser WebAssembly initialization failed:\\n" +
      initialization + "\\nBrowser errors: " + browserErrors.join("\\n"));
  }
  if (await runButton.isDisabled()) {
    throw new Error("MLS test button stayed disabled after initialization. Browser errors: " +
      browserErrors.join("\\n"));
  }

  await runButton.click();
  await page.waitForFunction(() => {
    const output = document.querySelector("#output")?.textContent ?? "";
    return output.includes("RESULT:") || output.includes("FAIL:");
  }, { timeout: 60_000 });

  const output = await page.locator("#output").innerText();
  console.log(output);
  if (!output.includes("RESULT: local group round-trip checks passed.")) {
    throw new Error("Browser MLS round-trip did not pass.");
  }
} finally {
  await browser.close();
}
