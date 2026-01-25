#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const searchTools = require("../../extension/lib/search_tools");
const calculateTools = require("../../extension/lib/calculate");

// Automation runs get throttled by Google frequently. Default to DuckDuckGo here,
// while keeping the extension's default engine as Google.
const HARNESS_SEARCH_SETTINGS = searchTools.normalizeSettings({
  ...searchTools.DEFAULT_SETTINGS,
  mode: "redirect-default",
  defaultEngine: "duckduckgo",
  customTemplate: searchTools.PROVIDERS.duckduckgo.template
});

let playwright;
try {
  playwright = require("playwright");
} catch (error) {
  console.error("Playwright is required. Install with: npm install playwright");
  process.exit(1);
}

const DEFAULT_SERVER_URL = "http://127.0.0.1:8765";
const DEFAULT_MAX_STEPS = 6;
const DEFAULT_OBSERVE_DELAY_MS = 300;
const DETAIL_OBSERVE_DELAY_MS = 500;
const SEARCH_OBSERVE_DELAY_MS = 1500;
const EMPTY_OBSERVE_RETRY_DELAY_MS = 900;
const EMPTY_OBSERVE_MAX_RETRIES = 1;
const DEFAULT_OBSERVE_OPTIONS = {
  maxChars: 12000,
  maxElements: 160,
  maxBlocks: 40,
  maxPrimaryChars: 1600,
  maxOutline: 80,
  maxOutlineChars: 180,
  maxItems: 30,
  maxItemChars: 240,
  maxComments: 24,
  maxCommentChars: 360
};
const DETAIL_OBSERVE_OPTIONS = {
  maxChars: 16000,
  maxElements: 200,
  maxBlocks: 80,
  maxPrimaryChars: 4000,
  maxOutline: 120,
  maxOutlineChars: 240,
  maxItems: 60,
  maxItemChars: 400,
  maxComments: 40,
  maxCommentChars: 600
};

function usage() {
  console.log(
    [
      "Usage:",
      "  node scripts/laika_harness.js --url <url> --goal \"...\" [--goal \"...\"]",
      "  node scripts/laika_harness.js --scenario <path/to/scenario.json>",
      "",
      "Options:",
      "  --server <url>        Plan server base URL (default http://127.0.0.1:8765)",
      "  --browser <name>      webkit | chromium | firefox (default webkit)",
      "  --max-steps <n>        Max tool-call steps per goal (default 6)",
      "  --detail              Use larger observe_dom budgets",
      "  --headed              Show browser window",
      "  --observe-wait <ms>    Delay before observing after load/actions",
      "  --debug-observe        Include observe_dom debug payloads in output",
      "  --output <path>        Write run results to JSON",
      "  --no-auto-approve      Stop on policy 'ask' instead of auto-approving"
    ].join("\n")
  );
}

function parseArgs() {
  const args = process.argv.slice(2);
  const goals = [];
  let url = null;
  let scenarioPath = null;
  let server = DEFAULT_SERVER_URL;
  let browserName = "webkit";
  let maxSteps = DEFAULT_MAX_STEPS;
  let headless = true;
  let detail = false;
  let outputPath = null;
  let autoApprove = true;
  let observeDelayMs = null;
  let debugObserve = false;

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
      case "--url":
        url = args[++i] || null;
        break;
      case "--goal":
        goals.push(args[++i] || "");
        break;
      case "--scenario":
        scenarioPath = args[++i] || null;
        break;
      case "--server":
        server = args[++i] || server;
        break;
      case "--browser":
        browserName = (args[++i] || browserName).toLowerCase();
        break;
      case "--max-steps":
        maxSteps = parseInt(args[++i] || String(DEFAULT_MAX_STEPS), 10);
        break;
      case "--detail":
        detail = true;
        break;
      case "--headed":
        headless = false;
        break;
      case "--output":
        outputPath = args[++i] || null;
        break;
      case "--observe-wait":
        observeDelayMs = parseInt(args[++i] || "0", 10);
        break;
      case "--debug-observe":
        debugObserve = true;
        break;
      case "--no-auto-approve":
        autoApprove = false;
        break;
      default:
        break;
    }
  }

  if (scenarioPath) {
    return {
      scenarioPath,
      server,
      browserName,
      maxSteps,
      headless,
      detail,
      outputPath,
      autoApprove,
      observeDelayMs,
      debugObserve
    };
  }
  if (!url || goals.length === 0) {
    return null;
  }
  return {
    url,
    goals,
    server,
    browserName,
    maxSteps,
    headless,
    detail,
    outputPath,
    autoApprove,
    observeDelayMs,
    debugObserve
  };
}

