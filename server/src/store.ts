import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import type { StoredArticle } from "./types.js";

export class ArticleStore {
  readonly root: string;
  private records = new Map<string, StoredArticle>();

  constructor(root = ".data") {
    this.root = path.resolve(root);
  }

  async load() {
    await mkdir(path.join(this.root, "audio"), { recursive: true });
    try {
      const items = JSON.parse(await readFile(path.join(this.root, "articles.json"), "utf8")) as StoredArticle[];
      this.records = new Map(items.map((item) => [item.id, item]));
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
    }
  }

  list() {
    return [...this.records.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  get(id: string) {
    return this.records.get(id);
  }

  async put(article: StoredArticle) {
    this.records.set(article.id, article);
    await this.persist();
    return article;
  }

  async delete(id: string) {
    const deleted = this.records.delete(id);
    if (deleted) await this.persist();
    return deleted;
  }

  private async persist() {
    const destination = path.join(this.root, "articles.json");
    const temporary = `${destination}.tmp`;
    await writeFile(temporary, JSON.stringify(this.list(), null, 2));
    await rename(temporary, destination);
  }
}
