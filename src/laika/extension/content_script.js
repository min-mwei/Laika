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

  function isEditableElement(element) {
    if (!element) {
      return false;
    }
    var tag = element.tagName ? element.tagName.toLowerCase() : "";
    if (tag === "input" || tag === "textarea" || tag === "select") {
      return true;
    }
    if (element.isContentEditable) {
      return true;
    }
    if (element.hasAttribute && element.hasAttribute("contenteditable")) {
      var editable = element.getAttribute("contenteditable");
      if (editable === "" || editable === "true") {
        return true;
      }
    }
    return false;
  }

  function hasEditableAncestor(element) {
    var current = element;
    while (current) {
      if (isEditableElement(current)) {
        return true;
      }
      current = current.parentElement;
    }
    return false;
  }

  function getLabel(element) {
    if (!element) {
      return "";
    }
    var aria = element.getAttribute("aria-label");
    if (aria) {
      return utils.normalizeWhitespace(aria);
    }
    var tagName = element.tagName ? element.tagName.toLowerCase() : "";
    if (tagName === "input" || tagName === "textarea" || tagName === "select") {
      if (element.labels && element.labels.length > 0) {
        var labelText = utils.normalizeWhitespace(element.labels[0].innerText || "");
        if (labelText) {
          return labelText;
        }
      }
      var placeholder = element.getAttribute("placeholder");
      if (placeholder) {
        return utils.normalizeWhitespace(placeholder);
      }
      var name = element.getAttribute("name") || element.getAttribute("id");
      if (name) {
        return utils.normalizeWhitespace(name);
      }
      var inputType = element.getAttribute("type") || element.type || "";
      if (inputType) {
        return "input(" + utils.normalizeWhitespace(inputType) + ")";
      }
      return tagName;
    }
    if (element.innerText) {
      return utils.normalizeWhitespace(element.innerText);
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

  function hostForURL(value) {
    if (!value) {
      return "";
    }
    try {
      return new URL(String(value), window.location.href).host || "";
    } catch (error) {
      return "";
    }
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

  function hasContentAncestor(element) {
    if (!element || !element.closest) {
      return false;
    }
    return !!element.closest("article,main,[role=\"main\"],[itemprop=\"articleBody\"]");
  }

  function hasNoiseLabel(element) {
    if (!element) {
      return false;
    }
    var labels = [];
    if (element.id) {
      labels.push(element.id);
    }
    if (typeof element.className === "string" && element.className) {
      labels.push(element.className);
    }
    if (element.getAttribute) {
      var aria = element.getAttribute("aria-label");
      if (aria) {
        labels.push(aria);
      }
    }
    if (labels.length === 0) {
      return false;
    }
    var value = labels.join(" ").toLowerCase();
    if (!value) {
      return false;
    }
    var pattern = /(^|\b)(nav|menu|footer|header|sidebar|breadcrumb|cookie|consent|modal|overlay|popup|banner|subscribe|signup|signin|login|share|social|related|recommend|sponsor|sponsored|advert|promo|cta)(\b|$)/;
    if (pattern.test(value)) {
      return true;
    }
    if (/\bads?\b/.test(value) || value.indexOf("ad-") >= 0 || value.indexOf("ads-") >= 0) {
      return true;
    }
    return false;
  }

  function hasNoiseAncestor(element) {
    var current = element;
    var depth = 0;
    while (current && depth < 4) {
      if (hasNoiseLabel(current)) {
        return true;
      }
      current = current.parentElement;
      depth += 1;
    }
    return false;
  }

  function isNoiseContainer(element) {
    if (!element || !element.closest) {
      return false;
    }
    if (element.closest("[aria-hidden=\"true\"],[aria-modal=\"true\"],[hidden]")) {
      return true;
    }
    if (element.closest("dialog,[role=\"dialog\"],[role=\"alertdialog\"],[role=\"tooltip\"]")) {
      return true;
    }
    if (element.closest("[role=\"navigation\"],[role=\"banner\"],[role=\"contentinfo\"],[role=\"menu\"],[role=\"search\"],[role=\"complementary\"],[role=\"tablist\"],[role=\"tab\"],[role=\"toolbar\"]")) {
      return true;
    }
    if (element.closest("nav,menu,aside,form,address")) {
      return true;
    }
    var headerFooter = element.closest("header,footer");
    if (headerFooter && !hasContentAncestor(headerFooter)) {
      return true;
    }
    if (hasNoiseAncestor(element)) {
      return true;
    }
    return false;
  }

  function extractCleanText(element, maxChars) {
    if (!element) {
      return "";
    }
    var clone = element.cloneNode(true);
    var removeSelectors = [
      "nav",
      "aside",
      "menu",
      "form",
      "button",
      "input",
      "textarea",
      "select",
      "svg",
      "img",
      "script",
      "style",
      "noscript",
      "dialog",
      "[role=\"navigation\"]",
      "[role=\"banner\"]",
      "[role=\"contentinfo\"]",
      "[role=\"menu\"]",
      "[role=\"search\"]",
      "[role=\"tablist\"]",
      "[role=\"tab\"]",
      "[role=\"toolbar\"]",
      "[role=\"dialog\"]",
      "[role=\"alertdialog\"]",
      "[role=\"tooltip\"]",
      "[aria-hidden=\"true\"]",
      "[aria-modal=\"true\"]",
      "[hidden]",
      ".visually-hidden",
      ".sr-only",
      ".screen-reader-text"
    ];
    var removals = clone.querySelectorAll(removeSelectors.join(","));
    for (var i = 0; i < removals.length; i += 1) {
      removals[i].remove();
    }
    var text = utils.normalizeWhitespace(clone.innerText || "");
    if (maxChars) {
      text = utils.budgetText(text, maxChars);
    }
    return text;
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
    var noiseCache = new WeakMap();
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
    function shouldSkipNode(node) {
      if (!node || !node.parentElement) {
        return true;
      }
      var parent = node.parentElement;
      if (noiseCache.has(parent)) {
        return noiseCache.get(parent);
      }
      var skip = isNoiseContainer(parent);
      noiseCache.set(parent, skip);
      return skip;
    }

    var walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, null);
    var chunks = [];
    var total = 0;
    var node;
    while ((node = walker.nextNode())) {
      if (!isNodeVisible(node)) {
        continue;
      }
      if (shouldSkipNode(node)) {
        continue;
      }
      if (hasEditableAncestor(node.parentElement)) {
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
    if (hasEditableAncestor(element)) {
      return false;
    }
    if (!isTextContainerVisible(element)) {
      return false;
    }
    if (isNoiseContainer(element)) {
      return false;
    }
    var tagName = element.tagName ? element.tagName.toLowerCase() : "";
    if (tagName === "address" || tagName === "form") {
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

  function textQualityScore(text) {
    var normalized = utils.normalizeWhitespace(text);
    if (!normalized) {
      return 0.3;
    }
    var words = normalized.split(" ");
    var wordCount = words.length || 1;
    var shortWords = 0;
    for (var i = 0; i < words.length; i += 1) {
      if (words[i].length <= 2) {
        shortWords += 1;
      }
    }
    var letters = 0;
    var uppercase = 0;
    var digits = 0;
    for (var j = 0; j < normalized.length; j += 1) {
      var ch = normalized.charAt(j);
      if (/[A-Z]/.test(ch)) {
        letters += 1;
        uppercase += 1;
      } else if (/[a-z]/.test(ch)) {
        letters += 1;
      } else if (/[0-9]/.test(ch)) {
        digits += 1;
      }
    }
    var total = letters + digits;
    if (total === 0) {
      return 0.3;
    }
    var letterRatio = letters / total;
    var upperRatio = letters > 0 ? uppercase / letters : 0;
    var shortRatio = shortWords / wordCount;
    var score = 1;
    if (letterRatio < 0.6) {
      score *= 0.6;
    }
    if (upperRatio > 0.6) {
      score *= 0.6;
    }
    if (shortRatio > 0.4) {
      score *= 0.7;
    }
    return Math.max(0.3, Math.min(1, score));
  }

  function collectTextBlocks(root, maxBlocks, maxPrimaryChars) {
    if (!root) {
      return { blocks: [], primary: null };
    }
    var blockTextLimit = 420;
    var selectors = "article,main,section,h1,h2,h3,p,li,td,div,blockquote,pre";
    var nodes = Array.from(root.querySelectorAll(selectors));
    var blocks = [];
    var seen = new Set();
    var order = 0;
    var firstHeadingOrder = null;
    nodes.forEach(function (element) {
      order += 1;
      var tagName = element.tagName ? element.tagName.toLowerCase() : "";
      if (!firstHeadingOrder && (tagName === "h1" || tagName === "h2")) {
        if (isTextContainerVisible(element) && !hasEditableAncestor(element)) {
          firstHeadingOrder = order;
        }
      }
      if (!isBlockCandidate(element)) {
        return;
      }
      var rawText = utils.normalizeWhitespace(element.innerText);
      if (!rawText || rawText.length < 30) {
        return;
      }
      if (rawText.length > 120) {
        var cleanedText = extractCleanText(element, 1800);
        if (cleanedText && cleanedText.length >= 30) {
          rawText = cleanedText;
        }
      }
      if (rawText.length > 900) {
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
      var tag = tagName;
      var role = element.getAttribute("role") || "";
      var handleId = ensureHandle(element) || "";
      var quality = textQualityScore(rawText);
      var score = rawText.length * (1 - stats.density) * quality;
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
        linkDensity: roundDensity(stats.density),
        handleId: handleId
      });
    });
    if (blocks.length === 0) {
      return { blocks: [], primary: null };
    }
    blocks.sort(function (a, b) {
      return b.score - a.score;
    });
    var primaryCandidate = blocks[0];
    var orderedBlocks = blocks.slice().sort(function (a, b) {
      return a.order - b.order;
    });
    var headingCandidate = null;
    if (firstHeadingOrder) {
      headingCandidate = orderedBlocks.find(function (block) {
        return block.order > firstHeadingOrder && block.text.length >= 120 && block.linkDensity <= 0.4;
      });
    }
    var mainCandidate = orderedBlocks.find(function (block) {
      return block.tag === "article" || block.tag === "main";
    });
    if (headingCandidate) {
      primaryCandidate = headingCandidate;
    } else if (mainCandidate) {
      primaryCandidate = mainCandidate;
    } else {
      var earlyCandidate = orderedBlocks.find(function (block) {
        return block.text.length >= 120 && block.linkDensity <= 0.4;
      });
      if (earlyCandidate) {
        primaryCandidate = earlyCandidate;
      }
    }
    var primary = {
      tag: primaryCandidate.tag,
      role: primaryCandidate.role,
      text: utils.budgetText(primaryCandidate.rawText, maxPrimaryChars),
      linkCount: primaryCandidate.linkCount,
      linkDensity: primaryCandidate.linkDensity,
      handleId: primaryCandidate.handleId || ""
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
        linkDensity: block.linkDensity,
        handleId: block.handleId
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

  function collectItems(root, maxItems, maxChars) {
    if (!root) {
      return [];
    }
    var selectors = "article,li,section,div,tr,td,dt,dd";
    var nodes = Array.from(root.querySelectorAll(selectors));
    var items = [];
    var seen = new Set();
    var maxLinksPerItem = 6;
    var order = 0;
    var originHost = hostForURL(window.location.href);

    function digitRatio(text) {
      var digits = 0;
      var alnum = 0;
      for (var i = 0; i < text.length; i += 1) {
        var ch = text.charAt(i);
        if (/\p{N}/u.test(ch)) {
          digits += 1;
          alnum += 1;
        } else if (/\p{L}/u.test(ch)) {
          alnum += 1;
        }
      }
      if (alnum === 0) {
        return 0;
      }
      return digits / alnum;
    }

    function looksLikeDomainLabel(text) {
      var trimmed = String(text || "").trim();
      if (!trimmed) {
        return false;
      }
      if (/\s/.test(trimmed)) {
        return false;
      }
      if (trimmed.length > 24) {
        return false;
      }
      return trimmed.indexOf(".") >= 0 || trimmed.indexOf("/") >= 0;
    }

    function looksLikeTimeLabel(text) {
      var trimmed = String(text || "").trim().toLowerCase();
      if (!trimmed) {
        return false;
      }
      if (trimmed === "just now") {
        return true;
      }
      if (/^\d{1,2}:\d{2}$/.test(trimmed)) {
        return true;
      }
      var agoPattern = /^\d+\s+(min|mins|minute|minutes|hour|hours|day|days|week|weeks|month|months|year|years)\s+ago$/;
      if (agoPattern.test(trimmed)) {
        return true;
      }
      var shortPattern = /^\d+\s*(s|sec|secs|m|min|mins|h|hr|hrs|d|w|wk|wks|mo|yr)s?$/;
      return shortPattern.test(trimmed);
    }

    function looksLikeMetaLabel(text) {
      var trimmed = String(text || "").trim().toLowerCase();
      if (!trimmed) {
        return false;
      }
      if (trimmed.length <= 3) {
        return true;
      }
      if (trimmed.length <= 5 && /\d/.test(trimmed)) {
        return true;
      }
      var uiLabels = [
        "more",
        "next",
        "prev",
        "previous",
        "reply",
        "replies",
        "share",
        "hide",
        "login",
        "log in",
        "sign in",
        "sign up",
        "signup",
        "subscribe",
        "save",
        "bookmark",
        "view"
      ];
      for (var i = 0; i < uiLabels.length; i += 1) {
        if (trimmed === uiLabels[i]) {
          return true;
        }
      }
      return false;
    }

    function containsDigit(text) {
      return /\p{N}/u.test(String(text || ""));
    }

    function isCommentLinkCandidate(text, url) {
      var label = String(text || "").toLowerCase();
      var href = String(url || "").toLowerCase();
      if (label.indexOf("comment") >= 0 || label.indexOf("comments") >= 0) {
        return true;
      }
      if (label.indexOf("discuss") >= 0 || label.indexOf("discussion") >= 0) {
        return true;
      }
      if (label.indexOf("thread") >= 0 || label.indexOf("reply") >= 0 || label.indexOf("replies") >= 0) {
        return true;
      }
      if (href.indexOf("comment") >= 0 || href.indexOf("discussion") >= 0 || href.indexOf("thread") >= 0) {
        return true;
      }
      if (href.indexOf("#comments") >= 0 || href.indexOf("reply") >= 0) {
        return true;
      }
      return false;
    }

    nodes.forEach(function (element) {
      order += 1;
      if (!isBlockCandidate(element)) {
        return;
      }
      var anchors = element.querySelectorAll("a");
      if (!anchors || anchors.length === 0) {
        return;
      }
      var rawText = utils.normalizeWhitespace(element.innerText);
      if (!rawText || rawText.length < 20) {
        return;
      }
      var cleanedText = rawText;
      if (rawText.length > 120) {
        var cleanedCandidate = extractCleanText(element, maxChars * 2);
        if (cleanedCandidate && cleanedCandidate.length >= 20) {
          cleanedText = cleanedCandidate;
        }
      }
      var stats = linkStatsForElement(element, cleanedText.length);
      if (stats.count > 120) {
        return;
      }
      if (stats.count > 60 && stats.density > 0.4) {
        return;
      }
      var bestAnchor = null;
      var bestScore = -1;
      var bestTextLength = 0;
      var linkCandidates = [];
      var linkSeen = new Set();
      var anchorLengths = [];
      var siblingMetaText = "";
      for (var i = 0; i < anchors.length; i += 1) {
        var anchorText = utils.normalizeWhitespace(anchors[i].innerText);
        var anchorUrl = getHref(anchors[i]);
        if (!anchorText || anchorText.length < 2 || !anchorUrl) {
          continue;
        }
        var isMetaAnchor = looksLikeTimeLabel(anchorText) || looksLikeMetaLabel(anchorText) || looksLikeDomainLabel(anchorText);
        if (!isMetaAnchor && !isCommentLinkCandidate(anchorText, anchorUrl)) {
          anchorLengths.push(anchorText.length);
        }
        var anchorHost = hostForURL(anchorUrl);
        var score = anchorText.length;
        if (anchorHost && originHost && anchorHost !== originHost) {
          score += 80;
        }
        if (anchorText.length < 6) {
          score -= 10;
        }
        if (looksLikeDomainLabel(anchorText)) {
          score -= 20;
        }
        if (looksLikeTimeLabel(anchorText)) {
          score -= 60;
        }
        if (looksLikeMetaLabel(anchorText)) {
          score -= 50;
        }
        var isCommentLink = isCommentLinkCandidate(anchorText, anchorUrl);
        if (isCommentLink) {
          score -= 40;
        }
        score += Math.round(textQualityScore(anchorText) * 15);
        if (linkCandidates.length < maxLinksPerItem || isCommentLink) {
          var linkKey = (anchorText + "|" + anchorUrl).toLowerCase();
          if (!linkSeen.has(linkKey)) {
            linkSeen.add(linkKey);
            linkCandidates.push({
              title: anchorText,
              url: anchorUrl,
              handleId: ensureHandle(anchors[i]) || ""
            });
          }
        }
        if (score > bestScore) {
          bestScore = score;
          bestAnchor = anchors[i];
          bestTextLength = anchorText.length;
        }
      }
      if (linkCandidates.length < maxLinksPerItem) {
        var sibling = element.nextElementSibling;
        if (sibling && isBlockCandidate(sibling)) {
          var siblingText = utils.normalizeWhitespace(sibling.innerText);
          if (siblingText && siblingText.length <= 240) {
            var siblingAnchors = sibling.querySelectorAll("a");
            var hasStrongSibling = false;
            if (siblingAnchors && siblingAnchors.length > 0) {
              for (var j = 0; j < siblingAnchors.length; j += 1) {
                var siblingTextLabel = utils.normalizeWhitespace(siblingAnchors[j].innerText);
                if (!siblingTextLabel) {
                  continue;
                }
                if (siblingTextLabel.length >= 18 || siblingTextLabel.length >= bestTextLength + 6) {
                  hasStrongSibling = true;
                  break;
                }
              }
            }
            if (!hasStrongSibling) {
              siblingMetaText = siblingText;
              if (siblingAnchors && siblingAnchors.length > 0) {
                for (var k = 0; k < siblingAnchors.length; k += 1) {
                  var siblingLabel = utils.normalizeWhitespace(siblingAnchors[k].innerText);
                  var siblingUrl = getHref(siblingAnchors[k]);
                  if (!siblingLabel || !siblingUrl) {
                    continue;
                  }
                  var siblingIsComment = isCommentLinkCandidate(siblingLabel, siblingUrl);
                  if (linkCandidates.length >= maxLinksPerItem && !siblingIsComment) {
                    break;
                  }
                  var siblingKey = (siblingLabel + "|" + siblingUrl).toLowerCase();
                  if (linkSeen.has(siblingKey)) {
                    continue;
                  }
                  linkSeen.add(siblingKey);
                  linkCandidates.push({
                    title: siblingLabel,
                    url: siblingUrl,
                    handleId: ensureHandle(siblingAnchors[k]) || ""
                  });
                }
              }
            }
          }
        }
      }
      if (!bestAnchor) {
        return;
      }
      var strongThreshold = Math.max(24, Math.round(bestTextLength * 0.55));
      var strongAnchorCount = 0;
      for (var m = 0; m < anchorLengths.length; m += 1) {
        if (anchorLengths[m] >= strongThreshold) {
          strongAnchorCount += 1;
        }
      }
      var title = utils.normalizeWhitespace(bestAnchor.innerText);
      if (!title || title.length < 4) {
        return;
      }
      if (looksLikeTimeLabel(title)) {
        return;
      }
      if (looksLikeMetaLabel(title)) {
        return;
      }
      if (title.length <= 12 && digitRatio(title) > 0.4) {
        return;
      }
      if (looksLikeDomainLabel(title)) {
        return;
      }
      var url = getHref(bestAnchor);
      if (!url) {
        return;
      }
      var textLength = cleanedText.length;
      var bestHost = hostForURL(url);
      if (bestHost && originHost && bestHost === originHost) {
        if (bestTextLength <= 12 && textLength <= 80 && linkCandidates.length >= 2) {
          return;
        }
      }
      if (textLength < 30 && bestTextLength < 18) {
        return;
      }
      var anchorShare = textLength > 0 ? bestTextLength / textLength : 0;
      if (textLength >= 120 && anchorShare < 0.12) {
        return;
      }
      if (bestTextLength <= 12 && textLength >= 60 && anchorShare < 0.2 && linkCandidates.length >= 3) {
        return;
      }
      if (strongAnchorCount >= 2 && textLength < 500) {
        return;
      }
      if (stats.density > 0.7 && cleanedText.length < 200 && anchorShare < 0.5) {
        return;
      }
      var snippetText = cleanedText;
      if (siblingMetaText) {
        var normalizedSnippet = snippetText.toLowerCase();
        var normalizedSibling = siblingMetaText.toLowerCase();
        if (normalizedSnippet.indexOf(normalizedSibling) === -1) {
          if (containsDigit(siblingMetaText) || siblingMetaText.length > snippetText.length) {
            snippetText = rawText + " | " + siblingMetaText;
          }
        }
      }
      var snippet = utils.budgetText(snippetText, maxChars);
      var key = (title + "|" + url).toLowerCase();
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      var tag = element.tagName ? element.tagName.toLowerCase() : "";
      items.push({
        order: order,
        title: title,
        url: url,
        snippet: snippet,
        tag: tag,
        linkCount: stats.count,
        linkDensity: roundDensity(stats.density),
        handleId: ensureHandle(bestAnchor) || "",
        links: linkCandidates
      });
    });
    items.sort(function (a, b) {
      return a.order - b.order;
    });
    var trimmed = items.slice(0, maxItems);
    return trimmed.map(function (item) {
      return {
        title: item.title,
        url: item.url,
        snippet: item.snippet,
        tag: item.tag,
        linkCount: item.linkCount,
        linkDensity: item.linkDensity,
        handleId: item.handleId,
        links: item.links
      };
    });
  }

  function pickContentRoot(root) {
    if (!root || !root.querySelectorAll) {
      return null;
    }
    var candidates = Array.from(root.querySelectorAll("main,article,[role=\"main\"],[itemprop=\"articleBody\"]"));
    if (candidates.length === 0) {
      return null;
    }
    var bodyText = utils.normalizeWhitespace(root.innerText || "");
    var bodyLength = bodyText.length;
    var best = null;
    var bestScore = 0;
    var bestLength = 0;
    candidates.forEach(function (candidate) {
      if (!candidate || !isTextContainerVisible(candidate) || hasEditableAncestor(candidate)) {
        return;
      }
      if (isNoiseContainer(candidate)) {
        return;
      }
      var text = utils.normalizeWhitespace(candidate.innerText || "");
      if (!text || text.length < 400) {
        return;
      }
      var stats = linkStatsForElement(candidate, text.length);
      var quality = textQualityScore(text);
      var score = text.length * (1 - stats.density) * quality;
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
        bestLength = text.length;
      }
    });
    if (!best) {
      return null;
    }
    if (bodyLength > 0) {
      var ratio = bestLength / bodyLength;
      if (bestLength < 600 && ratio < 0.25) {
        return null;
      }
    }
    return best;
  }

  function hasCommentHint(element) {
    if (!element) {
      return false;
    }
    var id = (element.id || "").toLowerCase();
    var className = "";
    if (typeof element.className === "string") {
      className = element.className.toLowerCase();
    }
    if (id.indexOf("comment") >= 0 || className.indexOf("comment") >= 0) {
      return true;
    }
    if (id.indexOf("reply") >= 0 || className.indexOf("reply") >= 0) {
      return true;
    }
    if (id.indexOf("thread") >= 0 || className.indexOf("thread") >= 0) {
      return true;
    }
    if (id.indexOf("discussion") >= 0 || className.indexOf("discussion") >= 0) {
      return true;
    }
    if (hasCommentMetadata(element)) {
      return true;
    }
    if (hasCommentTextHint(element)) {
      return true;
    }
    return false;
  }

  function hasCommentMetadata(element) {
    if (!element || !element.querySelector) {
      return false;
    }
    var timeEl = element.querySelector("time,[datetime],[data-time],.age,.time,.timestamp");
    if (!timeEl) {
      return false;
    }
    var authorEl = element.querySelector(
      "[rel=\"author\"],[itemprop=\"author\"],[data-author],.author,.user,.username,.byline,.comment-author"
    );
    if (authorEl) {
      return true;
    }
    var replyEl = element.querySelector(".reply,[data-reply-id],a[href*=\"reply\"]");
    return !!replyEl;
  }

  function hasCommentTextHint(element) {
    if (!element || !element.querySelector) {
      return false;
    }
    var textEl = element.querySelector("[class*=\"comment\"],[class*=\"commtext\"],[class*=\"reply\"],[itemprop=\"text\"]");
    return !!textEl;
  }

  function findMetaText(container, selectors, maxChars) {
    if (!container) {
      return "";
    }
    for (var i = 0; i < selectors.length; i += 1) {
      var element = container.querySelector(selectors[i]);
      if (!element) {
        continue;
      }
      var text = utils.normalizeWhitespace(element.innerText || "");
      if (!text) {
        var fallback = element.getAttribute("title") || element.getAttribute("datetime") || "";
        text = utils.normalizeWhitespace(fallback);
      }
      if (!text) {
        continue;
      }
      if (maxChars && text.length > maxChars) {
        text = text.slice(0, maxChars);
      }
      return text;
    }
    return "";
  }

  function extractCommentDepth(container) {
    if (!container) {
      return 0;
    }
    var attrCandidates = ["data-depth", "data-level", "aria-level", "indent"];
    for (var i = 0; i < attrCandidates.length; i += 1) {
      var attr = container.getAttribute(attrCandidates[i]);
      if (attr) {
        var value = parseInt(attr, 10);
        if (Number.isFinite(value)) {
          return Math.max(0, value);
        }
      }
    }
    var indentElement = container.querySelector("[indent]");
    if (indentElement) {
      var indentAttr = indentElement.getAttribute("indent");
      var indentValue = parseInt(indentAttr, 10);
      if (Number.isFinite(indentValue)) {
        return Math.max(0, indentValue);
      }
    }
    var depth = 0;
    var parent = container.parentElement;
    while (parent) {
      var tag = parent.tagName ? parent.tagName.toLowerCase() : "";
      if (tag === "ol" || tag === "ul" || tag === "blockquote") {
        depth += 1;
      }
      parent = parent.parentElement;
    }
    return depth;
  }

  function pickCommentTextElement(container) {
    if (!container) {
      return null;
    }
    var selectors = [
      "[itemprop=\"text\"]",
      ".comment",
      "[class*=\"comment\"]",
      "[class*=\"commtext\"]",
      ".comment-body",
      ".comment_body",
      ".comment-content",
      ".content",
      ".message",
      ".text"
    ];
    var nodes = container.querySelectorAll(selectors.join(","));
    var best = null;
    var bestLength = 0;
    for (var i = 0; i < nodes.length; i += 1) {
      var nodeText = utils.normalizeWhitespace(nodes[i].innerText || "");
      if (nodeText.length > bestLength) {
        bestLength = nodeText.length;
        best = nodes[i];
      }
    }
    return best || container;
  }

  function extractCommentText(container, maxChars) {
    var element = pickCommentTextElement(container) || container;
    if (!element) {
      return "";
    }
    var clone = element.cloneNode(true);
    var removeSelectors = [
      "nav",
      "header",
      "footer",
      "aside",
      "form",
      "button",
      "input",
      "textarea",
      "select",
      "svg",
      "img",
      "script",
      "style",
      "time",
      "[datetime]",
      "[data-time]",
      ".reply",
      ".comment-actions",
      ".actions",
      ".age",
      ".time",
      ".timestamp",
      ".user",
      ".username",
      ".author",
      ".byline",
      ".comment-author",
      ".nav",
      ".navs",
      ".navigation",
      ".controls",
      ".meta",
      ".metadata",
      ".permalink",
      "[rel=\"author\"]",
      "[itemprop=\"author\"]",
      "[data-author]",
      "a[href*=\"user\"]",
      "a[href*=\"profile\"]"
    ];
    var removals = clone.querySelectorAll(removeSelectors.join(","));
    for (var i = 0; i < removals.length; i += 1) {
      removals[i].remove();
    }
    var nestedLists = clone.querySelectorAll("ol, ul");
    for (var j = 0; j < nestedLists.length; j += 1) {
      nestedLists[j].remove();
    }
    var text = utils.normalizeWhitespace(clone.innerText || "");
    if (maxChars) {
      text = utils.budgetText(text, maxChars);
    }
    return text;
  }

  function isLikelyAuthorLabel(text) {
    var normalized = utils.normalizeWhitespace(text || "");
    if (!normalized) {
      return false;
    }
    if (normalized.length > 40) {
      return false;
    }
    var words = normalized.split(" ");
    if (words.length > 3) {
      return false;
    }
    return true;
  }

  function collectComments(root, maxComments, maxChars) {
    if (!root || maxComments <= 0) {
      return [];
    }
    var selectors = [
      "[role=\"comment\"]",
      "[itemprop=\"comment\"]",
      "[itemtype*=\"Comment\"]",
      "[data-comment-id]",
      "[data-comment]",
      "[data-thread-id]",
      "[data-reply-id]",
      ".comment",
      "[class*=\"comment\"]",
      "[class*=\"commtext\"]",
      "[class*=\"reply\"]",
      ".comment-body",
      ".comment_body",
      ".comment-content"
    ];
    var nodes = Array.from(root.querySelectorAll(selectors.join(",")));
    if (nodes.length < 3) {
      var fallbackNodes = Array.from(root.querySelectorAll("article,li,div,section,tr"));
      for (var i = 0; i < fallbackNodes.length; i += 1) {
        if (hasCommentHint(fallbackNodes[i])) {
          nodes.push(fallbackNodes[i]);
        }
      }
      if (nodes.length < 3) {
        var lists = root.querySelectorAll("ol, ul");
        for (var j = 0; j < lists.length; j += 1) {
          var listItems = Array.from(lists[j].children).filter(function (child) {
            return child && child.tagName && child.tagName.toLowerCase() === "li";
          });
          if (listItems.length < 3) {
            continue;
          }
          nodes = nodes.concat(listItems);
        }
      }
    }

    var seen = new Set();
    var comments = [];
    for (var k = 0; k < nodes.length; k += 1) {
      if (comments.length >= maxComments) {
        break;
      }
      var node = nodes[k];
      if (!node) {
        continue;
      }
      var container = node.closest ? node.closest("article,li,div,section,td,tr") : node;
      if (!container) {
        container = node;
      }
      if (!isBlockCandidate(container)) {
        continue;
      }
      var text = extractCommentText(container, maxChars);
      if (!text || text.length < 30) {
        continue;
      }
      var key = text.toLowerCase();
      if (seen.has(key)) {
        continue;
      }
      seen.add(key);
      var author = findMetaText(container, [
        "[rel=\"author\"]",
        "[itemprop=\"author\"]",
        "[data-author]",
        ".author",
        ".user",
        ".username",
        ".byline",
        ".comment-author",
        "a[href*=\"user\"]",
        "a[href*=\"profile\"]"
      ], 80);
      if (!isLikelyAuthorLabel(author)) {
        author = "";
      }
      var age = findMetaText(container, [
        "time",
        "[datetime]",
        "[data-time]",
        ".age",
        ".time",
        ".timestamp"
      ], 80);
      var score = "";
      var scoreElement = container.querySelector("[data-score],[data-vote-count],.score,.points,.likes,.upvotes");
      if (scoreElement) {
        var scoreText = utils.normalizeWhitespace(scoreElement.innerText || scoreElement.getAttribute("data-score") || "");
        if (!scoreText) {
          scoreText = utils.normalizeWhitespace(scoreElement.getAttribute("data-vote-count") || "");
        }
        score = scoreText;
      }
      comments.push({
        text: text,
        author: author,
        age: age,
        score: score,
        depth: extractCommentDepth(container),
        handleId: ensureHandle(container) || ""
      });
    }
    return comments;
  }

  function observeDom(options) {
    var maxChars = (options && options.maxChars) || 4000;
    var maxElements = (options && options.maxElements) || 50;
    var maxBlocks = (options && options.maxBlocks) || 30;
    var maxPrimaryChars = (options && options.maxPrimaryChars) || 1200;
    var maxOutline = (options && options.maxOutline) || 50;
    var maxOutlineChars = (options && options.maxOutlineChars) || 160;
    var maxItems = (options && options.maxItems) || 24;
    var maxItemChars = (options && options.maxItemChars) || 240;
    var maxComments = (options && options.maxComments) || 24;
    var maxCommentChars = (options && options.maxCommentChars) || 360;
    var root = document.body;
    if (options && options.rootHandleId) {
      var target = findElement(options.rootHandleId);
      if (target) {
        root = target;
      }
    }
    var textRoot = root;
    if (!options || !options.rootHandleId) {
      var contentRoot = pickContentRoot(root);
      if (contentRoot) {
        textRoot = contentRoot;
      }
    }
    var elements = Array.from((root || document).querySelectorAll("a, button, input, textarea, select"));
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

    var text = collectVisibleText(textRoot, maxChars);
    var blockResult = collectTextBlocks(textRoot, maxBlocks, maxPrimaryChars);
    var blocks = blockResult.blocks;
    var primary = blockResult.primary;
    var outline = collectOutline(textRoot, maxOutline, maxOutlineChars);
    var items = collectItems(textRoot, maxItems, maxItemChars);
    var comments = collectComments(textRoot, maxComments, maxCommentChars);
    return {
      url: window.location.href,
      title: document.title || "",
      text: text,
      elements: limited,
      blocks: blocks,
      items: items,
      outline: outline,
      primary: primary,
      comments: comments
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

  if (typeof window !== "undefined" && window.__LAIKA_HARNESS__) {
    if (!window.LaikaHarness) {
      window.LaikaHarness = {};
    }
    window.LaikaHarness.observeDom = observeDom;
    window.LaikaHarness.applyTool = applyTool;
  }
})();