function loadScenario(scenarioPath) {
  const raw = fs.readFileSync(scenarioPath, "utf8");
  const payload = JSON.parse(raw);
  if (!payload || typeof payload.url !== "string" || !Array.isArray(payload.goals)) {
    throw new Error("Scenario must include url and goals array.");
  }
  return payload;
}

function pickNextAction(actions) {
  if (!Array.isArray(actions)) {
    return null;
  }
  for (const action of actions) {
    if (!action || !action.toolCall || !action.policy) {
      continue;
    }
    if (action.policy.decision === "allow" || action.policy.decision === "ask") {
      return action;
    }
  }
  return null;
}

async function callPlan(server, planRequest) {
  const response = await fetch(`${server}/plan`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(planRequest)
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(`Plan failed: ${response.status} ${text}`);
  }
  return await response.json();
}

function buildTabs(observation) {
  if (!observation || !observation.url) {
    return [];
  }
  let origin = "";
  try {
    origin = new URL(observation.url).origin;
  } catch (error) {
    origin = "";
  }
  return [
    {
      title: observation.title || "",
      url: observation.url,
      origin: origin,
      isActive: true
    }
  ];
}

function isDocument(doc) {
  return doc && typeof doc === "object" && doc.type === "doc" && Array.isArray(doc.children);
}

function renderPlainInline(nodes) {
  if (!Array.isArray(nodes)) {
    return "";
  }
  return nodes.map((node) => renderPlainNode(node)).join("").trim();
}

function renderPlainList(items, ordered) {
  if (!Array.isArray(items) || items.length === 0) {
    return "";
  }
  const lines = items.map((item, index) => {
    const content = renderPlainBlock(item);
    const prefix = ordered ? `${index + 1}. ` : "- ";
    return `${prefix}${content}`;
  });
  return lines.join("\n");
}

function renderPlainBlock(node) {
  if (!node || typeof node !== "object") {
    return "";
  }
  switch (node.type) {
  case "heading":
    return renderPlainInline(node.children);
  case "paragraph":
    return renderPlainInline(node.children);
  case "list":
    return renderPlainList(node.items, !!node.ordered);
  case "list_item":
    return renderPlainInline(node.children);
  case "blockquote": {
    const inner = renderPlainInline(node.children);
    return inner ? `> ${inner}` : "";
  }
  case "code_block":
    return typeof node.text === "string" ? node.text.trim() : "";
  case "text":
    return typeof node.text === "string" ? node.text : "";
  case "link":
    return renderPlainInline(node.children);
  default:
    return "";
  }
}

function renderPlainNode(node) {
  return renderPlainBlock(node);
}

function plainTextFromDocument(doc) {
  if (!isDocument(doc)) {
    return "";
  }
  const parts = doc.children.map((child) => renderPlainBlock(child)).filter(Boolean);
  return parts.join("\n").trim();
}

function extractPlanSummary(plan) {
  if (plan && plan.assistant && isDocument(plan.assistant.render)) {
    const text = plainTextFromDocument(plan.assistant.render);
    if (text) {
      return text;
    }
  }
  if (plan && typeof plan.summary === "string") {
    return plan.summary;
  }
  return "";
}

function buildToolResult(toolCall, status, payload) {
  return {
    toolCallId: toolCall.id,
    status: status,
    payload: payload || {}
  };
}

