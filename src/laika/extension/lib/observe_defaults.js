(function (root, factory) {
  if (typeof module === "object" && module.exports) {
    module.exports = factory();
  } else {
    root.LaikaObserveDefaults = factory();
  }
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  var DEFAULT_OBSERVE_OPTIONS = Object.freeze({
    maxChars: 12000,
    maxElements: 160,
    maxBlocks: 40,
    maxPrimaryChars: 1600,
    maxOutline: 80,
    maxOutlineChars: 180,
    maxItems: 30,
    maxItemChars: 240,
    maxComments: 28,
    maxCommentChars: 360,
    includeMarkdown: true,
    captureMode: "auto",
    captureMaxChars: 24000,
    captureLinks: false
  });

  var DETAIL_OBSERVE_OPTIONS = Object.freeze({
    maxChars: 18000,
    maxElements: 180,
    maxBlocks: 60,
    maxPrimaryChars: 2400,
    maxOutline: 120,
    maxOutlineChars: 220,
    maxItems: 36,
    maxItemChars: 260,
    maxComments: 32,
    maxCommentChars: 420,
    includeMarkdown: true,
    captureMode: "auto",
    captureMaxChars: 24000,
    captureLinks: false
  });

  function cloneOptions(options) {
    return Object.assign({}, options || {});
  }

  function optionsForDetail(detail) {
    return cloneOptions(detail ? DETAIL_OBSERVE_OPTIONS : DEFAULT_OBSERVE_OPTIONS);
  }

  return {
    DEFAULT_OBSERVE_OPTIONS: DEFAULT_OBSERVE_OPTIONS,
    DETAIL_OBSERVE_OPTIONS: DETAIL_OBSERVE_OPTIONS,
    cloneOptions: cloneOptions,
    optionsForDetail: optionsForDetail
  };
});
