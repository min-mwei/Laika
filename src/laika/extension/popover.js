"use strict";

var NATIVE_APP_ID = "com.laika.Laika";
var statusEl = document.getElementById("agent-status");
var goalInput = document.getElementById("goal");
var sendButton = document.getElementById("send");
var chatLog = document.getElementById("chat-log");
var closeButton = document.getElementById("close-sidecar");
var clearButton = document.getElementById("clear-chat");
var openPanelButton = document.getElementById("open-panel");
var isPanelWindow = false;

var DEFAULT_MAX_TOKENS = 3072;
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

var CHAT_HISTORY_KEY = "laika.chat.history.v1";
// Stored as a unix epoch ms watermark. Entries older than this are treated as deleted.
var CHAT_HISTORY_TOMBSTONE_KEY = "laika.chat.history.tombstone.v1";
var CHAT_HISTORY_LIMIT = 200;
// Keep persisted chat history comfortably under Safari's extension storage quota.
var CHAT_HISTORY_CHAR_BUDGET = 240000;
var chatHistory = [];
var chatHistoryLoaded = false;
var chatHistoryTombstone = 0;

var MESSAGE_FORMAT_PLAIN = "plain";
var MESSAGE_FORMAT_MARKDOWN = "markdown";
var markdownRenderer = null;
var sanitizerReady = false;
var MARKDOWN_SANITIZE_CONFIG = {
  ALLOWED_TAGS: [
    "p",
    "br",
    "ul",
    "ol",
    "li",
    "strong",
    "em",
    "code",
    "pre",
    "blockquote",
    "h2",
    "h3",
    "h4",
    "a"
  ],
  ALLOWED_ATTR: ["href", "title", "rel", "target"],
  ALLOW_DATA_ATTR: false,
  ALLOWED_URI_REGEXP: /^(https?:|mailto:)/i
};

var MAX_AGENT_STEPS = 6;
var DEFAULT_OBSERVE_OPTIONS = {
  maxChars: 12000,
  maxElements: 160,
  maxBlocks: 40,
  maxPrimaryChars: 1600,
  maxOutline: 80,
  maxOutlineChars: 180,
  maxItems: 30,
  maxItemChars: 240,
  maxComments: 28,
  maxCommentChars: 360
};

var DETAIL_OBSERVE_OPTIONS = {
  maxChars: 18000,
  maxElements: 180,
  maxBlocks: 60,
  maxPrimaryChars: 2400,
  maxOutline: 120,
  maxOutlineChars: 220,
  maxItems: 36,
  maxItemChars: 260,
  maxComments: 32,
  maxCommentChars: 420
};

