"use strict";

var NATIVE_APP_ID = "com.laika.Laika";
var statusEl = document.getElementById("native-status");
var goalInput = document.getElementById("goal");
var sendButton = document.getElementById("send");
var chatLog = document.getElementById("chat-log");
var settingsButton = document.getElementById("open-settings");
var closeButton = document.getElementById("close-sidecar");
var isPanelWindow = false;

var DEFAULT_MAX_TOKENS = 2048;
var MAX_TOKENS_CAP = 8192;
var maxTokensSetting = DEFAULT_MAX_TOKENS;

var lastObservation = null;
var lastObservationTabId = null;
var lastAssistantSummary = "";
var planValidator = window.LaikaPlanValidator || {
  validatePlanResponse: function () {
    return { ok: true };
  }
};

var MAX_AGENT_STEPS = 6;
var MAX_OBSERVE_STEPS = 2;
var DEFAULT_OBSERVE_OPTIONS = {
  maxChars: 8000,
  maxElements: 120,
  maxBlocks: 30,
  maxPrimaryChars: 1200,
  maxOutline: 60,
  maxOutlineChars: 160
};
var DEFAULT_ASSIST_OPTIONS = {
  maxChars: 8000,
  maxElements: 120,
  maxBlocks: 24,
  maxPrimaryChars: 900,
  maxOutline: 40,
  maxOutlineChars: 140
};
var DETAIL_SUMMARY_OPTIONS = {
  maxChars: 16000,
  maxElements: 200,
  maxBlocks: 50,
  maxPrimaryChars: 1800,
  maxOutline: 80,
  maxOutlineChars: 180
};

function logDebug(text) {
  if (typeof console !== "undefined" && console.debug) {
    console.debug("[Laika]", text);
  }
}

function openSettings() {
  if (typeof browser !== "undefined" && browser.runtime) {
    if (browser.runtime.openOptionsPage) {
      browser.runtime.openOptionsPage();
      return;
    }
    if (browser.runtime.getURL && browser.tabs && browser.tabs.create) {
      browser.tabs.create({ url: browser.runtime.getURL("options.html") });
      return;
    }
  }
  appendMessage("system", "Unable to open settings.");
}

function closeSidecar() {
  if (isPanelWindow) {
    if (typeof browser !== "undefined" && browser.runtime && browser.runtime.sendMessage) {
      try {
        var request = browser.runtime.sendMessage({ type: "laika.panel.close" });
        if (request && request.catch) {
          request.catch(function () {
          });
        }
      } catch (error) {
      }
    }
    try {
      window.close();
    } catch (error) {
    }
    return;
  }
  if (typeof browser === "undefined" || !browser.runtime) {
    return;
  }
  if (browser.runtime.sendMessage) {
    var request = browser.runtime.sendMessage({ type: "laika.sidecar.hide" });
    if (request && request.catch) {
      request.catch(function () {
      });
    }
  }
}

function clampMaxTokens(value) {
  if (typeof value !== "number" || !isFinite(value)) {
    return DEFAULT_MAX_TOKENS;
  }
  var rounded = Math.floor(value);
  if (rounded < 64) {
    return 64;
  }
  if (rounded > MAX_TOKENS_CAP) {
    return MAX_TOKENS_CAP;
  }
  return rounded;
}

async function loadMaxTokens() {
  if (!browser.storage || !browser.storage.local) {
    maxTokensSetting = DEFAULT_MAX_TOKENS;
    return;
  }
  try {
    var stored = await browser.storage.local.get({ maxTokens: DEFAULT_MAX_TOKENS });
    maxTokensSetting = clampMaxTokens(stored.maxTokens);
  } catch (error) {
    maxTokensSetting = DEFAULT_MAX_TOKENS;
  }
}

function setStatus(text) {
  statusEl.textContent = text;
  logDebug("status: " + text);
}

function labelForRole(role) {
  if (role === "user") {
    return "you";
  }
  if (role === "assistant") {
    return "Laika";
  }
  if (role === "system") {
    return "status";
  }
  return role;
}

