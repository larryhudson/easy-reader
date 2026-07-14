export type ArticleStatus = "queued" | "rendering" | "extracting" | "cleaning" | "speaking" | "ready" | "failed";
export type ArticleSourceType = "url" | "text";

export interface Article {
  id: string;
  sourceType?: ArticleSourceType;
  url?: string;
  title?: string;
  author?: string;
  site?: string;
  imageURL?: string;
  wordCount?: number;
  audioChunksCompleted?: number;
  audioChunksTotal?: number;
  ttsProvider?: string;
  status: ArticleStatus;
  error?: string;
  createdAt: string;
  updatedAt: string;
  audioURL?: string;
  cleanupRequested?: boolean;
  cleanupCompleted?: boolean;
}

export interface StoredArticle extends Article {
  sourceText?: string;
  text?: string;
  audioPath?: string;
}
