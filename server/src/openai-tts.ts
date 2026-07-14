import { spawn } from "node:child_process";
import { mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

const SAMPLE_RATE = 24_000;
const CHANNELS = 1;
const BITS_PER_SAMPLE = 16;

export function chunkText(text: string, maximum = 3500): string[] {
  if (maximum < 100) throw new Error("TTS chunk size must be at least 100 characters.");
  const paragraphs = text.split(/\n{2,}/).map((part) => part.trim()).filter(Boolean);
  const chunks: string[] = [];
  let current = "";
  const add = (part: string) => {
    if (!current) current = part;
    else if (current.length + part.length + 2 <= maximum) current += `\n\n${part}`;
    else { chunks.push(current); current = part; }
  };

  for (const paragraph of paragraphs) {
    if (paragraph.length <= maximum) { add(paragraph); continue; }
    const sentences = paragraph.match(/[^.!?]+(?:[.!?]+[”’"']?|$)/g) ?? [paragraph];
    for (const sentenceValue of sentences) {
      let sentence = sentenceValue.trim();
      while (sentence.length > maximum) {
        let split = sentence.lastIndexOf(" ", maximum);
        if (split < maximum * 0.6) split = maximum;
        add(sentence.slice(0, split).trim());
        sentence = sentence.slice(split).trim();
      }
      if (sentence) add(sentence);
    }
  }
  if (current) chunks.push(current);
  return chunks;
}

async function requestOpenAIPCM(input: string, apiKey: string): Promise<Buffer> {
  for (let attempt = 0; attempt < 3; attempt++) {
    const response = await fetch("https://api.openai.com/v1/audio/speech", {
      method: "POST",
      headers: { authorization: `Bearer ${apiKey}`, "content-type": "application/json" },
      body: JSON.stringify({
        model: process.env.OPENAI_TTS_MODEL || "tts-1-hd",
        voice: process.env.OPENAI_TTS_VOICE || "alloy",
        input,
        response_format: "pcm",
      }),
      signal: AbortSignal.timeout(120_000),
    });
    if (response.ok) return Buffer.from(await response.arrayBuffer());
    const detail = (await response.text()).slice(0, 500);
    const retryable = response.status === 429 || response.status >= 500;
    if (!retryable || attempt === 2) throw new Error(`OpenAI speech request failed (${response.status}): ${detail}`);
    const retryAfter = Number(response.headers.get("retry-after"));
    const delay = Number.isFinite(retryAfter) && retryAfter > 0 ? retryAfter * 1000 : 1000 * 2 ** attempt;
    await new Promise((resolve) => setTimeout(resolve, delay));
  }
  throw new Error("OpenAI speech request failed after retries.");
}

async function requestSpeechifyPCM(input: string, apiKey: string): Promise<Buffer> {
  for (let attempt = 0; attempt < 8; attempt++) {
    let response: Response;
    try {
      response = await fetch("https://api.speechify.ai/v1/audio/stream", {
        method: "POST",
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
          accept: "audio/pcm",
          "speechify-version": "2026-06-25",
        },
        body: JSON.stringify({
          input,
          model: process.env.SPEECHIFY_TTS_MODEL || "simba-3.2",
          voice_id: process.env.SPEECHIFY_TTS_VOICE || "geffen_32",
        }),
        signal: AbortSignal.timeout(600_000),
      });
      if (response.ok) return Buffer.from(await response.arrayBuffer());
    } catch (error) {
      if (attempt === 7) {
        const detail = error instanceof Error ? error.message : String(error);
        throw new Error(`Speechify speech request failed after 8 network/timeout attempts: ${detail}`, { cause: error });
      }
      const delay = 5_000 * (attempt + 1) + Math.random() * 2_000;
      await new Promise((resolve) => setTimeout(resolve, delay));
      continue;
    }
    const detail = (await response.text()).slice(0, 500);
    const retryable = response.status === 429 || response.status >= 500;
    const concurrencyLimited = response.status === 429 && detail.includes("concurrency_limit_reached");
    const lastAttempt = concurrencyLimited ? attempt === 7 : attempt === 2;
    if (!retryable || lastAttempt) throw new Error(`Speechify speech request failed (${response.status}): ${detail}`);
    const retryAfter = Number(response.headers.get("retry-after"));
    const resetAfter = Number(response.headers.get("ratelimit-reset"));
    const serverDelay = retryAfter || resetAfter;
    const fallbackDelay = concurrencyLimited
      ? 5_000 * (attempt + 1) + Math.random() * 2_000
      : 1_000 * 2 ** attempt;
    const reportedDelay = Number.isFinite(serverDelay) && serverDelay > 0 ? serverDelay * 1000 : 0;
    const delay = concurrencyLimited
      ? Math.max(reportedDelay, fallbackDelay)
      : reportedDelay || fallbackDelay;
    await new Promise((resolve) => setTimeout(resolve, delay));
  }
  throw new Error("Speechify speech request failed after retries.");
}

export function configuredTTSProvider() {
  const provider = (process.env.TTS_PROVIDER || "openai").toLowerCase();
  if (provider !== "openai" && provider !== "speechify") throw new Error(`Unsupported TTS_PROVIDER: ${provider}`);
  return provider as "openai" | "speechify";
}

function wavHeader(dataBytes: number) {
  const header = Buffer.alloc(44);
  header.write("RIFF", 0);
  header.writeUInt32LE(36 + dataBytes, 4);
  header.write("WAVEfmt ", 8);
  header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20);
  header.writeUInt16LE(CHANNELS, 22);
  header.writeUInt32LE(SAMPLE_RATE, 24);
  header.writeUInt32LE(SAMPLE_RATE * CHANNELS * BITS_PER_SAMPLE / 8, 28);
  header.writeUInt16LE(CHANNELS * BITS_PER_SAMPLE / 8, 32);
  header.writeUInt16LE(BITS_PER_SAMPLE, 34);
  header.write("data", 36);
  header.writeUInt32LE(dataBytes, 40);
  return header;
}

async function run(command: string, args: string[]) {
  await new Promise<void>((resolve, reject) => {
    const child = spawn(command, args);
    let stderr = "";
    child.stderr.on("data", (chunk) => { stderr += String(chunk); });
    child.on("error", reject);
    child.on("exit", (code) => code === 0 ? resolve() : reject(new Error(stderr || `${command} exited ${code}`)));
  });
}

export async function synthesizeArticle(
  text: string,
  destination: string,
  onProgress?: (completed: number, total: number) => Promise<void>,
) {
  const provider = configuredTTSProvider();
  const apiKey = provider === "speechify" ? process.env.SPEECHIFY_API_KEY : process.env.OPENAI_API_KEY;
  if (!apiKey) throw new Error(`${provider === "speechify" ? "SPEECHIFY_API_KEY" : "OPENAI_API_KEY"} is missing from server/.env`);
  const maximum = provider === "speechify"
    ? Math.min(19_000, Number(process.env.SPEECHIFY_TTS_CHUNK_CHARS || 18_000))
    : Math.min(3500, Number(process.env.OPENAI_TTS_CHUNK_CHARS || 3500));
  const chunks = chunkText(text, maximum);
  const working = `${destination}.parts`;
  await mkdir(working, { recursive: true });

  const files: string[] = [];
  let completed = 0;
  let progressWrite = Promise.resolve();
  const reportProgress = () => {
    progressWrite = progressWrite.then(() => onProgress?.(completed, chunks.length));
    return progressWrite;
  };
  await reportProgress();

  for (const index of chunks.keys()) {
    files.push(path.join(working, `${String(index).padStart(4, "0")}.pcm`));
  }
  const configuredConcurrency = provider === "speechify"
    ? process.env.SPEECHIFY_TTS_CONCURRENCY
    : process.env.OPENAI_TTS_CONCURRENCY;
  const defaultConcurrency = provider === "speechify" ? 1 : 10;
  const concurrency = Math.max(1, Math.min(10, Number(configuredConcurrency || defaultConcurrency)));
  let nextIndex = 0;
  const worker = async () => {
    while (nextIndex < chunks.length) {
      const index = nextIndex++;
      const file = files[index]!;
      const existing = await readFile(file).catch(() => undefined);
      if (!existing?.length) {
        const audio = provider === "speechify"
          ? await requestSpeechifyPCM(chunks[index]!, apiKey)
          : await requestOpenAIPCM(chunks[index]!, apiKey);
        await writeFile(file, audio);
      }
      completed += 1;
      await reportProgress();
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, chunks.length) }, () => worker()));

  const gapMilliseconds = Math.max(0, Number(process.env.TTS_GAP_MS || process.env.OPENAI_TTS_GAP_MS || 350));
  const gap = Buffer.alloc(Math.round(SAMPLE_RATE * CHANNELS * (BITS_PER_SAMPLE / 8) * gapMilliseconds / 1000));
  const audio = await Promise.all(files.map((file) => readFile(file)));
  const pieces = audio.flatMap((item, index) => index === audio.length - 1 ? [item] : [item, gap]);
  const pcm = Buffer.concat(pieces);
  const wav = `${destination}.wav`;
  await writeFile(wav, Buffer.concat([wavHeader(pcm.length), pcm]));
  try {
    if (process.platform === "darwin") {
      await run("afconvert", [wav, destination, "-f", "m4af", "-d", "aac", "-b", "64000"]);
    } else {
      await run("ffmpeg", ["-y", "-loglevel", "error", "-i", wav, "-c:a", "aac", "-b:a", "64k", destination]);
    }
  } finally {
    await Promise.all([unlink(wav).catch(() => undefined), ...files.map((file) => unlink(file).catch(() => undefined))]);
  }
}