function logDebug(text) {
  if (typeof console !== "undefined" && console.debug) {
    console.debug("[Laika]", text);
  }
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

function openPanelWindow() {
  if (isPanelWindow) {
    return;
  }
  if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendMessage) {
    return;
  }
  try {
    var request = browser.runtime.sendMessage({ type: "laika.panel.open" });
    if (request && request.catch) {
      request.catch(function () {
      });
    }
  } catch (error) {
  }
  // Prefer a single UI per window: once the panel opens, hide the in-page sidecar.
  closeSidecar();
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
  var output = text || "";
  if (output.indexOf("Status:") !== 0) {
    output = output.replace(/^Agent:/, "Status:");
    if (output.indexOf("Status:") !== 0) {
      output = "Status: " + output;
    }
  }
  statusEl.textContent = output;
  logDebug("status: " + output);
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

function normalizeMessageFormat(format) {
  if (format === MESSAGE_FORMAT_MARKDOWN) {
    return MESSAGE_FORMAT_MARKDOWN;
  }
  return MESSAGE_FORMAT_PLAIN;
}

function initMarkdownSupport() {
  if (!markdownRenderer && typeof window !== "undefined" && window.markdownit) {
    markdownRenderer = window.markdownit({
      html: false,
      linkify: true,
      breaks: false
    });
    markdownRenderer.disable(["table", "strikethrough"]);
  }
  if (!sanitizerReady && typeof window !== "undefined" && window.DOMPurify) {
    window.DOMPurify.addHook("afterSanitizeAttributes", function (node) {
      if (!node || !node.tagName) {
        return;
      }
      if (node.tagName.toLowerCase() !== "a") {
        return;
      }
      var href = node.getAttribute("href");
      if (!href) {
        node.removeAttribute("target");
        node.removeAttribute("rel");
        return;
      }
      node.setAttribute("target", "_blank");
      node.setAttribute("rel", "noopener noreferrer");
    });
    sanitizerReady = true;
  }
}

function renderMessageBody(body, text, format) {
  if (!body) {
    return;
  }
  initMarkdownSupport();
  var normalizedFormat = normalizeMessageFormat(format);
  var output = typeof text === "string" ? text : String(text || "");
  body.classList.toggle("markdown", normalizedFormat === MESSAGE_FORMAT_MARKDOWN);
  if (normalizedFormat === MESSAGE_FORMAT_MARKDOWN && markdownRenderer && window.DOMPurify) {
    var html = markdownRenderer.render(output);
    var sanitized = window.DOMPurify.sanitize(html, MARKDOWN_SANITIZE_CONFIG);
    body.innerHTML = sanitized;
  } else {
    body.textContent = output;
  }
}

function getMessageBody(message) {
  if (!message) {
    return null;
  }
  return message.querySelector(".message-body");
}

function generateHistoryId() {
  return String(Date.now()) + "-" + Math.random().toString(16).slice(2);
}

function timestampFromHistoryId(historyId) {
  if (!historyId) {
    return 0;
  }
  var head = String(historyId).split("-")[0] || "";
  var parsed = parseInt(head, 10);
  return Number.isFinite(parsed) ? parsed : 0;
}

function saveChatHistory() {
  try {
    if (browser.storage && browser.storage.local) {
      trimChatHistory();
      if (!chatHistory.length) {
        var removeRequest = browser.storage.local.remove(CHAT_HISTORY_KEY);
        if (removeRequest && removeRequest.catch) {
          removeRequest.catch(function (error) {
            logDebug("failed to remove chat history: " + String(error && error.message ? error.message : error));
          });
        }
        return;
      }
      var payload = {};
      payload[CHAT_HISTORY_KEY] = chatHistory;
      var request = browser.storage.local.set(payload);
      if (request && request.catch) {
        request.catch(function (error) {
          logDebug("failed to save chat history: " + String(error && error.message ? error.message : error));
          var message = String(error && error.message ? error.message : error).toLowerCase();
          if (message.indexOf("quota") >= 0 || message.indexOf("exceeded") >= 0) {
            // Drop older entries to recover from quota exhaustion.
            if (chatHistory.length > 20) {
              chatHistory = chatHistory.slice(Math.floor(chatHistory.length / 2));
              trimChatHistory();
              syncChatHistory(chatHistory);
              var retryPayload = {};
              retryPayload[CHAT_HISTORY_KEY] = chatHistory;
              var retry = browser.storage.local.set(retryPayload);
              if (retry && retry.catch) {
                retry.catch(function (retryError) {
                  logDebug("failed to save trimmed chat history: " + String(retryError && retryError.message ? retryError.message : retryError));
                });
              }
            }
          }
        });
      }
      return;
    }
  } catch (error) {
  }
  try {
    if (typeof sessionStorage === "undefined") {
      return;
    }
    trimChatHistory();
    if (!chatHistory.length) {
      sessionStorage.removeItem(CHAT_HISTORY_KEY);
      return;
    }
    sessionStorage.setItem(CHAT_HISTORY_KEY, JSON.stringify(chatHistory));
  } catch (error) {
  }
}

function trimChatHistory() {
  if (chatHistory.length <= CHAT_HISTORY_LIMIT) {
    trimChatHistoryToBudget();
    return;
  }
  chatHistory = chatHistory.slice(-CHAT_HISTORY_LIMIT);
  trimChatHistoryToBudget();
}

function trimChatHistoryToBudget() {
  if (!chatHistory.length) {
    return;
  }
  var total = 0;
  var kept = [];
  for (var i = chatHistory.length - 1; i >= 0; i -= 1) {
    var entry = chatHistory[i];
    var text = entry && typeof entry.text === "string" ? entry.text : "";
    var cost = text.length + 80;
    if (kept.length > 0 && total + cost > CHAT_HISTORY_CHAR_BUDGET) {
      break;
    }
    total += cost;
    kept.push(entry);
  }
  if (kept.length < chatHistory.length) {
    kept.reverse();
    chatHistory = kept;
  }
}

function normalizeHistoryEntries(entries) {
  if (!Array.isArray(entries)) {
    return [];
  }
  var filtered = entries.filter(function (entry) {
    return entry && typeof entry.id === "string" && typeof entry.role === "string" && typeof entry.text === "string";
  });
  for (var i = 0; i < filtered.length; i += 1) {
    if (typeof filtered[i].createdAt !== "number" || !isFinite(filtered[i].createdAt)) {
      filtered[i].createdAt = timestampFromHistoryId(filtered[i].id);
    }
  }
  if (filtered.length > CHAT_HISTORY_LIMIT) {
    return filtered.slice(-CHAT_HISTORY_LIMIT);
  }
  return filtered;
}

function applyHistoryTombstone(entries) {
  if (!Array.isArray(entries) || entries.length === 0) {
    return [];
  }
  if (typeof chatHistoryTombstone !== "number" || !isFinite(chatHistoryTombstone) || chatHistoryTombstone <= 0) {
    return entries;
  }
  return entries.filter(function (entry) {
    var createdAt = typeof entry.createdAt === "number" && isFinite(entry.createdAt)
      ? entry.createdAt
      : timestampFromHistoryId(entry.id);
    return createdAt > chatHistoryTombstone;
  });
}

function syncChatHistory(entries) {
  var normalized = applyHistoryTombstone(normalizeHistoryEntries(entries));
  if (normalized.length === 0) {
    chatHistory = [];
    if (chatLog) {
      chatLog.textContent = "";
    }
    return;
  }
  var previous = chatHistory;
  var previousById = new Map();
  for (var i = 0; i < previous.length; i += 1) {
    previousById.set(previous[i].id, previous[i]);
  }
  chatHistory = normalized;
  if (!chatLog) {
    return;
  }
  var nodeMap = new Map();
  var nodes = chatLog.querySelectorAll(".message[data-history-id]");
  for (var j = 0; j < nodes.length; j += 1) {
    var nodeId = nodes[j].getAttribute("data-history-id");
    if (nodeId) {
      nodeMap.set(nodeId, nodes[j]);
    }
  }
  var nextIds = new Set();
  for (var k = 0; k < normalized.length; k += 1) {
    nextIds.add(normalized[k].id);
  }
  nodeMap.forEach(function (node, id) {
    if (!nextIds.has(id)) {
      node.remove();
    }
  });
  for (var m = 0; m < normalized.length; m += 1) {
    var entry = normalized[m];
    var existingNode = nodeMap.get(entry.id);
    if (existingNode) {
      var previousEntry = previousById.get(entry.id);
      if (!previousEntry || previousEntry.text !== entry.text || previousEntry.format !== entry.format) {
        renderMessageBody(getMessageBody(existingNode), entry.text, entry.format);
      }
    } else {
      appendMessage(entry.role, entry.text, {
        save: false,
        historyId: entry.id,
        format: entry.format
      });
    }
  }
}

async function clearChatHistory() {
  if (sendButton && sendButton.disabled) {
    appendMessage("system", "Can't clear chat while the agent is running.");
    return;
  }
  if (!chatHistory.length && (!chatLog || chatLog.childElementCount === 0)) {
    return;
  }
  try {
    if (typeof window !== "undefined" && window.confirm) {
      if (!window.confirm("Clear chat history?")) {
        return;
      }
    }
  } catch (error) {
  }

  if (clearButton) {
    clearButton.disabled = true;
  }

  var clearedAt = Date.now();
  chatHistoryTombstone = clearedAt;
  chatHistory = [];
  if (chatLog) {
    chatLog.textContent = "";
  }
  lastObservation = null;
  lastObservationTabId = null;
  lastAssistantSummary = "";
  try {
    if (typeof sessionStorage !== "undefined") {
      sessionStorage.removeItem(CHAT_HISTORY_KEY);
    }
  } catch (error) {
  }

  if (browser.storage && browser.storage.local) {
    // Removing the key first recovers from quota exhaustion.
    try {
      await browser.storage.local.remove(CHAT_HISTORY_KEY);
    } catch (error) {
      appendMessage(
        "system",
        "Failed to remove chat history: " + String(error && error.message ? error.message : error),
        { save: false }
      );
    }
    try {
      var tombstonePayload = {};
      tombstonePayload[CHAT_HISTORY_TOMBSTONE_KEY] = clearedAt;
      await browser.storage.local.set(tombstonePayload);
    } catch (error) {
      appendMessage(
        "system",
        "Failed to persist chat tombstone: " + String(error && error.message ? error.message : error),
        { save: false }
      );
    }
  }

  logDebug("chat history cleared (tombstone=" + String(clearedAt) + ")");
  if (clearButton) {
    clearButton.disabled = false;
  }
}

async function loadChatHistory() {
  if (chatHistoryLoaded) {
    return;
  }
  chatHistoryLoaded = true;
  var loaded = [];
  var loadedFromStorage = false;
  if (browser.storage && browser.storage.local) {
    try {
      var defaults = {};
      defaults[CHAT_HISTORY_KEY] = [];
      defaults[CHAT_HISTORY_TOMBSTONE_KEY] = 0;
      var stored = await browser.storage.local.get(defaults);
      if (stored && typeof stored[CHAT_HISTORY_TOMBSTONE_KEY] === "number" && isFinite(stored[CHAT_HISTORY_TOMBSTONE_KEY])) {
        chatHistoryTombstone = stored[CHAT_HISTORY_TOMBSTONE_KEY];
      }
      if (stored && Array.isArray(stored[CHAT_HISTORY_KEY])) {
        loaded = stored[CHAT_HISTORY_KEY];
        loadedFromStorage = true;
      }
    } catch (error) {
    }
  }
  if (!loadedFromStorage) {
    try {
      if (typeof sessionStorage === "undefined") {
        return;
      }
      var raw = sessionStorage.getItem(CHAT_HISTORY_KEY);
      if (!raw) {
        return;
      }
      var parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        loaded = parsed;
      }
    } catch (error) {
    }
  }
  if (!Array.isArray(loaded) || loaded.length === 0) {
    return;
  }
  syncChatHistory(loaded);
}

