// tps-hub.mjs — приёмник метрик скорости генерации: dsh-плагин (dsh/tps-push.mjs)
// и pi-расширение (extension/tps-push.js).
// Слушает только 127.0.0.1 и отдаёт:
//   POST /__ingest   — {kind:"session"|"start"|"delta"|"end", src, model, chars, wide}
//   GET  /__tps/state — JSON для оверлея
//   GET  /__tps/      — HTML-дашборд
//
// Запуск: node tps-hub.mjs [--port 57451]

import http from "node:http";

const argv = process.argv.slice(2);
const argOf = (name, fallback) => {
  const i = argv.indexOf(name);
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback;
};

const PORT = Number(argOf("--port", process.env.TPS_PORT ?? 57451));
const WINDOW_MS = Number(process.env.TPS_WINDOW_MS ?? 1200);
const IDLE_TIMEOUT_MS = 20000;

// token-оценка: латиница ~3.8 симв./токен, кириллица/CJK ~1.6
const tokensFrom = (chars, wide) => {
  const ascii = Math.max(0, chars - wide);
  return ascii / 3.8 + wide / 1.6;
};

/** src -> живой замер */
const turnsBySrc = new Map();
const finished = [];

function newTurn(src, model) {
  return {
    src,
    model: model ?? null,
    startedAt: Date.now(),
    firstTokenAt: 0,
    lastTokenAt: 0,
    tokens: 0,
    chars: 0,
    chunks: 0,
    points: [],
    usage: null,
  };
}

function recompute(turn, now = Date.now()) {
  const from = now - WINDOW_MS;
  let sum = 0;
  let firstT = 0;
  for (let i = turn.points.length - 1; i >= 0; i -= 1) {
    const p = turn.points[i];
    if (p.t < from) break;
    sum += p.tokens;
    firstT = p.t;
  }
  if (turn.points.length > 4000) turn.points = turn.points.slice(-2000);
  const span = firstT ? now - firstT : 0;
  turn.tps = span > 120 ? sum / (span / 1000) : 0;
  const genMs = turn.firstTokenAt ? now - turn.firstTokenAt : 0;
  turn.avgTps = genMs > 150 ? turn.tokens / (genMs / 1000) : 0;
  turn.ttftMs = turn.firstTokenAt ? turn.firstTokenAt - turn.startedAt : null;
}

function finishTurn(src, usage) {
  const turn = turnsBySrc.get(src);
  if (!turn) return;
  turnsBySrc.delete(src);
  const now = Date.now();
  recompute(turn, now);
  const genMs = turn.firstTokenAt ? now - turn.firstTokenAt : 0;
  const record = {
    model: turn.model,
    tokens: Math.round(turn.tokens * 10) / 10,
    avgTps: genMs > 150 ? Math.round((turn.tokens / (genMs / 1000)) * 10) / 10 : null,
    ttftMs: turn.ttftMs,
    genMs,
    promptTokens: usage?.input ?? null,
    completionTokens: usage?.output ?? null,
    finishedAt: new Date(now).toISOString(),
  };
  if (record.tokens > 0.5) {
    finished.unshift(record);
    if (finished.length > 40) finished.length = 40;
  }
}

function ingest(body) {
  if (process.env.TPS_DEBUG) console.log(new Date().toISOString(), body?.kind, body?.model, body?.chars, body?.usage ? JSON.stringify(body.usage) : '');
  ingestCount += 1;
  lastIngest = { at: new Date().toISOString(), kind: body?.kind, model: body?.model, src: body?.src };
  const src = String(body.src ?? "default");
  const kind = String(body.kind ?? "");
  const model = body.model ? String(body.model) : null;

  if (kind === "session") {
    // пинг источника: модель намеренно не трогаем — иначе в простое висит
    // устаревшее имя модели от другого рантайма (pi/dsh)
    return;
  }
  if (kind === "start") {
    turnsBySrc.set(src, newTurn(src, model));
    return;
  }
  if (kind === "delta") {
    let turn = turnsBySrc.get(src);
    if (!turn) turn = turnsBySrc.set(src, newTurn(src, model)).get(src);
    const chars = Number(body.chars ?? 0);
    const wide = Number(body.wide ?? 0);
    if (chars <= 0) return;
    const now = Date.now();
    if (!turn.firstTokenAt) turn.firstTokenAt = now;
    turn.lastTokenAt = now;
    turn.chars += chars;
    turn.chunks += 1;
    turn.tokens += tokensFrom(chars, wide);
    turn.points.push({ t: now, tokens: tokensFrom(chars, wide) });
    if (model) turn.model = model;
    recompute(turn, now);
    return;
  }
  if (kind === "end") {
    finishTurn(src, body.usage);
  }
}

let lastModel = null;
let ingestCount = 0;
let lastIngest = null;

