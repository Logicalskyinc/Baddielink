import { chromium } from "playwright";

const browser = await chromium.launch({ headless: true });
try {
  const page = await browser.newPage();
  page.on("pageerror", (error) => {
    throw error;
  });

  await page.goto("http://127.0.0.1:4173/index.html");
  const runButton = page.locator("#run");
  await runButton.waitFor({ state: "visible" });
  await page.waitForFunction(() => {
    const button = document.querySelector("#run");
    return button && !button.disabled && button.textContent.includes("Run MLS");
  }, { timeout: 60_000 });

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