function appendMessage(role, text) {
  var message = document.createElement("div");
  message.className = "message";
  var label = document.createElement("strong");
  label.textContent = labelForRole(role);
  var body = document.createElement("div");
  body.textContent = text;
  message.appendChild(label);
  message.appendChild(body);
  chatLog.appendChild(message);
  chatLog.scrollTop = chatLog.scrollHeight;
  return message;
}

function explainMissingContext() {
  appendMessage("system", "No page context available. Open a webpage and try again, or paste the key info here.");
}

function isObservationEmpty(observation) {
  if (!observation) {
    return true;
  }
  var text = (observation.text || "").trim();
  var title = (observation.title || "").trim();
  var elements = Array.isArray(observation.elements) ? observation.elements : [];
  return text.length === 0 && title.length === 0 && elements.length === 0;
}

function formatToolCall(action) {
  var name = action.toolCall.name;
  var args = action.toolCall.arguments || {};
  var argText = Object.keys(args)
    .map(function (key) {
      return key + "=" + JSON.stringify(args[key]);
    })
    .join(", ");
  return name + (argText ? " (" + argText + ")" : "");
}

function appendActionPrompt(action, tabId) {
  return new Promise(function (resolve) {
  var message = document.createElement("div");
  message.className = "message";
  var label = document.createElement("strong");
  label.textContent = "action";
  var body = document.createElement("div");
  body.textContent = formatToolCall(action);
  var buttons = document.createElement("div");
  buttons.className = "action-buttons";
  var approveButton = document.createElement("button");
  approveButton.textContent = "Approve";
  var rejectButton = document.createElement("button");
  rejectButton.textContent = "Reject";

  approveButton.addEventListener("click", function () {
    approveButton.disabled = true;
    rejectButton.disabled = true;
    runTool(action, tabId).then(function (result) {
      resolve({ decision: "approve", result: result });
    });
  });
  rejectButton.addEventListener("click", function () {
    approveButton.disabled = true;
    rejectButton.disabled = true;
    appendMessage("system", "Action rejected: " + formatToolCall(action));
    resolve({ decision: "reject", result: null });
  });

  buttons.appendChild(approveButton);
  buttons.appendChild(rejectButton);
  message.appendChild(label);
  message.appendChild(body);
  message.appendChild(buttons);
  chatLog.appendChild(message);
  chatLog.scrollTop = chatLog.scrollHeight;
  });
}

async function sendNativeMessage(payload) {
  if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendNativeMessage) {
    throw new Error("native_messaging_unavailable");
  }
  try {
    return await browser.runtime.sendNativeMessage(payload);
  } catch (error) {
    if (!NATIVE_APP_ID) {
      throw error;
    }
    return await browser.runtime.sendNativeMessage(NATIVE_APP_ID, payload);
  }
}

async function checkNative() {
  setStatus("Native: checking...");
  try {
    var response = await sendNativeMessage({ type: "ping" });
    if (response && response.ok) {
      setStatus("Native: ready");
      return;
    }
    setStatus("Native: error");
  } catch (error) {
    setStatus("Native: offline");
  }
}

async function observePage() {
  var result;
  try {
    result = await browser.runtime.sendMessage({
      type: "laika.observe",
      options: DEFAULT_OBSERVE_OPTIONS
    });
  } catch (error) {
    throw new Error("no_context");
  }
  if (!result || typeof result.status === "undefined") {
    throw new Error("no_context");
  }
  if (result.status !== "ok") {
    throw new Error(result.error || "observe_failed");
  }
  if (isObservationEmpty(result.observation)) {
    throw new Error("no_context");
  }
  if (typeof result.tabId === "number") {
    lastObservationTabId = result.tabId;
  } else {
    lastObservationTabId = null;
  }
  return { observation: result.observation, tabId: lastObservationTabId };
}

async function listTabContext() {
  if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendMessage) {
    return [];
  }
  try {
    var response = await browser.runtime.sendMessage({ type: "laika.tabs.list" });
    if (response && response.status === "ok" && Array.isArray(response.tabs)) {
      return response.tabs;
    }
  } catch (error) {
  }
  return [];
}

function sleep(ms) {
  return new Promise(function (resolve) {
    setTimeout(resolve, ms);
  });
}

