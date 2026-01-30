(function () {
  "use strict";

  var metaEl = document.getElementById("meta");
  var titleEl = document.getElementById("title");
  var questionEl = document.getElementById("question");
  var answerEl = document.getElementById("answer");
  var sourcesEl = document.getElementById("sources");
  var errorEl = document.getElementById("error");

  function showError(message) {
    if (errorEl) {
      errorEl.textContent = message;
      errorEl.hidden = false;
    }
  }

  function renderMarkdown(markdownText) {
    if (window.LaikaMarkdownRenderer && typeof window.LaikaMarkdownRenderer.renderMarkdown === "function") {
      return window.LaikaMarkdownRenderer.renderMarkdown(markdownText || "");
    }
    return markdownText || "";
  }

  function showPending(message) {
    if (errorEl) {
      errorEl.hidden = true;
      errorEl.textContent = "";
    }
    if (answerEl) {
      answerEl.textContent = message;
    }
  }

  function sleep(ms) {
    return new Promise(function (resolve) {
      window.setTimeout(resolve, ms);
    });
  }

  async function fetchPayload(token) {
    var response = await browser.runtime.sendMessage({
      type: "laika.answer_viewer.get",
      token: token
    });
    if (response && response.status === "ok" && response.payload) {
      return { status: "ok", payload: response.payload };
    }
    if (response && response.error) {
      return { status: "error", error: response.error };
    }
    return { status: "error", error: "unknown" };
  }

  function buildSourcesList(citations) {
    if (!sourcesEl) {
      return;
    }
    sourcesEl.innerHTML = "";
    if (!Array.isArray(citations) || citations.length === 0) {
      sourcesEl.hidden = true;
      return;
    }
    var seen = {};
    var list = document.createElement("ul");
    citations.forEach(function (citation) {
      if (!citation || !citation.url) {
        return;
      }
      var key = citation.url;
      if (seen[key]) {
        return;
      }
      seen[key] = true;
      var item = document.createElement("li");
      var link = document.createElement("a");
      link.href = citation.url;
      link.target = "_blank";
      link.rel = "noopener noreferrer";
      link.textContent = citation.url;
      item.appendChild(link);
      if (citation.quote) {
        var quote = document.createElement("div");
        quote.textContent = citation.quote;
        quote.style.fontSize = "13px";
        quote.style.color = "#64748b";
        quote.style.marginTop = "4px";
        item.appendChild(quote);
      }
      list.appendChild(item);
    });
    if (list.children.length === 0) {
      sourcesEl.hidden = true;
      return;
    }
    var heading = document.createElement("h2");
    heading.textContent = "Sources";
    sourcesEl.appendChild(heading);
    sourcesEl.appendChild(list);
    sourcesEl.hidden = false;
  }

  function updateViewerParams(payload) {
    if (!payload || !payload.collectionId || !payload.eventId) {
      return;
    }
    try {
      var url = new URL(window.location.href);
      url.searchParams.set("collectionId", payload.collectionId);
      url.searchParams.set("eventId", payload.eventId);
      if (payload.questionEventId) {
        url.searchParams.set("questionEventId", payload.questionEventId);
      }
      window.history.replaceState(null, "", url.toString());
    } catch (error) {
    }
  }

  async function fetchFromCollection(collectionId, eventId, questionEventId) {
    var response = await browser.runtime.sendMessage({
      type: "laika.collection.chat_event.get",
      collectionId: collectionId,
      eventId: eventId,
      questionEventId: questionEventId || null
    });
    if (!response || response.status !== "ok" || !response.payload) {
      return { status: "error", error: response && response.error ? response.error : "not_found" };
    }
    var payload = response.payload;
    var event = payload.event || {};
    var userEvent = payload.userEvent || null;
    var collection = payload.collection || {};
    return {
      status: "ok",
      payload: {
        markdown: typeof event.markdown === "string" ? event.markdown : "",
        citations: Array.isArray(event.citations) ? event.citations : [],
        question: userEvent && typeof userEvent.markdown === "string" ? userEvent.markdown : "",
        collectionId: typeof collection.id === "string" ? collection.id : collectionId,
        collectionTitle: typeof collection.title === "string" ? collection.title : "",
        eventId: typeof event.id === "string" ? event.id : eventId,
        questionEventId: userEvent && typeof userEvent.id === "string" ? userEvent.id : ""
      }
    };
  }

  async function loadPayload() {
    if (!window.browser || !browser.runtime || !browser.runtime.sendMessage) {
      showError("Unable to load answer viewer.");
      return;
    }
    var params = new URLSearchParams(window.location.search);
    var token = params.get("token");
    var collectionId = params.get("collectionId");
    var eventId = params.get("eventId");
    var questionEventId = params.get("questionEventId");
    var deadline = Date.now() + 60000;
    var payload = null;
    showPending("Preparing answer...");
    if (token) {
      while (Date.now() < deadline) {
        var result = await fetchPayload(token);
        if (result.status === "ok") {
          payload = result.payload;
          break;
        }
        if (result.error && result.error !== "not_found") {
          showError("Answer not found or expired.");
          return;
        }
        await sleep(1000);
      }
    }
    if (!payload && collectionId && eventId) {
      var fallback = await fetchFromCollection(collectionId, eventId, questionEventId);
      if (fallback.status === "ok") {
        payload = fallback.payload;
      }
    }
    if (!payload) {
      showError("Answer not found or expired.");
      return;
    }
    updateViewerParams(payload);
    var collectionTitle = payload.collectionTitle || "Collection";
    var title = payload.title || "Collection Answer";
    document.title = title;
    if (metaEl) {
      metaEl.textContent = collectionTitle;
    }
    if (titleEl) {
      titleEl.textContent = title;
    }
    if (questionEl) {
      questionEl.textContent = payload.question || "";
    }
    if (answerEl) {
      answerEl.innerHTML = renderMarkdown(payload.markdown || "");
    }
    buildSourcesList(payload.citations);
  }

  loadPayload().catch(function (error) {
    showError("Failed to load answer.");
    if (typeof console !== "undefined" && console.error) {
      console.error(error);
    }
  });
})();
