#!/usr/bin/env node
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, join, relative, sep } from "node:path";

const DEFAULT_MODEL = "gemini-2.5-flash";
const MAX_CHARS_PER_CHUNK = Number(process.env.DAILY_DIGEST_MAX_CHARS || 45000);
const MAX_ENTRY_CHARS = Number(process.env.DAILY_DIGEST_ENTRY_CHARS || 1800);

const DIGEST_SCHEMA = {
  type: "object",
  properties: {
    summary: { type: "string" },
    topics: {
      type: "array",
      items: {
        type: "object",
        properties: {
          title: { type: "string" },
          notes: { type: "array", items: { type: "string" } }
        },
        required: ["title", "notes"]
      }
    },
    decisions: { type: "array", items: { type: "string" } },
    open_threads: { type: "array", items: { type: "string" } },
    next_actions: { type: "array", items: { type: "string" } },
    facts_to_remember: { type: "array", items: { type: "string" } },
    people_mentioned: {
      type: "array",
      items: {
        type: "object",
        properties: {
          name: { type: "string" },
          context: { type: "string" }
        },
        required: ["name", "context"]
      }
    },
    mood: { type: "string" },
    risks: { type: "array", items: { type: "string" } },
    active_context_update: { type: "string" },
    action_log_entries: { type: "array", items: { type: "string" } },
    confidence: { type: "string", enum: ["high", "medium", "low"] },
    sources: { type: "array", items: { type: "string" } }
  },
  required: [
    "summary",
    "topics",
    "decisions",
    "open_threads",
    "next_actions",
    "facts_to_remember",
    "people_mentioned",
    "mood",
    "risks",
    "active_context_update",
    "action_log_entries",
    "confidence",
    "sources"
  ]
};

const ASSISTANT_NAME = process.env.ASSISTANT_NAME || "assistant";
const SYSTEM_PROMPT = [
  `You are ${ASSISTANT_NAME}'s nightly lifestream analyst.`,
  "Analyze only the supplied sources. Do not invent facts.",
  "Write concise Ukrainian/surzhyk when useful, but keep structured JSON field names unchanged.",
  "Treat raw logs as canonical truth and session summaries as lossy context.",
  "Never output API keys, tokens, passwords, private keys, or secret-looking strings.",
  "If evidence is thin, mark confidence as low and keep claims conservative."
].join("\n");

function parseArgs(argv) {
  const args = [...argv];
  let day = null;
  let workspace = process.env.CLAWD_WORKSPACE || "";

  while (args.length) {
    const arg = args.shift();
    if (arg === "--workspace") {
      workspace = args.shift();
    } else if (!day) {
      day = arg;
    }
  }

  if (!day) day = new Date().toISOString().slice(0, 10);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) {
    throw new Error(`day must be YYYY-MM-DD, got: ${day}`);
  }
  if (!workspace) throw new Error("workspace is required");

  return { day, workspace };
}

function readText(file) {
  return readFileSync(file, "utf8");
}

function writeText(file, text) {
  mkdirSync(dirname(file), { recursive: true });
  writeFileSync(file, text, "utf8");
}

function walkFiles(root) {
  if (!existsSync(root)) return [];
  const out = [];
  const stack = [root];

  while (stack.length) {
    const current = stack.pop();
    for (const entry of readdirSync(current)) {
      const full = join(current, entry);
      const stat = statSync(full);
      if (stat.isDirectory()) stack.push(full);
      if (stat.isFile()) out.push(full);
    }
  }

  return out.sort();
}

function scrubSecrets(text) {
  return String(text)
    .replace(/[0-9]{8,12}:[A-Za-z0-9_-]{30,}/g, "[redacted:telegram-token]")
    .replace(/AIza[A-Za-z0-9_-]{20,}/g, "[redacted:google-api-key]")
    .replace(/AQ\.[A-Za-z0-9_-]{30,}/g, "[redacted:google-api-key]")
    .replace(/\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}/g, "[redacted:api-key]")
    .replace(/\bgh[pousr]_[A-Za-z0-9]{20,}/g, "[redacted:github-token]")
    .replace(/\bgithub_pat_[A-Za-z0-9_]{20,}/g, "[redacted:github-token]")
    .replace(
      /((?:authorization|bearer|password|token|api[_-]?key|bot[_-]?token)\s*["']?\s*[:=]\s*["']?)[^\s,"'}]+/gi,
      "$1[redacted]",
    )
    .replace(/\b[A-Fa-f0-9]{64}\b/g, "[redacted:hex-secret]");
}