function summarizeObservation(observation) {
  if (!observation) {
    return null;
  }
  const isCommentLink = (link) => {
    if (!link) {
      return false;
    }
    const text = String(link.title || "").toLowerCase();
    const url = String(link.url || "").toLowerCase();
    return (
      text.includes("comment") ||
      text.includes("discuss") ||
      text.includes("reply") ||
      url.includes("comment") ||
      url.includes("discussion") ||
      url.includes("thread") ||
      url.includes("#comments")
    );
  };
  const items = Array.isArray(observation.items) ? observation.items : [];
  const comments = Array.isArray(observation.comments) ? observation.comments : [];
  const summaryItems = items.slice(0, 5).map((item) => {
    const links = Array.isArray(item.links) ? item.links : [];
    const summaryLinks = [];
    for (const link of links) {
      if (!link || !link.title || !link.url) {
        continue;
      }
      if (summaryLinks.length < 2) {
        summaryLinks.push(link);
      }
    }
    if (summaryLinks.length < 3) {
      const commentLink = links.find((link) => isCommentLink(link));
      if (commentLink && !summaryLinks.some((entry) => entry.url === commentLink.url)) {
        summaryLinks.push(commentLink);
      }
    }
    for (const link of links) {
      if (summaryLinks.length >= 3) {
        break;
      }
      if (!link || !link.title || !link.url) {
        continue;
      }
      if (!summaryLinks.some((entry) => entry.url === link.url && entry.title === link.title)) {
        summaryLinks.push(link);
      }
    }
    return {
      title: item.title || "",
      url: item.url || "",
      linkCount: links.length,
      links: summaryLinks.map((link) => ({
        title: link.title || "",
        url: link.url || ""
      }))
    };
  });
  const summaryComments = comments.slice(0, 3).map((comment) => ({
    author: comment.author || "",
    age: comment.age || "",
    text: (comment.text || "").slice(0, 140)
  }));
  const summary = {
    url: observation.url || "",
    title: observation.title || "",
    textChars: (observation.text || "").length,
    elementCount: Array.isArray(observation.elements) ? observation.elements.length : 0,
    blockCount: Array.isArray(observation.blocks) ? observation.blocks.length : 0,
    itemCount: items.length,
    outlineCount: Array.isArray(observation.outline) ? observation.outline.length : 0,
    commentCount: comments.length,
    primaryChars: observation.primary && observation.primary.text ? String(observation.primary.text).length : 0,
    items: summaryItems,
    comments: summaryComments
  };
  if (observation.debug && typeof observation.debug === "object") {
    summary.debug = observation.debug;
  }
  return summary;
}