function appendMessage(role, text, options) {
  var contentText = typeof text === "string" ? text : String(text || "");
  var message = document.createElement("div");
  message.className = "message";
  message.setAttribute("data-role", role);
  var label = document.createElement("strong");
  label.textContent = labelForRole(role);
  var body = document.createElement("div");
  body.className = "message-body";
  var format = normalizeMessageFormat(options && options.format ? options.format : MESSAGE_FORMAT_PLAIN);
  renderMessageBody(body, contentText, format);
  message.appendChild(label);
  message.appendChild(body);
  var shouldSave = !(options && options.save === false);
  if (shouldSave) {
    var historyId = generateHistoryId();
    message.setAttribute("data-history-id", historyId);
    chatHistory.push({
      id: historyId,
      role: role,
      text: contentText,
      format: format,
      createdAt: timestampFromHistoryId(historyId)
    });
    trimChatHistory();
    saveChatHistory();
  } else if (options && options.historyId) {
    message.setAttribute("data-history-id", options.historyId);
  }
  chatLog.appendChild(message);
  chatLog.scrollTop = chatLog.scrollHeight;
  return message;
}

function updateHistoryMessage(message, text, format) {
  if (!message) {
    return;
  }
  var historyId = message.getAttribute("data-history-id");
  if (!historyId) {
    return;
  }
  var contentText = typeof text === "string" ? text : String(text || "");
  for (var i = chatHistory.length - 1; i >= 0; i -= 1) {
    if (chatHistory[i].id === historyId) {
      chatHistory[i].text = contentText;
      if (format) {
        chatHistory[i].format = normalizeMessageFormat(format);
      }
      saveChatHistory();
      break;
    }
  }
}

