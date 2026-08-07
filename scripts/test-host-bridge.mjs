#!/usr/bin/env node

import assert from "node:assert/strict";
import plugin from "../plugins/assistant-host-bridge/index.js";

const tools = [];
const hooks = new Map();
plugin.register({
  registerTool(tool) {
    tools.push(tool);
  },
  on(name, handler) {
    hooks.set(name, handler);
  },
});

assert.deepEqual(
  tools.map((tool) => tool.name).sort(),
  [
    "assistant_gateway_restart",
    "assistant_host_logs",
    "assistant_host_resources",
    "assistant_host_status",
    "assistant_tailscale_status",
  ],
);

const sending = hooks.get("message_sending");
assert.equal(typeof sending, "function");
const telegram = `123456789:${"A".repeat(30)}`;
const gemini = `AQ.${"B".repeat(40)}`;
const github = `github_pat_${"C".repeat(30)}`;
const output = await sending({
  content: `telegram=${telegram} gemini=${gemini} github=${github}`,
});
assert.ok(output.content.includes("[redacted:telegram-token]"));
assert.ok(output.content.includes("[redacted:google-api-key]"));
assert.ok(output.content.includes("[redacted:github-token]"));
assert.ok(!output.content.includes(telegram));
assert.ok(!output.content.includes(gemini));
assert.ok(!output.content.includes(github));

const approval = hooks.get("before_tool_call");
assert.equal(await approval({ toolName: "assistant_host_status" }), undefined);
const restart = await approval({ toolName: "assistant_gateway_restart" });
assert.deepEqual(restart.requireApproval.allowedDecisions, ["allow-once", "deny"]);
assert.equal(restart.requireApproval.timeoutBehavior, "deny");

console.log("host bridge test passed");
