#!/usr/bin/env node

import {
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, join, resolve, sep } from "node:path";
import { homedir } from "node:os";

const workspace = resolve(process.env.CLAWD_WORKSPACE || "");
if (!workspace) throw new Error("CLAWD_WORKSPACE is required");

const sessionsDir = resolve(
  process.env.OPENCLAW_SESSIONS_DIR ||
    join(homedir(), ".openclaw", "agents", "main", "sessions"),
);
const indexFile = join(sessionsDir, "sessions.json");
if (!existsSync(indexFile)) process.exit(0);

function redact(value) {
  return String(value)
    .replace(/[0-9]{8,12}:[A-Za-z0-9_-]{20,}/g, "[redacted:telegram-token]")
    .replace(/AIza[A-Za-z0-9_-]{20,}/g, "[redacted:google-api-key]")
    .replace(/AQ\.[A-Za-z0-9_-]{30,}/g, "[redacted:google-api-key]")
    .replace(/\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}/g, "[redacted:api-key]")
    .replace(/\bgh[pousr]_[A-Za-z0-9]{20,}/g, "[redacted:github-token]")
    .replace(/\bgithub_pat_[A-Za-z0-9_]{20,}/g, "[redacted:github-token]")
    .replace(/(authorization|bearer|password|token|api[_-]?key)\s*[:=]\s*\S+/gi, "$1=[redacted]")
    .slice(0, 65536);
}

function messageText(content) {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .filter((block) => block?.type === "text" && typeof block.text === "string")
    .map((block) => block.text)
    .join("\n");
}

function readJsonLines(file) {
  return readFileSync(file, "utf8")
    .split(/\r?\n/)
    .filter(Boolean)
    .flatMap((line) => {
      try {
        return [JSON.parse(line)];
      } catch {
        return [];
      }
    });
}

const index = JSON.parse(readFileSync(indexFile, "utf8"));
const sessionKeyByFile = new Map();
for (const [sessionKey, record] of Object.entries(index)) {
  const candidate = record?.sessionFile || record?.file;
  if (typeof candidate !== "string") continue;
  const full = resolve(candidate);
  if (!full.startsWith(`${sessionsDir}${sep}`)) continue;
  sessionKeyByFile.set(full, sessionKey);
}

const byDay = new Map();
for (const entry of readdirSync(sessionsDir, { withFileTypes: true })) {
  if (!entry.isFile() || !entry.name.endsWith(".jsonl")) continue;
  const file = resolve(sessionsDir, entry.name);
  const sessionKey = sessionKeyByFile.get(file) || `session:${basename(file, ".jsonl")}`;

  for (const row of readJsonLines(file)) {
    if (row?.type !== "message") continue;
    const role = row?.message?.role;
    if (role !== "user" && role !== "assistant") continue;
    const text = redact(messageText(row.message.content)).trim();
    if (!text) continue;
    const timestamp = String(row.timestamp || row.message?.timestamp || "");
    const match = timestamp.match(/^(\d{4})-(\d{2})-(\d{2})/);
    if (!match) continue;
    const day = `${match[1]}/${match[2]}/${match[3]}`;
    const event = role === "user" ? "message:received" : "message:sent";
    const normalized = JSON.stringify({ timestamp, sessionKey, role, event, text });
    if (!byDay.has(day)) byDay.set(day, []);
    byDay.get(day).push(normalized);
  }
}

for (const [day, lines] of byDay) {
  const output = join(workspace, "raw", "sessions", `${day}.jsonl`);
  mkdirSync(dirname(output), { recursive: true });
  const uniqueLines = [...new Set(lines)].sort();
  const body = `${uniqueLines.join("\n")}\n`;
  if (!existsSync(output) || readFileSync(output, "utf8") !== body) {
    const temp = `${output}.tmp`;
    writeFileSync(temp, body, { encoding: "utf8", mode: 0o600 });
    renameSync(temp, output);
  }

  const indexed = join(workspace, "raw-indexed", "sessions", `${day}.md`);
  const indexedBody = [
    `# session transcript ${day.replaceAll("/", "-")}`,
    "",
    ...uniqueLines.map((line) => {
      const record = JSON.parse(line);
      const text = record.text.replace(/\n/g, "\n  ");
      return `- ${record.timestamp} ${record.role}: ${text}`;
    }),
    "",
  ].join("\n");
  mkdirSync(dirname(indexed), { recursive: true });
  if (!existsSync(indexed) || readFileSync(indexed, "utf8") !== indexedBody) {
    const indexedTemp = `${indexed}.tmp`;
    writeFileSync(indexedTemp, indexedBody, { encoding: "utf8", mode: 0o600 });
    renameSync(indexedTemp, indexed);
  }
}
