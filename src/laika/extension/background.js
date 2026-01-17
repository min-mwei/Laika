"use strict";

var ALLOWED_TOOLS = {
  "browser.click": true,
  "browser.type": true,
  "browser.scroll": true,
  "browser.open_tab": true
};

async function getActiveTab() {
  var tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs && tabs.length ? tabs[0] : null;
}

async function handleObserve(options) {
  var tab = await getActiveTab();
  if (!tab || typeof tab.id === "undefined") {
    return { status: "error", error: "no_active_tab" };
  }
  return browser.tabs.sendMessage(tab.id, { type: "laika.observe", options: options || {} });
}

async function handleTool(toolName, args) {
  if (!ALLOWED_TOOLS[toolName]) {
    return { status: "error", error: "unsupported_tool" };
  }
  if (toolName === "browser.open_tab") {
    if (args && args.url) {
      await browser.tabs.create({ url: args.url });
      return { status: "ok" };
    }
    return { status: "error", error: "missing_url" };
  }

  var tab = await getActiveTab();
  if (!tab || typeof tab.id === "undefined") {
    return { status: "error", error: "no_active_tab" };
  }
  return browser.tabs.sendMessage(tab.id, { type: "laika.tool", toolName: toolName, args: args || {} });
}

browser.runtime.onMessage.addListener(function (message) {
  if (!message || !message.type) {
    return Promise.resolve({ status: "error", error: "invalid_message" });
  }
  if (message.type === "laika.observe") {
    return handleObserve(message.options);
  }
  if (message.type === "laika.tool") {
    return handleTool(message.toolName, message.args || {});
  }
  return Promise.resolve({ status: "error", error: "unknown_type" });
});
