#!/usr/bin/env node

import {
  chmodSync,
  existsSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, join, resolve, sep } from "node:path";

const workspace = resolve(process.argv[2] || process.env.CLAWD_WORKSPACE || "");
if (!workspace || workspace === sep) {
  throw new Error("pass a workspace path as argv[2] or CLAWD_WORKSPACE");
}

const sensitiveKey = /(?:^|[_-])(api[_-]?key|authorization|bot[_-]?token|password|secret|token)(?:$|[_-])/i;

function redactText(value) {
  return String(value)
    .replace(/[0-9]{8,12}:[A-Za-z0-9_-]{20,}/g, "[redacted:telegram-token]")
    .replace(/AIza[A-Za-z0-9_-]{20,}/g, "[redacted:google-api-key]")
    .replace(/AQ\.[A-Za-z0-9_-]{30,}/g, "[redacted:google-api-key]")
    .replace(/\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}/g, "[redacted:api-key]")
    .replace(/\bgh[pousr]_[A-Za-z0-9]{20,}/g, "[redacted:github-token]")
    .replace(/\bgithub_pat_[A-Za-z0-9_]{20,}/g, "[redacted:github-token]")
    .replace(
      /((?:authorization|bearer|password|token|api[_-]?key|bot[_-]?token)\s*["']?\s*[:=]\s*["']?)[^\s,"'}]+/gi,
      "$1[redacted]",
    );
}

function sanitize(value, key = "") {
  if (key === "cfg") return undefined;
  if (sensitiveKey.test(`_${key}_`)) return "[redacted]";
  if (typeof value === "string") return redactText(value);
  if (Array.isArray(value)) return value.map((item) => sanitize(item));
  if (!value || typeof value !== "object") return value;

  const output = {};
  for (const [childKey, childValue] of Object.entries(value)) {
    const clean = sanitize(childValue, childKey);
    if (clean !== undefined) output[childKey] = clean;
  }
  return output;
}

function filesBelow(root) {
  if (!existsSync(root)) return [];
  const output = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name);
    if (entry.isSymbolicLink()) continue;
    if (entry.isDirectory()) output.push(...filesBelow(path));
    if (entry.isFile() && (path.endsWith(".jsonl") || path.endsWith(".md"))) {
      output.push(path);
    }
  }
  return output;
}

function atomicWrite(file, body) {
  const mode = statSync(file).mode & 0o777;
  const temp = `${file}.sanitize-tmp`;
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(temp, body, { encoding: "utf8", mode });
  chmodSync(temp, mode);
  renameSync(temp, file);
}

let changed = 0;
let dropped = 0;
for (const file of [
  ...filesBelow(join(workspace, "raw")),
  ...filesBelow(join(workspace, "raw-indexed")),
]) {
  if (lstatSync(file).isSymbolicLink()) continue;
  const original = readFileSync(file, "utf8");
  let clean;

  if (file.endsWith(".jsonl")) {
    const lines = [];
    for (const line of original.split(/\r?\n/).filter(Boolean)) {
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        lines.push(redactText(line));
        continue;
      }
      if (record?.action === "preprocessed") {
        dropped += 1;
        continue;
      }
      lines.push(JSON.stringify(sanitize(record)));
    }
    clean = lines.length ? `${lines.join("\n")}\n` : "";
  } else {
    clean = redactText(original);
  }

  if (clean !== original) {
    atomicWrite(file, clean);
    changed += 1;
  }
}

console.log(`sanitized ${changed} file(s); dropped ${dropped} internal event(s)`);