function snapshot() {
  const now = Date.now();
  // чистим зависшие замеры
  for (const [src, turn] of turnsBySrc) {
    const last = turn.lastTokenAt || turn.startedAt;
    if (now - last > IDLE_TIMEOUT_MS) finishTurn(src, null);
  }

  const active = [...turnsBySrc.values()].sort(
    (a, b) => (b.lastTokenAt || b.startedAt) - (a.lastTokenAt || a.startedAt),
  );
  const top = active[0] ?? null;
  if (top?.model) lastModel = top.model;

  const record = finished[0] ?? null;
  if (!top) {
    return {
      model: lastModel,
      active: false,
      tps: 0,
      avgTps: 0,
      ttftMs: record?.ttftMs ?? null,
      tokens: 0,
      firstTokenAt: 0,
      lastTokenAt: 0,
      activeTurns: 0,
      turns: finished.slice(0, 20),
      updatedAt: now,
    };
  }
  recompute(top, now);
  return {
    model: top.model,
    active: true,
    tps: top.tps,
    avgTps: top.avgTps,
    ttftMs: top.ttftMs,
    tokens: top.tokens,
    firstTokenAt: top.firstTokenAt,
    lastTokenAt: top.lastTokenAt,
    activeTurns: active.length,
    turns: finished.slice(0, 20),
    updatedAt: now,
  };
}

const DASHBOARD = `<!doctype html><html lang="ru"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DeepAI Code — TPS</title>
<style>
 :root{color-scheme:dark}
 body{margin:0;font:14px/1.4 ui-sans-serif,system-ui,"Segoe UI",sans-serif;background:#101216;color:#e8eaf0;
      display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;gap:14px}
 #tps{font-size:96px;font-weight:700;font-variant-numeric:tabular-nums;letter-spacing:-2px}
 #tps small{font-size:24px;font-weight:400;opacity:.55;margin-left:8px}
 #bar{width:min(560px,80vw);height:6px;border-radius:3px;background:#232833;overflow:hidden}
 #bar>i{display:block;height:100%;width:0;background:#00ff88;transition:width .15s linear}
 #meta{display:flex;gap:22px;flex-wrap:wrap;justify-content:center;opacity:.8;font-variant-numeric:tabular-nums}
 #meta b{font-weight:600;color:#fff}
 #model{opacity:.5;font-size:12px;letter-spacing:.08em;text-transform:uppercase}
 #log{width:min(760px,92vw);max-height:32vh;overflow:auto;font:12px/1.5 ui-monospace,monospace;opacity:.75}
 #log div{display:grid;grid-template-columns:1fr auto auto auto;gap:10px;padding:2px 0}
 #log div+div{border-top:1px solid #1c2029}
</style>
<div id="model">—</div>
<div id="tps">0<small>tok/s</small></div>
<div id="bar"><i></i></div>
<div id="meta">
 <span>avg <b id="avg">—</b></span>
 <span>TTFT <b id="ttft">—</b></span>
 <span>tok <b id="tokens">0</b></span>
 <span>gen <b id="gen">—</b></span>
</div>
<div id="log"></div>
<script>
const $=(id)=>document.getElementById(id);
const color=(v)=>v>=45?"#44ddff":v>=30?"#00ff88":v>=15?"#ffaa00":v>0?"#ff4444":"#3a4050";
const fmt=(ms)=>ms==null?"—":ms<1000?Math.round(ms)+" ms":(ms/1000).toFixed(2)+" s";
async function tick(){
  try{
    const s=await (await fetch("/__tps/state",{cache:"no-store"})).json();
    const v=s.active?s.tps:0;
    $("tps").innerHTML=(v?v.toFixed(1):"0")+"<small>tok/s</small>";
    $("tps").style.color=color(v);
    $("bar").firstElementChild.style.width=Math.min(100,v/60*100)+"%";
    $("bar").firstElementChild.style.background=color(v);
    $("avg").textContent=s.avgTps?s.avgTps.toFixed(1):"—";
    $("ttft").textContent=fmt(s.ttftMs);
    $("tokens").textContent=s.active?Math.round(s.tokens):"—";
    $("gen").textContent=s.active&&s.firstTokenAt?fmt(Date.now()-s.firstTokenAt):"—";
    $("model").textContent=(s.model??"—")+(s.active?"":" · idle")+(s.activeTurns>1?" · "+s.activeTurns+" потоков":"");
    $("log").innerHTML=s.turns.map(t=>"<div><span>"+t.finishedAt.slice(11,19)+" "+(t.model??"")+"</span><span>"+(t.avgTps??"—")+" tok/s</span><span>TTFT "+fmt(t.ttftMs)+"</span><span>"+t.tokens+" tok</span></div>").join("");
  }catch(e){ $("model").textContent="хаб не запущен"; }
  setTimeout(tick,250);
}
tick();
</script></html>`;

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size <= 1_000_000) chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
  });
}

const server = http.createServer(async (req, res) => {
  const path = req.url ?? "/";

  if (req.method === "POST" && path.startsWith("/__ingest")) {
    const raw = await readBody(req);
    res.writeHead(204, { "access-control-allow-origin": "*" });
    res.end();
    try {
      ingest(JSON.parse(raw));
    } catch {
      /* мусор игнорируем */
    }
    return;
  }

  if (path.startsWith("/__tps/state")) {
    res.writeHead(200, {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "access-control-allow-origin": "*",
    });
    res.end(JSON.stringify({ ...snapshot(), port: PORT, windowMs: WINDOW_MS, ingestCount, lastIngest }));
    return;
  }

  if (path.startsWith("/__tps")) {
    res.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
    res.end(DASHBOARD);
    return;
  }

  res.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
  res.end("tps-hub: используйте /__tps/ или POST /__ingest");
});

server.listen(PORT, "127.0.0.1", () => {
  console.log(`tps-hub: http://127.0.0.1:${PORT}/__tps/`);
});