async function observeWithRetries(options, tabId) {
  var attempts = 5;
  for (var i = 0; i < attempts; i += 1) {
    try {
      var result = await browser.runtime.sendMessage({
        type: "laika.observe",
        options: options || DEFAULT_OBSERVE_OPTIONS,
        tabId: typeof tabId === "number" ? tabId : undefined
      });
      if (result && result.status === "ok" && result.observation && !isObservationEmpty(result.observation)) {
        return { observation: result.observation, tabId: typeof result.tabId === "number" ? result.tabId : tabId };
      }
    } catch (error) {
    }
    await sleep(250);
  }
  throw new Error("observe_failed");
}

async function requestPlan(goal, context) {
  var origin = "";
  try {
    origin = new URL(context.observation.url).origin;
  } catch (error) {
    origin = (context.observation && context.observation.url) || "";
  }
  var payload = {
    type: "plan",
    maxTokens: clampMaxTokens(maxTokensSetting),
    request: {
      goal: goal,
      context: {
        origin: origin,
        mode: context.mode || "assist",
        runId: context.runId || null,
        step: typeof context.step === "number" ? context.step : null,
        maxSteps: typeof context.maxSteps === "number" ? context.maxSteps : null,
        observation: context.observation,
        recentToolCalls: Array.isArray(context.recentToolCalls) ? context.recentToolCalls : [],
        recentToolResults: Array.isArray(context.recentToolResults) ? context.recentToolResults : [],
        tabs: Array.isArray(context.tabs) ? context.tabs : []
      }
    }
  };
  return await sendNativeMessage(payload);
}

async function runTool(action, tabId) {
  logDebug("Running tool " + action.toolCall.name);
  try {
    var payload = {
      type: "laika.tool",
      toolName: action.toolCall.name,
      args: action.toolCall.arguments || {}
    };
    if (typeof tabId === "number") {
      payload.tabId = tabId;
    }
    var result = await browser.runtime.sendMessage(payload);
    if (!result || typeof result.status !== "string") {
      appendMessage("system", "Tool failed: no_response");
      return { status: "error", error: "no_response" };
    }
    if (result.status !== "ok") {
      appendMessage("system", "Tool failed: " + (result.error || "unknown"));
      return result;
    }
    return result;
  } catch (error) {
    appendMessage("system", "Tool error: " + error.message);
    return { status: "error", error: error.message };
  }
}

function buildToolResult(toolCall, toolName, rawResult) {
  var status = rawResult && rawResult.status === "ok" ? "ok" : "error";
  var payload = {};
  if (rawResult && rawResult.error) {
    payload.error = rawResult.error;
  }
  if (toolName === "browser.open_tab" && rawResult && typeof rawResult.tabId === "number") {
    payload.tabId = rawResult.tabId;
  }
  if (toolName === "browser.observe_dom" && rawResult && rawResult.observation) {
    payload.url = rawResult.observation.url || "";
    payload.title = rawResult.observation.title || "";
    payload.textChars = (rawResult.observation.text || "").length;
    payload.elementCount = Array.isArray(rawResult.observation.elements) ? rawResult.observation.elements.length : 0;
    payload.blockCount = Array.isArray(rawResult.observation.blocks) ? rawResult.observation.blocks.length : 0;
    payload.outlineCount = Array.isArray(rawResult.observation.outline) ? rawResult.observation.outline.length : 0;
    payload.primaryChars = rawResult.observation.primary && rawResult.observation.primary.text
      ? String(rawResult.observation.primary.text).length
      : 0;
  }
  return {
    toolCallId: toolCall.id,
    status: status,
    payload: payload
  };
}

function pickNextAction(actions) {
  if (!Array.isArray(actions)) {
    return null;
  }
  for (var i = 0; i < actions.length; i += 1) {
    var action = actions[i];
    if (!action || !action.toolCall || !action.policy) {
      continue;
    }
    if (action.policy.decision === "allow" || action.policy.decision === "ask") {
      return action;
    }
  }
  return null;
}

function generateRunId() {
  return String(Date.now()) + "-" + Math.random().toString(16).slice(2);
}

function generateToolId() {
  return "tool-" + generateRunId();
}

