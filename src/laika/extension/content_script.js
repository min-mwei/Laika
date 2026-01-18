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

  function getBoundingBox(element) {
    var rect = element.getBoundingClientRect();
    return {
      x: rect.x,
      y: rect.y,
      width: rect.width,
      height: rect.height
    };
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
    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var chunks = [];
    var total = 0;
    var node;
    while ((node = walker.nextNode())) {
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

  function observeDom(options) {
    var maxChars = (options && options.maxChars) || 4000;
    var maxElements = (options && options.maxElements) || 50;
    var elements = Array.from(document.querySelectorAll("a, button, input, textarea, select"));
    var limited = elements.slice(0, maxElements).map(function (element) {
      var handleId = ensureHandle(element);
      return {
        handleId: handleId || "",
        role: getRole(element),
        label: getLabel(element),
        boundingBox: getBoundingBox(element)
      };
    });

    var text = collectVisibleText(document.body, maxChars);
    return {
      url: window.location.href,
      title: document.title || "",
      text: text,
      elements: limited
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
        input.scrollIntoView({ block: "center" });
        highlightElement(input);
        input.focus();
        input.value = args.text || "";
        input.dispatchEvent(new Event("input", { bubbles: true }));
        input.dispatchEvent(new Event("change", { bubbles: true }));
        return { status: "ok" };
      }
      return { status: "error", error: "not_found" };
    }

    if (toolName === "browser.scroll") {
      var deltaY = typeof args.deltaY === "number" ? args.deltaY : 0;
      window.scrollBy({ top: deltaY, left: 0, behavior: "smooth" });
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
