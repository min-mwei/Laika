const path = require("path");
const { pathToFileURL } = require("url");
const playwright = require("playwright");

const observeDefaults = require("../../extension/lib/observe_defaults");

const FIXTURES = [
  {
    file: "pitch_trip_planning.html",
    expects: ["Higashiyama Garden Hotel"]
  },
  {
    file: "sec_nvda.html",
    expects: ["NVIDIA CORPORATION", "NVDA"]
  },
  {
    file: "techmeme_maia_thread.html",
    expects: ["Maia 200"]
  }
];

function buildObserveOptions() {
  return observeDefaults.cloneOptions(observeDefaults.DEFAULT_OBSERVE_OPTIONS);
}

async function observeDom(page, options) {
  const observation = await page.evaluate((opts) => {
    if (!window.LaikaHarness || !window.LaikaHarness.observeDom) {
      return { __error: "missing_harness" };
    }
    return window.LaikaHarness.observeDom(opts || {});
  }, options || {});
  if (observation && observation.__error) {
    throw new Error(observation.__error);
  }
  return observation;
}

async function run() {
  const extensionRoot = path.resolve(__dirname, "../../extension");
  const fixtureRoot = path.resolve(__dirname, "../fixtures");
  const initScripts = [
    path.join(extensionRoot, "lib/text_utils.js"),
    path.join(extensionRoot, "lib/vendor/readability.js"),
    path.join(extensionRoot, "lib/vendor/turndown.js"),
    path.join(extensionRoot, "lib/markdown_postprocess.js"),
    path.join(extensionRoot, "content_script.js")
  ];

  const browser = await playwright.webkit.launch({ headless: true });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  await context.addInitScript(() => {
    window.__LAIKA_HARNESS__ = true;
  });
  for (const scriptPath of initScripts) {
    await context.addInitScript({ path: scriptPath });
  }

  const observeOptions = buildObserveOptions();
  for (const fixture of FIXTURES) {
    const page = await context.newPage();
    const fileUrl = pathToFileURL(path.join(fixtureRoot, fixture.file));
    await page.goto(fileUrl.href, { waitUntil: "domcontentloaded", timeout: 15000 });
    await page.waitForTimeout(200);
    const observation = await observeDom(page, observeOptions);
    const markdown = observation && typeof observation.markdown === "string" ? observation.markdown : "";
    if (!markdown.trim()) {
      throw new Error(`Empty markdown for fixture ${fixture.file}`);
    }
    for (const expected of fixture.expects) {
      if (!markdown.includes(expected)) {
        const snippet = markdown.slice(0, 400).replace(/\s+/g, " ").trim();
        throw new Error(`Missing "${expected}" in markdown for fixture ${fixture.file}. Snippet: ${snippet}`);
      }
    }
    await page.close();
  }

  await browser.close();
  console.log("Fixture capture tests passed.");
}

run().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
