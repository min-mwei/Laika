(function (root) {
  "use strict";

  function normalizeWhitespace(text) {
    return String(text || "")
      .replace(/\s+/g, " ")
      .trim();
  }

  function budgetText(text, maxChars) {
    var normalized = normalizeWhitespace(text);
    if (normalized.length <= maxChars) {
      return normalized;
    }
    return normalized.slice(0, Math.max(0, maxChars));
  }

  var api = {
    normalizeWhitespace: normalizeWhitespace,
    budgetText: budgetText
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (root) {
    root.LaikaTextUtils = api;
  }
})(typeof window !== "undefined" ? window : undefined);
