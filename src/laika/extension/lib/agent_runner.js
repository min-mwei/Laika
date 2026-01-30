(function (root) {
  "use strict";

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function isDocument(doc) {
    return doc && typeof doc === "object" && doc.type === "doc" && Array.isArray(doc.children);
  }

  function renderPlainInline(nodes) {
    if (!Array.isArray(nodes)) {
      return "";
    }
    return nodes.map(renderPlainNode).join("").trim();
  }

  function renderPlainList(items, ordered) {
    if (!Array.isArray(items) || items.length === 0) {
      return "";
    }
    var lines = items.map(function (item, index) {
      var content = renderPlainBlock(item);
      var prefix = ordered ? (index + 1) + ". " : "- ";
      return prefix + content;
    });
    return lines.join("\n");
  }

  function renderPlainBlock(node) {
    if (!node || typeof node !== "object") {
      return "";
    }
    switch (node.type) {
    case "heading":
      return renderPlainInline(node.children);
    case "paragraph":
      return renderPlainInline(node.children);
    case "list":
      return renderPlainList(node.items, !!node.ordered);
    case "list_item":
      return renderPlainInline(node.children);
    case "blockquote": {
      var inner = renderPlainInline(node.children);
      return inner ? "> " + inner : "";
    }
    case "code_block":
      return typeof node.text === "string" ? node.text.trim() : "";
    case "text":
      return typeof node.text === "string" ? node.text : "";
    case "link":
      return renderPlainInline(node.children);
    default:
      return "";
    }
  }

  function renderPlainNode(node) {
    return renderPlainBlock(node);
  }

  function plainTextFromDocument(doc) {
    if (!isDocument(doc)) {
      return "";
    }
    var parts = doc.children.map(function (child) {
      return renderPlainBlock(child);
    }).filter(Boolean);
    return parts.join("\n").trim();
  }

  function extractPlanSummary(plan) {
    if (plan && plan.assistant && isDocument(plan.assistant.render)) {
      var text = plainTextFromDocument(plan.assistant.render);
      if (text) {
        return text;
      }
    }
    if (plan && typeof plan.summary === "string") {
      return plan.summary;
    }
    return "";
  }

  function clampMaxTokens(value) {
    var defaultTokens = 3072;
    var maxCap = 8192;
    var minTokens = 64;
    if (typeof value !== "number" || !isFinite(value)) {
      return defaultTokens;
    }
    var rounded = Math.floor(value);
    if (rounded < minTokens) {
      return minTokens;
    }
    if (rounded > maxCap) {
      return maxCap;
    }
    return rounded;
  }

  var DEFAULT_OBSERVE_OPTIONS = {
    maxChars: 12000,
    maxElements: 160,
    maxBlocks: 40,
    maxPrimaryChars: 1600,
    maxOutline: 80,
    maxOutlineChars: 180,
    maxItems: 30,
    maxItemChars: 240,
    maxComments: 28,
    maxCommentChars: 360
  };

  var DETAIL_OBSERVE_OPTIONS = {
    maxChars: 18000,
    maxElements: 180,
    maxBlocks: 60,
    maxPrimaryChars: 2400,
    maxOutline: 120,
    maxOutlineChars: 220,
    maxItems: 36,
    maxItemChars: 260,
    maxComments: 32,
    maxCommentChars: 420
  };

  function isObservationEmpty(observation) {
    if (!observation) {
      return true;
    }
    var text = String(observation.text || "").trim();
    var title = String(observation.title || "").trim();
    var elements = Array.isArray(observation.elements) ? observation.elements : [];
    return text.length === 0 && title.length === 0 && elements.length === 0;
  }

  function sleep(ms) {
    return new Promise(function (resolve) {
      setTimeout(resolve, ms);
    });
  }

  function withTimeout(promise, timeoutMs, timeoutCode) {
    return new Promise(function (resolve, reject) {
      var done = false;
      var timer = setTimeout(function () {
        if (done) {
          return;
        }
        done = true;
        var error = new Error(timeoutCode || "timeout");
        error.code = timeoutCode || "timeout";
        reject(error);
      }, timeoutMs);
      promise.then(function (result) {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        resolve(result);
      }).catch(function (error) {
        if (done) {
          return;
        }
        done = true;
        clearTimeout(timer);
        reject(error);
      });
    });
  }

  var DEFAULT_NATIVE_TIMEOUT_MS = 30000;

  async function observeWithRetries(observeFn, options, tabId, settings) {
    var attempts = 5;
    var delayMs = 250;
    var initialDelayMs = 0;
    var lastStatus = null;
    var lastError = null;
    var lastErrorDetails = null;
    var lastObservationSummary = null;
    var lastTabId = null;
    if (settings && typeof settings === "object") {
      if (typeof settings.attempts === "number" && isFinite(settings.attempts) && settings.attempts > 0) {
        attempts = Math.floor(settings.attempts);
      }
      if (typeof settings.delayMs === "number" && isFinite(settings.delayMs) && settings.delayMs >= 0) {
        delayMs = Math.floor(settings.delayMs);
      }
      if (typeof settings.initialDelayMs === "number" && isFinite(settings.initialDelayMs) && settings.initialDelayMs > 0) {
        initialDelayMs = Math.floor(settings.initialDelayMs);
      }
    }
    if (initialDelayMs > 0) {
      await sleep(initialDelayMs);
    }
    for (var i = 0; i < attempts; i += 1) {
      var result = await observeFn(options || DEFAULT_OBSERVE_OPTIONS, tabId);
      if (result && typeof result.tabId === "number") {
        lastTabId = result.tabId;
      }
      lastStatus = result && typeof result.status === "string" ? result.status : null;
      lastError = result && result.error ? result.error : lastError;
      lastErrorDetails = result && result.errorDetails ? result.errorDetails : lastErrorDetails;
      if (result && result.observation) {
        lastObservationSummary = summarizeObservation(result.observation);
      }
      if (result && result.status === "ok" && result.observation && !isObservationEmpty(result.observation)) {
        return {
          observation: result.observation,
          tabId: typeof result.tabId === "number" ? result.tabId : tabId
        };
      }
      await sleep(delayMs);
    }
    var error = new Error("observe_failed");
    error.details = {
      attempts: attempts,
      lastStatus: lastStatus,
      lastError: lastError,
      lastErrorDetails: lastErrorDetails,
      lastObservation: lastObservationSummary,
      lastTabId: lastTabId
    };
    throw error;
  }

  function buildToolResult(toolCall, toolName, rawResult) {
    var status = rawResult && rawResult.status === "ok" ? "ok" : "error";
    var payload = {};
    if (rawResult && rawResult.error) {
      payload.error = rawResult.error;
    }
    if (toolName === "search") {
      if (rawResult && typeof rawResult.tabId === "number") {
        payload.tabId = rawResult.tabId;
      }
      if (rawResult && typeof rawResult.url === "string") {
        payload.url = rawResult.url;
      }
      if (rawResult && typeof rawResult.engine === "string") {
        payload.engine = rawResult.engine;
      }
    }
    if (toolName === "browser.open_tab" && rawResult && typeof rawResult.tabId === "number") {
      payload.tabId = rawResult.tabId;
    }
    if (toolName === "browser.observe_dom" && rawResult && rawResult.observation) {
      payload.url = rawResult.observation.url || "";
      payload.title = rawResult.observation.title || "";
      if (rawResult.observation.documentId) {
        payload.documentId = rawResult.observation.documentId;
      }
      var navigationGeneration = rawResult.observation.navigationGeneration;
      if (typeof navigationGeneration !== "number") {
        navigationGeneration = rawResult.observation.navGeneration;
      }
      if (typeof navigationGeneration === "number") {
        payload.navigationGeneration = navigationGeneration;
      }
      if (typeof rawResult.observation.observedAtMs === "number") {
        payload.observedAtMs = rawResult.observation.observedAtMs;
      }
      payload.textChars = (rawResult.observation.text || "").length;
      payload.elementCount = Array.isArray(rawResult.observation.elements) ? rawResult.observation.elements.length : 0;
      payload.blockCount = Array.isArray(rawResult.observation.blocks) ? rawResult.observation.blocks.length : 0;
      payload.itemCount = Array.isArray(rawResult.observation.items) ? rawResult.observation.items.length : 0;
      payload.outlineCount = Array.isArray(rawResult.observation.outline) ? rawResult.observation.outline.length : 0;
      payload.primaryChars = rawResult.observation.primary && rawResult.observation.primary.text
        ? String(rawResult.observation.primary.text).length
        : 0;
    }
    if (toolName === "browser.get_selection_links" && rawResult) {
      if (Array.isArray(rawResult.urls)) {
        payload.urls = rawResult.urls.filter(function (value) {
          return typeof value === "string" && value;
        });
        payload.urlCount = payload.urls.length;
      }
      if (typeof rawResult.totalFound === "number") {
        payload.totalFound = rawResult.totalFound;
      }
      if (typeof rawResult.truncated === "boolean") {
        payload.truncated = rawResult.truncated;
      }
    }
    if (toolName === "app.calculate" && rawResult) {
      if (typeof rawResult.result === "number") {
        payload.result = rawResult.result;
      }
      if (typeof rawResult.precision === "number") {
        payload.precision = rawResult.precision;
      }
      if (typeof rawResult.formatted === "string") {
        payload.formatted = rawResult.formatted;
      }
    }
    return {
      toolCallId: toolCall.id,
      status: status,
      payload: payload
    };
  }

  function isToolBlocked(toolName, blockedTools) {
    if (!toolName || !Array.isArray(blockedTools) || blockedTools.length === 0) {
      return false;
    }
    for (var i = 0; i < blockedTools.length; i += 1) {
      if (blockedTools[i] === toolName) {
        return true;
      }
    }
    return false;
  }

  function findBlockedAction(actions, blockedTools) {
    if (!Array.isArray(actions) || !Array.isArray(blockedTools) || blockedTools.length === 0) {
      return null;
    }
    for (var i = 0; i < actions.length; i += 1) {
      var action = actions[i];
      if (!action || !action.toolCall || !action.policy) {
        continue;
      }
      if (action.policy.decision !== "allow" && action.policy.decision !== "ask") {
        continue;
      }
      if (isToolBlocked(action.toolCall.name, blockedTools)) {
        return action;
      }
    }
    return null;
  }

  function pickNextAction(actions, blockedTools) {
    if (!Array.isArray(actions)) {
      return null;
    }
    for (var i = 0; i < actions.length; i += 1) {
      var action = actions[i];
      if (!action || !action.toolCall || !action.policy) {
        continue;
      }
      if (isToolBlocked(action.toolCall.name, blockedTools)) {
        continue;
      }
      if (action.policy.decision === "allow" || action.policy.decision === "ask") {
        return action;
      }
    }
    return null;
  }

  function summarizeObservation(observation) {
    if (!observation) {
      return null;
    }
    return {
      url: observation.url || "",
      title: observation.title || "",
      textChars: (observation.text || "").length,
      elementCount: Array.isArray(observation.elements) ? observation.elements.length : 0,
      blockCount: Array.isArray(observation.blocks) ? observation.blocks.length : 0,
      itemCount: Array.isArray(observation.items) ? observation.items.length : 0,
      outlineCount: Array.isArray(observation.outline) ? observation.outline.length : 0,
      commentCount: Array.isArray(observation.comments) ? observation.comments.length : 0,
      primaryChars: observation.primary && observation.primary.text ? String(observation.primary.text).length : 0
    };
  }

  async function sendNativeMessage(payload, nativeAppId, timeoutMs) {
    if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendNativeMessage) {
      throw new Error("native_messaging_unavailable");
    }
    var resolvedTimeout = DEFAULT_NATIVE_TIMEOUT_MS;
    if (typeof timeoutMs === "number" && isFinite(timeoutMs) && timeoutMs > 0) {
      resolvedTimeout = Math.floor(timeoutMs);
    }
    var sendPromise = (async function () {
      try {
        return await browser.runtime.sendNativeMessage(payload);
      } catch (error) {
        if (!nativeAppId) {
          throw error;
        }
        return await browser.runtime.sendNativeMessage(nativeAppId, payload);
      }
    })();
    return await withTimeout(sendPromise, resolvedTimeout, "native_timeout");
  }

  async function requestPlan(goal, context, maxTokens, nativeAppId, timeoutMs) {
    var origin = "";
    try {
      origin = new URL(context.observation.url).origin;
    } catch (error) {
      origin = (context.observation && context.observation.url) || "";
    }
    var payload = {
      type: "plan",
      maxTokens: clampMaxTokens(maxTokens),
      request: {
        goal: goal,
        context: {
          origin: origin,
          mode: context.mode || "assist",
          runId: context.runId || null,
          step: typeof context.step === "number" ? context.step : null,
          maxSteps: typeof context.maxSteps === "number" ? context.maxSteps : null,
          observation: context.observation,
          recentToolCalls: Array.isArray(context.recentToolCalls) ? context.recentToolCalls : [],
          recentToolResults: Array.isArray(context.recentToolResults) ? context.recentToolResults : [],
          tabs: Array.isArray(context.tabs) ? context.tabs : []
        }
      }
    };
    return await sendNativeMessage(payload, nativeAppId, timeoutMs);
  }

  function generateRunId() {
    return String(Date.now()) + "-" + Math.random().toString(16).slice(2);
  }

  function normalizeGoals(goals, goal) {
    var items = Array.isArray(goals)
      ? goals.slice()
      : (typeof goal === "string" && goal.trim() ? [goal] : []);
    var normalized = [];
    items.forEach(function (item) {
      if (typeof item === "string" && item.trim()) {
        normalized.push({ type: "plan", text: item.trim() });
        return;
      }
      if (!isObject(item)) {
        return;
      }
      var rawType = typeof item.type === "string" ? item.type.trim() : "";
      if (rawType === "collection.answer") {
        var question = typeof item.question === "string" ? item.question.trim() : "";
        if (!question) {
          return;
        }
        normalized.push({
          type: "collection.answer",
          question: question,
          collectionId: typeof item.collectionId === "string" ? item.collectionId : null,
          maxSources: typeof item.maxSources === "number" && isFinite(item.maxSources) ? item.maxSources : null,
          maxTokens: typeof item.maxTokens === "number" && isFinite(item.maxTokens) ? item.maxTokens : null
        });
        return;
      }
      if (rawType === "collection.capture") {
        var urls = [];
        if (Array.isArray(item.urls)) {
          urls = item.urls.slice(0);
        } else if (Array.isArray(item.sources)) {
          urls = item.sources.slice(0);
        }
        urls = urls.filter(function (value) {
          return typeof value === "string" && value.trim();
        }).map(function (value) {
          return value.trim();
        });
        if (!urls.length) {
          return;
        }
        normalized.push({
          type: "collection.capture",
          title: typeof item.title === "string" ? item.title.trim() : "",
          collectionId: typeof item.collectionId === "string" ? item.collectionId : null,
          urls: urls,
          maxChars: typeof item.maxChars === "number" && isFinite(item.maxChars) ? item.maxChars : null
        });
        return;
      }
      if (rawType === "plan" || rawType === "goal") {
        var text = typeof item.goal === "string" ? item.goal.trim() : "";
        if (!text) {
          text = typeof item.text === "string" ? item.text.trim() : "";
        }
        if (text) {
          normalized.push({ type: "plan", text: text });
        }
      }
    });
    return normalized;
  }

  function dedupeUrls(urls) {
    if (!Array.isArray(urls)) {
      return [];
    }
    var seen = {};
    var deduped = [];
    urls.forEach(function (url) {
      if (typeof url !== "string") {
        return;
      }
      var trimmed = url.trim();
      if (!trimmed) {
        return;
      }
      var key = trimmed.toLowerCase();
      if (seen[key]) {
        return;
      }
      seen[key] = true;
      deduped.push(trimmed);
    });
    return deduped;
  }

  async function requestCollection(action, payload, nativeAppId, timeoutMs) {
    var message = {
      type: "collection",
      action: action,
      payload: payload || {}
    };
    return await sendNativeMessage(message, nativeAppId, timeoutMs);
  }

  function unwrapCollectionResult(response) {
    if (response && response.ok && response.result && response.result.status === "ok") {
      return response.result;
    }
    if (response && response.result && response.result.error) {
      throw new Error(response.result.error);
    }
    if (response && response.error) {
      throw new Error(response.error);
    }
    throw new Error("collection_error");
  }

  function summarizeMarkdown(text) {
    if (typeof text !== "string") {
      return "";
    }
    var trimmed = text.trim();
    if (!trimmed) {
      return "";
    }
    if (trimmed.length <= 280) {
      return trimmed;
    }
    return trimmed.slice(0, 280);
  }

  async function waitForCapturedSources(collectionId, nativeAppId, timeoutMs, maxAttempts, delayMs) {
    var attempts = typeof maxAttempts === "number" && isFinite(maxAttempts) ? Math.max(1, Math.floor(maxAttempts)) : 6;
    var delay = typeof delayMs === "number" && isFinite(delayMs) ? Math.max(300, Math.floor(delayMs)) : 1500;
    for (var i = 0; i < attempts; i += 1) {
      await sleep(delay);
      var listResponse = await requestCollection("list_sources", { collectionId: collectionId }, nativeAppId, timeoutMs);
      var listResult = unwrapCollectionResult(listResponse);
      var sources = Array.isArray(listResult.sources) ? listResult.sources : [];
      var capturedCount = sources.filter(function (source) {
        return source && source.captureStatus === "captured";
      }).length;
      if (capturedCount > 0) {
        return sources;
      }
      var pendingCount = sources.filter(function (source) {
        return source && source.captureStatus === "pending";
      }).length;
      if (pendingCount === 0) {
        return sources;
      }
    }
    var finalResponse = await requestCollection("list_sources", { collectionId: collectionId }, nativeAppId, timeoutMs);
    var finalResult = unwrapCollectionResult(finalResponse);
    return Array.isArray(finalResult.sources) ? finalResult.sources : [];
  }

  async function runAutomationGoals(config) {
    if (!config || typeof config !== "object") {
      throw new Error("missing_config");
    }
    var deps = config.deps || {};
    if (typeof deps.observe !== "function") {
      throw new Error("missing_observe");
    }
    if (typeof deps.runTool !== "function") {
      throw new Error("missing_run_tool");
    }
    if (typeof deps.requestPlan !== "function" && typeof requestPlan !== "function") {
      throw new Error("missing_request_plan");
    }

    var goalSpecs = normalizeGoals(config.goals, config.goal);
    if (goalSpecs.length === 0) {
      throw new Error("missing_goals");
    }
    var goals = goalSpecs.map(function (spec) {
      if (spec.type === "collection.answer") {
        return spec.question;
      }
      if (spec.type === "collection.capture") {
        return spec.title ? "Capture sources for " + spec.title : "Capture collection sources";
      }
      return spec.text;
    });

    var runId = config.runId || generateRunId();
    var maxSteps = typeof config.maxSteps === "number" && isFinite(config.maxSteps)
      ? Math.max(1, Math.floor(config.maxSteps))
      : 6;
    var autoApprove = config.autoApprove !== false;
    var blockedTools = Array.isArray(config.blockedTools)
      ? config.blockedTools.map(function (name) {
        return typeof name === "string" ? name.trim() : "";
      }).filter(function (name) {
        return !!name;
      })
      : [];
    if (config.disallowOpenTabs === true) {
      blockedTools.push("browser.open_tab");
    }
    var observeOptions = config.observeOptions || (config.detail ? DETAIL_OBSERVE_OPTIONS : DEFAULT_OBSERVE_OPTIONS);
    var requestPlanFn = deps.requestPlan || requestPlan;
    var validatePlanFn = typeof deps.validatePlan === "function" ? deps.validatePlan : null;
    var listTabsFn = typeof deps.listTabs === "function" ? deps.listTabs : null;
    var onStep = typeof deps.onStep === "function" ? deps.onStep : null;
    var onStatus = typeof deps.onStatus === "function" ? deps.onStatus : null;
    var shouldCancel = typeof deps.shouldCancel === "function" ? deps.shouldCancel : null;
    var maxTokens = config.maxTokens;
    var planTimeoutMs = typeof config.planTimeoutMs === "number" && isFinite(config.planTimeoutMs) && config.planTimeoutMs > 0
      ? Math.floor(config.planTimeoutMs)
      : null;

    var lastStatus = null;
    var lastStep = null;
    var lastToolCall = null;
    var lastGoalIndex = null;
    var lastGoal = null;

    function noteStatus(status) {
      if (typeof status === "string" && status) {
        lastStatus = status;
      }
      if (onStatus) {
        onStatus(status);
      }
    }

    try {
      var tabsContext = listTabsFn ? await listTabsFn() : [];
      var tabIdForPlan = typeof config.tabId === "number" ? config.tabId : null;
      noteStatus("observing");
      var firstObservation = await observeWithRetries(deps.observe, observeOptions, tabIdForPlan, config.initialObserveSettings);
      var lastObservation = firstObservation.observation;
      if (typeof firstObservation.tabId === "number") {
        tabIdForPlan = firstObservation.tabId;
      }

      var results = [];
      for (var goalIndex = 0; goalIndex < goalSpecs.length; goalIndex += 1) {
        var goalSpec = goalSpecs[goalIndex];
        var goal = goalSpec.type === "collection.answer"
          ? goalSpec.question
          : (goalSpec.type === "collection.capture"
            ? (goalSpec.title ? "Capture sources for " + goalSpec.title : "Capture collection sources")
            : goalSpec.text);
        var steps = [];
        var recentToolCalls = [];
        var recentToolResults = [];
        var summary = "";
        lastGoalIndex = goalIndex;
        lastGoal = goal;

        if (goalSpec.type === "collection.capture") {
          noteStatus("collection_capture");
          lastToolCall = "collection.capture";

          var collectionId = goalSpec.collectionId;
          if (collectionId) {
            var activateResponse = await requestCollection("set_active", { collectionId: collectionId }, config.nativeAppId, planTimeoutMs);
            unwrapCollectionResult(activateResponse);
          } else if (goalSpec.title) {
            var createResponse = await requestCollection("create", { title: goalSpec.title }, config.nativeAppId, planTimeoutMs);
            var createResult = unwrapCollectionResult(createResponse);
            collectionId = (createResult.collection && createResult.collection.id) ? createResult.collection.id : (createResult.activeCollectionId || null);
          } else {
            var listResponse = await requestCollection("list", {}, config.nativeAppId, planTimeoutMs);
            var listResult = unwrapCollectionResult(listResponse);
            collectionId = listResult.activeCollectionId || null;
            if (!collectionId) {
              var fallbackResponse = await requestCollection("create", { title: "Automation collection" }, config.nativeAppId, planTimeoutMs);
              var fallbackResult = unwrapCollectionResult(fallbackResponse);
              collectionId = (fallbackResult.collection && fallbackResult.collection.id) ? fallbackResult.collection.id : (fallbackResult.activeCollectionId || null);
            }
          }
          if (!collectionId) {
            throw new Error("missing_collection");
          }

          var urls = dedupeUrls(goalSpec.urls);
          if (urls.length === 0) {
            throw new Error("missing_urls");
          }
          var addSourcesPayload = {
            collectionId: collectionId,
            sources: urls.map(function (url) {
              return { type: "url", url: url };
            })
          };
          var addResponse = await requestCollection("add_sources", addSourcesPayload, config.nativeAppId, planTimeoutMs);
          unwrapCollectionResult(addResponse);

          var maxChars = goalSpec.maxChars !== null && goalSpec.maxChars !== undefined ? Math.floor(goalSpec.maxChars) : null;
          var captureResults = [];
          for (var i = 0; i < urls.length; i += 1) {
            var url = urls[i];
            var captureArgs = { collectionId: collectionId, url: url };
            if (typeof maxChars === "number" && isFinite(maxChars)) {
              captureArgs.maxChars = maxChars;
            }
            noteStatus("capturing_sources");
            lastToolCall = "source.capture";
            var captureAction = { toolCall: { name: "source.capture", arguments: captureArgs } };
            var captureResult = await deps.runTool(captureAction, tabIdForPlan);
            captureResults.push({ url: url, result: captureResult });
            if (captureResult && typeof captureResult.tabId === "number") {
              tabIdForPlan = captureResult.tabId;
            }
          }

          var sources = await waitForCapturedSources(collectionId, config.nativeAppId, planTimeoutMs);
          var capturedCount = sources.filter(function (source) {
            return source && source.captureStatus === "captured";
          }).length;
          var failedCount = sources.filter(function (source) {
            return source && source.captureStatus === "failed";
          }).length;
          if (capturedCount === 0) {
            throw new Error("no_captured_sources");
          }
          summary = "Captured " + capturedCount + "/" + urls.length + " sources.";
          if (failedCount > 0) {
            summary += " Failed: " + failedCount + ".";
          }

          var stepInfo = {
            step: 1,
            summary: summary,
            action: { name: "collection.capture", arguments: { collectionId: collectionId, urls: urls, maxChars: maxChars } },
            policy: { decision: "allow" }
          };
          steps.push(stepInfo);
          if (onStep) {
            onStep(stepInfo, { goalIndex: goalIndex, goal: goal });
          }
          results.push({
            goal: goal,
            summary: summary,
            steps: steps,
            collectionId: collectionId,
            captureResults: captureResults
          });
          continue;
        }

        if (goalSpec.type === "collection.answer") {
          noteStatus("collection_answer");
          lastToolCall = "collection.answer";
          var collectionId = goalSpec.collectionId;
          if (!collectionId) {
            var listResponse = await requestCollection("list", {}, config.nativeAppId, planTimeoutMs);
            var listResult = unwrapCollectionResult(listResponse);
            collectionId = listResult.activeCollectionId || null;
          }
          if (!collectionId) {
            throw new Error("missing_collection");
          }
          var listResponse = await requestCollection("list_sources", { collectionId: collectionId }, config.nativeAppId, planTimeoutMs);
          var listResult = unwrapCollectionResult(listResponse);
          var sources = Array.isArray(listResult.sources) ? listResult.sources : [];
          var capturedCount = sources.filter(function (source) {
            return source && source.captureStatus === "captured";
          }).length;
          var pendingCount = sources.filter(function (source) {
            return source && source.captureStatus === "pending";
          }).length;
          if (capturedCount === 0 && pendingCount > 0) {
            sources = await waitForCapturedSources(collectionId, config.nativeAppId, planTimeoutMs);
            capturedCount = sources.filter(function (source) {
              return source && source.captureStatus === "captured";
            }).length;
          }
          if (capturedCount === 0) {
            throw new Error("no_captured_sources");
          }
          var answerPayload = {
            collectionId: collectionId,
            question: goalSpec.question
          };
          if (goalSpec.maxSources !== null && goalSpec.maxSources !== undefined) {
            answerPayload.maxSources = Math.max(1, Math.floor(goalSpec.maxSources));
          }
          var requestedTokens = goalSpec.maxTokens !== null && goalSpec.maxTokens !== undefined
            ? goalSpec.maxTokens
            : maxTokens;
          if (typeof requestedTokens === "number" && isFinite(requestedTokens)) {
            answerPayload.maxTokens = clampMaxTokens(requestedTokens);
          }
          var answerResponse = await requestCollection("answer", answerPayload, config.nativeAppId, planTimeoutMs);
          var answerResult = unwrapCollectionResult(answerResponse);
          var answer = answerResult.answer || {};
          summary = summarizeMarkdown(answer.markdown || "");
          var stepInfo = {
            step: 1,
            summary: summary,
            action: { name: "collection.answer", arguments: answerPayload },
            policy: { decision: "allow" }
          };
          steps.push(stepInfo);
          if (onStep) {
            onStep(stepInfo, { goalIndex: goalIndex, goal: goal });
          }
          results.push({
            goal: goal,
            summary: summary,
            steps: steps,
            answer: answer,
            collectionId: collectionId
          });
          continue;
        }

        for (var step = 1; step <= maxSteps; step += 1) {
          lastStep = step;
          if (shouldCancel && shouldCancel()) {
            noteStatus("cancelled");
            return {
              runId: runId,
              goals: goals,
              results: results,
              cancelled: true
            };
          }

          noteStatus("planning");
          var context = {
            mode: config.mode || "assist",
            runId: runId,
            step: step,
            maxSteps: maxSteps,
            observation: lastObservation,
            recentToolCalls: recentToolCalls.slice(-8),
            recentToolResults: recentToolResults.slice(-8),
            tabs: tabsContext
          };
          var response = await requestPlanFn(goal, context, maxTokens, config.nativeAppId, planTimeoutMs);
          if (!response || response.ok !== true) {
            throw new Error("plan_failed");
          }
          var plan = response.plan;
          if (validatePlanFn) {
            var validation = validatePlanFn(plan);
            if (!validation.ok) {
              throw new Error("invalid_plan: " + validation.error);
            }
          }
          summary = extractPlanSummary(plan);
          var action = pickNextAction(plan.actions, blockedTools);
          var blockedAction = action ? null : findBlockedAction(plan.actions, blockedTools);
          lastToolCall = action && action.toolCall ? action.toolCall.name : null;
          var stepInfo = {
            step: step,
            summary: summary,
            action: action ? action.toolCall : null,
            policy: action ? action.policy : null,
            goalPlan: plan.goalPlan || null,
            planActions: Array.isArray(plan.actions) ? plan.actions : [],
            observation: summarizeObservation(lastObservation)
          };
          steps.push(stepInfo);
          if (onStep) {
            onStep(stepInfo, { goalIndex: goalIndex, goal: goal });
          }
          if (!action) {
            if (blockedAction) {
              recentToolCalls.push(blockedAction.toolCall);
              recentToolResults.push(buildToolResult(blockedAction.toolCall, blockedAction.toolCall.name, {
                status: "error",
                error: "blocked_tool"
              }));
              continue;
            }
            break;
          }
          if (action.policy && action.policy.decision === "deny") {
            break;
          }
          if (step === maxSteps) {
            break;
          }
          if (action.policy && action.policy.decision === "ask" && !autoApprove) {
            break;
          }

          noteStatus("running_action");
          var toolResult = await deps.runTool(action, tabIdForPlan);
          recentToolCalls.push(action.toolCall);
          recentToolResults.push(buildToolResult(action.toolCall, action.toolCall.name, toolResult));

          if (toolResult && typeof toolResult.tabId === "number") {
            tabIdForPlan = toolResult.tabId;
          } else if (action.toolCall.name === "search" || action.toolCall.name === "browser.open_tab" || action.toolCall.name === "browser.navigate") {
            tabIdForPlan = null;
          }

          if (action.toolCall.name === "browser.observe_dom" && toolResult && toolResult.observation) {
            lastObservation = toolResult.observation;
            if (typeof toolResult.tabId === "number") {
              tabIdForPlan = toolResult.tabId;
            }
          } else {
            noteStatus("observing");
            tabsContext = listTabsFn ? await listTabsFn() : tabsContext;
            var observeSettings = null;
            if (action.toolCall.name === "search" || action.toolCall.name === "browser.open_tab" || action.toolCall.name === "browser.navigate") {
              observeSettings = { attempts: 14, delayMs: 350, initialDelayMs: 700 };
            }
            var updated = await observeWithRetries(deps.observe, observeOptions, tabIdForPlan, observeSettings);
            lastObservation = updated.observation;
            if (typeof updated.tabId === "number") {
              tabIdForPlan = updated.tabId;
            }
          }

          stepInfo.toolResult = toolResult;
          stepInfo.nextObservation = summarizeObservation(lastObservation);
        }

        results.push({ goal: goal, summary: summary, steps: steps });
      }

      return {
        runId: runId,
        goals: goals,
        results: results,
        cancelled: false
      };
    } catch (error) {
      if (error && typeof error === "object") {
        var details = error.details && typeof error.details === "object" ? Object.assign({}, error.details) : {};
        if (details.lastStatus === undefined && lastStatus) {
          details.lastStatus = lastStatus;
        }
        if (details.lastStep === undefined && typeof lastStep === "number") {
          details.lastStep = lastStep;
        }
        if (details.lastToolCall === undefined && lastToolCall) {
          details.lastToolCall = lastToolCall;
        }
        if (details.lastGoalIndex === undefined && typeof lastGoalIndex === "number") {
          details.lastGoalIndex = lastGoalIndex;
        }
        if (details.lastGoal === undefined && lastGoal) {
          details.lastGoal = lastGoal;
        }
        error.details = details;
      }
      throw error;
    }
  }

  var api = {
    DEFAULT_OBSERVE_OPTIONS: DEFAULT_OBSERVE_OPTIONS,
    DETAIL_OBSERVE_OPTIONS: DETAIL_OBSERVE_OPTIONS,
    clampMaxTokens: clampMaxTokens,
    sendNativeMessage: sendNativeMessage,
    requestPlan: requestPlan,
    pickNextAction: pickNextAction,
    buildToolResult: buildToolResult,
    isObservationEmpty: isObservationEmpty,
    observeWithRetries: observeWithRetries,
    summarizeObservation: summarizeObservation,
    extractPlanSummary: extractPlanSummary,
    generateRunId: generateRunId,
    runAutomationGoals: runAutomationGoals
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (root) {
    root.LaikaAgentRunner = api;
  }
})(typeof self !== "undefined" ? self : (typeof window !== "undefined" ? window : undefined));
