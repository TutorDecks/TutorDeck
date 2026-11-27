// Writes docs/centre-data-export-dictionary.md from the column list the export code uses (assets/js/org-export-core.js).
// Run:  node tests/gen-export-dictionary.js      (tests/org-export-core.test.js fails if the file is out of date)
const fs = require("node:fs"), path = require("node:path");
const X = require("../assets/js/org-export-core.js");
const out = path.join(__dirname, "..", "docs", "centre-data-export-dictionary.md");
fs.writeFileSync(out, X.dictionaryMarkdown() + "\n");
console.log("wrote " + path.relative(process.cwd(), out));