function extractTopicIndex(goal) {
  var text = String(goal || "").toLowerCase();
  if (text.indexOf("first") >= 0 || text.indexOf("1st") >= 0) {
    return 1;
  }
  if (text.indexOf("second") >= 0 || text.indexOf("2nd") >= 0) {
    return 2;
  }
  if (text.indexOf("third") >= 0 || text.indexOf("3rd") >= 0) {
    return 3;
  }
  return null;
}

function isTopicDetailGoal(goal) {
  var text = String(goal || "").toLowerCase();
  if (!text) {
    return false;
  }
  var hasTopicKeyword =
    text.indexOf("topic") >= 0 ||
    text.indexOf("link") >= 0 ||
    text.indexOf("item") >= 0 ||
    text.indexOf("story") >= 0 ||
    text.indexOf("post") >= 0;
  var hasTellIntent =
    text.indexOf("tell me") >= 0 ||
    text.indexOf("tell us") >= 0 ||
    text.indexOf("describe") >= 0 ||
    text.indexOf("explain") >= 0 ||
    text.indexOf("about the") >= 0;
  if (!hasTopicKeyword || extractTopicIndex(goal) === null) {
    return false;
  }
  if (hasTellIntent) {
    return true;
  }
  return text.trim().endsWith("?") || text.trim().length <= 40;
}

function isMainLinkLabel(label) {
  var excluded = {
    "new": true,
    "past": true,
    "comments": true,
    "ask": true,
    "show": true,
    "jobs": true,
    "submit": true,
    "login": true,
    "logout": true,
    "hide": true,
    "reply": true,
    "flag": true,
    "edit": true,
    "more": true,
    "next": true,
    "prev": true,
    "previous": true,
    "upvote": true,
    "downvote": true
  };
  var trimmed = String(label || "").trim();
  if (!trimmed) {
    return false;
  }
  var lower = trimmed.toLowerCase();
  if (excluded[lower]) {
    return false;
  }
  if (trimmed.length < 12) {
    return false;
  }
  return trimmed.indexOf(" ") >= 0;
}

function mainLinkCandidates(elements) {
  if (!Array.isArray(elements)) {
    return [];
  }
  return elements.filter(function (element) {
    return element &&
      String(element.role || "").toLowerCase() === "a" &&
      element.href &&
      isMainLinkLabel(element.label);
  });
}

function commentLinkCandidates(elements) {
  if (!Array.isArray(elements)) {
    return [];
  }
  return elements.filter(function (element) {
    if (!element || String(element.role || "").toLowerCase() !== "a") {
      return false;
    }
    var label = String(element.label || "").toLowerCase();
    var href = String(element.href || "");
    if (!href || href.indexOf("item?id=") === -1) {
      return false;
    }
    return label.indexOf("comment") >= 0 || label.indexOf("discuss") >= 0;
  });
}

function pickCommentLinkForMain(mainLink, commentLinks) {
  if (!mainLink || !mainLink.boundingBox || !Array.isArray(commentLinks) || commentLinks.length === 0) {
    return null;
  }
  var best = null;
  var bestDelta = Infinity;
  for (var i = 0; i < commentLinks.length; i += 1) {
    var comment = commentLinks[i];
    if (!comment.boundingBox) {
      continue;
    }
    var delta = Math.abs(comment.boundingBox.y - mainLink.boundingBox.y);
    if (delta < bestDelta) {
      bestDelta = delta;
      best = comment;
    }
  }
  if (best && bestDelta <= 80) {
    return best;
  }
  return best || null;
}

async function requestSummary(goal, observation, tabsContext, runId, step, maxSteps) {
  var context = {
    mode: "observe",
    runId: runId,
    step: step,
    maxSteps: maxSteps,
    observation: observation,
    recentToolCalls: [],
    recentToolResults: [],
    tabs: Array.isArray(tabsContext) ? tabsContext : []
  };
  var response = await requestPlan(goal, context);
  if (!response || response.ok !== true) {
    throw new Error(response && response.error ? response.error : "plan_failed");
  }
  var plan = response.plan;
  var validation = planValidator.validatePlanResponse(plan);
  if (!validation.ok) {
    throw new Error("invalid_plan");
  }
  return plan.summary || "";
}

