"use strict";

var NATIVE_APP_ID = "com.laika.Laika";
var statusEl = document.getElementById("native-status");
var goalInput = document.getElementById("goal");
var sendButton = document.getElementById("send");
var chatLog = document.getElementById("chat-log");
var settingsButton = document.getElementById("open-settings");
var closeButton = document.getElementById("close-sidecar");
var isPanelWindow = false;

var lastObservation = null;
var planValidator = window.LaikaPlanValidator || {
  validatePlanResponse: function () {
    return { ok: true };
  }
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

function setStatus(text) {
  statusEl.textContent = text;
  logDebug("status: " + text);
}

function labelForRole(role) {
  if (role === "user") {
    return "you";
  }
  if (role === "system") {
    return "Laika";
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

function appendActionPrompt(action) {
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
    runTool(action);
  });
  rejectButton.addEventListener("click", function () {
    approveButton.disabled = true;
    rejectButton.disabled = true;
    appendMessage("system", "Action rejected: " + formatToolCall(action));
  });

  buttons.appendChild(approveButton);
  buttons.appendChild(rejectButton);
  message.appendChild(label);
  message.appendChild(body);
  message.appendChild(buttons);
  chatLog.appendChild(message);
  chatLog.scrollTop = chatLog.scrollHeight;
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
      options: { maxChars: 1600, maxElements: 40 }
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
  return result.observation;
}

async function requestPlan(goal, observation) {
  var origin = "";
  try {
    origin = new URL(observation.url).origin;
  } catch (error) {
    origin = observation.url || "";
  }
  var payload = {
    type: "plan",
    request: {
      goal: goal,
      context: {
        origin: origin,
        mode: "assist",
        observation: observation,
        recentToolCalls: []
      }
    }
  };
  return await sendNativeMessage(payload);
}

async function runTool(action) {
  appendMessage("system", "Running " + action.toolCall.name + "...");
  try {
    var result = await browser.runtime.sendMessage({
      type: "laika.tool",
      toolName: action.toolCall.name,
      args: action.toolCall.arguments || {}
    });
    if (result.status !== "ok") {
      appendMessage("system", "Tool failed: " + (result.error || "unknown"));
      return;
    }
    appendMessage("system", "Tool executed: " + action.toolCall.name);
  } catch (error) {
    appendMessage("system", "Tool error: " + error.message);
  }
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

  try {
    lastObservation = await observePage();
    appendMessage("system", "Planning with local model...");
    var response = await requestPlan(goal, lastObservation);
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
    appendMessage("assistant", plan.summary || "Plan ready.");
    plan.actions.forEach(function (action) {
      if (action.policy.decision === "deny") {
        appendMessage("system", "Blocked: " + action.policy.reasonCode);
      } else if (action.policy.decision === "allow") {
        runTool(action);
      } else {
        appendActionPrompt(action);
      }
    });
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
  if (settingsButton) {
    settingsButton.addEventListener("click", openSettings);
  }
  if (closeButton) {
    closeButton.addEventListener("click", closeSidecar);
  }
  checkNative();
})();
