(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.LaikaMarkdownPostprocess = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  function isFenceLine(trimmed) {
    return /^(```+|~~~+)/.test(trimmed);
  }

  function fenceMarkerFromLine(trimmed) {
    if (trimmed.startsWith("~~~")) {
      return "~";
    }
    return "`";
  }

  function splitLongLine(line, maxLen) {
    if (!line || line.length <= maxLen) {
      return [line];
    }
    var trimmed = line.trim();
    if (!trimmed || trimmed.indexOf(" ") === -1) {
      return [line];
    }
    if (trimmed.startsWith("#") || trimmed.startsWith(">")) {
      return [line];
    }
    if (/^[-*+]\s+/.test(trimmed) || /^\d+\.\s+/.test(trimmed)) {
      return [line];
    }
    var segments = line.split(/([.!?])\s+/);
    if (segments.length <= 1) {
      return [line];
    }
    var sentences = [];
    for (var i = 0; i < segments.length; i += 2) {
      var sentence = segments[i];
      if (i + 1 < segments.length) {
        sentence += segments[i + 1];
      }
      sentences.push(sentence.trim());
    }
    var output = [];
    var current = "";
    for (var j = 0; j < sentences.length; j += 1) {
      var candidate = current ? current + " " + sentences[j] : sentences[j];
      if (candidate.length > maxLen && current) {
        output.push(current);
        current = sentences[j];
      } else {
        current = candidate;
      }
    }
    if (current) {
      output.push(current);
    }
    return output.length ? output : [line];
  }

  function splitLongParagraphs(text) {
    var lines = String(text || "").split(/\r?\n/);
    var output = [];
    var inFence = false;
    var fenceMarker = null;
    var maxLen = 480;
    for (var i = 0; i < lines.length; i += 1) {
      var line = lines[i];
      var trimmed = line.trim();
      if (isFenceLine(trimmed)) {
        var marker = fenceMarkerFromLine(trimmed);
        if (!inFence) {
          inFence = true;
          fenceMarker = marker;
        } else if (fenceMarker === marker) {
          inFence = false;
          fenceMarker = null;
        }
        output.push(line);
        continue;
      }
      if (inFence) {
        output.push(line);
        continue;
      }
      if (line.length > maxLen) {
        var splits = splitLongLine(line, maxLen);
        for (var j = 0; j < splits.length; j += 1) {
          output.push(splits[j]);
        }
      } else {
        output.push(line);
      }
    }
    return output.join("\n");
  }

  function postProcessMarkdown(markdown) {
    var text = String(markdown || "");
    if (!text) {
      return "";
    }
    var lines = text.split(/\r?\n/);
    var output = [];
    var seen = {};
    var inFence = false;
    var fenceMarker = null;
    for (var i = 0; i < lines.length; i += 1) {
      var line = lines[i];
      var trimmed = line.trim();
      var fenceMatch = trimmed.match(/^(```+|~~~+)/);
      if (fenceMatch) {
        var marker = fenceMarkerFromLine(trimmed);
        if (!inFence) {
          inFence = true;
          fenceMarker = marker;
        } else if (fenceMarker === marker) {
          inFence = false;
          fenceMarker = null;
        }
        output.push(line);
        continue;
      }
      if (inFence) {
        output.push(line);
        continue;
      }
      if (!trimmed) {
        output.push("");
        continue;
      }
      var lower = trimmed.toLowerCase();
      if (lower === "advertisement" || lower === "sponsored" || lower === "promoted") {
        continue;
      }
      var hasCookieNotice = lower.indexOf("cookie") >= 0 && (
        lower.indexOf("policy") >= 0 ||
        lower.indexOf("consent") >= 0 ||
        lower.indexOf("preferences") >= 0 ||
        lower.indexOf("settings") >= 0
      );
      if (trimmed.length < 100 &&
          (lower.indexOf("subscribe") >= 0 ||
           lower.indexOf("newsletter") >= 0 ||
           lower.indexOf("sign up") >= 0 ||
           lower.indexOf("sign-up") >= 0 ||
           lower.indexOf("sign in") >= 0 ||
           lower.indexOf("log in") >= 0 ||
           lower.indexOf("follow us") >= 0 ||
           lower.indexOf("share this") >= 0 ||
           lower.indexOf("share on") >= 0 ||
           lower.indexOf("related articles") >= 0 ||
           lower.indexOf("related coverage") >= 0 ||
           lower.indexOf("you might also like") >= 0 ||
           hasCookieNotice ||
           lower.indexOf("privacy policy") >= 0 ||
           lower.indexOf("terms of service") >= 0 ||
           lower.indexOf("all rights reserved") >= 0)) {
        continue;
      }
      if (trimmed.length < 120) {
        var count = seen[lower] || 0;
        if (count > 0 && (
          lower.indexOf("privacy") >= 0 ||
          lower.indexOf("terms") >= 0 ||
          hasCookieNotice ||
          lower.indexOf("subscribe") >= 0 ||
          lower.indexOf("newsletter") >= 0)) {
          continue;
        }
        seen[lower] = count + 1;
      }
      output.push(line);
    }
    var joined = output.join("\n").replace(/\n{3,}/g, "\n\n");
    joined = splitLongParagraphs(joined);
    return joined.trim();
  }

  return {
    isFenceLine: isFenceLine,
    fenceMarkerFromLine: fenceMarkerFromLine,
    splitLongLine: splitLongLine,
    splitLongParagraphs: splitLongParagraphs,
    postProcessMarkdown: postProcessMarkdown
  };
});
