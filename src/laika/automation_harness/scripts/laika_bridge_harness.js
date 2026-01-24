#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const http = require("http");
const crypto = require("crypto");

const DEFAULT_PORT = 8766;

function usage() {
  console.log(
    [
      "Usage:",
      "  node scripts/laika_bridge_harness.js --scenario <path/to/scenario.json>",
      "",
      "Options:",
      "  --port <n>       Port to host the harness page (default 8766)",
      "  --output <path>  Write results to JSON",
      "  --nonce <token>  Use a fixed nonce (default random)",
      "  --timeout <sec> Timeout in seconds to emit an error payload",
      "  --keep-open      Keep server running after first result"
    ].join("\n")
  );
}

function parseArgs() {
  const args = process.argv.slice(2);
  let scenarioPath = null;
  let port = DEFAULT_PORT;
  let outputPath = null;
  let nonce = null;
  let timeoutSeconds = 0;
  let keepOpen = false;

  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    switch (arg) {
      case "--scenario":
        scenarioPath = args[++i] || null;
        break;
      case "--port":
        port = parseInt(args[++i] || String(DEFAULT_PORT), 10);
        break;
      case "--output":
        outputPath = args[++i] || null;
        break;
      case "--nonce":
        nonce = args[++i] || null;
        break;
      case "--timeout":
        timeoutSeconds = parseInt(args[++i] || "0", 10);
        if (!Number.isFinite(timeoutSeconds) || timeoutSeconds < 0) {
          timeoutSeconds = 0;
        }
        break;
      case "--keep-open":
        keepOpen = true;
        break;
      default:
        break;
    }
  }

  if (!scenarioPath) {
    return null;
  }
  return { scenarioPath, port, outputPath, nonce, timeoutSeconds, keepOpen };
}

function readScenario(filePath) {
  const raw = fs.readFileSync(filePath, "utf8");
  const payload = JSON.parse(raw);
  if (!payload || typeof payload.url !== "string" || !Array.isArray(payload.goals)) {
    throw new Error("Scenario must include url and goals array.");
  }
  return payload;
}

function readBody(req) {
  return new Promise((resolve) => {
    let data = "";
    req.on("data", (chunk) => {
      data += chunk;
    });
    req.on("end", () => {
      resolve(data);
    });
  });
}

async function main() {
  const args = parseArgs();
  if (!args) {
    usage();
    process.exit(1);
  }

  const scenario = readScenario(args.scenarioPath);
  const runId = String(Date.now());
  const nonce = args.nonce || crypto.randomBytes(16).toString("hex");
  const htmlPath = path.resolve(__dirname, "bridge_harness.html");
  const html = fs.readFileSync(htmlPath, "utf8");

  let received = false;
  let reported = false;
  let timeoutHandle = null;

  function writePayload(payload) {
    if (args.outputPath) {
      fs.writeFileSync(args.outputPath, JSON.stringify(payload, null, 2));
    } else {
      console.log("Received results:");
      console.log(JSON.stringify(payload, null, 2));
    }
  }

  function finalize(payload) {
    if (!args.keepOpen && reported) {
      return;
    }
    reported = true;
    if (timeoutHandle) {
      clearTimeout(timeoutHandle);
      timeoutHandle = null;
    }
    const finalPayload = payload && typeof payload === "object" ? payload : { error: "invalid_payload" };
    if (!finalPayload.runId) {
      finalPayload.runId = runId;
    }
    if (!finalPayload.scenario) {
      finalPayload.scenario = scenario;
    }
    if (!finalPayload.receivedAt) {
      finalPayload.receivedAt = new Date().toISOString();
    }
    writePayload(finalPayload);
    received = true;
    if (!args.keepOpen) {
      setTimeout(() => {
        server.close();
      }, 200);
    }
  }

  const server = http.createServer(async (req, res) => {
    if (!req.url) {
      res.writeHead(400);
      res.end("bad request");
      return;
    }
    if (req.url === "/" || req.url.startsWith("/harness.html")) {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(html);
      return;
    }
    if (req.url === "/api/config") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ scenario, runId, nonce }));
      return;
    }
    if (req.url === "/api/report" && req.method === "POST") {
      const raw = await readBody(req);
      let payload = null;
      try {
        payload = JSON.parse(raw || "{}");
      } catch (error) {
        payload = { error: "invalid_json" };
      }
      finalize(payload);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true }));
      return;
    }
    res.writeHead(404);
    res.end("not found");
  });

  server.listen(args.port, "127.0.0.1", () => {
    console.log("Harness server running:");
    console.log(`  http://127.0.0.1:${args.port}/harness.html`);
    console.log("Scenario:", args.scenarioPath);
    if (args.outputPath) {
      console.log("Output:", args.outputPath);
    }
    console.log("Nonce:", nonce);
    if (args.timeoutSeconds > 0 && !args.keepOpen) {
      timeoutHandle = setTimeout(() => {
        if (reported) {
          return;
        }
        finalize({
          runId: runId,
          scenario: scenario,
          error: "timeout"
        });
      }, args.timeoutSeconds * 1000);
      console.log("Timeout:", `${args.timeoutSeconds}s`);
    }
  });

  process.on("SIGINT", () => {
    if (received || args.keepOpen) {
      process.exit(0);
    }
    process.exit(1);
  });
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : String(error));
  process.exit(1);
});
