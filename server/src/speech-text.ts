const splitTableRow = (line: string) => line
  .trim()
  .replace(/^\||\|$/g, "")
  .split("|")
  .map((cell) => cell.trim());

const tableSeparator = (line: string) => splitTableRow(line)
  .every((cell) => /^:?-{3,}:?$/.test(cell));

const makeTablesListenable = (markdown: string) => {
  const lines = markdown.split("\n");
  const output: string[] = [];

  for (let index = 0; index < lines.length; index++) {
    const headerLine = lines[index]!;
    const separatorLine = lines[index + 1];
    if (!headerLine.includes("|") || !separatorLine?.includes("|") || !tableSeparator(separatorLine)) {
      output.push(headerLine);
      continue;
    }

    const headers = splitTableRow(headerLine);
    index += 1;
    while (index + 1 < lines.length && lines[index + 1]!.includes("|")) {
      const cells = splitTableRow(lines[++index]!);
      const description = cells
        .map((cell, cellIndex) => cell ? `${headers[cellIndex] || `Column ${cellIndex + 1}`}: ${cell}` : "")
        .filter(Boolean)
        .join("; ");
      if (description) output.push(`${description}.`);
    }
  }

  return output.join("\n");
};

export const removeVisualElements = (document: Document) => {
  document
    .querySelectorAll("svg, canvas, script, style, template, noscript, iframe, object, embed")
    .forEach((element) => element.remove());
};

export const speechText = (markdown: string) => makeTablesListenable(markdown)
  .replace(/```[\s\S]*?```/g, "")
  .replace(/<svg\b[\s\S]*?<\/svg\s*>?/gi, "")
  .replace(/<(?:script|style|template|noscript|canvas|iframe|object|embed)\b[\s\S]*?<\/(?:script|style|template|noscript|canvas|iframe|object|embed)\s*>?/gi, "")
  .replace(/<\/?[a-z][^>\n]*(?:>|$)/gi, "")
  .replace(/!\[[^\]]*\]\([^)]*\)/g, "")
  .replace(/\[([^\]]+)\]\([^)]*\)/g, "$1")
  .replace(/^#{1,6}\s+/gm, "")
  .replace(/[*_>`~]/g, "")
  .replace(/[ \t]+\n/g, "\n")
  .replace(/\n{3,}/g, "\n\n")
  .trim();
