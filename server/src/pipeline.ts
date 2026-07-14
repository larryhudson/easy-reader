import path from "node:path";
import { chromium } from "playwright";
import { parseHTML } from "linkedom";
import { Defuddle } from "defuddle/node";
import type { StoredArticle } from "./types.js";
import { ArticleStore } from "./store.js";
import { configuredTTSProvider, synthesizeArticle } from "./openai-tts.js";
import { cleanTextForAudio } from "./cleanup.js";
import { removeVisualElements, speechText } from "./speech-text.js";

export async function processArticle(store: ArticleStore, original: StoredArticle) {
  let article = original;
  const update = async (changes: Partial<StoredArticle>) => {
    article = { ...article, ...changes, updatedAt: new Date().toISOString() };
    await store.put(article);
  };

  try {
    const sourceType = article.sourceType ?? (article.url ? "url" : "text");
    let text: string;
    if (sourceType === "url") {
      if (!article.url) throw new Error("The article URL is missing.");
      await update({ status: "rendering" });
      const browser = await chromium.launch({ headless: true });
      let html: string;
      try {
        const page = await browser.newPage();
        await page.goto(article.url, { waitUntil: "domcontentloaded", timeout: 45_000 });
        await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => undefined);
        html = await page.content();
      } finally {
        await browser.close();
      }

      await update({ status: "extracting" });
      const { document } = parseHTML(html);
      removeVisualElements(document);
      const result = await Defuddle(document, article.url, { markdown: true, useAsync: false });
      text = speechText(result.content);
      await update({
        title: result.title || new URL(article.url).hostname,
        author: result.author || undefined,
        site: result.site || result.domain || undefined,
        imageURL: result.image || undefined,
      });
    } else {
      await update({ status: "extracting" });
      text = speechText(article.sourceText ?? "");
    }
    if (text.length < 100) throw new Error("The page did not contain enough readable content.");
    await update({
      wordCount: text.split(/\s+/).length,
      text,
    });

    if (article.cleanupRequested) {
      await update({ status: "cleaning" });
      text = await cleanTextForAudio(text);
      if (text.length < 100) throw new Error("AI cleanup returned too little readable content.");
      await update({
        text,
        wordCount: text.split(/\s+/).length,
        cleanupCompleted: true,
      });
    }

    await update({ status: "speaking" });

    const ttsProvider = configuredTTSProvider();
    const audioPath = path.join(store.root, "audio", `${article.id}.${ttsProvider}.m4a`);
    await update({ ttsProvider });
    await synthesizeArticle(text, audioPath, async (audioChunksCompleted, audioChunksTotal) => {
      await update({ audioChunksCompleted, audioChunksTotal });
    });
    await update({ status: "ready", audioPath, audioURL: `/v1/articles/${article.id}/audio` });
  } catch (error) {
    await update({ status: "failed", error: error instanceof Error ? error.message : String(error) });
  }
}
