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

  async function observeWithRetries(observeFn, options, tabId, settings) {
    var attempts = 5;
    var delayMs = 250;
    var initialDelayMs = 0;
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
      if (result && result.status === "ok" && result.observation && !isObservationEmpty(result.observation)) {
        return {
          observation: result.observation,
          tabId: typeof result.tabId === "number" ? result.tabId : tabId
        };
      }
      await sleep(delayMs);
    }
    throw new Error("observe_failed");
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
      if (typeof rawResult.observation.navGeneration === "number") {
        payload.navGeneration = rawResult.observation.navGeneration;
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

  function pickNextAction(actions) {
    if (!Array.isArray(actions)) {
      return null;
    }
    for (var i = 0; i < actions.length; i += 1) {
      var action = actions[i];
      if (!action || !action.toolCall || !action.policy) {
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

  async function sendNativeMessage(payload, nativeAppId) {
    if (typeof browser === "undefined" || !browser.runtime || !browser.runtime.sendNativeMessage) {
      throw new Error("native_messaging_unavailable");
    }
    try {
      return await browser.runtime.sendNativeMessage(payload);
    } catch (error) {
      if (!nativeAppId) {
        throw error;
      }
      return await browser.runtime.sendNativeMessage(nativeAppId, payload);
    }
  }

  async function requestPlan(goal, context, maxTokens, nativeAppId) {
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
    return await sendNativeMessage(payload, nativeAppId);
  }

  function generateRunId() {
    return String(Date.now()) + "-" + Math.random().toString(16).slice(2);
  }

  function normalizeGoals(goals, goal) {
    if (Array.isArray(goals)) {
      return goals.filter(function (item) {
        return typeof item === "string" && item.trim();
      });
    }
    if (typeof goal === "string" && goal.trim()) {
      return [goal.trim()];
    }
    return [];
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

    var goals = normalizeGoals(config.goals, config.goal);
    if (goals.length === 0) {
      throw new Error("missing_goals");
    }

    var runId = config.runId || generateRunId();
    var maxSteps = typeof config.maxSteps === "number" && isFinite(config.maxSteps)
      ? Math.max(1, Math.floor(config.maxSteps))
      : 6;
    var autoApprove = config.autoApprove !== false;
    var observeOptions = config.observeOptions || (config.detail ? DETAIL_OBSERVE_OPTIONS : DEFAULT_OBSERVE_OPTIONS);
    var requestPlanFn = deps.requestPlan || requestPlan;
    var validatePlanFn = typeof deps.validatePlan === "function" ? deps.validatePlan : null;
    var listTabsFn = typeof deps.listTabs === "function" ? deps.listTabs : null;
    var onStep = typeof deps.onStep === "function" ? deps.onStep : null;
    var onStatus = typeof deps.onStatus === "function" ? deps.onStatus : null;
    var shouldCancel = typeof deps.shouldCancel === "function" ? deps.shouldCancel : null;
    var maxTokens = config.maxTokens;

    var tabsContext = listTabsFn ? await listTabsFn() : [];
    var tabIdForPlan = typeof config.tabId === "number" ? config.tabId : null;
    if (onStatus) {
      onStatus("observing");
    }
    var firstObservation = await observeWithRetries(deps.observe, observeOptions, tabIdForPlan, config.initialObserveSettings);
    var lastObservation = firstObservation.observation;
    if (typeof firstObservation.tabId === "number") {
      tabIdForPlan = firstObservation.tabId;
    }

    var results = [];
    for (var goalIndex = 0; goalIndex < goals.length; goalIndex += 1) {
      var goal = goals[goalIndex];
      var steps = [];
      var recentToolCalls = [];
      var recentToolResults = [];
      var summary = "";

      for (var step = 1; step <= maxSteps; step += 1) {
        if (shouldCancel && shouldCancel()) {
          if (onStatus) {
            onStatus("cancelled");
          }
          return {
            runId: runId,
            goals: goals,
            results: results,
            cancelled: true
          };
        }

        if (onStatus) {
          onStatus("planning");
        }
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
        var response = await requestPlanFn(goal, context, maxTokens, config.nativeAppId);
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
        var action = pickNextAction(plan.actions);
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

        if (onStatus) {
          onStatus("running_action");
        }
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
          if (onStatus) {
            onStatus("observing");
          }
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
