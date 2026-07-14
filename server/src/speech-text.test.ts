import assert from "node:assert/strict";
import test from "node:test";
import { parseHTML } from "linkedom";
import { removeVisualElements, speechText } from "./speech-text.js";

test("removes visual-only elements before extraction", () => {
  const { document } = parseHTML("<article><p>Keep me.</p><svg><text>Do not narrate me</text></svg><canvas>chart</canvas></article>");
  removeVisualElements(document);
  assert.equal(document.querySelector("article")?.textContent, "Keep me.");
});

test("removes code and residual SVG markup from speech text", () => {
  const markdown = "Before.\n```js\nconsole.log('no');\n```\n<svg><rect x=\"1\"><title>chart data</title></rect></svg>\nAfter.";
  assert.equal(speechText(markdown), "Before.\n\nAfter.");
});

test("turns markdown tables into labelled sentences", () => {
  const markdown = "| Language | Cleanup |\n| --- | --- |\n| Zig | defer |\n| Rust | Drop |";
  assert.equal(speechText(markdown), "Language: Zig; Cleanup: defer.\nLanguage: Rust; Cleanup: Drop.");
});
