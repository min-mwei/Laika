(function (root) {
  "use strict";

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  function validatePlanResponse(payload) {
    if (!isObject(payload)) {
      return { ok: false, error: "invalid payload" };
    }
    if (!Array.isArray(payload.actions)) {
      return { ok: false, error: "missing actions array" };
    }
    return { ok: true };
  }

  var api = {
    validatePlanResponse: validatePlanResponse
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (root) {
    root.LaikaPlanValidator = api;
  }
})(typeof window !== "undefined" ? window : undefined);
