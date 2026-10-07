#!/usr/bin/env node
// HTML -> readable Markdown for Nano.Web. Takes a file path (never stdin: a Node process reading
// piped stdin blocks under the eval group leader, which never EOFs).
//
// Two extractors, in order of quality on this container's Node 20:
//   1. @postlight/parser (Mercury) - pure JS, no jsdom; gives clean article markdown.
//   2. html2text over a chrome-stripped body - always available, good enough.
// jsdom + Readability is tried last, because Debian's jsdom/undici pair fails to load here.
const fs = require('fs');
const html = fs.readFileSync(process.argv[2], 'utf8');
const url = process.argv[3] || 'about:blank';

function stripChrome(s) {
  return s
    .replace(/<script[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style[\s\S]*?<\/style>/gi, ' ')
    .replace(/<noscript[\s\S]*?<\/noscript>/gi, ' ')
    .replace(/<svg[\s\S]*?<\/svg>/gi, ' ')
    .replace(/<template[\s\S]*?<\/template>/gi, ' ')
    .replace(/<nav[\s\S]*?<\/nav>/gi, ' ')
    .replace(/<footer[\s\S]*?<\/footer>/gi, ' ')
    .replace(/<header[\s\S]*?<\/header>/gi, ' ')
    .replace(/<form[\s\S]*?<\/form>/gi, ' ')
    .replace(/<aside[\s\S]*?<\/aside>/gi, ' ');
}

function toMarkdown(s) {
  try { return require('html2text')(s); } catch (e) {}
  try { return require('html2text').html2text(s); } catch (e) {}
  return s.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();
}

function main() {
  // 1. Mercury/Postlight: best article text, no browser.
  try {
    const Parser = require('@postlight/parser');
    const p = Parser.parse(url, { html: html, contentType: 'text/html' });
    if (p && typeof p.then === 'function') {
      return p.then(r => {
        if (r && r.content && r.content.length > 500) return emit(r.content);
        next();
      }).catch(() => next());
    }
    if (p && p.content && p.content.length > 500) return emit(p.content);
  } catch (e) { /* next */ }

  next();

  function next() {
    // 2. jsdom + Readability, if that pair loads.
    try {
      const { JSDOM } = require('jsdom');
      const { Readability } = require('@mozilla/readability');
      const dom = new JSDOM(html, { url });
      const a = new Readability(dom.window.document).parse();
      if (a && a.content && a.content.length > 500) return emit(a.content);
    } catch (e) { /* next */ }
    // 3. Strip the obvious chrome, then html2text.
    emit(stripChrome(html));
  }

  function emit(s) {
    process.stdout.write(toMarkdown(s));
  }
}

main();