function truncate(text, max = MAX_ENTRY_CHARS) {
  const clean = scrubSecrets(String(text || "").trim());
  if (clean.length <= max) return clean;
  return `${clean.slice(0, max)}... [truncated ${clean.length - max} chars]`;
}

function datedPathSuffix(day, extension) {
  const [yyyy, mm, dd] = day.split("-");
  return `${yyyy}${sep}${mm}${sep}${dd}.${extension}`;
}

function findRawFiles(workspace, day) {
  const suffix = datedPathSuffix(day, "jsonl");
  return walkFiles(join(workspace, "raw")).filter((file) => file.endsWith(suffix));
}

function findRawIndexedFiles(workspace, day) {
  const suffix = datedPathSuffix(day, "md");
  return walkFiles(join(workspace, "raw-indexed")).filter((file) => file.endsWith(suffix));
}

function findSessionFiles(workspace, day) {
  const memoryRoot = join(workspace, "memory");
  return walkFiles(memoryRoot).filter((file) => {
    const rel = relative(memoryRoot, file);
    if (!file.endsWith(".md")) return false;
    if (rel.startsWith(`context${sep}daily${sep}`)) return false;
    return basename(file).includes(day);
  });
}

function firstString(...values) {
  for (const value of values) {
    if (typeof value === "string" && value.trim()) return value;
  }
  return "";
}

function extractRawEntry(line, file, index) {
  let obj;
  try {
    obj = JSON.parse(line);
  } catch {
    return {
      file,
      index,
      timestamp: "",
      actor: "unknown",
      event: "raw",
      text: truncate(line)
    };
  }

  const message = obj.message || obj.payload?.message || obj.data?.message || {};
  const payload = obj.payload || obj.data || {};
  const event = firstString(obj.event, obj.type, obj.name, payload.event, obj.hookEvent?.name, obj.direction) || "message";
  const actor =
    firstString(
      obj.actor,
      obj.role,
      obj.sender,
      obj.author,
      obj.from?.username,
      message.from?.username,
      payload.actor,
      payload.role
    ) || inferActor(event);
  const text =
    firstString(
      obj.text,
      obj.content,
      obj.messageText,
      message.text,
      message.caption,
      payload.text,
      payload.content,
      payload.normalized,
      obj.output,
      obj.response?.text
    ) || JSON.stringify(obj);

  return {
    file,
    index,
    timestamp: firstString(obj.timestamp, obj.time, obj.createdAt, payload.timestamp, message.date),
    actor,
    event,
    text: truncate(text)
  };
}

function inferActor(event) {
  const lower = String(event).toLowerCase();
  if (lower.includes("sent")) return "assistant";
  if (lower.includes("received")) return "user";
  return "unknown";
}

function loadSources(workspace, day) {
  const rawFiles = findRawFiles(workspace, day);
  const rawEntries = [];

  for (const file of rawFiles) {
    const lines = readText(file).split(/\r?\n/).filter(Boolean);
    lines.forEach((line, index) => rawEntries.push(extractRawEntry(line, relative(workspace, file), index + 1)));
  }

  const rawIndexedFiles = findRawIndexedFiles(workspace, day);
  const rawIndexedText =
    rawEntries.length === 0
      ? rawIndexedFiles.map((file) => `# ${relative(workspace, file)}\n${truncate(readText(file), 12000)}`).join("\n\n")
      : "";

  const sessionFiles = findSessionFiles(workspace, day);
  const sessionsText = sessionFiles
    .map((file) => `# ${relative(workspace, file)}\n${truncate(readText(file), 16000)}`)
    .join("\n\n");

  const activeFile = join(workspace, "memory", "context", "active.md");
  const activeText = existsSync(activeFile) ? truncate(readText(activeFile), 12000) : "";

  return {
    rawFiles,
    rawEntries,
    rawIndexedFiles,
    rawIndexedText,
    sessionFiles,
    sessionsText,
    activeText
  };
}

function sourceCount(sources) {
  return sources.rawEntries.length + sources.sessionFiles.length + (sources.rawIndexedText ? 1 : 0);
}

