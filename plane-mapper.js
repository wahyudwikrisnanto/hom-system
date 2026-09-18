#!/usr/bin/env node
// Maps listing-feature-testing/index.html into Plane work items.
//
//   node plane-mapper.js --dry-run   # parse and print the plan, no HTTP
//   node plane-mapper.js             # create work items + attach screenshots
//
// .env: PLANE_API_KEY, PLANE_WORKSPACE_SLUG, PLANE_PROJECT_ID, PLANE_BASE_URL (optional)
// Progress is kept in .plane-mapper-state.json so reruns skip what already exists.

const fs = require("node:fs");
const fsp = require("node:fs/promises");
const path = require("node:path");

const ROOT = __dirname;
const SOURCE_DIR = path.join(ROOT, "listing-feature-testing");
const SOURCE_HTML = path.join(SOURCE_DIR, "index.html");
const STATE_FILE = path.join(ROOT, ".plane-mapper-state.json");
const EXTERNAL_SOURCE = "listing-feature-testing";
const DRY_RUN = process.argv.includes("--dry-run");

// ---------------------------------------------------------------- parsing

const decode = (s) =>
  s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&amp;/g, "&");

const stripTags = (s) => decode(s.replace(/<[^>]+>/g, "")).trim();

function title(prefix, text, max = 90) {
  const first = text.split(/(?<=[.?!])\s/)[0].trim();
  const cut = first.length > max ? `${first.slice(0, max - 1).trimEnd()}…` : first;
  return `${prefix} ${cut}`;
}

function parse(html) {
  const groups = [];

  const sectionRe = /<section class="date-section" id="(sec\d+)">([\s\S]*?)<\/section>/g;
  for (const [, sectionId, body] of html.matchAll(sectionRe)) {
    const date = stripTags(body.match(/<span class="date">([\s\S]*?)<\/span>/)[1]);
    const shortDate = date.replace(/\/\d{4}$/, "");
    const children = [];

    // Split on item openings; each chunk holds exactly one item.
    const itemRe = /<div class="item( highlight)?" id="(sec\d+-item(\d+))">/g;
    const starts = [...body.matchAll(itemRe)];
    starts.forEach((m, i) => {
      const chunk = body.slice(m.index, i + 1 < starts.length ? starts[i + 1].index : undefined);
      const paragraphs = [...chunk.matchAll(/<p>([\s\S]*?)<\/p>/g)].map((p) => p[1]);
      const images = [...chunk.matchAll(/<figure><img src="([^"]+)"[^>]*>(?:<figcaption>([\s\S]*?)<\/figcaption>)?/g)].map(
        (f) => ({ file: f[1], caption: f[2] ?? "" }),
      );
      const text = paragraphs.map(stripTags).join(" ");

      // Placeholder points like "(tidak ada catatan tambahan)" carry nothing to track.
      if (images.length === 0 && /^\(.*\)$/.test(text)) return;

      children.push({
        externalId: m[2],
        name: title(`[${shortDate} #${m[3]}]`, text),
        descriptionHtml:
          paragraphs.map((p) => `<p>${p}</p>`).join("") +
          (images.length
            ? `<p><strong>Screenshot:</strong></p><ul>${images.map((img) => `<li>${img.caption || path.basename(img.file)}</li>`).join("")}</ul>`
            : ""),
        priority: m[1] ? "high" : "none",
        images,
      });
    });

    groups.push({
      parent: {
        externalId: sectionId,
        name: `Listing Feature Testing – ${date}`,
        descriptionHtml: `<p>Hasil testing fitur tanggal ${date} (${children.length} poin).</p>`,
        priority: "none",
        images: [],
      },
      children,
    });
  }

  const notes = html.match(/<section class="notes-section" id="notes">([\s\S]*?)<\/section>/);
  if (notes) {
    const children = [...notes[1].matchAll(/<li>([\s\S]*?)<\/li>/g)].map((li, i) => ({
      externalId: `note-${i + 1}`,
      name: title(`[Catatan #${i + 1}]`, stripTags(li[1])),
      descriptionHtml: `<p>${li[1]}</p>`,
      priority: "none",
      images: [],
    }));
    groups.push({
      parent: {
        externalId: "notes",
        name: "Listing Feature Testing – Catatan Diskusi / Best Practice",
        descriptionHtml: `<p>Catatan diskusi dan best practice dari sesi testing (${children.length} catatan).</p>`,
        priority: "none",
        images: [],
      },
      children,
    });
  }

  return groups;
}

// ---------------------------------------------------------------- state

function loadState() {
  try {
    return JSON.parse(fs.readFileSync(STATE_FILE, "utf8"));
  } catch {
    return {};
  }
}

const saveState = (state) => fsp.writeFile(STATE_FILE, `${JSON.stringify(state, null, 2)}\n`);

// ---------------------------------------------------------------- plane api

