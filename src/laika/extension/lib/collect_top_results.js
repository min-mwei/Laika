(function (root) {
  "use strict";

  var TRACKING_KEYS = {
    fbclid: true,
    gclid: true,
    yclid: true,
    mc_cid: true,
    mc_eid: true,
    ref: true,
    ref_src: true,
    ref_url: true,
    referrer: true,
    source: true,
    spm: true,
    igshid: true,
    mkt_tok: true
  };

  var NOISE_SEGMENTS = {
    about: true,
    account: true,
    accounts: true,
    contact: true,
    faq: true,
    help: true,
    login: true,
    logout: true,
    privacy: true,
    register: true,
    rss: true,
    feed: true,
    share: true,
    signin: true,
    signup: true,
    subscribe: true,
    support: true,
    terms: true
  };

  function isHttpUrl(url) {
    try {
      var parsed = new URL(url);
      return parsed.protocol === "http:" || parsed.protocol === "https:";
    } catch (error) {
      return false;
    }
  }

  function normalizeUrlForDedup(url) {
    try {
      var parsed = new URL(url);
      if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
        return "";
      }
      parsed.hash = "";
      parsed.protocol = parsed.protocol.toLowerCase();
      parsed.hostname = parsed.hostname.toLowerCase();
      var params = parsed.searchParams;
      var entries = [];
      params.forEach(function (value, key) {
        var lowerKey = key.toLowerCase();
        if (lowerKey.indexOf("utm_") === 0 || TRACKING_KEYS[lowerKey]) {
          return;
        }
        entries.push([key, value]);
      });
      if (entries.length) {
        entries.sort(function (a, b) {
          if (a[0] === b[0]) {
            return a[1] < b[1] ? -1 : (a[1] > b[1] ? 1 : 0);
          }
          return a[0] < b[0] ? -1 : 1;
        });
      }
      var rebuilt = new URLSearchParams();
      entries.forEach(function (pair) {
        rebuilt.append(pair[0], pair[1]);
      });
      var search = rebuilt.toString();
      parsed.search = search ? "?" + search : "";
      var normalized = parsed.toString();
      if (normalized.length > 1 && normalized.endsWith("/")) {
        normalized = normalized.slice(0, -1);
      }
      return normalized;
    } catch (error) {
      return "";
    }
  }

  function isNoiseUrl(url) {
    try {
      var parsed = new URL(url);
      var path = parsed.pathname || "";
      if (!path) {
        return false;
      }
      var segments = path.toLowerCase().split("/").filter(Boolean);
      for (var i = 0; i < segments.length; i += 1) {
        var segment = segments[i];
        if (NOISE_SEGMENTS[segment]) {
          return true;
        }
        if (segment.endsWith(".rss") || segment.endsWith(".xml")) {
          return true;
        }
      }
    } catch (error) {
      return true;
    }
    return false;
  }

  function isHostBlocked(hostname, blockedHosts) {
    if (!hostname || !Array.isArray(blockedHosts) || blockedHosts.length === 0) {
      return false;
    }
    var lower = hostname.toLowerCase();
    return blockedHosts.some(function (suffix) {
      if (!suffix || typeof suffix !== "string") {
        return false;
      }
      var trimmed = suffix.trim().toLowerCase();
      if (!trimmed) {
        return false;
      }
      if (lower === trimmed) {
        return true;
      }
      return lower.endsWith("." + trimmed);
    });
  }

  function extractTopResults(observation, options) {
    var items = observation && Array.isArray(observation.items) ? observation.items : [];
    var maxResults = options && typeof options.maxResults === "number" && isFinite(options.maxResults)
      ? Math.max(1, Math.floor(options.maxResults))
      : 10;
    var hostCap = options && typeof options.hostCap === "number" && isFinite(options.hostCap)
      ? Math.max(1, Math.floor(options.hostCap))
      : 2;
    var blockedHosts = options && Array.isArray(options.blockedHosts) ? options.blockedHosts : [];
    var results = [];
    var seen = {};
    var hostCounts = {};
    var skipped = { duplicates: 0, noise: 0, invalid: 0, hostCap: 0, blockedHost: 0 };

    for (var i = 0; i < items.length && results.length < maxResults; i += 1) {
      var item = items[i];
      if (!item || typeof item.url !== "string") {
        skipped.invalid += 1;
        continue;
      }
      var normalized = normalizeUrlForDedup(item.url);
      if (!normalized || !isHttpUrl(normalized)) {
        skipped.invalid += 1;
        continue;
      }
      if (isNoiseUrl(normalized)) {
        skipped.noise += 1;
        continue;
      }
      var host = "";
      try {
        host = new URL(normalized).hostname.toLowerCase();
      } catch (error) {
        skipped.invalid += 1;
        continue;
      }
      if (isHostBlocked(host, blockedHosts)) {
        skipped.blockedHost += 1;
        continue;
      }
      if (seen[normalized]) {
        skipped.duplicates += 1;
        continue;
      }
      if (hostCap && hostCounts[host] >= hostCap) {
        skipped.hostCap += 1;
        continue;
      }
      seen[normalized] = true;
      hostCounts[host] = (hostCounts[host] || 0) + 1;
      results.push({
        url: normalized,
        title: typeof item.title === "string" ? item.title : "",
        snippet: typeof item.snippet === "string" ? item.snippet : ""
      });
    }

    return { items: results, skipped: skipped };
  }

  var api = {
    extractTopResults: extractTopResults,
    normalizeUrlForDedup: normalizeUrlForDedup,
    isNoiseUrl: isNoiseUrl,
    isHttpUrl: isHttpUrl
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }
  if (root) {
    root.LaikaCollectTopResults = api;
  }
})(typeof self !== "undefined" ? self : (typeof window !== "undefined" ? window : undefined));