function buildSourceText(sources) {
  const rawText = sources.rawEntries
    .map((entry) => {
      const time = entry.timestamp ? ` ${entry.timestamp}` : "";
      return `- [${entry.file}:${entry.index}${time}] ${entry.actor}/${entry.event}: ${entry.text}`;
    })
    .join("\n");

  return [
    "## active context before this digest",
    sources.activeText || "(none)",
    "",
    "## raw telegram entries",
    rawText || sources.rawIndexedText || "(none)",
    "",
    "## session summaries",
    sources.sessionsText || "(none)"
  ].join("\n");
}

function splitText(text, maxChars) {
  if (text.length <= maxChars) return [text];

  const chunks = [];
  let current = "";
  for (const paragraph of text.split(/\n(?=- \[|#)/)) {
    if (current.length + paragraph.length + 1 > maxChars && current.trim()) {
      chunks.push(current.trim());
      current = "";
    }
    current += `${paragraph}\n`;
  }
  if (current.trim()) chunks.push(current.trim());
  return chunks;
}

async function generateDigest(day, sources) {
  if (process.env.DAILY_DIGEST_MOCK_JSON) {
    return normalizeDigest(JSON.parse(readText(process.env.DAILY_DIGEST_MOCK_JSON)));
  }

  const apiKey = readGeminiApiKey();
  const model = process.env.DIGEST_GEMINI_MODEL || DEFAULT_MODEL;
  const sourceText = buildSourceText(sources);
  const chunks = splitText(sourceText, MAX_CHARS_PER_CHUNK);

  if (chunks.length === 1) {
    return normalizeDigest(await callGemini(apiKey, model, buildDigestPrompt(day, chunks[0])));
  }

  const partials = [];
  for (let index = 0; index < chunks.length; index += 1) {
    partials.push(
      await callGemini(
        apiKey,
        model,
        buildDigestPrompt(day, chunks[index], `This is chunk ${index + 1} of ${chunks.length}. Produce a partial digest.`)
      )
    );
  }

  const mergePrompt = [
    `date: ${day}`,
    "Merge these partial daily digests into one final daily digest.",
    "Deduplicate repeated items. Keep only grounded claims.",
    "",
    JSON.stringify(partials, null, 2)
  ].join("\n");

  return normalizeDigest(await callGemini(apiKey, model, mergePrompt));
}

function readGeminiApiKey() {
  const secretsFile = process.env.OPENCLAW_SECRETS_FILE || join(homedir(), ".openclaw", "secrets.json");
  if (!existsSync(secretsFile)) throw new Error(`missing secrets file: ${secretsFile}`);
  const secrets = JSON.parse(readText(secretsFile));
  if (!secrets.GEMINI_API_KEY) throw new Error("GEMINI_API_KEY missing in secrets file");
  return secrets.GEMINI_API_KEY;
}

function buildDigestPrompt(day, sourceText, note = "") {
  return [
    `date: ${day}`,
    note,
    "",
    "Return JSON that matches the provided schema.",
    "Extract: topics, decisions, open threads, next actions, durable facts, people mentioned, mood, risks, active context update, and action log entries.",
    "Facts_to_remember are proposals only. Do not rewrite user profile or long-term notes.",
    "Action log entries should be short, factual, and grounded in sources.",
    "",
    sourceText
  ].join("\n");
}

async function callGemini(apiKey, model, prompt) {
  const modelPath = model.startsWith("models/") ? model : `models/${model}`;
  const url = `https://generativelanguage.googleapis.com/v1beta/${modelPath}:generateContent`;
  const baseBody = {
    systemInstruction: { parts: [{ text: SYSTEM_PROMPT }] },
    contents: [{ role: "user", parts: [{ text: prompt }] }]
  };

  const legacyBody = {
    ...baseBody,
    generationConfig: {
      temperature: 0.2,
      maxOutputTokens: 8192,
      responseMimeType: "application/json",
      responseSchema: DIGEST_SCHEMA
    }
  };

  const modernBody = {
    ...baseBody,
    generationConfig: {
      temperature: 0.2,
      maxOutputTokens: 8192,
      responseFormat: {
        text: {
          mimeType: "application/json",
          schema: DIGEST_SCHEMA
        }
      }
    }
  };

  let response = await postJson(url, apiKey, legacyBody);
  if (!response.ok && [400, 404].includes(response.status)) {
    response = await postJson(url, apiKey, modernBody);
  }
  if (!response.ok) {
    throw new Error(`gemini generateContent failed: ${response.status} ${response.text.slice(0, 500)}`);
  }

  const text = response.json.candidates?.[0]?.content?.parts?.map((part) => part.text || "").join("") || "";
  return parseJsonResponse(text);
}

async function postJson(url, apiKey, body) {
  const res = await fetch(url, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "x-goog-api-key": apiKey
    },
    body: JSON.stringify(body)
  });
  const text = await res.text();
  let json = {};
  try {
    json = JSON.parse(text);
  } catch {
    json = {};
  }
  return { ok: res.ok, status: res.status, text, json };
}

function parseJsonResponse(text) {
  const clean = text.trim().replace(/^```json\s*/i, "").replace(/^```\s*/i, "").replace(/```$/i, "").trim();
  try {
    return JSON.parse(clean);
  } catch {
    const start = clean.indexOf("{");
    const end = clean.lastIndexOf("}");
    if (start >= 0 && end > start) return JSON.parse(clean.slice(start, end + 1));
    throw new Error("gemini response was not valid JSON");
  }
}

function normalizeDigest(input) {
  const digest = input && typeof input === "object" ? input : {};
  return {
    summary: asString(digest.summary),
    topics: asTopics(digest.topics),
    decisions: asStringArray(digest.decisions),
    open_threads: asStringArray(digest.open_threads),
    next_actions: asStringArray(digest.next_actions),
    facts_to_remember: asStringArray(digest.facts_to_remember),
    people_mentioned: asPeople(digest.people_mentioned),
    mood: asString(digest.mood),
    risks: asStringArray(digest.risks),
    active_context_update: asString(digest.active_context_update || digest.summary),
    action_log_entries: asStringArray(digest.action_log_entries),
    confidence: ["high", "medium", "low"].includes(digest.confidence) ? digest.confidence : "low",
    sources: asStringArray(digest.sources)
  };
}

function asString(value) {
  return scrubSecrets(typeof value === "string" ? value.trim() : "");
}

function asStringArray(value) {
  if (!Array.isArray(value)) return [];
  return value.map((item) => asString(item)).filter(Boolean);
}

function asTopics(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((topic) => ({
      title: asString(topic?.title || topic),
      notes: asStringArray(topic?.notes)
    }))
    .filter((topic) => topic.title);
}

function asPeople(value) {
  if (!Array.isArray(value)) return [];
  return value
    .map((person) => ({
      name: asString(person?.name || person),
      context: asString(person?.context)
    }))
    .filter((person) => person.name);
}

function buildFallbackDigest(day, sources, reason) {
  return normalizeDigest({
    summary: `fallback digest for ${day}: ${reason}`,
    topics: [],
    decisions: [],
    open_threads: [],
    next_actions: [],
    facts_to_remember: [],
    people_mentioned: [],
    mood: "unknown",
    risks: [`smart digest unavailable: ${reason}`],
    active_context_update: "",
    action_log_entries: [],
    confidence: "low",
    sources: buildSourceList(sources)
  });
}

function buildSourceList(sources) {
  return [
    ...sources.rawFiles.map((file) => relative(sources.workspace || "", file).replace(/^\.\//, "")),
    ...sources.rawIndexedFiles.map((file) => relative(sources.workspace || "", file).replace(/^\.\//, "")),
    ...sources.sessionFiles.map((file) => relative(sources.workspace || "", file).replace(/^\.\//, ""))
  ].filter(Boolean);
}

function renderMarkdown(day, digest, sources) {
  const sourceList = buildSourceList({ ...sources, workspace: sources.workspace });
  return scrubSecrets(
    [
      `# ${day}`,
      "",
      "## summary",
      "",
      digest.summary || "-",
      "",
      "## topics",
      "",
      renderTopics(digest.topics),
      "",
      "## decisions",
      "",
      renderList(digest.decisions),
      "",
      "## open threads",
      "",
      renderList(digest.open_threads),
      "",
      "## next actions",
      "",
      renderList(digest.next_actions),
      "",
      "## facts to remember",
      "",
      renderList(digest.facts_to_remember),
      "",
      "## people mentioned",
      "",
      renderPeople(digest.people_mentioned),
      "",
      "## mood",
      "",
      digest.mood || "-",
      "",
      "## risks",
      "",
      renderList(digest.risks),
      "",
      "## status",
      "",
      `- confidence: ${digest.confidence}`,
      `- raw entries: ${sources.rawEntries.length}`,
      `- raw files: ${sources.rawFiles.length}`,
      `- raw-indexed fallback files: ${sources.rawIndexedFiles.length}`,
      `- session files: ${sources.sessionFiles.length}`,
      "",
      "## sources",
      "",
      renderList(digest.sources.length ? digest.sources : sourceList)
    ].join("\n")
  ).trimEnd() + "\n";
}

