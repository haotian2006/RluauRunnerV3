const {
  TextCensor,
  RegExpMatcher,
  englishDataset,
  englishRecommendedTransformers,
} = require("obscenity");
const { FILTER_BAD_WORDS } = require("./config");

const Matcher = new RegExpMatcher({
  ...englishDataset.build(),
  ...englishRecommendedTransformers,
});
const Censor = new TextCensor();

function censorText(text) {
  if (!FILTER_BAD_WORDS) return text;
  const matches = Matcher.getAllMatches(text);
  return Censor.applyTo(text, matches);
}

function stripNoShowForExecution(code) {
  return code
    .replace(/--\[\[NO_SHOW\]\]\r?\n?/g, "")
    .replace(/--\[\[END\]\]\r?\n?/g, "");
}

function stripNoShowForDisplay(text) {
  return text
    .replace(/--\[\[NO_SHOW\]\][\s\S]*?--\[\[END\]\]/g, "")
    .replace(/--\[\[NO_EXECUTE\]\]\r?\n?/g, "")
    .replace(/--\[\[name:[^\]]*\]\]\r?\n?/g, "");
}

function extractDocCodeBlocks(markdown) {
  const results = [];
  const fence = /```(?:lua|luau)[^\n]*\n([\s\S]*?)```/g;
  let match;
  while ((match = fence.exec(markdown)) !== null) {
    let raw = match[1].trim();
    if (!raw) continue;
    if (raw.includes("--[[NO_EXECUTE]]")) continue;
    let label = "";
    const nameMatch = raw.match(/^--\[\[name:\s*(.+?)\]\]/);
    if (nameMatch) {
      label = nameMatch[1].trim();
      raw = raw.slice(raw.indexOf("\n") + 1).trim();
    } else {
      const before = markdown.slice(0, match.index);
      const lines = before.split("\n").map((l) => l.trim());
      for (let i = lines.length - 1; i >= 0; i--) {
        if (/^#+\s/.test(lines[i])) {
          label = lines[i];
          break;
        }
      }
      if (!label) {
        const nonEmpty = lines.filter((l) => l.length > 0);
        label = nonEmpty[nonEmpty.length - 1] || `Block ${results.length + 1}`;
      }
      label = label
        .replace(/^#+\s*/, "")
        .replace(/\*\*/g, "")
        .replace(/\*/g, "")
        .trim();
      label = label.split(" - ")[0].trim();
    }
    if (label.length > 80) label = label.slice(0, 77) + "...";
    const code = stripNoShowForExecution(raw);
    results.push({ code, label });
  }
  return results;
}

module.exports = { censorText, stripNoShowForDisplay, extractDocCodeBlocks };
