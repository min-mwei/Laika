(function () {
  "use strict";

  if (typeof window !== "undefined") {
    if (window.__LAIKA_CONTENT_SCRIPT__) {
      return;
    }
    window.__LAIKA_CONTENT_SCRIPT__ = true;
  }

  var utils = window.LaikaTextUtils || {
    normalizeWhitespace: function (text) {
      return String(text || "").replace(/\s+/g, " ").trim();
    },
    budgetText: function (text, maxChars) {
      var normalized = String(text || "").replace(/\s+/g, " ").trim();
      return normalized.length <= maxChars ? normalized : normalized.slice(0, maxChars);
    }
  };

  var ToolErrorCode = {
    INVALID_ARGUMENTS: "INVALID_ARGUMENTS",
    NO_CONTEXT: "NO_CONTEXT",
    UNSUPPORTED_TOOL: "UNSUPPORTED_TOOL",
    STALE_HANDLE: "STALE_HANDLE",
    NOT_FOUND: "NOT_FOUND",
    NOT_INTERACTABLE: "NOT_INTERACTABLE",
    DISABLED: "DISABLED",
    BLOCKED_BY_OVERLAY: "BLOCKED_BY_OVERLAY"
  };

  var ObservationSignal = {
    PAYWALL_OR_LOGIN: "paywall_or_login",
    CONSENT_MODAL: "consent_modal",
    CAPTCHA_OR_ROBOT_CHECK: "captcha_or_robot_check",
    OVERLAY_BLOCKING: "overlay_blocking",
    SPARSE_TEXT: "sparse_text",
    NON_TEXT_CONTENT: "non_text_content",
    CROSS_ORIGIN_IFRAME: "cross_origin_iframe",
    CLOSED_SHADOW_ROOT: "closed_shadow_root",
    VIRTUALIZED_LIST: "virtualized_list",
    INFINITE_SCROLL: "infinite_scroll",
    PDF_VIEWER: "pdf_viewer",
    URL_REDACTED: "url_redacted",
    AGE_GATE: "age_gate",
    GEO_BLOCK: "geo_block",
    SCRIPT_REQUIRED: "script_required"
  };

  var documentId = null;
  var navGeneration = 0;
  var navChangedAtMs = 0;
  var lastObservedDocumentId = null;
  var lastObservedGeneration = null;
  var overlayCache = { generation: null, overlay: null, checkedAt: 0 };
  var overlayCacheTtlMs = 750;

  function randomId(prefix) {
    var randomPart = Math.random().toString(36).slice(2, 10);
    var timePart = Date.now().toString(36);
    return (prefix || "id") + "-" + timePart + "-" + randomPart;
  }

  function ensureDocumentId() {
    if (!documentId) {
      documentId = randomId("doc");
    }
    return documentId;
  }

  function markNavigation() {
    navGeneration += 1;
    navChangedAtMs = Date.now();
  }

  function initNavigationTracking() {
    if (typeof window === "undefined" || !window.history) {
      return;
    }
    try {
      var originalPush = window.history.pushState;
      var originalReplace = window.history.replaceState;
      if (originalPush) {
        window.history.pushState = function () {
          markNavigation();
          return originalPush.apply(this, arguments);
        };
      }
      if (originalReplace) {
        window.history.replaceState = function () {
          markNavigation();
          return originalReplace.apply(this, arguments);
        };
      }
    } catch (error) {
    }
    window.addEventListener("popstate", markNavigation);
    window.addEventListener("hashchange", markNavigation);
  }

  initNavigationTracking();

  var handleCounter = 0;
  var handleMap = new Map();
  var SIDECAR_ID = "laika-sidecar";
  var SIDECAR_FRAME_ID = "laika-sidecar-frame";
  var SIDECAR_WIDTH = 360;
  var CONTENT_ROOT_SELECTORS = [
    "article",
    "main",
    "[role=\"main\"]",
    "[role=\"article\"]",
    "[itemprop=\"articleBody\"]",
    "#content",
    "#main",
    "#main-content",
    "#mainContent",
    ".content",
    ".content-main",
    ".content-body",
    ".main",
    ".main-content",
    ".article",
    ".article-body",
    ".article-content",
    ".post-content",
    ".entry-content",
    ".story-body",
    ".story-content",
    ".page-content"
  ].join(",");
  var TEXT_ELEMENT_TAGS = new Set([
    "p",
    "li",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "blockquote",
    "pre",
    "code",
    "summary",
    "caption",
    "figcaption",
    "td",
    "th",
    "dt",
    "dd"
  ]);
  var COMMENT_SELECTORS = [
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
  ].join(",");
  var INLINE_COMMENT_TAGS = new Set(["span", "a", "em", "strong", "b", "i", "small", "time", "code"]);
  var ACCESS_OVERLAY_SELECTORS = [
    "dialog",
    "[role=\"dialog\"]",
    "[role=\"alertdialog\"]",
    "[aria-modal=\"true\"]",
    "[class*=\"modal\"]",
    "[class*=\"overlay\"]",
    "[class*=\"paywall\"]",
    "[class*=\"subscribe\"]",
    "[class*=\"consent\"]",
    "[id*=\"modal\"]",
    "[id*=\"overlay\"]",
    "[id*=\"paywall\"]",
    "[id*=\"subscribe\"]",
    "[id*=\"consent\"]",
    "[data-testid*=\"modal\"]",
    "[data-testid*=\"overlay\"]",
    "[data-testid*=\"paywall\"]"
  ].join(",");
  var PAYWALL_KEYWORDS_STRONG = [
    "subscribe to continue",
    "continue reading",
    "subscription",
    "subscribe now",
    "start your free trial",
    "start free trial",
    "members only",
    "member-only",
    "already a subscriber",
    "sign in to continue",
    "log in to continue",
    "paywall"
  ];
  var PAYWALL_KEYWORDS_WEAK = ["subscribe", "subscriber", "membership", "member", "premium", "free trial"];
  var AUTH_GATE_KEYWORDS_STRONG = [
    "sign in to",
    "log in to",
    "login to",
    "create an account",
    "create account",
    "register to",
    "account required",
    "sign in required",
    "login required"
  ];
  var AUTH_GATE_KEYWORDS_WEAK = ["sign in", "log in", "login", "sign up", "signup", "register", "create account"];
  var CONSENT_KEYWORDS = [
    "cookie",
    "consent",
    "privacy choices",
    "privacy settings",
    "cookie preferences",
    "manage cookies",
    "gdpr"
  ];
  var AGE_GATE_KEYWORDS = [
    "age verification",
    "verify your age",
    "confirm your age",
    "enter your date of birth",
    "enter your birthday",
    "you must be 18",
    "age gate"
  ];
  var GEO_BLOCK_KEYWORDS = [
    "not available in your country",
    "not available in your region",
    "not available in your location",
    "unavailable in your region",
    "not available in your area",
    "outside your region"
  ];
  var SCRIPT_BLOCK_KEYWORDS = [
    "enable javascript",
    "javascript is disabled",
    "please enable javascript",
    "turn off ad blocker",
    "disable adblock",
    "ad blocker"
  ];
  var ROBOT_CHECK_KEYWORDS = [
    "verify that you are not a robot",
    "are you a robot",
    "captcha",
    "robot check",
    "human verification",
    "please verify",
    "unusual traffic"
  ];
  var BLOCK_CHILD_SELECTORS = [
    "p",
    "li",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "blockquote",
    "pre",
    "table",
    "ul",
    "ol",
    "dl",
    "section",
    "article",
    "main"
  ].join(",");

  function normalizeInlineText(text) {
    return utils.normalizeWhitespace(text);
  }

  function normalizeStructuredText(text) {
    var raw = String(text || "");
    if (!raw) {
      return "";
    }
    var lines = raw.split(/\r?\n/);
    var cleaned = [];
    for (var i = 0; i < lines.length; i += 1) {
      var normalized = utils.normalizeWhitespace(lines[i]);
      if (normalized) {
        cleaned.push(normalized);
      }
    }
    return cleaned.join("\n");
  }

  function budgetStructuredText(text, maxChars) {
    var normalized = normalizeStructuredText(text);
    if (!maxChars || normalized.length <= maxChars) {
      return normalized;
    }
    return normalized.slice(0, Math.max(0, maxChars));
  }

  function nowMs() {
    if (typeof performance !== "undefined" && performance.now) {
      return performance.now();
    }
    return Date.now();
  }

  function trimDebugValue(value, maxChars) {
    var normalized = utils.normalizeWhitespace(value || "");
    if (maxChars && normalized.length > maxChars) {
      return normalized.slice(0, maxChars) + "...";
    }
    return normalized;
  }

  function debugElementInfo(element) {
    if (!element || !element.tagName) {
      return null;
    }
    var className = "";
    if (typeof element.className === "string") {
      className = element.className;
    }
    return {
      tag: element.tagName.toLowerCase(),
      id: trimDebugValue(element.id || "", 60),
      className: trimDebugValue(className, 120),
      role: trimDebugValue(element.getAttribute ? element.getAttribute("role") || "" : "", 40)
    };
  }

  function isHeadingTag(tagName) {
    if (!tagName) {
      return false;
    }
    return tagName.length === 2 && tagName.charAt(0) === "h" && tagName.charAt(1) >= "1" && tagName.charAt(1) <= "6";
  }

  var blockChildCache = new WeakMap();
  function hasBlockChild(element) {
    if (!element || !element.querySelector) {
      return false;
    }
    if (blockChildCache.has(element)) {
      return blockChildCache.get(element);
    }
    var found = !!element.querySelector(BLOCK_CHILD_SELECTORS);
    blockChildCache.set(element, found);
    return found;
  }

  function isLeafTextContainer(element) {
    if (!element || !element.tagName) {
      return false;
    }
    var tag = element.tagName.toLowerCase();
    if (tag === "div" || tag === "section" || tag === "article" || tag === "main") {
      return !hasBlockChild(element);
    }
    return false;
  }

  function getTextContainer(element) {
    var current = element;
    while (current) {
      if (current.tagName) {
        var tagName = current.tagName.toLowerCase();
        if (tagName === "li" || tagName === "dt" || tagName === "dd") {
          return current;
        }
      }
      current = current.parentElement;
    }
    current = element;
    while (current) {
      if (!current.tagName) {
        current = current.parentElement;
        continue;
      }
      var tag = current.tagName.toLowerCase();
      if (TEXT_ELEMENT_TAGS.has(tag)) {
        return current;
      }
      if (isLeafTextContainer(current)) {
        return current;
      }
      current = current.parentElement;
    }
    return element;
  }

  function listDepth(element) {
    var depth = 0;
    var parent = element ? element.parentElement : null;
    while (parent) {
      var tag = parent.tagName ? parent.tagName.toLowerCase() : "";
      if (tag === "ul" || tag === "ol") {
        depth += 1;
      }
      parent = parent.parentElement;
    }
    return depth;
  }

  function formatStructuredLine(element, text) {
    if (!text) {
      return "";
    }
    var tag = element && element.tagName ? element.tagName.toLowerCase() : "";
    if (isHeadingTag(tag)) {
      return tag.toUpperCase() + ": " + text;
    }
    if (tag === "li") {
      var depth = listDepth(element);
      var indent = "";
      if (depth > 1) {
        indent = "  ".repeat(Math.min(depth - 1, 4));
      }
      return indent + "- " + text;
    }
    if (tag === "blockquote") {
      return "> " + text;
    }
    if (tag === "pre" || tag === "code") {
      return "Code: " + text;
    }
    if (tag === "summary") {
      return "Summary: " + text;
    }
    if (tag === "caption" || tag === "figcaption") {
      return "Caption: " + text;
    }
    if (tag === "dt") {
      return "Term: " + text;
    }
    if (tag === "dd") {
      return "Definition: " + text;
    }
    return text;
  }

  function formatBlockText(element, text) {
    if (!text) {
      return "";
    }
    if (text.indexOf("\n") >= 0) {
      return text;
    }
    return formatStructuredLine(element, text);
  }

  function minBlockLength(tagName) {
    if (isHeadingTag(tagName)) {
      return 12;
    }
    if (tagName === "li" || tagName === "dt" || tagName === "dd") {
      return 12;
    }
    if (tagName === "pre" || tagName === "code") {
      return 8;
    }
    return 20;
  }

  function isMeaningfulShortText(text) {
    var normalized = utils.normalizeWhitespace(text);
    if (!normalized) {
      return false;
    }
    if (normalized.length >= 18) {
      return true;
    }
    if (/\d/.test(normalized)) {
      return true;
    }
    if (/[A-Z]/.test(normalized) && normalized.split(" ").length >= 2) {
      return true;
    }
    return false;
  }

  function isLikelyShadowHost(element) {
    if (!element || !element.tagName) {
      return false;
    }
    var tagName = element.tagName.toLowerCase();
    if (tagName.indexOf("-") === -1) {
      return false;
    }
    if (element.shadowRoot) {
      return false;
    }
    if (element.childElementCount > 0) {
      return false;
    }
    return true;
  }

  function collectRoots(root, signalState) {
    var roots = [];
    var seen = new Set();
    function visit(node) {
      if (!node || seen.has(node)) {
        return;
      }
      seen.add(node);
      roots.push(node);
      if (!node.querySelectorAll) {
        return;
      }
      var walker = document.createTreeWalker(node, NodeFilter.SHOW_ELEMENT, null);
      var current = walker.nextNode();
      while (current) {
        if (current.shadowRoot && current.shadowRoot.mode === "open") {
          visit(current.shadowRoot);
        } else if (signalState && isLikelyShadowHost(current)) {
          signalState.closedShadowRoot = true;
        }
        if (current.tagName && current.tagName.toLowerCase() === "iframe") {
          try {
            var frameDoc = current.contentDocument;
            if (frameDoc && frameDoc.documentElement) {
              visit(frameDoc);
            } else if (signalState) {
              signalState.crossOriginIframe = true;
            }
          } catch (error) {
            if (signalState) {
              signalState.crossOriginIframe = true;
            }
          }
        }
        current = walker.nextNode();
      }
    }
    visit(root);
    return roots;
  }

  function querySelectorAllDeep(root, selector, roots) {
    var rootList = roots;
    if (!rootList) {
      if (!root) {
        return [];
      }
      rootList = collectRoots(root);
    }
    var results = [];
    for (var i = 0; i < rootList.length; i += 1) {
      if (rootList[i] && rootList[i].querySelectorAll) {
        results = results.concat(Array.from(rootList[i].querySelectorAll(selector)));
      }
    }
    return results;
  }

  function ensureHandle(element) {
    if (!element) {
      return null;
    }
    var existing = element.getAttribute("data-laika-handle");
    if (existing) {
      if (!handleMap.has(existing)) {
        handleMap.set(existing, { element: element, generation: navGeneration, documentId: ensureDocumentId() });
      }
      return existing;
    }
    handleCounter += 1;
    var handle = "laika-" + handleCounter;
    element.setAttribute("data-laika-handle", handle);
    handleMap.set(handle, { element: element, generation: navGeneration, documentId: ensureDocumentId() });
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

  var SAFE_QUERY_KEYS = {
    id: true,
    item: true,
    p: true,
    page: true,
    q: true,
    query: true,
    search: true
  };
  var BLOCKED_QUERY_KEY_PATTERN = /(token|auth|session|sid|key|code|pass|secret|signature|sig|jwt|bearer|oauth|utm_|fbclid|gclid|yclid|mc_cid|mc_eid)/i;
  var urlRedactionCounter = null;

  function looksSensitiveValue(value) {
    if (!value) {
      return false;
    }
    if (value.length >= 40) {
      return true;
    }
    if (/^[A-Za-z0-9\-_]{24,}$/.test(value)) {
      return true;
    }
    if (/^[A-Fa-f0-9]{24,}$/.test(value)) {
      return true;
    }
    return false;
  }

  function sanitizeURLString(value) {
    if (!value) {
      return "";
    }
    try {
      var parsed = new URL(String(value), window.location.href);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        return "";
      }
      var originalHash = parsed.hash || "";
      var originalSearch = parsed.search || "";
      var redacted = false;
      if (originalHash) {
        redacted = true;
      }
      parsed.hash = "";
      if (parsed.search) {
        var params = new URLSearchParams(parsed.search);
        var filtered = new URLSearchParams();
        var removed = 0;
        params.forEach(function (paramValue, key) {
          var lowerKey = String(key).toLowerCase();
          if (BLOCKED_QUERY_KEY_PATTERN.test(lowerKey)) {
            removed += 1;
            return;
          }
          if (looksSensitiveValue(paramValue) && !SAFE_QUERY_KEYS[lowerKey]) {
            removed += 1;
            return;
          }
          filtered.append(key, paramValue);
        });
        var query = filtered.toString();
        parsed.search = query ? "?" + query : "";
        if (removed > 0 || (originalSearch && query !== params.toString())) {
          redacted = true;
        }
      }
      if (redacted && urlRedactionCounter) {
        urlRedactionCounter.count += 1;
      }
      return parsed.toString();
    } catch (error) {
      return "";
    }
  }

  function sanitizeHref(href) {
    return sanitizeURLString(href);
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
    var style = window.getComputedStyle(element);
    if (!style) {
      return true;
    }
    if (style.display === "none" || style.visibility === "hidden" || style.opacity === "0") {
      return false;
    }
    if (style.display === "contents") {
      return true;
    }
    var rect = element.getBoundingClientRect();
    if (rect && (rect.width > 0 || rect.height > 0)) {
      return true;
    }
    var rects = element.getClientRects ? element.getClientRects() : null;
    if (rects && rects.length > 0) {
      return true;
    }
    return false;
  }

  function hasContentAncestor(element) {
    if (!element || !element.closest) {
      return false;
    }
    return !!element.closest(CONTENT_ROOT_SELECTORS);
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
    var insideContent = hasContentAncestor(element);
    var roleNoise = element.closest("[role=\"navigation\"],[role=\"banner\"],[role=\"contentinfo\"],[role=\"menu\"],[role=\"search\"],[role=\"complementary\"],[role=\"tablist\"],[role=\"tab\"],[role=\"toolbar\"]");
    if (roleNoise) {
      if (!insideContent) {
        return true;
      }
      var role = (roleNoise.getAttribute("role") || "").toLowerCase();
      if (role === "navigation" || role === "menu" || role === "toolbar") {
        return true;
      }
    }
    if (element.closest("nav,menu")) {
      return true;
    }
    if (element.closest("aside") && !insideContent) {
      return true;
    }
    var form = element.closest("form");
    if (form) {
      if (!insideContent) {
        return true;
      }
      if (formIsLikelyChrome(form)) {
        return true;
      }
    }
    if (element.closest("address") && !insideContent) {
      return true;
    }
    var headerFooter = element.closest("header,footer");
    if (headerFooter && !hasContentAncestor(headerFooter)) {
      return true;
    }
    if (!insideContent && hasNoiseAncestor(element)) {
      return true;
    }
    return false;
  }

  function formIsLikelyChrome(form) {
    if (!form || !form.querySelector) {
      return false;
    }
    if (hasNoiseLabel(form)) {
      return true;
    }
    if (form.querySelector("input[type=\"password\"],input[type=\"email\"]")) {
      return true;
    }
    if (form.querySelector("input[type=\"search\"],[role=\"searchbox\"]")) {
      return true;
    }
    return false;
  }

  function extractCleanText(element, maxChars, options) {
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
    var preserveLines = options && options.preserveLines;
    var rawText = clone.innerText || "";
    var text = preserveLines ? normalizeStructuredText(rawText) : utils.normalizeWhitespace(rawText);
    if (maxChars) {
      text = preserveLines ? budgetStructuredText(text, maxChars) : utils.budgetText(text, maxChars);
    }
    return text;
  }

  function extractSignalText(element, maxChars) {
    if (!element) {
      return "";
    }
    var raw = element.innerText || element.textContent || "";
    var text = utils.normalizeWhitespace(raw);
    if (maxChars) {
      text = utils.budgetText(text, maxChars);
    }
    return text;
  }

  function containsAnyKeyword(text, keywords) {
    if (!text) {
      return false;
    }
    for (var i = 0; i < keywords.length; i += 1) {
      if (text.indexOf(keywords[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  function isDialogLike(element) {
    if (!element) {
      return false;
    }
    var tag = element.tagName ? element.tagName.toLowerCase() : "";
    if (tag === "dialog") {
      return true;
    }
    if (element.getAttribute) {
      var role = (element.getAttribute("role") || "").toLowerCase();
      if (role === "dialog" || role === "alertdialog") {
        return true;
      }
      if (element.getAttribute("aria-modal") === "true") {
        return true;
      }
    }
    return false;
  }

  function isLargeOverlay(element, viewportWidth, viewportHeight) {
    if (!element || !element.getBoundingClientRect) {
      return false;
    }
    var rect = element.getBoundingClientRect();
    if (!rect || rect.width <= 0 || rect.height <= 0) {
      return false;
    }
    var viewportArea = viewportWidth * viewportHeight;
    if (viewportArea <= 0) {
      return false;
    }
    var area = rect.width * rect.height;
    var coverRatio = area / viewportArea;
    if (coverRatio < 0.2) {
      return false;
    }
    var style = window.getComputedStyle(element);
    var position = style ? style.position : "";
    if (position !== "fixed" && position !== "sticky" && position !== "absolute") {
      return false;
    }
    return true;
  }

  function findOverlayCandidate(root, rootRoots) {
    var candidates = querySelectorAllDeep(root || document, ACCESS_OVERLAY_SELECTORS, rootRoots);
    if (!candidates.length) {
      return null;
    }
    var viewportWidth = Math.max(
      document.documentElement ? document.documentElement.clientWidth : 0,
      window.innerWidth || 0
    );
    var viewportHeight = Math.max(
      document.documentElement ? document.documentElement.clientHeight : 0,
      window.innerHeight || 0
    );
    var best = null;
    var bestArea = 0;
    var limit = Math.min(candidates.length, 40);
    for (var i = 0; i < limit; i += 1) {
      var candidate = candidates[i];
      if (!candidate || candidate === document.body || candidate === document.documentElement) {
        continue;
      }
      if (!isTextContainerVisible(candidate)) {
        continue;
      }
      if (isDialogLike(candidate)) {
        return candidate;
      }
      if (!candidate.getBoundingClientRect) {
        continue;
      }
      var rect = candidate.getBoundingClientRect();
      if (!rect || rect.width <= 0 || rect.height <= 0) {
        continue;
      }
      if (!isLargeOverlay(candidate, viewportWidth, viewportHeight)) {
        continue;
      }
      var area = rect.width * rect.height;
      if (area > bestArea) {
        best = candidate;
        bestArea = area;
      }
    }
    return best;
  }

  function collectAccessSignals(root, rootRoots) {
    var signals = [];
    var seen = new Set();
    function addSignal(signal) {
      if (!signal || seen.has(signal)) {
        return;
      }
      seen.add(signal);
      signals.push(signal);
    }
    var baseRoot = root || document.body || document.documentElement;
    if (!baseRoot) {
      return signals;
    }
    var authField = baseRoot.querySelector("input[type=\"password\"],input[type=\"email\"]");
    if (authField) {
      addSignal(ObservationSignal.PAYWALL_OR_LOGIN);
    }
    var overlay = findOverlayCandidate(baseRoot, rootRoots);
    if (overlay) {
      addSignal(ObservationSignal.OVERLAY_BLOCKING);
    }
    var overlayText = overlay ? extractSignalText(overlay, 900) : "";
    var searchText = overlayText;
    if (!searchText) {
      searchText = extractCleanText(baseRoot, 900);
    }
    if (!searchText && document.body && document.body.textContent) {
      searchText = utils.budgetText(utils.normalizeWhitespace(document.body.textContent), 900);
    }
    var gateElement = baseRoot.querySelector("[data-paywall],[class*=\"paywall\"],[id*=\"paywall\"],[class*=\"gateway\"],[id*=\"gateway\"]");
    if (gateElement) {
      addSignal(ObservationSignal.PAYWALL_OR_LOGIN);
    }
    var lower = searchText.toLowerCase();
    if (!lower) {
      return signals;
    }
    var paywallHit =
      containsAnyKeyword(lower, PAYWALL_KEYWORDS_STRONG) ||
      (!!overlay && containsAnyKeyword(lower, PAYWALL_KEYWORDS_WEAK));
    if (paywallHit) {
      addSignal(ObservationSignal.PAYWALL_OR_LOGIN);
    }
    var authHit =
      containsAnyKeyword(lower, AUTH_GATE_KEYWORDS_STRONG) ||
      (!!overlay && containsAnyKeyword(lower, AUTH_GATE_KEYWORDS_WEAK));
    if (authHit) {
      addSignal(ObservationSignal.PAYWALL_OR_LOGIN);
    }
    var consentHit = containsAnyKeyword(lower, CONSENT_KEYWORDS);
    if (consentHit && overlay) {
      addSignal(ObservationSignal.CONSENT_MODAL);
    }
    if (containsAnyKeyword(lower, AGE_GATE_KEYWORDS)) {
      addSignal(ObservationSignal.AGE_GATE);
    }
    if (containsAnyKeyword(lower, GEO_BLOCK_KEYWORDS)) {
      addSignal(ObservationSignal.GEO_BLOCK);
    }
    if (containsAnyKeyword(lower, SCRIPT_BLOCK_KEYWORDS)) {
      addSignal(ObservationSignal.SCRIPT_REQUIRED);
    }
    if (containsAnyKeyword(lower, ROBOT_CHECK_KEYWORDS)) {
      addSignal(ObservationSignal.CAPTCHA_OR_ROBOT_CHECK);
    }
    return signals;
  }

  function hasNonTextContent(root) {
    var base = root || document;
    if (!base || !base.querySelector) {
      return false;
    }
    return !!base.querySelector("canvas,video,svg,img");
  }

  function isPdfViewerDocument() {
    var contentType = document.contentType || "";
    if (contentType && contentType.toLowerCase().indexOf("pdf") >= 0) {
      return true;
    }
    if (document.querySelector("embed[type=\"application/pdf\"],object[type=\"application/pdf\"]")) {
      return true;
    }
    return false;
  }

  function isLikelyVirtualizedList(node) {
    if (!node || !node.getAttribute) {
      return false;
    }
    var className = typeof node.className === "string" ? node.className.toLowerCase() : "";
    if (className.indexOf("virtual") >= 0 || className.indexOf("infinite") >= 0) {
      return true;
    }
    if (node.getAttribute("data-virtualized") === "true") {
      return true;
    }
    if (node.getAttribute("aria-rowcount")) {
      return true;
    }
    return false;
  }

  function isInfiniteScrollContainer(node) {
    if (!node || !node.scrollHeight || !node.clientHeight) {
      return false;
    }
    return node.scrollHeight > node.clientHeight * 3;
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

  function collectVisibleText(root, maxChars, roots) {
    if (!root) {
      return "";
    }
    var visibilityCache = new WeakMap();
    var noiseCache = new WeakMap();
    var containerCache = new WeakMap();
    function isNodeVisible(node) {
      if (!node || !node.parentElement) {
        return false;
      }
      var parent = node.parentElement;
      if (visibilityCache.has(parent)) {
        return visibilityCache.get(parent);
      }
      var visible = isTextContainerVisible(parent);
      if (!visible) {
        try {
          var range = document.createRange();
          range.selectNodeContents(node);
          var rects = range.getClientRects();
          visible = !!(rects && rects.length > 0);
        } catch (error) {
          visible = false;
        }
      }
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

    var rootList = roots || collectRoots(root);
    var entries = [];
    var entryMap = new WeakMap();
    var order = 0;
    function containerForNode(node) {
      var parent = node.parentElement;
      if (!parent) {
        return null;
      }
      if (containerCache.has(parent)) {
        return containerCache.get(parent);
      }
      var container = getTextContainer(parent);
      containerCache.set(parent, container);
      return container;
    }
    for (var r = 0; r < rootList.length; r += 1) {
      var walker = document.createTreeWalker(rootList[r], NodeFilter.SHOW_TEXT, null);
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
        var text = normalizeInlineText(node.nodeValue);
        if (!text) {
          continue;
        }
        var container = containerForNode(node);
        if (!container) {
          continue;
        }
        var entry = entryMap.get(container);
        if (!entry) {
          order += 1;
          entry = { order: order, element: container, parts: [] };
          entryMap.set(container, entry);
          entries.push(entry);
        }
        entry.parts.push(text);
      }
    }
    entries.sort(function (a, b) {
      return a.order - b.order;
    });
    var lines = [];
    var total = 0;
    var limit = typeof maxChars === "number" && maxChars > 0 ? maxChars : 0;
    for (var i = 0; i < entries.length; i += 1) {
      var lineText = normalizeInlineText(entries[i].parts.join(" "));
      if (!lineText) {
        continue;
      }
      var line = formatStructuredLine(entries[i].element, lineText);
      if (!line) {
        continue;
      }
      if (limit && total >= limit) {
        break;
      }
      if (limit) {
        var newlineCost = lines.length > 0 ? 1 : 0;
        var remaining = limit - total - newlineCost;
        if (remaining <= 0) {
          break;
        }
        if (line.length > remaining) {
          line = line.slice(0, remaining);
        }
      }
      lines.push(line);
      total += line.length + (lines.length > 1 ? 1 : 0);
    }
    return lines.join("\n");
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
    if (tagName === "address") {
      return false;
    }
    if (tagName === "form") {
      if (!hasContentAncestor(element) || formIsLikelyChrome(element)) {
        return false;
      }
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

  function selectBlockWindow(orderedBlocks, maxBlocks, primaryOrder) {
    if (!orderedBlocks || orderedBlocks.length === 0) {
      return [];
    }
    if (orderedBlocks.length <= maxBlocks) {
      return orderedBlocks.slice();
    }
    var primaryIndex = orderedBlocks.findIndex(function (block) {
      return block.order === primaryOrder;
    });
    if (primaryIndex < 0) {
      primaryIndex = 0;
    }
    var tailCount = Math.min(4, Math.max(2, Math.floor(maxBlocks / 4)));
    if (orderedBlocks.length <= maxBlocks + tailCount) {
      tailCount = Math.max(0, orderedBlocks.length - maxBlocks);
    }
    var windowCount = maxBlocks - tailCount;
    if (windowCount <= 0) {
      windowCount = maxBlocks;
      tailCount = 0;
    }
    var windowStart = Math.max(0, primaryIndex - Math.floor(windowCount / 3));
    var windowEnd = Math.min(orderedBlocks.length, windowStart + windowCount);
    if (windowEnd - windowStart < windowCount) {
      windowStart = Math.max(0, windowEnd - windowCount);
    }
    var selected = [];
    var seen = new Set();
    function pushBlock(block) {
      if (!block) {
        return;
      }
      if (seen.has(block.order)) {
        return;
      }
      seen.add(block.order);
      selected.push(block);
    }
    for (var i = windowStart; i < windowEnd; i += 1) {
      pushBlock(orderedBlocks[i]);
    }
    if (tailCount > 0) {
      var tailStart = Math.max(windowEnd, orderedBlocks.length - tailCount);
      for (var j = tailStart; j < orderedBlocks.length; j += 1) {
        pushBlock(orderedBlocks[j]);
      }
    }
    selected.sort(function (a, b) {
      return a.order - b.order;
    });
    if (selected.length > maxBlocks) {
      return selected.slice(0, maxBlocks);
    }
    return selected;
  }

  function pruneContentRootCandidates(candidates, maxCandidates) {
    if (!candidates || candidates.length <= maxCandidates) {
      return candidates || [];
    }
    var scored = [];
    for (var i = 0; i < candidates.length; i += 1) {
      var candidate = candidates[i];
      if (!candidate) {
        continue;
      }
      var length = (candidate.textContent || "").length;
      if (length < 160) {
        continue;
      }
      scored.push({ element: candidate, length: length });
    }
    scored.sort(function (a, b) {
      return b.length - a.length;
    });
    return scored.slice(0, maxCandidates).map(function (item) {
      return item.element;
    });
  }

  function selectListRoot(root, roots, debugInfo) {
    if (!root || !root.querySelectorAll) {
      return null;
    }
    var candidates = querySelectorAllDeep(root, "table, ul, ol", roots);
    var candidateCount = candidates.length;
    if (candidates.length > 240) {
      candidates = candidates.slice(0, 240);
    }
    var best = null;
    var bestScore = 0;
    var bestItemCount = 0;
    candidates.forEach(function (candidate) {
      if (!candidate || !candidate.tagName) {
        return;
      }
      if (!isTextContainerVisible(candidate) || hasEditableAncestor(candidate)) {
        return;
      }
      if (isNoiseContainer(candidate)) {
        return;
      }
      var tag = candidate.tagName.toLowerCase();
      var itemSelector = tag === "table" ? "tr" : "li";
      var items = candidate.querySelectorAll(itemSelector);
      if (!items || items.length < 6) {
        return;
      }
      var withAnchors = 0;
      for (var i = 0; i < items.length && i < 80; i += 1) {
        if (items[i].querySelector && items[i].querySelector("a")) {
          withAnchors += 1;
        }
      }
      if (withAnchors < 6) {
        return;
      }
      var anchorCount = candidate.querySelectorAll("a").length;
      var textLength = (candidate.textContent || "").length;
      var score = withAnchors * 6 + Math.min(anchorCount, 200) + Math.min(Math.floor(textLength / 30), 200);
      if (score > bestScore) {
        bestScore = score;
        best = candidate;
        bestItemCount = items.length;
      }
    });
    if (debugInfo) {
      debugInfo.listRoot = {
        candidateCount: candidateCount,
        sampledCount: candidates.length,
        selected: debugElementInfo(best),
        bestScore: Math.round(bestScore),
        itemCount: bestItemCount
      };
    }
    if (!best || bestScore <= 0) {
      return null;
    }
    return best;
  }

  function detectSearchEngine() {
    try {
      var parsed = new URL(window.location.href);
      var host = (parsed.hostname || "").toLowerCase();
      var path = parsed.pathname || "";
      if (host.indexOf("duckduckgo.com") >= 0 && parsed.searchParams && parsed.searchParams.get("q")) {
        return "duckduckgo";
      }
      if (host.indexOf("bing.com") >= 0 && path === "/search" && parsed.searchParams && parsed.searchParams.get("q")) {
        return "bing";
      }
      if (host.indexOf("google.") >= 0 && path === "/search" && parsed.searchParams && parsed.searchParams.get("q")) {
        return "google";
      }
    } catch (error) {
    }
    return null;
  }

  function selectDuckDuckGoResultsRoot(root) {
    if (!root || !root.querySelectorAll) {
      return null;
    }
    var articles = root.querySelectorAll('article[id^="r1-"]');
    if (!articles || articles.length < 4) {
      return null;
    }
    var targetCount = Math.min(articles.length, 6);
    var candidate = articles[0].parentElement;
    while (candidate && candidate !== root && candidate !== document.body && candidate !== document.documentElement) {
      try {
        var count = candidate.querySelectorAll ? candidate.querySelectorAll('article[id^="r1-"]').length : 0;
        if (count >= targetCount) {
          return candidate;
        }
      } catch (error) {
      }
      candidate = candidate.parentElement;
    }
    return root;
  }

  function selectSearchRoot(root, roots, debugInfo) {
    var engine = detectSearchEngine();
    if (!engine) {
      return null;
    }
    var selected = null;
    if (engine === "duckduckgo") {
      selected = selectDuckDuckGoResultsRoot(root);
    }
    if (debugInfo) {
      debugInfo.searchRoot = {
        engine: engine,
        selected: debugElementInfo(selected)
      };
    }
    return selected;
  }

  function collectTextBlocks(root, maxBlocks, maxPrimaryChars, roots) {
    if (!root) {
      return { blocks: [], primary: null };
    }
    var blockTextLimit = 420;
    var selectors = "article,main,section,h1,h2,h3,h4,h5,h6,p,li,td,th,dt,dd,div,blockquote,pre,code,summary,caption,figcaption";
    var nodes = querySelectorAllDeep(root, selectors, roots);
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
      var rawText = normalizeStructuredText(element.innerText);
      var minLength = minBlockLength(tagName);
      if (!rawText || (rawText.length < minLength && !isMeaningfulShortText(rawText))) {
        return;
      }
      if (rawText.length > 120) {
        var cleanedText = extractCleanText(element, 1800, { preserveLines: true });
        if (cleanedText && cleanedText.length >= minLength) {
          rawText = cleanedText;
        }
      }
      if (rawText.length > 1200 && (tagName === "div" || tagName === "section")) {
        if (hasBlockChild(element)) {
          return;
        }
      }
      var stats = linkStatsForElement(element, rawText.length);
      if (stats.density > 0.6 && rawText.length < 200) {
        return;
      }
      var text = budgetStructuredText(rawText, blockTextLimit);
      text = formatBlockText(element, text);
      var key = rawText.toLowerCase();
      if (key.length > 600) {
        key = key.slice(0, 600);
      }
      if (seen.has(key)) {
        return;
      }
      seen.add(key);
      var tag = tagName;
      var role = element.getAttribute("role") || "";
      var handleId = ensureHandle(element);
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
      text: budgetStructuredText(primaryCandidate.rawText, maxPrimaryChars),
      linkCount: primaryCandidate.linkCount,
      linkDensity: primaryCandidate.linkDensity,
      handleId: primaryCandidate.handleId
    };
    var trimmed = selectBlockWindow(orderedBlocks, maxBlocks, primaryCandidate.order);
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

  function collectOutline(root, maxItems, maxChars, roots) {
    if (!root) {
      return [];
    }
    var selectors = "h1,h2,h3,h4,h5,h6,li,dt,dd,summary,caption";
    var nodes = querySelectorAllDeep(root, selectors, roots);
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

  function collectItems(root, maxItems, maxChars, roots) {
    if (!root) {
      return [];
    }
    var selectors = "article,li,section,div,tr,td,dt,dd";
    var nodes = querySelectorAllDeep(root, selectors, roots);
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

    function isUserProfileUrl(url) {
      var href = String(url || "").toLowerCase();
      if (!href) {
        return false;
      }
      if (href.indexOf("user?id=") >= 0) {
        return true;
      }
      if (href.indexOf("/user/") >= 0 || href.indexOf("/users/") >= 0) {
        return true;
      }
      if (href.indexOf("profile") >= 0 && href.indexOf("user") >= 0) {
        return true;
      }
      return false;
    }

    function isMetaHeavyText(text) {
      var lower = String(text || "").toLowerCase();
      if (!lower) {
        return false;
      }
      var hints = [
        "point",
        "comment",
        "reply",
        "replie",
        "ago",
        "hour",
        "day",
        "min",
        "by ",
        "hide",
        "favorite",
        "past",
        "flag",
        "save"
      ];
      var hits = 0;
      for (var i = 0; i < hints.length; i += 1) {
        if (lower.indexOf(hints[i]) >= 0) {
          hits += 1;
        }
      }
      return hits >= 2 || (hits >= 1 && lower.length < 120);
    }

    function hasLongAnchor(anchorLengths, minLength) {
      for (var i = 0; i < anchorLengths.length; i += 1) {
        if (anchorLengths[i] >= minLength) {
          return true;
        }
      }
      return false;
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
      var tagName = element.tagName ? element.tagName.toLowerCase() : "";
      if ((tagName === "td" || tagName === "th") && element.closest) {
        var row = element.closest("tr");
        if (row && row !== element && isBlockCandidate(row)) {
          return;
        }
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
        var cleanedCandidate = extractCleanText(element, maxChars * 2, { preserveLines: false });
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
              handleId: ensureHandle(anchors[i])
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
        if (sibling) {
          var siblingText = utils.normalizeWhitespace(sibling.innerText);
          var siblingAnchors = sibling.querySelectorAll ? sibling.querySelectorAll("a") : null;
          var siblingHasComment = false;
          var hasStrongSibling = false;
          if (siblingAnchors && siblingAnchors.length > 0) {
            for (var j = 0; j < siblingAnchors.length; j += 1) {
              var siblingTextLabel = utils.normalizeWhitespace(siblingAnchors[j].innerText);
              if (!siblingTextLabel) {
                continue;
              }
              var siblingUrl = getHref(siblingAnchors[j]);
              if (isCommentLinkCandidate(siblingTextLabel, siblingUrl)) {
                siblingHasComment = true;
              }
              if (siblingTextLabel.length >= 18 || siblingTextLabel.length >= bestTextLength + 6) {
                hasStrongSibling = true;
              }
            }
          }
          if (siblingText && siblingText.length <= 240 && (isBlockCandidate(sibling) || siblingHasComment)) {
            if (!hasStrongSibling || siblingHasComment) {
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
                    handleId: ensureHandle(siblingAnchors[k])
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
      var hasLongTitleAnchor = hasLongAnchor(anchorLengths, 18);
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
      if (!hasLongTitleAnchor && isMetaHeavyText(cleanedText)) {
        if (isUserProfileUrl(url) || isCommentLinkCandidate(title, url) || looksLikeTimeLabel(title)) {
          return;
        }
      }
      var bestHost = hostForURL(url);
      var isExternal = !!(bestHost && originHost && bestHost !== originHost);
      if (bestHost && originHost && bestHost === originHost) {
        if (bestTextLength <= 12 && textLength <= 80 && linkCandidates.length >= 2) {
          return;
        }
      }
      if (textLength < 30 && bestTextLength < 18) {
        return;
      }
      var anchorShare = textLength > 0 ? bestTextLength / textLength : 0;
      if (textLength >= 120 && anchorShare < 0.12 && !isExternal) {
        return;
      }
      if (bestTextLength <= 12 && textLength >= 60 && anchorShare < 0.2 && linkCandidates.length >= 3 && !isExternal) {
        return;
      }
      if (strongAnchorCount >= 2 && textLength < 500) {
        return;
      }
      if (stats.density > 0.7 && cleanedText.length < 200 && anchorShare < 0.5 && !isExternal) {
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
        handleId: ensureHandle(bestAnchor),
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

  function pickContentRoot(root, roots, debugInfo) {
    if (!root || !root.querySelectorAll) {
      return null;
    }
    var candidates = querySelectorAllDeep(root, CONTENT_ROOT_SELECTORS, roots);
    if (candidates.length === 0) {
      candidates = querySelectorAllDeep(root, "article,main,section,div", roots);
    }
    if (candidates.length === 0) {
      if (debugInfo) {
        debugInfo.contentRoot = { candidateCount: 0, prunedCount: 0, selected: null };
      }
      return null;
    }
    var candidateCount = candidates.length;
    candidates = pruneContentRootCandidates(candidates, 320);
    var prunedCount = candidates.length;
    var bodyText = normalizeStructuredText(root.innerText || "");
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
      var quickLength = (candidate.textContent || "").length;
      if (quickLength < 160) {
        return;
      }
      var text = normalizeStructuredText(candidate.innerText || "");
      if (!text || text.length < 240) {
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
      if (debugInfo) {
        debugInfo.contentRoot = {
          candidateCount: candidateCount,
          prunedCount: prunedCount,
          selected: null,
          bodyLength: bodyLength
        };
      }
      return null;
    }
    if (bodyLength > 0) {
      var ratio = bestLength / bodyLength;
      if (bestLength < 400 && ratio < 0.18) {
        if (debugInfo) {
          debugInfo.contentRoot = {
            candidateCount: candidateCount,
            prunedCount: prunedCount,
            selected: null,
            bodyLength: bodyLength
          };
        }
        return null;
      }
    }
    if (debugInfo) {
      debugInfo.contentRoot = {
        candidateCount: candidateCount,
        prunedCount: prunedCount,
        selected: debugElementInfo(best),
        bestScore: Math.round(bestScore),
        bestLength: bestLength,
        bodyLength: bodyLength
      };
    }
    return best;
  }

  function hasCommentLabel(element) {
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
    return false;
  }

  function hasCommentHint(element) {
    if (!element) {
      return false;
    }
    if (hasCommentLabel(element)) {
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
      if (isNestedCommentThread(nestedLists[j])) {
        nestedLists[j].remove();
      }
    }
    var text = normalizeStructuredText(clone.innerText || "");
    if (maxChars) {
      text = budgetStructuredText(text, maxChars);
    }
    return text;
  }

  function isNestedCommentThread(list) {
    if (!list) {
      return false;
    }
    if (hasCommentHint(list)) {
      return true;
    }
    var items = list.querySelectorAll("li");
    if (!items || items.length === 0) {
      return false;
    }
    var commentLike = 0;
    for (var i = 0; i < items.length && i < 4; i += 1) {
      if (hasCommentHint(items[i])) {
        commentLike += 1;
      }
    }
    return commentLike >= 2;
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

  function resolveCommentContainer(node) {
    if (!node) {
      return null;
    }
    if (!node.closest) {
      return node;
    }
    var labeled = node.closest(COMMENT_SELECTORS);
    if (labeled) {
      var labeledTag = labeled.tagName ? labeled.tagName.toLowerCase() : "";
      if (INLINE_COMMENT_TAGS.has(labeledTag)) {
        var labeledParent = labeled.closest("article,li,section,td,tr,div");
        if (labeledParent && isBlockCandidate(labeledParent)) {
          return labeledParent;
        }
      } else if (isBlockCandidate(labeled)) {
        return labeled;
      }
    }
    var structural = node.closest("article,li,section,td,tr");
    if (structural && isBlockCandidate(structural)) {
      return structural;
    }
    var fallback = node.closest("div");
    if (fallback && isBlockCandidate(fallback)) {
      if (hasCommentLabel(fallback) || hasCommentMetadata(fallback) || hasCommentTextHint(fallback)) {
        return fallback;
      }
      var parent = fallback.parentElement;
      if (parent && isBlockCandidate(parent)) {
        return parent;
      }
      return fallback;
    }
    if (isBlockCandidate(node)) {
      return node;
    }
    return null;
  }

  function collectCommentCandidates(root, roots, maxCandidates) {
    if (!root || !root.querySelectorAll) {
      return [];
    }
    var nodes = querySelectorAllDeep(root, COMMENT_SELECTORS, roots);
    var candidates = [];
    var seen = new Set();
    if (maxCandidates && nodes.length > maxCandidates) {
      nodes = nodes.slice(0, maxCandidates);
    }
    nodes.forEach(function (node) {
      if (!node) {
        return;
      }
      var container = resolveCommentContainer(node);
      if (!container) {
        return;
      }
      if (seen.has(container)) {
        return;
      }
      seen.add(container);
      candidates.push(container);
    });
    if (candidates.length >= 3) {
      return candidates;
    }
    var fallbackNodes = querySelectorAllDeep(root, "article,li,div,section,tr", roots);
    for (var i = 0; i < fallbackNodes.length; i += 1) {
      if (maxCandidates && candidates.length >= maxCandidates) {
        break;
      }
      var fallback = fallbackNodes[i];
      if (!hasCommentHint(fallback)) {
        continue;
      }
      var fallbackContainer = resolveCommentContainer(fallback);
      if (!fallbackContainer) {
        continue;
      }
      if (seen.has(fallbackContainer)) {
        continue;
      }
      seen.add(fallbackContainer);
      candidates.push(fallbackContainer);
    }
    return candidates;
  }

  function pickCommentRoot(root, roots, debugInfo) {
    if (!root || !root.querySelectorAll) {
      return null;
    }
    var candidates = collectCommentCandidates(root, roots, 240);
    var candidateCount = candidates.length;
    if (candidateCount < 3) {
      if (debugInfo) {
        debugInfo.commentRoot = { candidateCount: candidateCount, sampledCount: 0, selected: null };
      }
      return null;
    }
    var sampleLimit = 80;
    var sample = candidates.length > sampleLimit ? candidates.slice(0, sampleLimit) : candidates;
    var scale = candidates.length > sample.length ? candidates.length / sample.length : 1;
    var stats = new Map();
    var textCache = new Map();

    function cachedTextLength(element) {
      if (!element) {
        return 0;
      }
      var cached = textCache.get(element);
      if (typeof cached === "number") {
        return cached;
      }
      var length = (element.textContent || "").length;
      if (length > 120000) {
        length = 120000;
      }
      textCache.set(element, length);
      return length;
    }

    sample.forEach(function (container) {
      var commentLength = cachedTextLength(container);
      if (commentLength < 20) {
        return;
      }
      var current = container;
      var depth = 0;
      while (current && current !== root && depth < 10) {
        if (!isBlockCandidate(current)) {
          current = current.parentElement;
          depth += 1;
          continue;
        }
        var entry = stats.get(current);
        if (!entry) {
          entry = { element: current, commentCount: 0, commentChars: 0, minDepth: depth };
          stats.set(current, entry);
        }
        entry.commentCount += 1;
        entry.commentChars += commentLength;
        if (depth < entry.minDepth) {
          entry.minDepth = depth;
        }
        current = current.parentElement;
        depth += 1;
      }
    });

    var minCount = Math.max(3, Math.min(6, Math.round(candidateCount * 0.25)));
    var best = null;
    var bestScore = 0;
    var bestCount = 0;
    var bestDensity = 0;
    stats.forEach(function (entry) {
      var estimatedCount = Math.round(entry.commentCount * scale);
      if (estimatedCount < minCount) {
        return;
      }
      var textLength = cachedTextLength(entry.element);
      if (textLength < 200) {
        return;
      }
      var density = (estimatedCount * 160) / Math.max(textLength, 160);
      if (density < 0.18) {
        return;
      }
      var score = estimatedCount * 18;
      score += Math.min((entry.commentChars * scale) / 120, 200);
      score += density * 120;
      score -= Math.min(entry.minDepth * 2, 12);
      if (entry.element === document.body || entry.element === document.documentElement) {
        score -= 40;
      }
      if (isNoiseContainer(entry.element)) {
        score -= 30;
      }
      if (score > bestScore) {
        bestScore = score;
        best = entry.element;
        bestCount = estimatedCount;
        bestDensity = density;
      }
    });
    if (debugInfo) {
      debugInfo.commentRoot = {
        candidateCount: candidateCount,
        sampledCount: sample.length,
        minCount: minCount,
        selected: debugElementInfo(best),
        bestScore: Math.round(bestScore),
        estimatedCount: bestCount,
        density: roundDensity(bestDensity)
      };
    }
    if (!best || bestScore <= 0) {
      return null;
    }
    return best;
  }

  function collectComments(root, maxComments, maxChars, roots) {
    if (!root || maxComments <= 0) {
      return [];
    }
    var nodes = querySelectorAllDeep(root, COMMENT_SELECTORS, roots);
    if (nodes.length < 3) {
      var fallbackNodes = querySelectorAllDeep(root, "article,li,div,section,tr", roots);
      for (var i = 0; i < fallbackNodes.length; i += 1) {
        if (hasCommentHint(fallbackNodes[i])) {
          nodes.push(fallbackNodes[i]);
        }
      }
      if (nodes.length < 3) {
        var lists = querySelectorAllDeep(root, "ol, ul", roots);
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
      var container = resolveCommentContainer(node);
      if (!container) {
        continue;
      }
      var text = extractCommentText(container, maxChars);
      if (!text || text.length < 20) {
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
        author = null;
      }
      if (!author && container.parentElement) {
        var parentAuthor = findMetaText(container.parentElement, [
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
        if (isLikelyAuthorLabel(parentAuthor)) {
          author = parentAuthor;
        }
      }
      var age = findMetaText(container, [
        "time",
        "[datetime]",
        "[data-time]",
        ".age",
        ".time",
        ".timestamp"
      ], 80);
      if (!age && container.parentElement) {
        age = findMetaText(container.parentElement, [
          "time",
          "[datetime]",
          "[data-time]",
          ".age",
          ".time",
          ".timestamp"
        ], 80);
      }
      var score = null;
      var scoreElement = container.querySelector("[data-score],[data-vote-count],.score,.points,.likes,.upvotes");
      if (!scoreElement && container.parentElement) {
        scoreElement = container.parentElement.querySelector("[data-score],[data-vote-count],.score,.points,.likes,.upvotes");
      }
      if (scoreElement) {
        var scoreText = utils.normalizeWhitespace(scoreElement.innerText || scoreElement.getAttribute("data-score") || "");
        if (!scoreText) {
          scoreText = utils.normalizeWhitespace(scoreElement.getAttribute("data-vote-count") || "");
        }
        score = scoreText || null;
      }
      if (!author) {
        author = null;
      }
      if (!age) {
        age = null;
      }
      comments.push({
        text: text,
        author: author,
        age: age,
        score: score,
        depth: extractCommentDepth(container),
        handleId: ensureHandle(container)
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
    var debugEnabled = !!(options && options.debug);
    var debugInfo = debugEnabled
      ? { timings: {}, counts: {}, root: null, textRoot: null, contentRoot: null, listRoot: null, commentRoot: null, signals: [] }
      : null;
    var localUrlRedaction = { count: 0 };
    urlRedactionCounter = localUrlRedaction;
    var totalStart = debugEnabled ? nowMs() : 0;
    var root = document.body;
    if (options && options.rootHandleId) {
      var target = findElement(options.rootHandleId);
      if (target) {
        root = target;
      }
    }
    if (debugInfo) {
      debugInfo.root = debugElementInfo(root);
      debugInfo.pageState = {
        readyState: document.readyState || "",
        visibility: document.visibilityState || "",
        bodyChildCount: document.body ? document.body.childElementCount : 0,
        bodyTextLength: document.body && document.body.textContent ? document.body.textContent.length : 0
      };
    }
    ensureDocumentId();
    var rootsStart = debugEnabled ? nowMs() : 0;
    var signalState = { crossOriginIframe: false, closedShadowRoot: false };
    var rootRoots = collectRoots(root || document, signalState);
    if (debugInfo) {
      debugInfo.timings.collectRootsMs = Math.round(nowMs() - rootsStart);
      debugInfo.counts.rootCount = rootRoots.length;
    }
    var signalsStart = debugEnabled ? nowMs() : 0;
    var signals = collectAccessSignals(root, rootRoots);
    if (signalState.crossOriginIframe) {
      signals.push(ObservationSignal.CROSS_ORIGIN_IFRAME);
    }
    if (signalState.closedShadowRoot) {
      signals.push(ObservationSignal.CLOSED_SHADOW_ROOT);
    }
    if (debugInfo) {
      debugInfo.timings.collectSignalsMs = Math.round(nowMs() - signalsStart);
      debugInfo.signals = signals;
    }
    var textRoot = root;
    var searchRoot = null;
    var listRoot = null;
    var contentRoot = null;
    if (!options || !options.rootHandleId) {
      searchRoot = selectSearchRoot(root, rootRoots, debugInfo);
      if (searchRoot) {
        textRoot = searchRoot;
      } else {
        var contentStart = debugEnabled ? nowMs() : 0;
        contentRoot = pickContentRoot(root, rootRoots, debugInfo);
        if (debugInfo) {
          debugInfo.timings.pickContentRootMs = Math.round(nowMs() - contentStart);
        }
        if (!contentRoot) {
          listRoot = selectListRoot(root, rootRoots, debugInfo);
          if (listRoot) {
            contentRoot = listRoot;
          }
        }
        var shouldCheckCommentRoot = !contentRoot || hasCommentLabel(contentRoot);
        if (!shouldCheckCommentRoot && contentRoot) {
          var contentLength = (contentRoot.textContent || "").length;
          if (contentLength > 0 && contentLength < 4000) {
            var rootLength = (root.textContent || "").length;
            var share = rootLength > 0 ? contentLength / rootLength : 1;
            if (share < 0.2) {
              shouldCheckCommentRoot = true;
            }
          }
        }
        if (shouldCheckCommentRoot && !listRoot) {
          var commentStart = debugEnabled ? nowMs() : 0;
          var commentRoot = pickCommentRoot(root, rootRoots, debugInfo);
          if (debugInfo) {
            debugInfo.timings.pickCommentRootMs = Math.round(nowMs() - commentStart);
          }
          if (commentRoot) {
            contentRoot = commentRoot;
          }
        }
        if (contentRoot) {
          textRoot = contentRoot;
        }
      }
    }
    if (debugInfo) {
      debugInfo.textRoot = debugElementInfo(textRoot);
    }
    var textRootStart = debugEnabled ? nowMs() : 0;
    var textRoots = textRoot === root ? rootRoots : collectRoots(textRoot);
    if (debugInfo) {
      debugInfo.timings.collectTextRootsMs = Math.round(nowMs() - textRootStart);
      debugInfo.counts.textRootCount = textRoots.length;
    }
    var elementsStart = debugEnabled ? nowMs() : 0;
    var elements = querySelectorAllDeep(root || document, "a, button, input, textarea, select", rootRoots);
    var projected = elements
      .map(function (element) {
        var boundingBox = getBoundingBox(element);
        if (!boundingBox || boundingBox.width <= 0 || boundingBox.height <= 0) {
          return null;
        }
        var handleId = ensureHandle(element);
        return {
          handleId: handleId,
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
    if (debugInfo) {
      debugInfo.timings.collectElementsMs = Math.round(nowMs() - elementsStart);
      debugInfo.counts.elementCount = limited.length;
    }

    var textStart = debugEnabled ? nowMs() : 0;
    var text = collectVisibleText(textRoot, maxChars, textRoots);
    if (debugInfo) {
      debugInfo.timings.collectTextMs = Math.round(nowMs() - textStart);
      debugInfo.counts.textChars = text.length;
    }
    var blocksStart = debugEnabled ? nowMs() : 0;
    var blockResult = collectTextBlocks(textRoot, maxBlocks, maxPrimaryChars, textRoots);
    var blocks = blockResult.blocks;
    var primary = blockResult.primary;
    if (debugInfo) {
      debugInfo.timings.collectBlocksMs = Math.round(nowMs() - blocksStart);
      debugInfo.counts.blockCount = blocks.length;
      debugInfo.counts.primaryChars = primary && primary.text ? primary.text.length : 0;
    }
    var outlineStart = debugEnabled ? nowMs() : 0;
    var outline = collectOutline(textRoot, maxOutline, maxOutlineChars, textRoots);
    if (debugInfo) {
      debugInfo.timings.collectOutlineMs = Math.round(nowMs() - outlineStart);
      debugInfo.counts.outlineCount = outline.length;
    }
    var itemsStart = debugEnabled ? nowMs() : 0;
    var items = collectItems(textRoot, maxItems, maxItemChars, textRoots);
    if (debugInfo) {
      debugInfo.timings.collectItemsMs = Math.round(nowMs() - itemsStart);
      debugInfo.counts.itemCount = items.length;
    }
    var commentsStart = debugEnabled ? nowMs() : 0;
    var comments = [];
    if (!searchRoot) {
      comments = collectComments(root, maxComments, maxCommentChars, rootRoots);
    }
    if (debugInfo) {
      debugInfo.timings.collectCommentsMs = Math.round(nowMs() - commentsStart);
      debugInfo.counts.commentCount = comments.length;
      debugInfo.timings.totalMs = Math.round(nowMs() - totalStart);
    }
    var pageUrl = sanitizeURLString(window.location.href);
    var signalSet = new Set(signals);
    if (localUrlRedaction.count > 0) {
      signalSet.add(ObservationSignal.URL_REDACTED);
      if (debugInfo) {
        debugInfo.counts.urlRedacted = localUrlRedaction.count;
      }
    }
    if (text.length < 180) {
      signalSet.add(ObservationSignal.SPARSE_TEXT);
    }
    if (text.length < 80 && hasNonTextContent(root)) {
      signalSet.add(ObservationSignal.NON_TEXT_CONTENT);
    }
    if (isPdfViewerDocument()) {
      signalSet.add(ObservationSignal.PDF_VIEWER);
    }
    if (listRoot && isLikelyVirtualizedList(listRoot)) {
      signalSet.add(ObservationSignal.VIRTUALIZED_LIST);
    }
    if (listRoot && isInfiniteScrollContainer(listRoot)) {
      signalSet.add(ObservationSignal.INFINITE_SCROLL);
    }
    signals = Array.from(signalSet);
    urlRedactionCounter = null;
    lastObservedDocumentId = documentId || null;
    lastObservedGeneration = navGeneration;
    return {
      url: pageUrl,
      title: document.title || "",
      documentId: documentId || "",
      navigationGeneration: navGeneration,
      observedAtMs: Date.now(),
      text: text,
      elements: limited,
      blocks: blocks,
      items: items,
      outline: outline,
      primary: primary,
      comments: comments,
      signals: signals,
      debug: debugInfo
    };
  }

  function observeDomWithStatus(options) {
    if (options && options.rootHandleId) {
      var resolved = resolveHandle(options.rootHandleId);
      if (resolved.error) {
        return { status: "error", error: resolved.error };
      }
    }
    return { status: "ok", observation: observeDom(options || {}) };
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

  function resolveHandle(handleId) {
    if (!handleId) {
      return { element: null, error: ToolErrorCode.INVALID_ARGUMENTS };
    }
    var cached = handleMap.get(handleId);
    if (cached) {
      var cachedElement = cached.element || cached;
      if (cached.documentId && cached.documentId !== documentId) {
        return { element: null, error: ToolErrorCode.STALE_HANDLE };
      }
      if (typeof cached.generation === "number" && cached.generation !== navGeneration) {
        return { element: null, error: ToolErrorCode.STALE_HANDLE };
      }
      if (!cachedElement || !cachedElement.isConnected) {
        return { element: null, error: ToolErrorCode.NOT_FOUND };
      }
      return { element: cachedElement };
    }
    var found = document.querySelector('[data-laika-handle="' + handleId + '"]');
    if (!found) {
      if (lastObservedDocumentId && lastObservedDocumentId !== documentId) {
        return { element: null, error: ToolErrorCode.STALE_HANDLE };
      }
      if (typeof lastObservedGeneration === "number" && lastObservedGeneration !== navGeneration) {
        return { element: null, error: ToolErrorCode.STALE_HANDLE };
      }
      return { element: null, error: ToolErrorCode.NOT_FOUND };
    }
    handleMap.set(handleId, { element: found, generation: navGeneration, documentId: ensureDocumentId() });
    return { element: found };
  }

  function findElement(handleId) {
    var resolved = resolveHandle(handleId);
    return resolved.element || null;
  }

  function isElementDisabled(element) {
    if (!element) {
      return false;
    }
    if (element.disabled || element.getAttribute("disabled") !== null) {
      return true;
    }
    var ariaDisabled = element.getAttribute("aria-disabled");
    if (ariaDisabled && ariaDisabled.toLowerCase() === "true") {
      return true;
    }
    return false;
  }

  function isElementVisible(element) {
    if (!element || !element.getBoundingClientRect) {
      return false;
    }
    var style = window.getComputedStyle(element);
    if (style) {
      if (style.display === "none" || style.visibility === "hidden") {
        return false;
      }
      var opacity = parseFloat(style.opacity);
      if (!isNaN(opacity) && opacity <= 0.01) {
        return false;
      }
      if (style.pointerEvents === "none") {
        return false;
      }
    }
    var rect = element.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0;
  }

  function getOverlayCandidate(root) {
    var now = nowMs();
    if (overlayCache.overlay &&
        overlayCache.generation === navGeneration &&
        (now - overlayCache.checkedAt) <= overlayCacheTtlMs &&
        overlayCache.overlay.isConnected) {
      return overlayCache.overlay;
    }
    var overlay = findOverlayCandidate(root, collectRoots(root));
    overlayCache = { generation: navGeneration, overlay: overlay, checkedAt: now };
    return overlay;
  }

  function overlayBlocksElement(element) {
    if (!element) {
      return false;
    }
    var root = document.body || document.documentElement;
    if (!root) {
      return false;
    }
    var rect = element.getBoundingClientRect ? element.getBoundingClientRect() : null;
    if (rect && rect.width > 0 && rect.height > 0) {
      var centerX = rect.left + rect.width / 2;
      var centerY = rect.top + rect.height / 2;
      if (centerX >= 0 && centerY >= 0 && centerX <= window.innerWidth && centerY <= window.innerHeight) {
        var hit = document.elementFromPoint(centerX, centerY);
        if (hit && (hit === element || element.contains(hit))) {
          return false;
        }
      }
    }
    var overlay = getOverlayCandidate(root);
    if (!overlay) {
      return false;
    }
    if (overlay.contains(element)) {
      return false;
    }
    return true;
  }

  function applyTool(toolName, args) {
    if (toolName === "browser.click") {
      var resolvedClick = resolveHandle(args.handleId);
      if (resolvedClick.error) {
        return { status: "error", error: resolvedClick.error };
      }
      var target = resolvedClick.element;
      if (overlayBlocksElement(target)) {
        return { status: "error", error: ToolErrorCode.BLOCKED_BY_OVERLAY };
      }
      if (!isElementVisible(target)) {
        return { status: "error", error: ToolErrorCode.NOT_INTERACTABLE };
      }
      if (isElementDisabled(target)) {
        return { status: "error", error: ToolErrorCode.DISABLED };
      }
      target.scrollIntoView({ block: "center" });
      highlightElement(target);
      target.click();
      return { status: "ok" };
    }

    if (toolName === "browser.type") {
      if (!args || typeof args.text !== "string") {
        return { status: "error", error: ToolErrorCode.INVALID_ARGUMENTS };
      }
      var resolvedInput = resolveHandle(args.handleId);
      if (resolvedInput.error) {
        return { status: "error", error: resolvedInput.error };
      }
      var input = resolvedInput.element;
      if (overlayBlocksElement(input)) {
        return { status: "error", error: ToolErrorCode.BLOCKED_BY_OVERLAY };
      }
      var tagName = input.tagName ? input.tagName.toLowerCase() : "";
      var isEditable = tagName === "input" || tagName === "textarea" || !!input.isContentEditable;
      if (!isEditable) {
        return { status: "error", error: ToolErrorCode.NOT_INTERACTABLE };
      }
      if (isElementDisabled(input)) {
        return { status: "error", error: ToolErrorCode.DISABLED };
      }
      if (!isElementVisible(input)) {
        return { status: "error", error: ToolErrorCode.NOT_INTERACTABLE };
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

    if (toolName === "browser.scroll") {
      if (!args || typeof args.deltaY !== "number" || !isFinite(args.deltaY)) {
        return { status: "error", error: ToolErrorCode.INVALID_ARGUMENTS };
      }
      var deltaY = args.deltaY;
      window.scrollBy({ top: deltaY, left: 0, behavior: "auto" });
      return { status: "ok" };
    }

    if (toolName === "browser.select") {
      if (!args || typeof args.value !== "string" || !args.value) {
        return { status: "error", error: ToolErrorCode.INVALID_ARGUMENTS };
      }
      var resolvedSelect = resolveHandle(args.handleId);
      if (resolvedSelect.error) {
        return { status: "error", error: resolvedSelect.error };
      }
      var selectEl = resolvedSelect.element;
      if (overlayBlocksElement(selectEl)) {
        return { status: "error", error: ToolErrorCode.BLOCKED_BY_OVERLAY };
      }
      if (selectEl.tagName && selectEl.tagName.toLowerCase() !== "select") {
        return { status: "error", error: ToolErrorCode.NOT_INTERACTABLE };
      }
      if (isElementDisabled(selectEl)) {
        return { status: "error", error: ToolErrorCode.DISABLED };
      }
      if (!isElementVisible(selectEl)) {
        return { status: "error", error: ToolErrorCode.NOT_INTERACTABLE };
      }
      var value = typeof args.value === "string" ? args.value : "";
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

    return { status: "error", error: ToolErrorCode.UNSUPPORTED_TOOL };
  }

  var AUTOMATION_ALLOWED_HOSTS = {
    "127.0.0.1": true,
    "localhost": true
  };
  var automationState = {
    origin: null,
    nonce: null,
    runId: null,
    reportUrl: null,
    startPending: false,
    startAcked: false,
    readySent: false,
    port: null,
    heartbeatTimer: null,
    reconnectTimer: null
  };

  function stopAutomationHeartbeat() {
    if (automationState.heartbeatTimer) {
      clearInterval(automationState.heartbeatTimer);
      automationState.heartbeatTimer = null;
    }
  }

  function clearAutomationReconnect() {
    if (automationState.reconnectTimer) {
      clearTimeout(automationState.reconnectTimer);
      automationState.reconnectTimer = null;
    }
  }

  function startAutomationHeartbeat() {
    if (automationState.heartbeatTimer || !automationState.port) {
      return;
    }
    automationState.heartbeatTimer = setInterval(function () {
      if (!automationState.port) {
        stopAutomationHeartbeat();
        return;
      }
      try {
        automationState.port.postMessage({ type: "laika.automation.ping", runId: automationState.runId });
      } catch (error) {
      }
    }, 20000);
  }

  function scheduleAutomationReconnect() {
    if (automationState.reconnectTimer || (!automationState.startPending && !automationState.startAcked)) {
      return;
    }
    automationState.reconnectTimer = setTimeout(function () {
      automationState.reconnectTimer = null;
      if (!automationState.startPending && !automationState.startAcked) {
        return;
      }
      ensureAutomationPort();
      if (!automationState.port) {
        scheduleAutomationReconnect();
      }
    }, 1000);
  }

  function ensureAutomationPort() {
    if (automationState.port || typeof browser === "undefined" || !browser.runtime || !browser.runtime.connect) {
      return;
    }
    try {
      var port = browser.runtime.connect({ name: "laika.automation" });
      automationState.port = port;
      port.onDisconnect.addListener(function () {
        automationState.port = null;
        stopAutomationHeartbeat();
        scheduleAutomationReconnect();
      });
      port.onMessage.addListener(function (message) {
        if (!message || message.type !== "laika.automation.pong") {
          return;
        }
      });
      startAutomationHeartbeat();
    } catch (error) {
    }
  }

  function resetAutomationPort() {
    clearAutomationReconnect();
    stopAutomationHeartbeat();
    if (automationState.port) {
      try {
        automationState.port.disconnect();
      } catch (error) {
      }
      automationState.port = null;
    }
  }

  function isAllowedAutomationOrigin(origin) {
    if (!origin) {
      return false;
    }
    try {
      var parsed = new URL(origin);
      return !!AUTOMATION_ALLOWED_HOSTS[parsed.hostname];
    } catch (error) {
      return false;
    }
  }

  function setAutomationState(origin, nonce, runId, reportUrl) {
    automationState.origin = origin;
    automationState.nonce = nonce;
    automationState.runId = runId;
    if (reportUrl) {
      automationState.reportUrl = reportUrl;
    }
  }

  function postAutomationMessage(payload) {
    if (typeof window === "undefined" || !automationState.origin) {
      return;
    }
    var message = payload && typeof payload === "object" ? payload : { type: "laika.automation.message" };
    if (automationState.nonce && !message.nonce) {
      message.nonce = automationState.nonce;
    }
    window.postMessage(message, automationState.origin);
  }

  function announceAutomationReady() {
    if (automationState.readySent || typeof window === "undefined" || !window.location) {
      return;
    }
    var origin = window.location.origin || "";
    if (!isAllowedAutomationOrigin(origin)) {
      return;
    }
    automationState.readySent = true;
    window.postMessage({ type: "laika.automation.ready", at: new Date().toISOString() }, origin);
  }

  function scheduleAutomationReady() {
    if (typeof document === "undefined") {
      announceAutomationReady();
      return;
    }
    if (document.readyState === "complete" || document.readyState === "interactive") {
      announceAutomationReady();
      return;
    }
    document.addEventListener("DOMContentLoaded", announceAutomationReady);
  }

  async function sendAutomationRequest(payload) {
    if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendMessage) {
      return { status: "error", error: "runtime_unavailable" };
    }
    try {
      return await browser.runtime.sendMessage(payload);
    } catch (error) {
      return { status: "error", error: "message_failed" };
    }
  }

  function handleAutomationMessage(event) {
    if (!event || event.source !== window || !event.data || typeof event.data.type !== "string") {
      return;
    }
    if (!isAllowedAutomationOrigin(event.origin)) {
      return;
    }
    var payload = event.data || {};
    if (payload.type === "laika.automation.enable") {
      var enableNonce = typeof payload.nonce === "string" && payload.nonce.length >= 8 ? payload.nonce : null;
      if (!enableNonce) {
        if (typeof window !== "undefined") {
          window.postMessage({ type: "laika.automation.enabled", status: "error", error: "missing_nonce" }, event.origin);
        }
        return;
      }
      var enableRunId = typeof payload.runId === "string" && payload.runId ? payload.runId : automationState.runId;
      setAutomationState(event.origin, enableNonce, enableRunId, automationState.reportUrl);
      ensureAutomationPort();
      sendAutomationRequest({
        type: "laika.automation.enable",
        origin: event.origin,
        nonce: enableNonce
      }).then(function (response) {
        var message = {
          type: "laika.automation.enabled",
          runId: enableRunId,
          status: response && response.status ? response.status : "error",
          error: response && response.error ? response.error : undefined
        };
        if (response && typeof response.enabled === "boolean") {
          message.enabled = response.enabled;
        }
        if (response && typeof response.alreadyEnabled === "boolean") {
          message.alreadyEnabled = response.alreadyEnabled;
        }
        postAutomationMessage(message);
      });
      return;
    }
    if (payload.type === "laika.automation.disable") {
      var disableNonce = typeof payload.nonce === "string" && payload.nonce.length >= 8 ? payload.nonce : null;
      if (!disableNonce) {
        if (typeof window !== "undefined") {
          window.postMessage({ type: "laika.automation.disabled", status: "error", error: "missing_nonce" }, event.origin);
        }
        return;
      }
      var disableRunId = typeof payload.runId === "string" && payload.runId ? payload.runId : automationState.runId;
      setAutomationState(event.origin, disableNonce, disableRunId, automationState.reportUrl);
      ensureAutomationPort();
      sendAutomationRequest({
        type: "laika.automation.disable",
        origin: event.origin,
        nonce: disableNonce
      }).then(function (response) {
        var message = {
          type: "laika.automation.disabled",
          runId: disableRunId,
          status: response && response.status ? response.status : "error",
          error: response && response.error ? response.error : undefined
        };
        if (response && typeof response.enabled === "boolean") {
          message.enabled = response.enabled;
        }
        if (response && typeof response.alreadyDisabled === "boolean") {
          message.alreadyDisabled = response.alreadyDisabled;
        }
        postAutomationMessage(message);
      });
      return;
    }
    if (payload.type === "laika.automation.start") {
      var nonce = typeof payload.nonce === "string" && payload.nonce.length >= 8 ? payload.nonce : null;
      if (!nonce) {
        if (typeof window !== "undefined") {
          window.postMessage({ type: "laika.automation.error", error: "missing_nonce" }, event.origin);
        }
        return;
      }
      var runId = typeof payload.runId === "string" && payload.runId ? payload.runId : null;
      var reportUrl = typeof payload.reportUrl === "string" && payload.reportUrl ? payload.reportUrl : null;
      if (automationState.runId && automationState.nonce === nonce && automationState.runId === runId) {
        if (automationState.startAcked) {
          postAutomationMessage({ type: "laika.automation.ack", runId: automationState.runId, status: "ok" });
          return;
        }
        if (automationState.startPending) {
          return;
        }
      }
      automationState.startPending = true;
      automationState.startAcked = false;
      automationState.reportUrl = reportUrl;
      setAutomationState(event.origin, nonce, runId, reportUrl);
      ensureAutomationPort();
      sendAutomationRequest({
        type: "laika.automation.start",
        runId: runId,
        goals: payload.goals,
        goal: payload.goal,
        options: payload.options || {},
        targetUrl: payload.targetUrl || "",
        origin: event.origin,
        nonce: nonce,
        reportUrl: reportUrl
      }).then(function (response) {
        automationState.startPending = false;
        if (!response || response.status !== "ok") {
          resetAutomationPort();
          postAutomationMessage({ type: "laika.automation.error", runId: runId, error: (response && response.error) || "start_failed" });
          return;
        }
        if (response && response.runId) {
          setAutomationState(event.origin, nonce, response.runId, reportUrl);
        }
        automationState.startAcked = true;
        postAutomationMessage({ type: "laika.automation.ack", runId: response.runId || runId, status: "ok" });
      });
      return;
    }
    if (!automationState.nonce || payload.nonce !== automationState.nonce) {
      return;
    }
    if (payload.type === "laika.automation.status" || payload.type === "laika.automation.cancel") {
      sendAutomationRequest({
        type: payload.type,
        runId: payload.runId || automationState.runId,
        nonce: payload.nonce
      }).then(function (response) {
        postAutomationMessage({
          type: payload.type === "laika.automation.cancel" ? "laika.automation.cancelled" : "laika.automation.status",
          runId: payload.runId || automationState.runId,
          status: response && response.status ? response.status : "unknown",
          error: response && response.error ? response.error : undefined
        });
      });
    }
  }

  if (typeof window !== "undefined" && window.addEventListener) {
    window.addEventListener("message", handleAutomationMessage);
  }

  if (typeof browser !== "undefined" && browser.runtime && browser.runtime.onMessage) {
    browser.runtime.onMessage.addListener(function (message) {
      if (!message || !message.type) {
        return Promise.resolve({ status: "error", error: "invalid_message" });
      }
      if (message.type === "laika.ping") {
        return Promise.resolve({ status: "ok" });
      }
      if (message.type === "laika.automation.progress" ||
          message.type === "laika.automation.result" ||
          message.type === "laika.automation.error" ||
          message.type === "laika.automation.status") {
        if (message.type === "laika.automation.result" ||
            (message.type === "laika.automation.error" && automationState.startAcked)) {
          automationState.startPending = false;
          automationState.startAcked = false;
          resetAutomationPort();
        }
        postAutomationMessage(message);
        return Promise.resolve({ status: "ok" });
      }
      if (message.type === "laika.observe") {
        return Promise.resolve(observeDomWithStatus(message.options || {}));
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

  scheduleAutomationReady();

  if (typeof window !== "undefined" && window.__LAIKA_HARNESS__) {
    if (!window.LaikaHarness) {
      window.LaikaHarness = {};
    }
    window.LaikaHarness.observeDom = observeDom;
    window.LaikaHarness.applyTool = applyTool;
  }
})();
