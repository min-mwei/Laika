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
var lastAssistantFingerprint = "";
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
var MESSAGE_FORMAT_RENDER = "render";

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
  if (format === MESSAGE_FORMAT_RENDER) {
    return MESSAGE_FORMAT_RENDER;
  }
  return MESSAGE_FORMAT_PLAIN;
}

function isDocument(doc) {
  return doc && typeof doc === "object" && doc.type === "doc" && Array.isArray(doc.children);
}

function sanitizeHref(href) {
  if (!href || typeof href !== "string") {
    return null;
  }
  var trimmed = href.trim();
  if (!trimmed) {
    return null;
  }
  if (/^(https?:|mailto:)/i.test(trimmed)) {
    return trimmed;
  }
  return null;
}

function renderInlineNodes(container, nodes) {
  if (!Array.isArray(nodes)) {
    return;
  }
  for (var i = 0; i < nodes.length; i += 1) {
    var node = renderDocumentNode(nodes[i]);
    if (node) {
      container.appendChild(node);
    }
  }
}

function renderDocumentNode(node) {
  if (!node || typeof node !== "object") {
    return null;
  }
  var type = node.type;
  if (type === "text") {
    var textValue = typeof node.text === "string" ? node.text : "";
    return document.createTextNode(textValue);
  }
  if (type === "link") {
    var href = sanitizeHref(node.href);
    if (!href) {
      var fallback = document.createDocumentFragment();
      renderInlineNodes(fallback, node.children);
      return fallback;
    }
    var link = document.createElement("a");
    link.setAttribute("href", href);
    link.setAttribute("target", "_blank");
    link.setAttribute("rel", "noopener noreferrer");
    renderInlineNodes(link, node.children);
    return link;
  }
  if (type === "heading") {
    var level = typeof node.level === "number" ? Math.max(1, Math.min(6, Math.floor(node.level))) : 2;
    var heading = document.createElement("h" + String(level));
    renderInlineNodes(heading, node.children);
    return heading;
  }
  if (type === "paragraph") {
    var paragraph = document.createElement("p");
    renderInlineNodes(paragraph, node.children);
    return paragraph;
  }
  if (type === "list") {
    var ordered = !!node.ordered;
    var list = document.createElement(ordered ? "ol" : "ul");
    if (Array.isArray(node.items)) {
      for (var i = 0; i < node.items.length; i += 1) {
        var itemNode = renderDocumentNode(node.items[i]);
        if (itemNode) {
          list.appendChild(itemNode);
        }
      }
    }
    return list;
  }
  if (type === "list_item") {
    var listItem = document.createElement("li");
    renderInlineNodes(listItem, node.children);
    return listItem;
  }
  if (type === "blockquote") {
    var blockquote = document.createElement("blockquote");
    renderInlineNodes(blockquote, node.children);
    return blockquote;
  }
  if (type === "code_block") {
    var pre = document.createElement("pre");
    var code = document.createElement("code");
    var codeText = typeof node.text === "string" ? node.text : "";
    code.textContent = codeText;
    pre.appendChild(code);
    return pre;
  }
  return null;
}

function renderDocument(body, doc) {
  if (!body) {
    return;
  }
  body.textContent = "";
  if (!isDocument(doc)) {
    body.textContent = "Unable to render response.";
    return;
  }
  for (var i = 0; i < doc.children.length; i += 1) {
    var node = renderDocumentNode(doc.children[i]);
    if (node) {
      body.appendChild(node);
    }
  }
}

function renderPlainInline(nodes) {
  if (!Array.isArray(nodes)) {
    return "";
  }
  var output = "";
  for (var i = 0; i < nodes.length; i += 1) {
    output += renderPlainNode(nodes[i]);
  }
  return output.trim();
}

function renderPlainList(items, ordered) {
  if (!Array.isArray(items) || items.length === 0) {
    return "";
  }
  var lines = [];
  for (var i = 0; i < items.length; i += 1) {
    var content = renderPlainBlock(items[i]);
    if (!content) {
      content = "";
    }
    var prefix = ordered ? String(i + 1) + ". " : "- ";
    lines.push(prefix + content);
  }
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
    var inner = renderPlainInline(node.children);
    return inner ? "> " + inner : "";
  }
  case "code_block": {
    var text = typeof node.text === "string" ? node.text.trim() : "";
    return text;
  }
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
  var parts = [];
  for (var i = 0; i < doc.children.length; i += 1) {
    var block = renderPlainBlock(doc.children[i]);
    if (block) {
      parts.push(block);
    }
  }
  return parts.join("\n").trim();
}

