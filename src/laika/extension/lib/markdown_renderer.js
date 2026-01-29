(function (root) {
  "use strict";

  var DEFAULT_ALLOWED_TAGS = [
    "p", "br", "strong", "em", "code", "pre", "blockquote", "hr",
    "ul", "ol", "li",
    "h1", "h2", "h3", "h4", "h5", "h6",
    "table", "thead", "tbody", "tr", "th", "td",
    "a"
  ];

  var DEFAULT_ALLOWED_ATTR = ["href"];
  var DEFAULT_URI_REGEXP = /^(?:https?:|mailto:)/i;

  function resolveRoot() {
    if (typeof root !== "undefined" && root) {
      return root;
    }
    if (typeof globalThis !== "undefined") {
      return globalThis;
    }
    return undefined;
  }

  function resolveMarkdownIt(markdownItOverride) {
    if (markdownItOverride) {
      return markdownItOverride;
    }
    var resolvedRoot = resolveRoot();
    if (resolvedRoot && resolvedRoot.markdownit) {
      return resolvedRoot.markdownit;
    }
    if (typeof require === "function") {
      return require("./vendor/markdown-it.min.js");
    }
    return null;
  }

  function resolvePurify(purifyOverride) {
    if (purifyOverride) {
      return purifyOverride;
    }
    var resolvedRoot = resolveRoot();
    if (resolvedRoot && resolvedRoot.DOMPurify) {
      return resolvedRoot.DOMPurify;
    }
    if (typeof require === "function") {
      return require("./vendor/purify.min.js");
    }
    return null;
  }

  function buildSanitizerConfig(options) {
    var allowedTags = DEFAULT_ALLOWED_TAGS.slice();
    var allowedAttr = DEFAULT_ALLOWED_ATTR.slice();
    if (options && Array.isArray(options.allowedTags)) {
      allowedTags = options.allowedTags.slice();
    }
    if (options && Array.isArray(options.allowedAttr)) {
      allowedAttr = options.allowedAttr.slice();
    }
    return {
      ALLOWED_TAGS: allowedTags,
      ALLOWED_ATTR: allowedAttr,
      FORBID_TAGS: ["script", "style", "iframe", "object", "embed", "form"],
      ALLOWED_URI_REGEXP: DEFAULT_URI_REGEXP,
      KEEP_CONTENT: true
    };
  }

  function ensureLinkHook(purifyInstance) {
    if (!purifyInstance || typeof purifyInstance.addHook !== "function") {
      return;
    }
    if (purifyInstance.laikaLinkHookAdded) {
      return;
    }
    purifyInstance.laikaLinkHookAdded = true;
    purifyInstance.addHook("afterSanitizeAttributes", function (node) {
      if (!node || node.tagName !== "A") {
        return;
      }
      node.setAttribute("rel", "noopener noreferrer");
      node.setAttribute("target", "_blank");
    });
  }

  function createMarkdownRenderer(options) {
    var rendererOptions = options || {};
    var markdownItFactory = resolveMarkdownIt(rendererOptions.markdownIt);
    if (!markdownItFactory) {
      throw new Error("markdown-it not available");
    }
    var markdownOptions = rendererOptions.markdownOptions || {};
    if (typeof markdownOptions.html === "undefined") {
      markdownOptions.html = false;
    }
    var markdownItInstance = typeof markdownItFactory === "function"
      ? markdownItFactory(markdownOptions)
      : markdownItFactory;

    if (!markdownItInstance || typeof markdownItInstance.render !== "function") {
      throw new Error("invalid markdown-it instance");
    }

    var purifyInstance = resolvePurify(rendererOptions.purify);
    var sanitizerConfig = buildSanitizerConfig(rendererOptions);
    ensureLinkHook(purifyInstance);

    function render(markdownText) {
      var sourceMarkdown = typeof markdownText === "string" ? markdownText : "";
      var rawHtml = markdownItInstance.render(sourceMarkdown);
      if (!purifyInstance || typeof purifyInstance.sanitize !== "function") {
        return rawHtml;
      }
      return purifyInstance.sanitize(rawHtml, sanitizerConfig);
    }

    return {
      render: render,
      sanitizerConfig: sanitizerConfig
    };
  }

  function renderMarkdown(markdownText, options) {
    return createMarkdownRenderer(options).render(markdownText);
  }

  var api = {
    createMarkdownRenderer: createMarkdownRenderer,
    renderMarkdown: renderMarkdown,
    buildSanitizerConfig: buildSanitizerConfig
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  var resolvedRoot = resolveRoot();
  if (resolvedRoot) {
    resolvedRoot.LaikaMarkdownRenderer = api;
  }
})(typeof window !== "undefined" ? window : undefined);