function buildObservePayload(observation) {
  if (!observation) {
    return {};
  }
  return {
    url: observation.url || "",
    title: observation.title || "",
    documentId: observation.documentId || "",
    navGeneration: typeof observation.navGeneration === "number" ? observation.navGeneration : null,
    observedAtMs: typeof observation.observedAtMs === "number" ? observation.observedAtMs : null,
    textChars: (observation.text || "").length,
    elementCount: Array.isArray(observation.elements) ? observation.elements.length : 0,
    blockCount: Array.isArray(observation.blocks) ? observation.blocks.length : 0,
    itemCount: Array.isArray(observation.items) ? observation.items.length : 0,
    outlineCount: Array.isArray(observation.outline) ? observation.outline.length : 0,
    primaryChars: observation.primary && observation.primary.text ? String(observation.primary.text).length : 0
  };
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

function isEmptyObservation(observation) {
  if (!observation) {
    return true;
  }
  const textLength = String(observation.text || "").trim().length;
  if (textLength > 0) {
    return false;
  }
  const arrays = ["elements", "blocks", "items", "outline", "comments"];
  for (const key of arrays) {
    if (Array.isArray(observation[key]) && observation[key].length > 0) {
      return false;
    }
  }
  const primaryText = observation.primary && observation.primary.text ? String(observation.primary.text) : "";
  if (primaryText.trim().length > 0) {
    return false;
  }
  return true;
}

async function waitForObserveDelay(page, delayMs) {
  if (typeof delayMs !== "number" || !isFinite(delayMs) || delayMs <= 0) {
    return;
  }
  await page.waitForTimeout(delayMs);
}

function resolveObserveDelayMs(detail, override) {
  if (typeof override === "number" && isFinite(override) && override >= 0) {
    return override;
  }
  return detail ? DETAIL_OBSERVE_DELAY_MS : DEFAULT_OBSERVE_DELAY_MS;
}

async function observeWithRetry(page, options, observeDelayMs) {
  let observation = await observeDom(page, options);
  let retries = 0;
  const retryDelay = Math.max(EMPTY_OBSERVE_RETRY_DELAY_MS, observeDelayMs || 0);
  while (retries < EMPTY_OBSERVE_MAX_RETRIES && isEmptyObservation(observation)) {
    retries += 1;
    await waitForObserveDelay(page, retryDelay);
    observation = await observeDom(page, options);
  }
  return { observation, retryCount: retries };
}

async function applyTool(page, toolName, args) {
  return await page.evaluate(
    (name, payload) => {
      if (!window.LaikaHarness || !window.LaikaHarness.applyTool) {
        return { status: "error", error: "missing_harness" };
      }
      return window.LaikaHarness.applyTool(name, payload || {});
    },
    toolName,
    args || {}
  );
}

async function executeTool(page, toolCall, observeOptions, navTimeoutMs, observeDelayMs) {
  const name = toolCall.name;
  const args = toolCall.arguments || {};
  let result = { status: "ok" };
  let observation = null;
  let retryCount = 0;
  if (name === "browser.observe_dom") {
    await waitForObserveDelay(page, observeDelayMs);
    const observed = await observeWithRetry(page, Object.keys(args).length ? args : observeOptions, observeDelayMs);
    observation = observed.observation;
    retryCount = observed.retryCount;
  } else if (name === "search") {
    const query = args.query;
    if (typeof query !== "string" || !query) {
      result = { status: "error", error: "missing_query" };
    } else {
      const built = searchTools.buildSearchUrl(query, args.engine || "", HARNESS_SEARCH_SETTINGS);
      if (!built || built.error) {
        result = { status: "error", error: built && built.error ? built.error : "search_failed" };
      } else {
        await page.goto(built.url, { waitUntil: "domcontentloaded", timeout: navTimeoutMs });
        result = { status: "ok", url: built.url, finalUrl: page.url(), engine: built.engine || "" };
        const searchDelay = Math.max(observeDelayMs || 0, SEARCH_OBSERVE_DELAY_MS);
        await waitForObserveDelay(page, searchDelay);
        const observed = await observeWithRetry(page, observeOptions, searchDelay);
        observation = observed.observation;
        retryCount = observed.retryCount;
      }
    }
  } else if (name === "browser.open_tab" || name === "browser.navigate") {
    const url = args.url;
    if (typeof url !== "string" || !url) {
      result = { status: "error", error: "missing_url" };
    } else {
      await page.goto(url, { waitUntil: "domcontentloaded", timeout: navTimeoutMs });
      await waitForObserveDelay(page, observeDelayMs);
      const observed = await observeWithRetry(page, observeOptions, observeDelayMs);
      observation = observed.observation;
      retryCount = observed.retryCount;
    }
  } else if (name === "browser.back") {
    await page.goBack({ waitUntil: "domcontentloaded", timeout: navTimeoutMs }).catch(() => {});
    await waitForObserveDelay(page, observeDelayMs);
    const observed = await observeWithRetry(page, observeOptions, observeDelayMs);
    observation = observed.observation;
    retryCount = observed.retryCount;
  } else if (name === "browser.forward") {
    await page.goForward({ waitUntil: "domcontentloaded", timeout: navTimeoutMs }).catch(() => {});
    await waitForObserveDelay(page, observeDelayMs);
    const observed = await observeWithRetry(page, observeOptions, observeDelayMs);
    observation = observed.observation;
    retryCount = observed.retryCount;
  } else if (name === "browser.refresh") {
    await page.reload({ waitUntil: "domcontentloaded", timeout: navTimeoutMs }).catch(() => {});
    await waitForObserveDelay(page, observeDelayMs);
    const observed = await observeWithRetry(page, observeOptions, observeDelayMs);
    observation = observed.observation;
    retryCount = observed.retryCount;
  } else if (name === "app.calculate") {
    if (!calculateTools || typeof calculateTools.evaluateExpression !== "function") {
      result = { status: "error", error: "calculator_unavailable" };
    } else if (typeof args.expression !== "string" || !args.expression) {
      result = { status: "error", error: "missing_expression" };
    } else {
      const precision = calculateTools.normalizePrecision(args.precision);
      if (!precision || !precision.ok) {
        result = { status: "error", error: "invalid_precision" };
      } else {
        const evaluated = calculateTools.evaluateExpression(args.expression);
        if (!evaluated || !evaluated.ok) {
          result = { status: "error", error: evaluated && evaluated.error ? evaluated.error : "invalid_expression" };
        } else {
          const formatted = calculateTools.formatValue(evaluated.value, precision.value);
          result = { status: "ok", result: formatted.result };
          if (precision.value !== null && typeof precision.value !== "undefined") {
            result.precision = precision.value;
          }
          if (formatted.formatted) {
            result.formatted = formatted.formatted;
          }
        }
      }
    }
  } else {
    const urlBefore = page.url();
    result = await applyTool(page, name, args);
    await waitForObserveDelay(page, observeDelayMs);
    if (page.url() !== urlBefore) {
      await page.waitForLoadState("domcontentloaded", { timeout: navTimeoutMs }).catch(() => {});
      await waitForObserveDelay(page, observeDelayMs);
    }
    const observed = await observeWithRetry(page, observeOptions, observeDelayMs);
    observation = observed.observation;
    retryCount = observed.retryCount;
  }
  return { result, observation, retryCount };
}

async function runGoals(state, goals, options) {
  const results = [];
  for (const goal of goals) {
    const goalSteps = [];
    let recentToolCalls = [];
    let recentToolResults = [];
    let summary = "";
    for (let step = 1; step <= options.maxSteps; step += 1) {
      const observation = state.observation;
      let origin = "";
      try {
        origin = new URL(observation.url).origin;
      } catch (error) {
        origin = "";
      }
      if (!origin || !origin.startsWith("http")) {
        throw new Error(`Invalid origin for plan request: ${observation.url}`);
      }
      const context = {
        origin: origin,
        mode: "assist",
        observation: observation,
        recentToolCalls: recentToolCalls.slice(-8),
        recentToolResults: recentToolResults.slice(-8),
        tabs: buildTabs(observation),
        runId: state.runId,
        step: step,
        maxSteps: options.maxSteps
      };
      const plan = await callPlan(options.server, { context, goal });
      summary = extractPlanSummary(plan);
      const goalPlan = plan.goalPlan || null;
      const planActions = Array.isArray(plan.actions) ? plan.actions : [];
      const action = pickNextAction(plan.actions);
      const stepInfo = {
        step: step,
        summary: summary,
        action: action ? action.toolCall : null,
        policy: action ? action.policy : null,
        goalPlan: goalPlan,
        planActions: planActions,
        observation: summarizeObservation(observation)
      };
      goalSteps.push(stepInfo);
      if (!action) {
        break;
      }
      if (action.policy && action.policy.decision === "deny") {
        break;
      }
      if (action.policy && action.policy.decision === "ask" && !options.autoApprove) {
        break;
      }
      const executed = await executeTool(
        state.page,
        action.toolCall,
        options.observeOptions,
        options.navTimeoutMs,
        options.observeDelayMs
      );
      recentToolCalls.push(action.toolCall);
      const payload = action.toolCall.name === "browser.observe_dom"
        ? buildObservePayload(executed.observation)
        : (action.toolCall.name === "search"
          ? {
              url: executed.result && executed.result.url ? executed.result.url : "",
              finalUrl: executed.result && executed.result.finalUrl ? executed.result.finalUrl : "",
              engine: executed.result && executed.result.engine ? executed.result.engine : ""
            }
          : (action.toolCall.name === "app.calculate"
            ? {
                result: executed.result && typeof executed.result.result === "number" ? executed.result.result : null,
                precision: executed.result && typeof executed.result.precision === "number" ? executed.result.precision : null,
                formatted: executed.result && typeof executed.result.formatted === "string" ? executed.result.formatted : null
              }
            : {}));
      recentToolResults.push(buildToolResult(action.toolCall, executed.result.status || "ok", payload));
      stepInfo.toolResult = executed.result;
      stepInfo.nextObservation = summarizeObservation(executed.observation);
      if (executed.retryCount) {
        stepInfo.nextObservationRetryCount = executed.retryCount;
      }
      if (executed.observation) {
        state.observation = executed.observation;
      }
    }
    results.push({ goal: goal, summary: summary, steps: goalSteps });
  }
  return results;
}

async function main() {
  const args = parseArgs();
  if (!args) {
    usage();
    process.exit(1);
  }

  let scenario = null;
  if (args.scenarioPath) {
    scenario = loadScenario(args.scenarioPath);
  }
  const url = scenario ? scenario.url : args.url;
  const goals = scenario ? scenario.goals : args.goals;
  const server = args.server;
  const observeOptions = args.detail ? DETAIL_OBSERVE_OPTIONS : DEFAULT_OBSERVE_OPTIONS;
  if (args.debugObserve) {
    observeOptions.debug = true;
  }
  const observeDelayMs = resolveObserveDelayMs(args.detail, args.observeDelayMs);

  const browserType = playwright[args.browserName] || playwright.webkit;
  const browser = await browserType.launch({ headless: args.headless });
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });

  const harnessFlag = () => {
    window.__LAIKA_HARNESS__ = true;
  };
  await context.addInitScript(harnessFlag);
  const contentScriptPath = path.resolve(__dirname, "../../extension/content_script.js");
  await context.addInitScript({ path: contentScriptPath });

  const page = await context.newPage();
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 15000 });
  await waitForObserveDelay(page, observeDelayMs);
  const initial = await observeWithRetry(page, observeOptions, observeDelayMs);
  const observation = initial.observation;

  const state = {
    page: page,
    observation: observation,
    runId: String(Date.now())
  };

  const results = await runGoals(state, goals, {
    server: server,
    observeOptions: observeOptions,
    navTimeoutMs: 15000,
    maxSteps: args.maxSteps,
    autoApprove: args.autoApprove,
    observeDelayMs: observeDelayMs
  });

  for (const result of results) {
    console.log("");
    console.log("Goal:", result.goal);
    console.log("Summary:", result.summary || "(empty)");
  }

  if (args.outputPath) {
    fs.writeFileSync(args.outputPath, JSON.stringify({ url, goals, results }, null, 2));
    console.log(`\nWrote results to ${args.outputPath}`);
  }

  await browser.close();
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
