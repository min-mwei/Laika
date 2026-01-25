(function (root) {
  "use strict";

  var MAX_PRECISION = 6;

  function isWhitespace(ch) {
    return /\s/.test(ch);
  }

  function isDigit(ch) {
    return ch >= "0" && ch <= "9";
  }

  function Parser(input) {
    this.input = String(input || "");
    this.index = 0;
  }

  Parser.prototype.isAtEnd = function () {
    return this.index >= this.input.length;
  };

  Parser.prototype.peek = function () {
    return this.input[this.index];
  };

  Parser.prototype.match = function (ch) {
    if (!this.isAtEnd() && this.input[this.index] === ch) {
      this.index += 1;
      return true;
    }
    return false;
  };

  Parser.prototype.skipWhitespace = function () {
    while (!this.isAtEnd() && isWhitespace(this.peek())) {
      this.index += 1;
    }
  };

  Parser.prototype.parseExpression = function () {
    this.skipWhitespace();
    if (this.isAtEnd()) {
      throw new Error("empty_expression");
    }
    var value = this.parseTerm();
    while (true) {
      this.skipWhitespace();
      if (this.match("+")) {
        value += this.parseTerm();
        continue;
      }
      if (this.match("-")) {
        value -= this.parseTerm();
        continue;
      }
      break;
    }
    return value;
  };

  Parser.prototype.parseTerm = function () {
    var value = this.parseFactor();
    while (true) {
      this.skipWhitespace();
      if (this.match("*")) {
        value *= this.parseFactor();
        continue;
      }
      if (this.match("/")) {
        var divisor = this.parseFactor();
        if (divisor === 0) {
          throw new Error("divide_by_zero");
        }
        value /= divisor;
        continue;
      }
      break;
    }
    return value;
  };

  Parser.prototype.parseFactor = function () {
    this.skipWhitespace();
    if (this.match("+")) {
      return this.parseFactor();
    }
    if (this.match("-")) {
      return -this.parseFactor();
    }
    if (this.match("(")) {
      var value = this.parseExpression();
      this.skipWhitespace();
      if (!this.match(")")) {
        throw new Error("unbalanced_parentheses");
      }
      return value;
    }
    return this.parseNumber();
  };

  Parser.prototype.parseNumber = function () {
    this.skipWhitespace();
    var start = this.index;
    var hasDot = false;
    while (!this.isAtEnd()) {
      var ch = this.peek();
      if (isDigit(ch)) {
        this.index += 1;
        continue;
      }
      if (ch === "." && !hasDot) {
        hasDot = true;
        this.index += 1;
        continue;
      }
      break;
    }
    if (start === this.index) {
      throw new Error("invalid_expression");
    }
    var valueString = this.input.slice(start, this.index);
    if (valueString === ".") {
      throw new Error("invalid_expression");
    }
    var value = Number(valueString);
    if (!isFinite(value)) {
      throw new Error("invalid_expression");
    }
    return value;
  };

  function evaluateExpression(input) {
    try {
      var parser = new Parser(input);
      var value = parser.parseExpression();
      parser.skipWhitespace();
      if (!parser.isAtEnd()) {
        return { ok: false, error: "invalid_expression" };
      }
      return { ok: true, value: value };
    } catch (error) {
      return { ok: false, error: error && error.message ? error.message : "invalid_expression" };
    }
  }

  function normalizePrecision(value) {
    if (value === null || typeof value === "undefined") {
      return { ok: true, value: null };
    }
    if (typeof value !== "number" || !isFinite(value)) {
      return { ok: false, error: "invalid_precision" };
    }
    var rounded = Math.floor(value);
    if (rounded !== value || rounded < 0 || rounded > MAX_PRECISION) {
      return { ok: false, error: "invalid_precision" };
    }
    return { ok: true, value: rounded };
  }

  function formatValue(value, precision) {
    if (precision === null || typeof precision === "undefined") {
      return { result: value, formatted: null };
    }
    var formatted = Number(value).toFixed(precision);
    return { result: Number(formatted), formatted: formatted };
  }

  var api = {
    MAX_PRECISION: MAX_PRECISION,
    evaluateExpression: evaluateExpression,
    normalizePrecision: normalizePrecision,
    formatValue: formatValue
  };

  if (typeof module !== "undefined" && module.exports) {
    module.exports = api;
  }

  if (root) {
    root.LaikaCalculate = api;
  }
})(typeof self !== "undefined" ? self : undefined);