function renderTopics(topics) {
  if (!topics.length) return "- none";
  return topics
    .map((topic) => {
      const notes = topic.notes.length ? topic.notes.map((note) => `  - ${note}`).join("\n") : "  - no details";
      return `- ${topic.title}\n${notes}`;
    })
    .join("\n");
}

function renderPeople(people) {
  if (!people.length) return "- none";
  return people.map((person) => `- ${person.name}: ${person.context || "-"}`).join("\n");
}

function renderList(items) {
  if (!items.length) return "- none";
  return items.map((item) => `- ${item}`).join("\n");
}

function updateActive(workspace, day, digest) {
  if (!digest.active_context_update && !digest.open_threads.length && !digest.next_actions.length) return;
  const file = join(workspace, "memory", "context", "active.md");
  const current = existsSync(file) ? readText(file) : "# active context\n";
  const block = [
    "<!-- daily-digest:start -->",
    "## daily digest active context",
    "",
    `last update: ${day}`,
    "",
    "### current read",
    "",
    digest.active_context_update || digest.summary || "-",
    "",
    "### open threads",
    "",
    renderList(digest.open_threads),
    "",
    "### next actions",
    "",
    renderList(digest.next_actions),
    "",
    "### latest decisions",
    "",
    renderList(digest.decisions),
    "",
    "<!-- daily-digest:end -->"
  ].join("\n");
  writeText(file, replaceManagedBlock(current, "<!-- daily-digest:start -->", "<!-- daily-digest:end -->", block));
}

