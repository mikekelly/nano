// Readable extraction of an HTML document: Mozilla Readability over jsdom, falling back to
// a plain tag-strip. Usage: node extract.js < input.html  ->  JSON {title, text, excerpt, byline}
const { JSDOM } = require("jsdom");

let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => {
  let out = { title: "", text: "", excerpt: "", byline: "" };
  try {
    const dom = new JSDOM(input, { url: "https://example.invalid/" });
    const { Readability } = require("@mozilla/readability");
    const article = new Readability(dom.window.document).parse();
    if (article) {
      out = {
        title: article.title || "",
        text: article.textContent || "",
        excerpt: article.excerpt || "",
        byline: article.byline || "",
      };
    }
  } catch (e) {
    out.error = String(e);
  }
  if (!out.text) {
    // Plain fallback: strip script/style, drop tags, collapse whitespace.
    out.text = input
      .replace(/<script[\s\S]*?<\/script>/gi, " ")
      .replace(/<style[\s\S]*?<\/style>/gi, " ")
      .replace(/<[^>]+>/g, " ")
      .replace(/&nbsp;/g, " ")
      .replace(/&amp;/g, "&")
      .replace(/&lt;/g, "<")
      .replace(/&gt;/g, ">")
      .replace(/\s+/g, " ")
      .trim();
  }
  process.stdout.write(JSON.stringify(out));
});