function renderDocumentFingerprint(doc) {
  var text = plainTextFromDocument(doc);
  if (text) {
    return text;
  }
  try {
    return JSON.stringify(doc);
  } catch (error) {
    return "";
  }
}

function renderMessageBody(body, text, format) {
  if (!body) {
    return;
  }
  var normalizedFormat = normalizeMessageFormat(format);
  var output = typeof text === "string" ? text : text;
  body.classList.toggle("render", normalizedFormat === MESSAGE_FORMAT_RENDER);
  if (normalizedFormat === MESSAGE_FORMAT_RENDER) {
    renderDocument(body, output);
    return;
  }
  body.textContent = typeof output === "string" ? output : String(output || "");
}

function getMessageBody(message) {
  if (!message) {
    return null;
  }
  return message.querySelector(".message-body");
}

function assistantPayloadFromPlan(plan) {
  if (!plan) {
    return null;
  }
  if (plan.assistant && isDocument(plan.assistant.render)) {
    var renderDoc = plan.assistant.render;
    return {
      format: MESSAGE_FORMAT_RENDER,
      content: renderDoc,
      fingerprint: renderDocumentFingerprint(renderDoc)
    };
  }
  if (typeof plan.summary === "string" && plan.summary.trim()) {
    var summary = plan.summary.trim();
    return {
      format: MESSAGE_FORMAT_PLAIN,
      content: summary,
      fingerprint: summary
    };
  }
  return null;
}