function config() {
  try {
    process.loadEnvFile(path.join(ROOT, ".env"));
  } catch {
    // fall back to the real environment
  }
  const required = ["PLANE_API_KEY", "PLANE_WORKSPACE_SLUG", "PLANE_PROJECT_ID"];
  const missing = required.filter((k) => !process.env[k]);
  if (missing.length) {
    console.error(`Missing in .env: ${missing.join(", ")}`);
    process.exit(1);
  }
  const base = (process.env.PLANE_BASE_URL || "https://api.plane.so").replace(/\/+$/, "");
  return {
    apiKey: process.env.PLANE_API_KEY,
    projectUrl: `${base}/api/v1/workspaces/${process.env.PLANE_WORKSPACE_SLUG}/projects/${process.env.PLANE_PROJECT_ID}`,
  };
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// fetch with retry on rate limit (Plane cloud: 60 req/min) and transient 5xx.
async function send(url, init, attempt = 1) {
  const res = await fetch(url, init);
  if ((res.status === 429 || res.status >= 500) && attempt <= 5) {
    const retryAfter = Number(res.headers.get("retry-after"));
    const reset = Number(res.headers.get("x-ratelimit-reset"));
    let wait = 2 ** attempt * 1000;
    if (retryAfter > 0) wait = retryAfter * 1000;
    else if (reset > 0) wait = Math.max(1000, reset * 1000 - Date.now());
    console.warn(`  … ${res.status}, retrying in ${Math.round(wait / 1000)}s`);
    await sleep(wait);
    return send(url, init, attempt + 1);
  }
  return res;
}

async function api(cfg, method, pathname, body) {
  const res = await send(`${cfg.projectUrl}${pathname}`, {
    method,
    headers: { "X-API-Key": cfg.apiKey, "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${method} ${pathname} → ${res.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

function createWorkItem(cfg, item, parentId) {
  return api(cfg, "POST", "/work-items/", {
    name: item.name,
    description_html: item.descriptionHtml,
    priority: item.priority,
    ...(parentId ? { parent: parentId } : {}),
    external_source: EXTERNAL_SOURCE,
    external_id: item.externalId,
  });
}

async function attachImage(cfg, workItemId, relPath) {
  const filePath = path.join(SOURCE_DIR, relPath);
  const buffer = await fsp.readFile(filePath);
  const name = path.basename(filePath);
  const type = name.endsWith(".png") ? "image/png" : "image/jpeg";

  // 1. presigned upload credentials
  const creds = await api(cfg, "POST", `/work-items/${workItemId}/attachments/`, {
    name,
    type,
    size: buffer.length,
  });
  const upload = creds?.upload_data;
  const assetId = creds?.asset_id ?? creds?.attachment?.id;
  if (!upload?.url || !upload?.fields || !assetId) {
    throw new Error(`Unexpected attachment response: ${JSON.stringify(creds)}`);
  }

  // 2. upload to storage — policy fields first, file last
  const form = new FormData();
  for (const [k, v] of Object.entries(upload.fields)) form.append(k, v);
  form.append("file", new Blob([buffer], { type }), name);
  const res = await send(upload.url, { method: "POST", body: form });
  if (!res.ok) throw new Error(`Storage upload ${name} → ${res.status}: ${await res.text()}`);

  // 3. mark as uploaded
  await api(cfg, "PATCH", `/work-items/${workItemId}/attachments/${assetId}/`, { is_uploaded: true });
}

// ---------------------------------------------------------------- run

async function sync(cfg, state, item, parentId) {
  let entry = state[item.externalId];
  let created = false;
  if (!entry) {
    const wi = await createWorkItem(cfg, item, parentId);
    entry = state[item.externalId] = { workItemId: wi.id, sequenceId: wi.sequence_id, attachments: [] };
    await saveState(state);
    created = true;
  }

  let uploaded = 0;
  for (const img of item.images) {
    if (entry.attachments.includes(img.file)) continue;
    await attachImage(cfg, entry.workItemId, img.file);
    entry.attachments.push(img.file);
    await saveState(state);
    uploaded++;
  }

  const mark = created || uploaded ? "✓" : "=";
  const imgs = item.images.length ? ` (${uploaded}/${item.images.length} image${item.images.length > 1 ? "s" : ""} uploaded)` : "";
  console.log(`${mark} ${item.name} → #${entry.sequenceId ?? entry.workItemId}${imgs}`);
  return entry.workItemId;
}

async function main() {
  const groups = parse(await fsp.readFile(SOURCE_HTML, "utf8"));

  if (DRY_RUN) {
    let children = 0;
    let images = 0;
    for (const { parent, children: kids } of groups) {
      console.log(`\n${parent.name}  [${parent.externalId}]`);
      for (const c of kids) {
        const missing = c.images.filter((img) => !fs.existsSync(path.join(SOURCE_DIR, img.file)));
        console.log(
          `  ${c.priority === "high" ? "!" : "-"} ${c.name}  [${c.externalId}]` +
            (c.images.length ? `  +${c.images.length} img` : "") +
            (missing.length ? `  MISSING: ${missing.map((m) => m.file).join(", ")}` : ""),
        );
        children++;
        images += c.images.length;
      }
    }
    console.log(`\n${groups.length} parents, ${children} children, ${images} images`);
    return;
  }

  const cfg = config();
  const state = loadState();
  for (const { parent, children } of groups) {
    const parentId = await sync(cfg, state, parent);
    for (const child of children) await sync(cfg, state, child, parentId);
  }
  console.log("\nDone.");
}

main().catch((err) => {
  console.error(`\n✗ ${err.message}`);
  console.error("Progress saved; rerun to resume.");
  process.exit(1);
});
