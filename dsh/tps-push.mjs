// tps-push.mjs — плагин dsh (cordis): живые метрики генерации в tps-hub.
// Ставится в <dsh-home>/profiles/<profile>/ и подключается из cordis.patch.yml.
// Ничего не патчит в модели: просто оборачивает поток чанков llm/stream.

import * as http from "node:http";
import * as https from "node:https";
import { randomUUID } from "node:crypto";

export const name = "tps-push";
export const inject = ["llm"];

const HUB_URL = process.env.TPS_HUB_URL ?? "http://127.0.0.1:57451";
const FLUSH_MS = 80;

const wideCount = (s) => {
  let n = 0;
  for (const ch of s) if (ch.codePointAt(0) >= 128) n += 1;
  return n;
};

export function apply(ctx) {
  const hub = new URL(HUB_URL);
  const isHttps = hub.protocol === "https:";
  const agent = new http.Agent({ keepAlive: true, maxSockets: 8 });
  const base = randomUUID();
  let calls = 0;
  let lastModel = null;

  function send(body) {
    let payload;
    try {
      payload = Buffer.from(JSON.stringify(body), "utf8");
    } catch {
      return;
    }
    try {
      const req = (isHttps ? https : http).request(
        {
          hostname: hub.hostname,
          port: hub.port || (isHttps ? 443 : 80),
          path: "/__ingest",
          method: "POST",
          agent: isHttps ? undefined : agent,
          headers: { "content-type": "application/json", "content-length": payload.length },
          timeout: 400,
        },
        (res) => res.resume(),
      );
      req.on("error", () => {});
      req.on("timeout", () => req.destroy());
      req.end(payload);
    } catch {
      /* хаб не запущен — молчим */
    }
  }

  // отметка «плагин жив»: оверлей сразу знает, что источник подключён
  send({ kind: "session", src: base, model: null });

  ctx.on("llm/stream", (options, next) => {
    const model = (options && options.model) || lastModel;
    if (model) lastModel = model;
    const src = `${base}:${++calls}`;
    let chars = 0;
    let wide = 0;
    let lastFlush = 0;
    let usage = null;

    function flush(force) {
      if (!chars && !wide) return;
      const now = Date.now();
      if (!force && now - lastFlush < FLUSH_MS) return;
      lastFlush = now;
      send({ kind: "delta", src, model, chars, wide });
      chars = 0;
      wide = 0;
    }

    return (async function* () {
      send({ kind: "start", src, model });
      try {
        const stream = next();
        for await (const chunk of stream) {
          if (!chunk) continue;
          if (chunk.type === "text-delta" || chunk.type === "reasoning-delta") {
            const text = typeof chunk.text === "string" ? chunk.text : "";
            if (text) {
              chars += text.length;
              wide += wideCount(text);
              flush(false);
            }
          } else if (chunk.type === "usage" && chunk.usage) {
            usage = {
              input: chunk.usage.inputTokens ?? null,
              output: chunk.usage.outputTokens ?? null,
            };
          }
          yield chunk;
        }
      } finally {
        flush(true);
        send({ kind: "end", src, usage });
      }
    })();
  });
}