function updateActionLog(workspace, day, digest) {
  const entries = [
    ...digest.action_log_entries,
    ...digest.decisions.map((item) => `decision: ${item}`),
    ...digest.next_actions.map((item) => `next: ${item}`)
  ].filter(Boolean);
  if (!entries.length) return;

  const file = join(workspace, "custom", "action-log.md");
  const current = existsSync(file) ? readText(file) : "# action log\n";
  const start = `<!-- daily-digest:${day}:start -->`;
  const end = `<!-- daily-digest:${day}:end -->`;
  const block = [start, `## ${day} daily digest`, "", renderList([...new Set(entries)]), "", end].join("\n");
  writeText(file, replaceManagedBlock(current, start, end, block));
}

function replaceManagedBlock(current, start, end, block) {
  const startIndex = current.indexOf(start);
  const endIndex = current.indexOf(end);
  if (startIndex >= 0 && endIndex > startIndex) {
    return `${current.slice(0, startIndex).trimEnd()}\n\n${block}\n\n${current.slice(endIndex + end.length).trimStart()}`;
  }
  return `${current.trimEnd()}\n\n${block}\n`;
}

async function main() {
  const { day, workspace } = parseArgs(process.argv.slice(2));
  const sources = loadSources(workspace, day);
  sources.workspace = workspace;

  if (sourceCount(sources) === 0) {
    console.log(`no digest sources for ${day}; skipping`);
    return;
  }

  let digest;
  let allowStateWrites = true;
  try {
    digest = await generateDigest(day, sources);
    digest.sources = digest.sources.length ? digest.sources : buildSourceList(sources);
  } catch (error) {
    console.error(`smart digest failed: ${error.message}`);
    digest = buildFallbackDigest(day, sources, error.message);
    allowStateWrites = false;
  }

  const dailyFile = join(workspace, "memory", "context", "daily", `${day}.md`);
  writeText(dailyFile, renderMarkdown(day, digest, sources));

  if (allowStateWrites || process.env.DAILY_DIGEST_MOCK_JSON) {
    updateActive(workspace, day, digest);
    updateActionLog(workspace, day, digest);
  }

  console.log(`daily digest written: ${dailyFile}`);
  console.log(`confidence: ${digest.confidence}`);
}

main().catch((error) => {
  console.error(error.stack || error.message);
  process.exitCode = 1;
});
