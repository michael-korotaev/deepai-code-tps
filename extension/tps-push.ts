// tps-push.ts — расширение pi: отправляет живые метрики генерации в tps-hub.
// Ставится в <agent-dir>/extensions/tps-push.ts, ничего не патчит и не меняет
// провайдера. Если хаб не запущен — молча ничего не делает.
//
// Протокол (POST /__ingest):
//   {kind:"session", src, model}
//   {kind:"start",   src, model}
//   {kind:"delta",   src, model, chars, wide}
//   {kind:"end",     src, usage:{input,output}}

import type { ExtensionAPI, AgentMessage } from "@earendil-works/pi-coding-agent";
import * as http from "node:http";
import * as https from "node:https";
import { randomUUID } from "node:crypto";

const HUB_URL = process.env.TPS_HUB_URL ?? "http://127.0.0.1:57451";
const FLUSH_MS = 80;

export default async function (pi: ExtensionAPI) {
  const agent = new http.Agent({ keepAlive: true, maxSockets: 4 });
  const src = randomUUID();
  const hub = new URL(HUB_URL);
  const isHttps = hub.protocol === "https:";

  let currentModel: string | null = null;
  let pendingChars = 0;
  let pendingWide = 0;
  let lastFlush = 0;
  let perBlock: number[] = [];

  function send(body: Record<string, unknown>) {
    const payload = Buffer.from(JSON.stringify({ src, ...body }), "utf8");
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
      /* хаб недоступен — не мешаем агенту */
    }
  }

  function flush(force = false) {
    if (!pendingChars && !pendingWide) return;
    const now = Date.now();
    if (!force && now - lastFlush < FLUSH_MS) return;
    lastFlush = now;
    send({ kind: "delta", model: currentModel, chars: pendingChars, wide: pendingWide });
    pendingChars = 0;
    pendingWide = 0;
  }

  function wideCount(s: string) {
    let n = 0;
    for (const ch of s) if (ch.codePointAt(0)! >= 128) n += 1;
    return n;
  }

  // Текст и размышления: считаем прирост по каждому блокy сообщения.
  function trackMessage(message: AgentMessage) {
    const content = (message as any)?.content;
    if (!Array.isArray(content)) return;
    for (let i = 0; i < content.length; i += 1) {
      const block = content[i];
      let value: string | undefined;
      if (block?.type === "text") value = block.text;
      else if (block?.type === "thinking") value = block.thinking;
      if (typeof value !== "string") continue;
      const prev = perBlock[i] ?? 0;
      if (value.length > prev) {
        const slice = value.slice(prev);
        pendingChars += slice.length;
        pendingWide += wideCount(slice);
      }
      perBlock[i] = value.length;
    }
  }

  pi.on("session_start", (_event, ctx) => {
    currentModel = (ctx.model as any)?.id ?? currentModel;
    send({ kind: "session", model: currentModel });
  });

  pi.on("message_start", (event) => {
    const message = event.message as any;
    if (message?.role !== "assistant") return;
    currentModel = message.model ?? currentModel;
    perBlock = [];
    pendingChars = 0;
    pendingWide = 0;
    lastFlush = 0;
    send({ kind: "start", model: currentModel });
  });

  pi.on("message_update", (event) => {
    trackMessage(event.message);
    flush();
  });

  pi.on("message_end", (event) => {
    const message = event.message as any;
    if (message?.role !== "assistant") return;
    trackMessage(event.message);
    flush(true);
  });

  pi.on("agent_end", (event) => {
    flush(true);
    const messages = event.messages ?? [];
    let usage: { input?: number; output?: number } | undefined;
    for (let i = messages.length - 1; i >= 0; i -= 1) {
      const message = messages[i] as any;
      if (message?.role === "assistant" && message.usage) {
        usage = { input: message.usage.input, output: message.usage.output };
        break;
      }
    }
    send({ kind: "end", usage });
  });

  pi.on("session_shutdown", () => {
    flush(true);
    agent.destroy();
  });
}
