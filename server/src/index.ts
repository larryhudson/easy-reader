import "dotenv/config";
import Fastify from "fastify";
import cors from "@fastify/cors";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import { ArticleStore } from "./store.js";
import { processArticle } from "./pipeline.js";
import type { StoredArticle } from "./types.js";

const app = Fastify({ logger: true });
await app.register(cors, { origin: false });
const store = new ArticleStore(process.env.DATA_DIR);
await store.load();
for (const article of store.list()) {
  if (article.status !== "ready" && article.status !== "failed") void processArticle(store, article);
}

app.addHook("onRequest", async (request, reply) => {
  const token = process.env.API_TOKEN;
  if (!token || request.url === "/health") return;
  if (request.headers.authorization !== `Bearer ${token}`) return reply.code(401).send({ error: "Unauthorized" });
});

const publicArticle = (article: StoredArticle) => {
  const { text: _text, audioPath: _audioPath, ...result } = article;
  return result;
};

app.get("/health", async () => ({ ok: true }));
app.get("/v1/articles", async () => store.list().map(publicArticle));
app.get<{ Params: { id: string } }>("/v1/articles/:id", async (request, reply) => {
  const article = store.get(request.params.id);
  return article ? publicArticle(article) : reply.code(404).send({ error: "Not found" });
});

app.post("/v1/articles", async (request, reply) => {
  const urlSource = z.object({
    type: z.literal("url"),
    url: z.string().url().refine((value) => /^https?:$/.test(new URL(value).protocol), "A valid HTTP(S) URL is required"),
  });
  const textSource = z.object({
    type: z.literal("text"),
    text: z.string().trim().min(100).max(100_000),
    title: z.string().trim().min(1).max(200).optional(),
  });
  const modernRequest = z.object({
    source: z.discriminatedUnion("type", [urlSource, textSource]),
    cleanup: z.boolean().optional().default(false),
  });
  // Keep accepting the original shape while already-installed clients transition.
  const legacyRequest = z.object({ url: urlSource.shape.url });
  const parsed = z.union([modernRequest, legacyRequest]).safeParse(request.body);
  if (!parsed.success) {
    return reply.code(400).send({ error: "Provide an HTTP(S) URL or between 100 and 100,000 characters of text" });
  }
  const source = "source" in parsed.data
    ? parsed.data.source
    : { type: "url" as const, url: parsed.data.url };
  const cleanupRequested = "source" in parsed.data ? parsed.data.cleanup : false;
  const existing = source.type === "url"
    ? store.list().find((item) => item.url === source.url && item.status !== "failed" && Boolean(item.cleanupRequested) === cleanupRequested)
    : undefined;
  if (existing) return reply.code(200).send(publicArticle(existing));

  const now = new Date().toISOString();
  const article: StoredArticle = {
    id: randomUUID(),
    sourceType: source.type,
    url: source.type === "url" ? source.url : undefined,
    sourceText: source.type === "text" ? source.text : undefined,
    title: source.type === "text" ? source.title : undefined,
    cleanupRequested,
    cleanupCompleted: false,
    status: "queued",
    createdAt: now,
    updatedAt: now,
  };
  await store.put(article);
  void processArticle(store, article);
  return reply.code(202).send(publicArticle(article));
});

app.post<{ Params: { id: string } }>("/v1/articles/:id/retry", async (request, reply) => {
  const article = store.get(request.params.id);
  if (!article) return reply.code(404).send({ error: "Not found" });
  if (article.status !== "failed") return reply.code(409).send({ error: "Only failed articles can be retried" });
  const retried: StoredArticle = {
    ...article,
    status: "queued",
    error: undefined,
    cleanupCompleted: false,
    updatedAt: new Date().toISOString(),
  };
  await store.put(retried);
  void processArticle(store, retried);
  return reply.code(202).send(publicArticle(retried));
});

app.delete<{ Params: { id: string } }>("/v1/articles/:id", async (request, reply) => {
  const article = store.get(request.params.id);
  if (!article) return reply.code(404).send({ error: "Not found" });
  if (article.status === "queued" || article.status === "extracting" || article.status === "speaking") {
    return reply.code(409).send({ error: "Articles being processed cannot be deleted" });
  }
  await store.delete(article.id);
  return reply.code(204).send();
});

app.get<{ Params: { id: string } }>("/v1/articles/:id/audio", async (request, reply) => {
  const article = store.get(request.params.id);
  if (!article?.audioPath || article.status !== "ready") return reply.code(404).send({ error: "Audio is not ready" });
  const size = (await stat(article.audioPath)).size;
  const type = path.extname(article.audioPath) === ".aiff" ? "audio/aiff" : "audio/mp4";
  const range = request.headers.range?.match(/^bytes=(\d*)-(\d*)$/);
  reply.type(type)
    .header("accept-ranges", "bytes")
    .header("cache-control", "private, max-age=31536000, immutable");

  if (range) {
    const requestedStart = range[1] ? Number(range[1]) : 0;
    const requestedEnd = range[2] ? Number(range[2]) : size - 1;
    const start = Math.max(0, requestedStart);
    const end = Math.min(size - 1, requestedEnd);
    if (start > end || start >= size) {
      return reply.code(416).header("content-range", `bytes */${size}`).send();
    }
    reply.code(206)
      .header("content-range", `bytes ${start}-${end}/${size}`)
      .header("content-length", end - start + 1);
    return reply.send(createReadStream(article.audioPath, { start, end }));
  }

  reply.header("content-length", size);
  return reply.send(createReadStream(article.audioPath));
});

await app.listen({
  host: process.env.HOST || "127.0.0.1",
  port: Number(process.env.PORT || 8787),
});