function appendAssistantFromPlan(plan) {
  var payload = assistantPayloadFromPlan(plan);
  if (!payload) {
    return false;
  }
  if (payload.fingerprint && payload.fingerprint === lastAssistantFingerprint) {
    return false;
  }
  appendMessage("assistant", payload.content, { format: payload.format });
  lastAssistantFingerprint = payload.fingerprint || "";
  return true;
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

function historyEntryContent(entry) {
  if (entry && entry.format === MESSAGE_FORMAT_RENDER && isDocument(entry.render)) {
    return entry.render;
  }
  return entry && typeof entry.text === "string" ? entry.text : "";
}

function historyEntryKey(entry) {
  if (entry && entry.format === MESSAGE_FORMAT_RENDER && isDocument(entry.render)) {
    return renderDocumentFingerprint(entry.render);
  }
  return entry && typeof entry.text === "string" ? entry.text : "";
}

function historyEntrySize(entry) {
  if (!entry) {
    return 0;
  }
  if (entry.format === MESSAGE_FORMAT_RENDER && isDocument(entry.render)) {
    var text = plainTextFromDocument(entry.render);
    if (!text) {
      try {
        text = JSON.stringify(entry.render);
      } catch (error) {
        text = "";
      }
    }
    return text.length + 80;
  }
  var raw = typeof entry.text === "string" ? entry.text : "";
  return raw.length + 80;
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
    var cost = historyEntrySize(entry);
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
  var filtered = [];
  for (var i = 0; i < entries.length; i += 1) {
    var entry = entries[i];
    if (!entry || typeof entry.id !== "string" || typeof entry.role !== "string") {
      continue;
    }
    var format = normalizeMessageFormat(entry.format);
    var normalized = {
      id: entry.id,
      role: entry.role,
      format: format,
      createdAt: typeof entry.createdAt === "number" && isFinite(entry.createdAt)
        ? entry.createdAt
        : timestampFromHistoryId(entry.id)
    };
    if (format === MESSAGE_FORMAT_RENDER && isDocument(entry.render)) {
      normalized.render = entry.render;
    } else {
      var text = typeof entry.text === "string" ? entry.text : "";
      if (!text && isDocument(entry.render)) {
        text = plainTextFromDocument(entry.render);
      }
      normalized.text = text;
      normalized.format = MESSAGE_FORMAT_PLAIN;
    }
    filtered.push(normalized);
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
      if (!previousEntry || historyEntryKey(previousEntry) !== historyEntryKey(entry) || previousEntry.format !== entry.format) {
        renderMessageBody(getMessageBody(existingNode), historyEntryContent(entry), entry.format);
      }
    } else {
      appendMessage(entry.role, historyEntryContent(entry), {
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
  lastAssistantFingerprint = "";
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
  var message = document.createElement("div");
  message.className = "message";
  message.setAttribute("data-role", role);
  var label = document.createElement("strong");
  label.textContent = labelForRole(role);
  var body = document.createElement("div");
  body.className = "message-body";
  var format = normalizeMessageFormat(options && options.format ? options.format : MESSAGE_FORMAT_PLAIN);
  if (format === MESSAGE_FORMAT_RENDER && !isDocument(text)) {
    format = MESSAGE_FORMAT_PLAIN;
  }
  var content = format === MESSAGE_FORMAT_PLAIN && typeof text !== "string" ? String(text || "") : text;
  renderMessageBody(body, content, format);
  message.appendChild(label);
  message.appendChild(body);
  var shouldSave = !(options && options.save === false);
  if (shouldSave) {
    var historyId = generateHistoryId();
    message.setAttribute("data-history-id", historyId);
    var entry = {
      id: historyId,
      role: role,
      format: format,
      createdAt: timestampFromHistoryId(historyId)
    };
    if (format === MESSAGE_FORMAT_RENDER && isDocument(content)) {
      entry.render = content;
    } else {
      entry.text = typeof content === "string" ? content : String(content || "");
      entry.format = MESSAGE_FORMAT_PLAIN;
    }
    chatHistory.push(entry);
    trimChatHistory();
    saveChatHistory();
  } else if (options && options.historyId) {
    message.setAttribute("data-history-id", options.historyId);
  }
  chatLog.appendChild(message);
  chatLog.scrollTop = chatLog.scrollHeight;
  return message;
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

function appendActionPrompt(action, tabId) {
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
    if (rawResult.observation.documentId) {
      payload.documentId = rawResult.observation.documentId;
    }
    var navigationGeneration = rawResult.observation.navigationGeneration;
    if (typeof navigationGeneration !== "number") {
      navigationGeneration = rawResult.observation.navGeneration;
    }
    if (typeof navigationGeneration === "number") {
      payload.navigationGeneration = navigationGeneration;
    }
    if (typeof rawResult.observation.observedAtMs === "number") {
      payload.observedAtMs = rawResult.observation.observedAtMs;
    }
    payload.textChars = (rawResult.observation.text || "").length;
    payload.elementCount = Array.isArray(rawResult.observation.elements) ? rawResult.observation.elements.length : 0;
    payload.blockCount = Array.isArray(rawResult.observation.blocks) ? rawResult.observation.blocks.length : 0;
    payload.itemCount = Array.isArray(rawResult.observation.items) ? rawResult.observation.items.length : 0;
    payload.outlineCount = Array.isArray(rawResult.observation.outline) ? rawResult.observation.outline.length : 0;
    payload.primaryChars = rawResult.observation.primary && rawResult.observation.primary.text
      ? String(rawResult.observation.primary.text).length
      : 0;
  }
  if (toolName === "app.calculate" && rawResult) {
    if (typeof rawResult.result === "number") {
      payload.result = rawResult.result;
    }
    if (typeof rawResult.precision === "number") {
      payload.precision = rawResult.precision;
    }
    if (typeof rawResult.formatted === "string") {
      payload.formatted = rawResult.formatted;
    }
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
  lastAssistantFingerprint = "";
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
      var nextAction = pickNextAction(plan.actions);
      if (!nextAction) {
        setStatus("Status: responding...");
        appendAssistantFromPlan(plan);
        break;
      }
      if (nextAction.policy.decision === "deny") {
        appendMessage("system", "Blocked: " + nextAction.policy.reasonCode);
        setStatus("Status: responding...");
        appendAssistantFromPlan(plan);
        break;
      }
      if (step === maxSteps) {
        appendMessage("system", "Step limit reached.");
        setStatus("Status: responding...");
        appendAssistantFromPlan(plan);
        break;
      }

      var approval = null;
      if (nextAction.policy.decision === "ask") {
        setStatus("Status: responding...");
        appendAssistantFromPlan(plan);
        setStatus("Status: awaiting approval...");
        approval = await appendActionPrompt(nextAction, tabIdForPlan);
        if (!approval || approval.decision !== "approve") {
          appendMessage("system", "Stopped: action not approved.");
          break;
        }
      } else {
        setStatus("Status: running action...");
        approval = { decision: "approve", result: await runTool(nextAction, tabIdForPlan) };
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
