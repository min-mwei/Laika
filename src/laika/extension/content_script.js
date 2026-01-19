(function () {
  "use strict";

  var utils = window.LaikaTextUtils || {
    normalizeWhitespace: function (text) {
      return String(text || "").replace(/\s+/g, " ").trim();
    },
    budgetText: function (text, maxChars) {
      var normalized = String(text || "").replace(/\s+/g, " ").trim();
      return normalized.length <= maxChars ? normalized : normalized.slice(0, maxChars);
    }
  };

  var handleCounter = 0;
  var handleMap = new Map();
  var SIDECAR_ID = "laika-sidecar";
  var SIDECAR_FRAME_ID = "laika-sidecar-frame";
  var SIDECAR_WIDTH = 360;

  function ensureHandle(element) {
    if (!element) {
      return null;
    }
    var existing = element.getAttribute("data-laika-handle");
    if (existing) {
      return existing;
    }
    handleCounter += 1;
    var handle = "laika-" + handleCounter;
    element.setAttribute("data-laika-handle", handle);
    handleMap.set(handle, element);
    return handle;
  }

  function getLabel(element) {
    if (!element) {
      return "";
    }
    var aria = element.getAttribute("aria-label");
    if (aria) {
      return utils.normalizeWhitespace(aria);
    }
    if (element.innerText) {
      return utils.normalizeWhitespace(element.innerText);
    }
    if (element.value) {
      return utils.normalizeWhitespace(element.value);
    }
    return "";
  }

  function getRole(element) {
    if (!element) {
      return "";
    }
    return element.getAttribute("role") || element.tagName.toLowerCase();
  }

  function sanitizeHref(href) {
    if (!href) {
      return "";
    }
    try {
      var parsed = new URL(String(href), window.location.href);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        return "";
      }
      return parsed.toString();
    } catch (error) {
      return "";
    }
  }

  function getHref(element) {
    if (!element) {
      return "";
    }
    if (element.tagName && element.tagName.toLowerCase() === "a") {
      return sanitizeHref(element.getAttribute("href") || element.href || "");
    }
    return "";
  }

  function getInputType(element) {
    if (!element) {
      return "";
    }
    if (element.tagName && element.tagName.toLowerCase() === "input") {
      return utils.normalizeWhitespace(element.getAttribute("type") || element.type || "");
    }
    return "";
  }

  function safeNumber(value) {
    return Number.isFinite(value) ? value : 0;
  }

  function getBoundingBox(element) {
    var rect = element.getBoundingClientRect();
    return {
      x: safeNumber(rect.x),
      y: safeNumber(rect.y),
      width: safeNumber(rect.width),
      height: safeNumber(rect.height)
    };
  }

  function isTextContainerVisible(element) {
    if (!element || !element.tagName) {
      return false;
    }
    var tag = element.tagName.toLowerCase();
    if (tag === "script" || tag === "style" || tag === "noscript" || tag === "head") {
      return false;
    }
    var rect = element.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) {
      return false;
    }
    var style = window.getComputedStyle(element);
    if (!style) {
      return true;
    }
    if (style.display === "none" || style.visibility === "hidden") {
      return false;
    }
    return true;
  }

  function applySidecarPlacement(container, side) {
    var placement = side === "left" ? "left" : "right";
    container.setAttribute("data-sidecar-side", placement);
    container.style.left = placement === "left" ? "0" : "auto";
    container.style.right = placement === "right" ? "0" : "auto";
    if (placement === "left") {
      container.style.borderRight = "1px solid rgba(0, 0, 0, 0.12)";
      container.style.borderLeft = "none";
    } else {
      container.style.borderLeft = "1px solid rgba(0, 0, 0, 0.12)";
      container.style.borderRight = "none";
    }
  }

  function ensureSidecar(side) {
    var root = document.body || document.documentElement;
    if (!root) {
      return null;
    }
    var container = document.getElementById(SIDECAR_ID);
    if (!container) {
      container = document.createElement("div");
      container.id = SIDECAR_ID;
      container.style.position = "fixed";
      container.style.top = "0";
      container.style.bottom = "0";
      container.style.width = SIDECAR_WIDTH + "px";
      container.style.maxWidth = "70vw";
      container.style.zIndex = "2147483647";
      container.style.background = "#f7f9fc";
      container.style.boxShadow = "none";
      container.style.pointerEvents = "auto";
      container.style.boxSizing = "border-box";
      var frame = document.createElement("iframe");
      frame.id = SIDECAR_FRAME_ID;
      frame.title = "Laika AIAgent";
      frame.style.width = "100%";
      frame.style.height = "100%";
      frame.style.border = "0";
      frame.style.background = "transparent";
      if (typeof browser !== "undefined" && browser.runtime && browser.runtime.getURL) {
        frame.src = browser.runtime.getURL("popover.html");
      }
      container.appendChild(frame);
      root.appendChild(container);
    }
    applySidecarPlacement(container, side);
    container.style.display = "block";
    return container;
  }

  function toggleSidecar(side) {
    var container = document.getElementById(SIDECAR_ID);
    if (container && container.style.display !== "none") {
      container.style.display = "none";
      return { status: "ok", visible: false };
    }
    ensureSidecar(side);
    return { status: "ok", visible: true };
  }

  function showSidecar(side) {
    ensureSidecar(side);
    return { status: "ok", visible: true };
  }

  function hideSidecar() {
    var container = document.getElementById(SIDECAR_ID);
    if (container) {
      container.style.display = "none";
    }
    return { status: "ok", visible: false };
  }

  function collectVisibleText(root, maxChars) {
    if (!root) {
      return "";
    }
    var visibilityCache = new WeakMap();
    function isNodeVisible(node) {
      if (!node || !node.parentElement) {
        return false;
      }
      var parent = node.parentElement;
      if (visibilityCache.has(parent)) {
        return visibilityCache.get(parent);
      }
      var visible = isTextContainerVisible(parent);
      visibilityCache.set(parent, visible);
      return visible;
    }

    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var chunks = [];
    var total = 0;
    var node;
    while ((node = walker.nextNode())) {
      if (!isNodeVisible(node)) {
        continue;
      }
      var text = utils.normalizeWhitespace(node.nodeValue);
      if (!text) {
        continue;
      }
      var remaining = maxChars - total;
      if (remaining <= 0) {
        break;
      }
      if (text.length > remaining) {
        text = text.slice(0, remaining);
      }
      chunks.push(text);
      total += text.length;
    }
    return chunks.join(" ");
  }

  function isBlockCandidate(element) {
    if (!element || !element.tagName) {
      return false;
    }
    if (!isTextContainerVisible(element)) {
      return false;
    }
    if (element.closest && element.closest("nav,header,footer,aside,menu")) {
      return false;
    }
    var role = (element.getAttribute("role") || "").toLowerCase();
    if (role === "navigation" || role === "banner" || role === "contentinfo" || role === "menu") {
      return false;
    }
    return true;
  }

  function linkStatsForElement(element, textLength) {
    var links = element.querySelectorAll("a");
    var linkText = 0;
    var maxLinks = 40;
    for (var i = 0; i < links.length && i < maxLinks; i += 1) {
      linkText += utils.normalizeWhitespace(links[i].innerText).length;
    }
    var density = textLength > 0 ? linkText / textLength : 0;
    if (!Number.isFinite(density)) {
      density = 0;
    }
    density = Math.max(0, Math.min(1, density));
    return { count: links.length, density: density };
  }

  function roundDensity(value) {
    return Math.round(value * 100) / 100;
  }

  function collectTextBlocks(root, maxBlocks, maxPrimaryChars) {
    if (!root) {
      return { blocks: [], primary: null };
    }
    var blockTextLimit = 360;
    var selectors = "article,main,section,h1,h2,h3,p,li,td,div";
    var nodes = Array.from(root.querySelectorAll(selectors));
    var blocks = [];
    var seen = new Set();
    var order = 0;
    nodes.forEach(function (element) {
      order += 1;
      if (!isBlockCandidate(element)) {
        return;
      }
      var rawText = utils.normalizeWhitespace(element.innerText);
      if (!rawText || rawText.length < 40) {
        return;
      }
      if (rawText.length > 900) {
        var tagName = element.tagName ? element.tagName.toLowerCase() : "";
        if (tagName === "div" || tagName === "section") {
          return;
        }
      }
      var stats = linkStatsForElement(element, rawText.length);
      if (stats.density > 0.6 && rawText.length < 200) {
        return;
      }
      var text = utils.budgetText(rawText, blockTextLimit);
      var key = text.toLowerCase();
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      var tag = element.tagName ? element.tagName.toLowerCase() : "";
      var role = element.getAttribute("role") || "";
      var score = rawText.length * (1 - stats.density);
      if (tag === "article" || tag === "main") {
        score += 200;
      }
      blocks.push({
        order: order,
        score: score,
        tag: tag,
        role: role,
        rawText: rawText,
        text: text,
        linkCount: stats.count,
        linkDensity: roundDensity(stats.density)
      });
    });
    if (blocks.length === 0) {
      return { blocks: [], primary: null };
    }
    blocks.sort(function (a, b) {
      return b.score - a.score;
    });
    var primaryCandidate = blocks[0];
    var primary = {
      tag: primaryCandidate.tag,
      role: primaryCandidate.role,
      text: utils.budgetText(primaryCandidate.rawText, maxPrimaryChars),
      linkCount: primaryCandidate.linkCount,
      linkDensity: primaryCandidate.linkDensity
    };
    var trimmed = blocks.slice(0, maxBlocks);
    trimmed.sort(function (a, b) {
      return a.order - b.order;
    });
    var outputBlocks = trimmed.map(function (block) {
      return {
        tag: block.tag,
        role: block.role,
        text: block.text,
        linkCount: block.linkCount,
        linkDensity: block.linkDensity
      };
    });
    return { blocks: outputBlocks, primary: primary };
  }

  function collectOutline(root, maxItems, maxChars) {
    if (!root) {
      return [];
    }
    var selectors = "h1,h2,h3,h4,h5,h6,li,dt,dd,summary,caption";
    var nodes = Array.from(root.querySelectorAll(selectors));
    var outline = [];
    var seen = new Set();
    var order = 0;
    nodes.forEach(function (element) {
      order += 1;
      if (!isBlockCandidate(element)) {
        return;
      }
      var rawText = utils.normalizeWhitespace(element.innerText);
      if (!rawText || rawText.length < 3) {
        return;
      }
      var text = utils.budgetText(rawText, maxChars);
      var key = text.toLowerCase();
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      var tag = element.tagName ? element.tagName.toLowerCase() : "";
      var role = element.getAttribute("role") || "";
      var level = 0;
      if (tag.length === 2 && tag.charAt(0) === "h") {
        var parsed = parseInt(tag.charAt(1), 10);
        level = Number.isFinite(parsed) ? parsed : 0;
      }
      outline.push({
        order: order,
        level: level,
        tag: tag,
        role: role,
        text: text
      });
    });
    outline.sort(function (a, b) {
      return a.order - b.order;
    });
    var trimmed = outline.slice(0, maxItems);
    return trimmed.map(function (item) {
      return {
        level: item.level,
        tag: item.tag,
        role: item.role,
        text: item.text
      };
    });
  }

  function observeDom(options) {
    var maxChars = (options && options.maxChars) || 4000;
    var maxElements = (options && options.maxElements) || 50;
    var maxBlocks = (options && options.maxBlocks) || 30;
    var maxPrimaryChars = (options && options.maxPrimaryChars) || 1200;
    var maxOutline = (options && options.maxOutline) || 50;
    var maxOutlineChars = (options && options.maxOutlineChars) || 160;
    var elements = Array.from(document.querySelectorAll("a, button, input, textarea, select"));
    var projected = elements
      .map(function (element) {
        var boundingBox = getBoundingBox(element);
        if (!boundingBox || boundingBox.width <= 0 || boundingBox.height <= 0) {
          return null;
        }
        var handleId = ensureHandle(element);
        return {
          handleId: handleId || "",
          role: getRole(element),
          label: getLabel(element),
          href: getHref(element),
          inputType: getInputType(element),
          boundingBox: boundingBox
        };
      })
      .filter(function (item) {
        return !!item && !!item.handleId;
      });
    projected.sort(function (a, b) {
      if (a.boundingBox.y === b.boundingBox.y) {
        return a.boundingBox.x - b.boundingBox.x;
      }
      return a.boundingBox.y - b.boundingBox.y;
    });
    var limited = projected.slice(0, maxElements);

    var text = collectVisibleText(document.body, maxChars);
    var blockResult = collectTextBlocks(document.body, maxBlocks, maxPrimaryChars);
    var blocks = blockResult.blocks;
    var primary = blockResult.primary;
    var outline = collectOutline(document.body, maxOutline, maxOutlineChars);
    return {
      url: window.location.href,
      title: document.title || "",
      text: text,
      elements: limited,
      blocks: blocks,
      outline: outline,
      primary: primary
    };
  }

  function highlightElement(element) {
    if (!element) {
      return;
    }
    var highlight = document.getElementById("laika-highlight");
    if (!highlight) {
      highlight = document.createElement("div");
      highlight.id = "laika-highlight";
      highlight.style.position = "fixed";
      highlight.style.border = "2px solid #00a870";
      highlight.style.zIndex = "2147483647";
      highlight.style.pointerEvents = "none";
      document.documentElement.appendChild(highlight);
    }
    var rect = element.getBoundingClientRect();
    highlight.style.left = rect.left + "px";
    highlight.style.top = rect.top + "px";
    highlight.style.width = rect.width + "px";
    highlight.style.height = rect.height + "px";
  }

  function findElement(handleId) {
    if (!handleId) {
      return null;
    }
    var cached = handleMap.get(handleId);
    if (cached) {
      return cached;
    }
    return document.querySelector('[data-laika-handle="' + handleId + '"]');
  }

  function applyTool(toolName, args) {
    if (toolName === "browser.click") {
      var target = findElement(args.handleId);
      if (target) {
        target.scrollIntoView({ block: "center" });
        highlightElement(target);
        target.click();
        return { status: "ok" };
      }
      return { status: "error", error: "not_found" };
    }

    if (toolName === "browser.type") {
      var input = findElement(args.handleId);
      if (input) {
        var tagName = input.tagName ? input.tagName.toLowerCase() : "";
        var isEditable = tagName === "input" || tagName === "textarea" || !!input.isContentEditable;
        if (!isEditable) {
          return { status: "error", error: "not_editable" };
        }
        input.scrollIntoView({ block: "center" });
        highlightElement(input);
        input.focus();
        var text = args.text || "";
        if (input.isContentEditable) {
          input.textContent = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
        } else {
          input.value = text;
          input.dispatchEvent(new Event("input", { bubbles: true }));
          input.dispatchEvent(new Event("change", { bubbles: true }));
        }
        return { status: "ok" };
      }
      return { status: "error", error: "not_found" };
    }

    if (toolName === "browser.scroll") {
      var deltaY = typeof args.deltaY === "number" ? args.deltaY : 0;
      window.scrollBy({ top: deltaY, left: 0, behavior: "smooth" });
      return { status: "ok" };
    }

    if (toolName === "browser.select") {
      var selectEl = findElement(args.handleId);
      if (!selectEl) {
        return { status: "error", error: "not_found" };
      }
      if (selectEl.tagName && selectEl.tagName.toLowerCase() !== "select") {
        return { status: "error", error: "not_select" };
      }
      var value = typeof args.value === "string" ? args.value : "";
      if (!value) {
        return { status: "error", error: "missing_value" };
      }
      var options = Array.from(selectEl.options || []);
      var matched = options.find(function (option) {
        return option.value === value || option.label === value || option.text === value;
      });
      if (matched) {
        selectEl.value = matched.value;
      } else {
        selectEl.value = value;
      }
      selectEl.dispatchEvent(new Event("input", { bubbles: true }));
      selectEl.dispatchEvent(new Event("change", { bubbles: true }));
      return { status: "ok" };
    }

    return { status: "error", error: "unsupported_tool" };
  }

  if (typeof browser !== "undefined" && browser.runtime && browser.runtime.onMessage) {
    browser.runtime.onMessage.addListener(function (message) {
      if (!message || !message.type) {
        return Promise.resolve({ status: "error", error: "invalid_message" });
      }
      if (message.type === "laika.observe") {
        return Promise.resolve({ status: "ok", observation: observeDom(message.options || {}) });
      }
      if (message.type === "laika.tool") {
        return Promise.resolve(applyTool(message.toolName, message.args || {}));
      }
      if (message.type === "laika.sidecar.toggle") {
        return Promise.resolve(toggleSidecar(message.side));
      }
      if (message.type === "laika.sidecar.show") {
        return Promise.resolve(showSidecar(message.side));
      }
      if (message.type === "laika.sidecar.hide") {
        return Promise.resolve(hideSidecar());
      }
      return Promise.resolve({ status: "error", error: "unknown_type" });
    });
  }
})();
