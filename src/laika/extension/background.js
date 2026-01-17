"use strict";

var ALLOWED_TOOLS = {
  "browser.click": true,
  "browser.type": true,
  "browser.scroll": true,
  "browser.open_tab": true
};

var DEFAULT_SIDECAR_SIDE = "right";

async function getActiveTab() {
  var tabs = await browser.tabs.query({ active: true, currentWindow: true });
  return tabs && tabs.length ? tabs[0] : null;
}

async function handleObserve(options) {
  var tab = await getActiveTab();
  if (!tab || typeof tab.id === "undefined") {
    return { status: "error", error: "no_active_tab" };
  }
  try {
    var result = await browser.tabs.sendMessage(tab.id, { type: "laika.observe", options: options || {} });
    if (!result || typeof result.status === "undefined") {
      return { status: "error", error: "no_context" };
    }
    return result;
  } catch (error) {
    return { status: "error", error: "no_context" };
  }
}

async function getSidecarSide() {
  if (!browser.storage || !browser.storage.local) {
    return DEFAULT_SIDECAR_SIDE;
  }
  var stored = await browser.storage.local.get({ sidecarSide: DEFAULT_SIDECAR_SIDE });
  return stored.sidecarSide === "left" ? "left" : DEFAULT_SIDECAR_SIDE;
}

async function sendSidecarMessage(type, sideOverride) {
  var tab = await getActiveTab();
  if (!tab || typeof tab.id === "undefined") {
    return { status: "error", error: "no_active_tab" };
  }
  var side = sideOverride || (await getSidecarSide());
  try {
    return await browser.tabs.sendMessage(tab.id, { type: type, side: side });
  } catch (error) {
    return { status: "error", error: "no_context" };
  }
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

function registerActionClick() {
  if (browser.action && browser.action.onClicked) {
    browser.action.onClicked.addListener(function () {
      sendSidecarMessage("laika.sidecar.toggle");
    });
    return;
  }
  if (browser.browserAction && browser.browserAction.onClicked) {
    browser.browserAction.onClicked.addListener(function () {
      sendSidecarMessage("laika.sidecar.toggle");
    });
  }
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
  if (message.type === "laika.sidecar.hide") {
    return sendSidecarMessage("laika.sidecar.hide", message.side);
  }
  if (message.type === "laika.sidecar.show") {
    return sendSidecarMessage("laika.sidecar.show", message.side);
  }
  if (message.type === "laika.sidecar.toggle") {
    return sendSidecarMessage("laika.sidecar.toggle", message.side);
  }
  return Promise.resolve({ status: "error", error: "unknown_type" });
});

registerActionClick();