async function runApprovedTool(toolName, args, tabId) {
  var action = {
    toolCall: {
      id: generateToolId(),
      name: toolName,
      arguments: args || {}
    },
    policy: { decision: "ask", reasonCode: "workflow" }
  };
  var approval = await appendActionPrompt(action, tabId);
  if (!approval || approval.decision !== "approve") {
    return null;
  }
  return approval.result;
}

async function runTopicDetailWorkflow(goal, index, listObservation, tabsContext, runId) {
  if (!listObservation || !listObservation.observation) {
    throw new Error("no_context");
  }
  var elements = listObservation.observation.elements || [];
  var mainLinks = mainLinkCandidates(elements);
  if (mainLinks.length < index) {
    appendMessage("system", "Unable to find that topic on this page.");
    return true;
  }
  var mainLink = mainLinks[index - 1];
  var commentLinks = commentLinkCandidates(elements);
  var commentLink = pickCommentLinkForMain(mainLink, commentLinks);

  setStatus("Native: opening story...");
  var storyResult = await runApprovedTool("browser.open_tab", { url: mainLink.href }, listObservation.tabId);
  if (!storyResult || storyResult.status !== "ok") {
    appendMessage("system", "Stopped: story tab not opened.");
    return true;
  }
  var storyObservation = await observeWithRetries(DETAIL_SUMMARY_OPTIONS, storyResult.tabId);
  var storySummary = await requestSummary(
    "Summarize the linked page content in 6-8 sentences. Highlight key facts, names, and numbers. Avoid navigation.",
    storyObservation.observation,
    tabsContext,
    runId,
    1,
    1
  );

  var commentSummary = "";
  if (commentLink && commentLink.href) {
    setStatus("Native: opening comments...");
    var commentResult = await runApprovedTool("browser.open_tab", { url: commentLink.href }, listObservation.tabId);
    if (commentResult && commentResult.status === "ok") {
      var commentObservation = await observeWithRetries(DETAIL_SUMMARY_OPTIONS, commentResult.tabId);
      commentSummary = await requestSummary(
        "Summarize the key points raised in the comment thread in 6-8 bullet points or sentences. Mention at least 3 distinct arguments or themes and any notable numbers. Avoid navigation.",
        commentObservation.observation,
        tabsContext,
        runId,
        1,
        1
      );
    }
  }

  var finalLines = [];
  var label = (mainLink.label || "").trim();
  if (label) {
    finalLines.push("Topic: " + label);
  }
  if (storySummary) {
    finalLines.push("Story: " + storySummary);
  }
  if (commentSummary) {
    finalLines.push("Comments: " + commentSummary);
  } else {
    finalLines.push("Comments: No comment thread was available or it could not be opened.");
  }
  appendMessage("assistant", finalLines.join("\n"));
  return true;
}

function isActionGoal(goal) {
  var text = String(goal || "").toLowerCase();
  if (!text) {
    return false;
  }
  return (
    text.indexOf("click") >= 0 ||
    text.indexOf("open ") >= 0 ||
    text.indexOf("go to") >= 0 ||
    text.indexOf("navigate") >= 0 ||
    text.indexOf("first link") >= 0 ||
    text.indexOf("second link") >= 0 ||
    text.indexOf("next page") >= 0 ||
    text.indexOf("previous page") >= 0 ||
    text.indexOf("back") >= 0 ||
    text.indexOf("forward") >= 0 ||
    text.indexOf("scroll") >= 0 ||
    text.indexOf("type ") >= 0
  );
}