function removeHistoryMessage(message) {
  if (!message) {
    return;
  }
  var historyId = message.getAttribute("data-history-id");
  if (!historyId) {
    return;
  }
  chatHistory = chatHistory.filter(function (entry) {
    return entry.id !== historyId;
  });
  saveChatHistory();
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

function appendActionPrompt(action, tabId, toolOptions) {
  return new Promise(function (resolve) {
  var message = document.createElement("div");
  message.className = "message";
  var label = document.createElement("strong");
  label.textContent = "action";
  var body = document.createElement("div");
  body.className = "message-body";
  renderMessageBody(body, formatToolCall(action), MESSAGE_FORMAT_PLAIN);
  var buttons = document.createElement("div");
  buttons.className = "action-buttons";
  var approveButton = document.createElement("button");
  approveButton.textContent = "Approve";
  var rejectButton = document.createElement("button");
  rejectButton.textContent = "Reject";

  approveButton.addEventListener("click", function () {
    approveButton.disabled = true;
    rejectButton.disabled = true;
    runTool(action, tabId, toolOptions).then(function (result) {
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
  setStatus("Status: connecting...");
  try {
    var response = await sendNativeMessage({ type: "ping" });
    if (response && response.ok) {
      setStatus("Status: ready");
      return;
    }
    setStatus("Status: error");
  } catch (error) {
    setStatus("Status: offline");
  }
}

function isSummaryGoalPlan(goalPlan) {
  if (!goalPlan || typeof goalPlan.intent !== "string") {
    return false;
  }
  if (goalPlan.intent === "page_summary" || goalPlan.intent === "item_summary" || goalPlan.intent === "comment_summary") {
    return true;
  }
  return goalPlan.wantsComments === true;
}

function buildSummaryContext(params) {
  if (!params || !params.observation) {
    return null;
  }
  var origin = "";
  try {
    origin = new URL(params.observation.url).origin;
  } catch (error) {
    origin = params.observation.url || "";
  }
  return {
    origin: origin,
    mode: "assist",
    runId: params.runId || null,
    step: typeof params.step === "number" ? params.step : null,
    maxSteps: typeof params.maxSteps === "number" ? params.maxSteps : null,
    observation: params.observation,
    recentToolCalls: Array.isArray(params.recentToolCalls) ? params.recentToolCalls : [],
    recentToolResults: Array.isArray(params.recentToolResults) ? params.recentToolResults : [],
    tabs: Array.isArray(params.tabs) ? params.tabs : [],
    goalPlan: params.goalPlan || null
  };
}

function formatFromPlan(plan) {
  if (plan && plan.summaryFormat === MESSAGE_FORMAT_MARKDOWN) {
    return MESSAGE_FORMAT_MARKDOWN;
  }
  return MESSAGE_FORMAT_PLAIN;
}

async function startSummaryStream(goal, context, goalPlan) {
  var payload = {
    type: "summary.start",
    maxTokens: clampMaxTokens(maxTokensSetting),
    request: {
      goal: goal,
      context: context
    }
  };
  if (goalPlan) {
    payload.goalPlan = goalPlan;
  }
  return await sendNativeMessage(payload);
}

async function pollSummaryStream(streamId) {
  return await sendNativeMessage({ type: "summary.poll", streamId: streamId });
}

async function cancelSummaryStream(streamId) {
  return await sendNativeMessage({ type: "summary.cancel", streamId: streamId });
}

async function consumeSummaryStream(streamId) {
  var message = appendMessage("assistant", "", { format: MESSAGE_FORMAT_MARKDOWN });
  var body = getMessageBody(message);
  var text = "";
  var delayMs = 140;
  for (;;) {
    var result = await pollSummaryStream(streamId);
    if (!result || result.ok !== true) {
      appendMessage("system", "Summary stream failed.");
      break;
    }
    if (Array.isArray(result.chunks) && result.chunks.length > 0) {
      text += result.chunks.join("");
      renderMessageBody(body, text, MESSAGE_FORMAT_MARKDOWN);
      chatLog.scrollTop = chatLog.scrollHeight;
    }
    if (result.error) {
      appendMessage("system", "Summary stream error: " + result.error);
      break;
    }
    if (result.done) {
      break;
    }
    await sleep(delayMs);
  }
  if (text.trim()) {
    lastAssistantSummary = text;
    updateHistoryMessage(message, text, MESSAGE_FORMAT_MARKDOWN);
  } else if (message) {
    var fallbackText = "No summary available.";
    renderMessageBody(body, fallbackText, MESSAGE_FORMAT_MARKDOWN);
    updateHistoryMessage(message, fallbackText, MESSAGE_FORMAT_MARKDOWN);
  }
  return text;
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
  var delayMs = 250;
  var initialDelayMs = 0;
  if (arguments.length >= 3 && arguments[2]) {
    var settings = arguments[2];
    if (typeof settings.attempts === "number" && isFinite(settings.attempts) && settings.attempts > 0) {
      attempts = Math.floor(settings.attempts);
    }
    if (typeof settings.delayMs === "number" && isFinite(settings.delayMs) && settings.delayMs >= 0) {
      delayMs = Math.floor(settings.delayMs);
    }
    if (typeof settings.initialDelayMs === "number" && isFinite(settings.initialDelayMs) && settings.initialDelayMs > 0) {
      initialDelayMs = Math.floor(settings.initialDelayMs);
    }
  }
  if (initialDelayMs > 0) {
    await sleep(initialDelayMs);
  }
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
    await sleep(delayMs);
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

async function runTool(action, tabId, options) {
  logDebug("Running tool " + action.toolCall.name);
  if (action.toolCall.name === "content.summarize") {
    if (!options || !options.summaryContext) {
      appendMessage("system", "Summary failed: missing context.");
      return { status: "error", error: "missing_context" };
    }
    setStatus("Status: summarizing...");
    try {
      var streamResponse = await startSummaryStream(options.goal || "", options.summaryContext, options.goalPlan || null);
      if (streamResponse && streamResponse.ok && streamResponse.stream && streamResponse.stream.id) {
        var summaryText = await consumeSummaryStream(streamResponse.stream.id);
        if (summaryText && summaryText.trim()) {
          return { status: "ok", summary: summaryText };
        }
        return { status: "error", error: "empty_summary" };
      }
      var errorMessage = "Summary failed: no stream.";
      var errorDetail = streamResponse && streamResponse.error ? String(streamResponse.error) : "";
      if (errorDetail) {
        errorMessage = "Summary failed: " + errorDetail;
      }
      appendMessage("system", errorMessage);
      return { status: "error", error: errorDetail || "no_stream" };
    } catch (error) {
      appendMessage("system", "Summary failed: " + error.message);
      return { status: "error", error: error.message };
    }
  }
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
  if (toolName === "content.summarize" && rawResult && typeof rawResult.summary === "string") {
    payload.summary = rawResult.summary;
    payload.summaryChars = rawResult.summary.length;
  }
  if (toolName === "search") {
    if (rawResult && typeof rawResult.tabId === "number") {
      payload.tabId = rawResult.tabId;
    }
    if (rawResult && typeof rawResult.url === "string") {
      payload.url = rawResult.url;
    }
    if (rawResult && typeof rawResult.engine === "string") {
      payload.engine = rawResult.engine;
    }
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
    payload.itemCount = Array.isArray(rawResult.observation.items) ? rawResult.observation.items.length : 0;
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

function shouldUseDetailObservation(goal) {
  var lower = String(goal || "").toLowerCase();
  if (!lower) {
    return false;
  }
  if (lower.length > 200) {
    return true;
  }
  var hints = [
    "detailed",
    "detail",
    "deep",
    "comprehensive",
    "full",
    "everything",
    "in depth",
    "long summary",
    "full summary"
  ];
  for (var i = 0; i < hints.length; i += 1) {
    if (lower.indexOf(hints[i]) >= 0) {
      return true;
    }
  }
  return false;
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
  if (clearButton) {
    clearButton.disabled = true;
  }
  if (openPanelButton) {
    openPanelButton.disabled = true;
  }
  lastObservationTabId = null;
  lastAssistantSummary = "";
  var searchTabIdsToCleanup = [];
  var originTabId = null;

  try {
    setStatus("Status: observing page...");
    await loadMaxTokens();
    var runId = generateRunId();
    var tabsContext = await listTabContext();
    var mode = "assist";
    var maxSteps = MAX_AGENT_STEPS;
    var observeOptions = shouldUseDetailObservation(goal) ? DETAIL_OBSERVE_OPTIONS : DEFAULT_OBSERVE_OPTIONS;
    var firstObservation = await observeWithRetries(observeOptions, null);
    lastObservation = firstObservation.observation;
    var tabIdForPlan = firstObservation.tabId;
    originTabId = tabIdForPlan;

    var recentToolCalls = [];
    var recentToolResults = [];

    for (var step = 1; step <= maxSteps; step += 1) {
      setStatus("Status: planning...");
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
      var goalPlan = plan.goalPlan || null;
      var summaryContext = buildSummaryContext({
        runId: context.runId,
        step: context.step,
        maxSteps: context.maxSteps,
        observation: lastObservation,
        recentToolCalls: recentToolCalls.slice(-8),
        recentToolResults: recentToolResults.slice(-8),
        tabs: tabsContext,
        goalPlan: goalPlan
      });
      var toolOptions = {
        goal: goal,
        goalPlan: goalPlan,
        summaryContext: summaryContext
      };

      var nextAction = pickNextAction(plan.actions);
      if (!nextAction) {
        var streamed = false;
        if (isSummaryGoalPlan(goalPlan) && summaryContext) {
          setStatus("Status: summarizing...");
          try {
            var streamResponse = await startSummaryStream(goal, summaryContext, goalPlan);
            if (streamResponse && streamResponse.ok && streamResponse.stream && streamResponse.stream.id) {
              var streamedText = await consumeSummaryStream(streamResponse.stream.id);
              streamed = !!(streamedText && streamedText.trim());
            }
          } catch (error) {
          }
        }
        if (!streamed && plan.summary && plan.summary !== lastAssistantSummary) {
          setStatus("Status: summarizing...");
          appendMessage("assistant", plan.summary, { format: formatFromPlan(plan) });
          lastAssistantSummary = plan.summary;
        }
        break;
      }
      if (nextAction.policy.decision === "deny") {
        appendMessage("system", "Blocked: " + nextAction.policy.reasonCode);
        if (plan.summary && plan.summary !== lastAssistantSummary) {
          setStatus("Status: summarizing...");
          appendMessage("assistant", plan.summary, { format: formatFromPlan(plan) });
          lastAssistantSummary = plan.summary;
        }
        break;
      }
      if (step === maxSteps) {
        appendMessage("system", "Step limit reached.");
        if (plan.summary && plan.summary !== lastAssistantSummary) {
          setStatus("Status: summarizing...");
          appendMessage("assistant", plan.summary, { format: formatFromPlan(plan) });
          lastAssistantSummary = plan.summary;
        }
        break;
      }

      var approval = null;
      if (nextAction.policy.decision === "ask") {
        if (plan.summary && plan.summary !== lastAssistantSummary) {
          setStatus("Status: summarizing...");
          appendMessage("assistant", plan.summary, { format: formatFromPlan(plan) });
          lastAssistantSummary = plan.summary;
        }
        setStatus("Status: awaiting approval...");
        approval = await appendActionPrompt(nextAction, tabIdForPlan, toolOptions);
        if (!approval || approval.decision !== "approve") {
          appendMessage("system", "Stopped: action not approved.");
          break;
        }
      } else {
        setStatus("Status: running action...");
        approval = { decision: "approve", result: await runTool(nextAction, tabIdForPlan, toolOptions) };
      }

      var toolResult = approval.result;
      recentToolCalls.push(nextAction.toolCall);
      recentToolResults.push(buildToolResult(nextAction.toolCall, nextAction.toolCall.name, toolResult));

      var executedToolName = nextAction.toolCall.name;
      if (executedToolName === "search" && toolResult && typeof toolResult.tabId === "number") {
        if (searchTabIdsToCleanup.indexOf(toolResult.tabId) === -1) {
          searchTabIdsToCleanup.push(toolResult.tabId);
        }
      }
      if (nextAction.toolCall.name === "content.summarize") {
        if (toolResult && toolResult.status === "ok" && typeof toolResult.summary === "string") {
          lastAssistantSummary = toolResult.summary;
        } else if (plan.summary && plan.summary !== lastAssistantSummary) {
          appendMessage("assistant", plan.summary, { format: formatFromPlan(plan) });
          lastAssistantSummary = plan.summary;
        }
        break;
      }

      if (toolResult && typeof toolResult.tabId === "number") {
        tabIdForPlan = toolResult.tabId;
      } else if (executedToolName === "search" || executedToolName === "browser.open_tab" || executedToolName === "browser.navigate") {
        // Fall back to the currently active tab if the tool didn't return a tab id.
        tabIdForPlan = null;
      }
      if (nextAction.toolCall.name === "browser.observe_dom" && toolResult && toolResult.observation) {
        setStatus("Status: observing page...");
        lastObservation = toolResult.observation;
        if (typeof toolResult.tabId === "number") {
          tabIdForPlan = toolResult.tabId;
        }
      } else {
        setStatus("Status: observing page...");
        tabsContext = await listTabContext();
        var toolName = nextAction && nextAction.toolCall && nextAction.toolCall.name ? nextAction.toolCall.name : "";
        var observeSettings = null;
        // New tabs / navigations can take longer to load + inject the content script.
        if (toolName === "search" || toolName === "browser.open_tab" || toolName === "browser.navigate") {
          observeSettings = { attempts: 14, delayMs: 350, initialDelayMs: 700 };
        }
        var updated = await observeWithRetries(observeOptions, tabIdForPlan, observeSettings);
        lastObservation = updated.observation;
        tabIdForPlan = updated.tabId;
      }
    }
  } catch (error) {
    if (error && (error.message === "no_context" || error.message === "no_active_tab")) {
      explainMissingContext();
    } else {
      appendMessage("system", "Error: " + error.message);
    }
  } finally {
    if (searchTabIdsToCleanup.length && typeof browser !== "undefined" && browser.runtime && browser.runtime.sendMessage) {
      try {
        await browser.runtime.sendMessage({
          type: "laika.search.cleanup",
          tabIds: searchTabIdsToCleanup.slice(0),
          fallbackTabId: originTabId
        });
      } catch (error) {
        if (typeof console !== "undefined" && console.debug) {
          console.debug("[Laika][search] cleanup_failed", error);
        }
      }
    }
    sendButton.disabled = false;
    if (clearButton) {
      clearButton.disabled = false;
    }
    if (openPanelButton) {
      openPanelButton.disabled = false;
    }
  }
});

(async function init() {
  try {
    isPanelWindow = window.top === window && new URL(window.location.href).searchParams.get("panel") === "1";
  } catch (error) {
    isPanelWindow = false;
  }
  initMarkdownSupport();
  if (sendButton) {
    sendButton.disabled = true;
  }
  if (clearButton) {
    clearButton.disabled = true;
  }
  if (openPanelButton) {
    openPanelButton.disabled = true;
  }
  await loadChatHistory();
  await loadMaxTokens();
  if (browser.storage && browser.storage.onChanged) {
    browser.storage.onChanged.addListener(function (changes, areaName) {
      if (areaName !== "local" || !changes) {
        return;
      }
      if (changes[CHAT_HISTORY_TOMBSTONE_KEY] && typeof changes[CHAT_HISTORY_TOMBSTONE_KEY].newValue === "number") {
        chatHistoryTombstone = changes[CHAT_HISTORY_TOMBSTONE_KEY].newValue;
      }
      if (changes[CHAT_HISTORY_KEY]) {
        syncChatHistory(changes[CHAT_HISTORY_KEY].newValue);
        return;
      }
      if (changes[CHAT_HISTORY_TOMBSTONE_KEY]) {
        syncChatHistory(chatHistory);
      }
    });
  }
  if (sendButton) {
    sendButton.disabled = false;
  }
  if (clearButton) {
    clearButton.disabled = false;
    clearButton.addEventListener("click", clearChatHistory);
  }
  if (openPanelButton) {
    openPanelButton.disabled = false;
    if (isPanelWindow) {
      openPanelButton.style.display = "none";
    } else {
      openPanelButton.addEventListener("click", openPanelWindow);
    }
  }
  if (closeButton) {
    closeButton.addEventListener("click", closeSidecar);
  }
  checkNative();
})();
