"use strict";

var NATIVE_APP_ID = "com.laika.Laika";
var statusEl = document.getElementById("native-status");
var goalInput = document.getElementById("goal");
var sendButton = document.getElementById("send");
var chatLog = document.getElementById("chat-log");

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

function setStatus(text) {
  statusEl.textContent = text;
  logDebug("status: " + text);
}

function appendMessage(role, text) {
  var message = document.createElement("div");
  message.className = "message";
  var label = document.createElement("strong");
  label.textContent = role;
  var body = document.createElement("div");
  body.textContent = text;
  message.appendChild(label);
  message.appendChild(body);
  chatLog.appendChild(message);
  chatLog.scrollTop = chatLog.scrollHeight;
  return message;
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
  var result = await browser.runtime.sendMessage({
    type: "laika.observe",
    options: { maxChars: 1600, maxElements: 40 }
  });
  if (result.status !== "ok") {
    throw new Error(result.error || "observe_failed");
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

  appendMessage("system", "Observing page...");
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
    appendMessage("system", "Error: " + error.message);
  } finally {
    sendButton.disabled = false;
  }
});

(function init() {
  checkNative();
})();