sendButton.addEventListener("click", async function () {
  var goal = goalInput.value.trim();
  if (!goal) {
    appendMessage("system", "Enter a message first.");
    return;
  }
  appendMessage("user", goal);
  goalInput.value = "";
  sendButton.disabled = true;
  lastObservationTabId = null;
  lastAssistantSummary = "";

  try {
    await loadMaxTokens();
    var runId = generateRunId();
    var tabsContext = await listTabContext();
    var firstObservation = await observeWithRetries(DEFAULT_ASSIST_OPTIONS, null);
    lastObservation = firstObservation.observation;
    var tabIdForPlan = firstObservation.tabId;

    if (isTopicDetailGoal(goal)) {
      var index = extractTopicIndex(goal);
      if (index !== null) {
        var handled = await runTopicDetailWorkflow(goal, index, firstObservation, tabsContext, runId);
        if (handled) {
          setStatus("Native: ready");
          return;
        }
      }
    }

    var mode = isActionGoal(goal) ? "assist" : "observe";
    var maxSteps = mode === "observe" ? MAX_OBSERVE_STEPS : MAX_AGENT_STEPS;
    var observeOptions = mode === "observe" ? DEFAULT_OBSERVE_OPTIONS : DEFAULT_ASSIST_OPTIONS;

    var recentToolCalls = [];
    var recentToolResults = [];

    for (var step = 1; step <= maxSteps; step += 1) {
      setStatus("Native: thinking...");
      var context = {
        mode: mode,
        runId: runId,
        step: step,
        maxSteps: maxSteps,
        observation: lastObservation,
        recentToolCalls: recentToolCalls.slice(-8),
        recentToolResults: recentToolResults.slice(-8),
        tabs: tabsContext
      };
      var response = await requestPlan(goal, context);
      if (!response || response.ok !== true) {
        appendMessage("system", "Plan failed: " + (response && response.error ? response.error : "unknown"));
        return;
      }
      var plan = response.plan;
      var validation = planValidator.validatePlanResponse(plan);
      if (!validation.ok) {
        appendMessage("system", "Invalid plan response: " + validation.error);
        return;
      }

      var nextAction = pickNextAction(plan.actions);
      if (!nextAction) {
        if (plan.summary && plan.summary !== lastAssistantSummary) {
          appendMessage("assistant", plan.summary);
          lastAssistantSummary = plan.summary;
        }
        break;
      }
      if (nextAction.policy.decision === "deny") {
        appendMessage("system", "Blocked: " + nextAction.policy.reasonCode);
        if (plan.summary && plan.summary !== lastAssistantSummary) {
          appendMessage("assistant", plan.summary);
          lastAssistantSummary = plan.summary;
        }
        break;
      }
      if (step === maxSteps) {
        appendMessage("system", "Step limit reached.");
        if (plan.summary && plan.summary !== lastAssistantSummary) {
          appendMessage("assistant", plan.summary);
          lastAssistantSummary = plan.summary;
        }
        break;
      }

      var approval = null;
      if (nextAction.policy.decision === "ask") {
        if (plan.summary && plan.summary !== lastAssistantSummary) {
          appendMessage("assistant", plan.summary);
          lastAssistantSummary = plan.summary;
        }
        approval = await appendActionPrompt(nextAction, tabIdForPlan);
        if (!approval || approval.decision !== "approve") {
          appendMessage("system", "Stopped: action not approved.");
          break;
        }
      } else {
        approval = { decision: "approve", result: await runTool(nextAction, tabIdForPlan) };
      }

      var toolResult = approval.result;
      recentToolCalls.push(nextAction.toolCall);
      recentToolResults.push(buildToolResult(nextAction.toolCall, nextAction.toolCall.name, toolResult));

      if (toolResult && typeof toolResult.tabId === "number") {
        tabIdForPlan = toolResult.tabId;
      }
      if (nextAction.toolCall.name === "browser.observe_dom" && toolResult && toolResult.observation) {
        lastObservation = toolResult.observation;
        if (typeof toolResult.tabId === "number") {
          tabIdForPlan = toolResult.tabId;
        }
      } else {
        tabsContext = await listTabContext();
        var updated = await observeWithRetries(observeOptions, tabIdForPlan);
        lastObservation = updated.observation;
        tabIdForPlan = updated.tabId;
      }
    }
    setStatus("Native: ready");
  } catch (error) {
    if (error && (error.message === "no_context" || error.message === "no_active_tab")) {
      explainMissingContext();
    } else {
      appendMessage("system", "Error: " + error.message);
    }
  } finally {
    sendButton.disabled = false;
  }
});

(function init() {
  try {
    isPanelWindow = window.top === window && new URL(window.location.href).searchParams.get("panel") === "1";
  } catch (error) {
    isPanelWindow = false;
  }
  loadMaxTokens();
  if (settingsButton) {
    settingsButton.addEventListener("click", openSettings);
  }
  if (closeButton) {
    closeButton.addEventListener("click", closeSidecar);
  }
  checkNative();
})();
