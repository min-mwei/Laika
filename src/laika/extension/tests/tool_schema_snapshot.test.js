const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const validator = require("../lib/plan_validator");

test("tool schema snapshot matches plan validator", () => {
  const schemaPath = path.resolve(
    __dirname,
    "../../shared/Tests/LaikaSharedTests/Resources/tool_schema_snapshot.json"
  );
  const snapshot = JSON.parse(fs.readFileSync(schemaPath, "utf8"));
  const actual = validator.getToolSchemaSnapshot();
  assert.deepEqual(actual, snapshot);
});
