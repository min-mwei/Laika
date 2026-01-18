"use strict";

var ALLOWED_TOOLS = {
  "browser.click": true,
  "browser.type": true,
  "browser.scroll": true,
  "browser.open_tab": true
};

var DEFAULT_SIDECAR_SIDE = "right";
var PANEL_WINDOW_ID = null;
var PANEL_TAB_ID = null;
var PANEL_OPEN_PROMISE = null;

function isPanelUrl(url) {
  if (!url || !browser.runtime || !browser.runtime.getURL) {
    return false;
  }
  try {
    var base = browser.runtime.getURL("popover.html");
    if (typeof base !== "string" || url.indexOf(base) !== 0) {
      return false;
    }
    var parsed = new URL(url);
    return parsed.searchParams.get("panel") === "1";
  } catch (error) {
    return false;
  }
}

async function findPanelTab() {
  if (!browser.tabs || !browser.tabs.query) {
    return null;
  }
  var tabs = await browser.tabs.query({});
  for (var i = 0; i < tabs.length; i += 1) {
    if (isPanelUrl(tabs[i].url)) {
      return tabs[i];
    }
  }
  return null;
}

async function focusTab(tab) {
  if (!tab || typeof tab.id === "undefined") {
    return;
  }
  if (browser.tabs && browser.tabs.update) {
    try {
      await browser.tabs.update(tab.id, { active: true });
    } catch (error) {
    }
  }
  if (browser.windows && browser.windows.update && typeof tab.windowId !== "undefined") {
    try {
      await browser.windows.update(tab.windowId, { focused: true });
    } catch (error) {
    }
  }
}

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

async function openPanelWindowInner() {
  if (!browser.runtime || !browser.runtime.getURL) {
    return { status: "error", error: "panel_unavailable" };
  }
  if (PANEL_TAB_ID && browser.tabs && browser.tabs.get) {
    try {
      var existing = await browser.tabs.get(PANEL_TAB_ID);
      if (existing && isPanelUrl(existing.url)) {
        PANEL_WINDOW_ID = typeof existing.windowId === "undefined" ? PANEL_WINDOW_ID : existing.windowId;
        await focusTab(existing);
        return { status: "ok", reused: true, tabId: PANEL_TAB_ID, windowId: PANEL_WINDOW_ID };
      }
    } catch (error) {
      PANEL_WINDOW_ID = null;
      PANEL_TAB_ID = null;
    }
  }

  try {
    var found = await findPanelTab();
    if (found) {
      PANEL_TAB_ID = found.id;
      PANEL_WINDOW_ID = typeof found.windowId === "undefined" ? PANEL_WINDOW_ID : found.windowId;
      await focusTab(found);
      return { status: "ok", reused: true, tabId: PANEL_TAB_ID, windowId: PANEL_WINDOW_ID };
    }
  } catch (error) {
  }

  var url = browser.runtime.getURL("popover.html?panel=1");
  if (browser.windows && browser.windows.create) {
    var height = 720;
    try {
      var current = await browser.windows.getCurrent();
      if (current && current.height) {
        height = Math.max(600, current.height - 120);
      }
    } catch (error) {
    }
    try {
      var panel = await browser.windows.create({
        url: url,
        type: "popup",
        width: 380,
        height: height,
        focused: true
      });
      PANEL_WINDOW_ID = panel.id || null;
      PANEL_TAB_ID = panel.tabs && panel.tabs[0] ? panel.tabs[0].id : null;
      return { status: "ok", windowId: PANEL_WINDOW_ID, tabId: PANEL_TAB_ID };
    } catch (error) {
      PANEL_WINDOW_ID = null;
      PANEL_TAB_ID = null;
    }
  }
  if (browser.tabs && browser.tabs.create) {
    var tab = await browser.tabs.create({ url: url, active: true });
    PANEL_TAB_ID = tab.id;
    PANEL_WINDOW_ID = typeof tab.windowId === "undefined" ? null : tab.windowId;
    return { status: "ok", tabId: PANEL_TAB_ID, windowId: PANEL_WINDOW_ID };
  }
  return { status: "error", error: "panel_unavailable" };
}

function openPanelWindow() {
  if (PANEL_OPEN_PROMISE) {
    return PANEL_OPEN_PROMISE;
  }
  PANEL_OPEN_PROMISE = openPanelWindowInner();
  if (PANEL_OPEN_PROMISE && PANEL_OPEN_PROMISE.finally) {
    PANEL_OPEN_PROMISE.finally(function () {
      PANEL_OPEN_PROMISE = null;
    });
  }
  return PANEL_OPEN_PROMISE;
}

async function closePanelWindow(sender) {
  var tabId = null;
  if (sender && sender.tab && typeof sender.tab.id !== "undefined") {
    if (isPanelUrl(sender.url) || isPanelUrl(sender.tab.url)) {
      tabId = sender.tab.id;
    }
  }

  if (!tabId && PANEL_TAB_ID) {
    tabId = PANEL_TAB_ID;
  }

  if (!tabId) {
    try {
      var found = await findPanelTab();
      if (found && typeof found.id !== "undefined") {
        tabId = found.id;
      }
    } catch (error) {
    }
  }

  if (tabId && browser.tabs && browser.tabs.remove) {
    try {
      await browser.tabs.remove(tabId);
    } catch (error) {
    }
  } else if (PANEL_WINDOW_ID && browser.windows && browser.windows.remove) {
    try {
      await browser.windows.remove(PANEL_WINDOW_ID);
    } catch (error) {
    }
  }

  PANEL_WINDOW_ID = null;
  PANEL_TAB_ID = null;
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
      handleToolbarClick().catch(function () {
        openPanelWindow();
      });
    });
    return;
  }
  if (browser.browserAction && browser.browserAction.onClicked) {
    browser.browserAction.onClicked.addListener(function () {
      handleToolbarClick().catch(function () {
        openPanelWindow();
      });
    });
  }
}

async function handleToolbarClick() {
  var result = await sendSidecarMessage("laika.sidecar.toggle");
  if (!result || result.status !== "ok") {
    return openPanelWindow();
  }
  return result;
}

browser.runtime.onMessage.addListener(function (message, sender) {
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
  if (message.type === "laika.panel.open") {
    return openPanelWindow();
  }
  if (message.type === "laika.panel.close") {
    return closePanelWindow(sender).then(function () {
      return { status: "ok" };
    });
  }
  return Promise.resolve({ status: "error", error: "unknown_type" });
});

registerActionClick();

if (browser.windows && browser.windows.onRemoved) {
  browser.windows.onRemoved.addListener(function (windowId) {
    if (PANEL_WINDOW_ID === windowId) {
      PANEL_WINDOW_ID = null;
      PANEL_TAB_ID = null;
    }
  });
}

if (browser.tabs && browser.tabs.onRemoved) {
  browser.tabs.onRemoved.addListener(function (tabId) {
    if (PANEL_TAB_ID === tabId) {
      PANEL_WINDOW_ID = null;
      PANEL_TAB_ID = null;
    }
  });
}
