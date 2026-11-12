// Configurazione di marked: id dei titoli, indice, colori del codice, formule e diagrammi.
(function () {
  var slugOccurrences = {};
  var headings = [];
  var flags = { math: false, mermaid: false };

  function escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function decodeHtml(s) {
    return s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
      .replace(/&#(\d+);/g, function (_, n) { return String.fromCodePoint(+n); })
      .replace(/&#x([0-9a-f]+);/gi, function (_, n) { return String.fromCodePoint(parseInt(n, 16)); })
      .replace(/&amp;/g, '&');
  }
  // Stesso algoritmo di GitHub (github-slugger): ogni spazio diventa un trattino,
  // quindi "Pro & contro" → "pro--contro"; i duplicati diventano "-1", "-2", …
  function slugify(s) {
    var base = s.toLowerCase().replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, '').replace(/ /g, '-');
    var slug = base;
    while (Object.prototype.hasOwnProperty.call(slugOccurrences, slug)) {
      slugOccurrences[base]++;
      slug = base + '-' + slugOccurrences[base];
    }
    slugOccurrences[slug] = 0;
    return slug;
  }
  function tex(src, display) {
    flags.math = true;
    try {
      return katex.renderToString(src, { displayMode: display, throwOnError: false, output: 'html' });
    } catch (e) {
      return '<code>' + escapeHtml(src) + '</code>';
    }
  }

  marked.use({
    gfm: true,
    extensions: [
      {
        name: 'mathBlock',
        level: 'block',
        start: function (src) { var i = src.indexOf('$$'); return i < 0 ? undefined : i; },
        tokenizer: function (src) {
          var m = /^\$\$([\s\S]+?)\$\$[ \t]*(?:\n|$)/.exec(src);
          if (m) return { type: 'mathBlock', raw: m[0], text: m[1].trim() };
        },
        renderer: function (t) { return '<div class="math-block">' + tex(t.text, true) + '</div>\n'; }
      },
      {
        name: 'mathInline',
        level: 'inline',
        start: function (src) { var i = src.indexOf('$'); return i < 0 ? undefined : i; },
        tokenizer: function (src) {
          var m = /^\$\$([^$]+?)\$\$/.exec(src);
          if (m) return { type: 'mathInline', raw: m[0], text: m[1].trim(), display: true };
          // $...$ come in Pandoc: niente spazi subito dentro i $, e dopo il $ di chiusura
          // niente lettere o cifre (così "5$ e 3$" e "$HOME/$USER" restano testo).
          m = /^\$(?![\s$])((?:\\.|[^\\$\n])+?)(?<![\s\\])\$(?![\p{L}\p{N}])/u.exec(src);
          if (m) return { type: 'mathInline', raw: m[0], text: m[1], display: false };
        },
        renderer: function (t) { return tex(t.text, t.display); }
      }
    ],
    renderer: {
      heading: function (token) {
        var inner = this.parser.parseInline(token.tokens);
        var plain = decodeHtml(inner.replace(/<[^>]*>/g, '')).trim();
        var id = slugify(plain);
        headings.push({ level: token.depth, text: plain, id: id });
        return '<h' + token.depth + ' id="' + id + '">' + inner + '</h' + token.depth + '>\n';
      },
      code: function (token) {
        var lang = (token.lang || '').trim().split(/\s+/)[0].toLowerCase();
        if (lang === 'mermaid') {
          flags.mermaid = true;
          return '<pre class="mermaid">' + escapeHtml(token.text) + '</pre>\n';
        }
        var body;
        if (lang && hljs.getLanguage(lang)) {
          try { body = hljs.highlight(token.text, { language: lang, ignoreIllegals: true }).value; } catch (e) {}
        }
        if (body === undefined) body = escapeHtml(token.text);
        var cls = lang ? ' language-' + escapeHtml(lang) : '';
        return '<pre><code class="hljs' + cls + '">' + body + '\n</code></pre>\n';
      }
    }
  });

  // Codice HTML colorato riga per riga: ogni riga è un elemento (per i numeri di riga) e la riga
  // in cui inizia un titolo ha un'àncora "src-<id>", così l'indice porta anche lì.
  globalThis.highlightHTMLSource = function (html) {
    var lines = html.replace(/\n$/, '').split('\n');
    return lines.map(function (line) {
      var m = /^<h[1-6] id="([^"]*)"/.exec(line);
      var anchor = m ? ' id="src-' + m[1] + '"' : '';
      var code = line ? hljs.highlight(line, { language: 'xml', ignoreIllegals: true }).value : '';
      return '<span class="line"' + anchor + '>' + code + '</span>';
    }).join('');
  };

  globalThis.renderMarkdown = function (src) {
    slugOccurrences = {};
    headings = [];
    flags = { math: false, mermaid: false };
    src = src.replace(/^﻿/, '');
    // Front matter YAML: solo se la prima riga dopo "---" è del tipo "chiave: valore",
    // così una linea orizzontale a inizio documento non fa sparire il testo.
    src = src.replace(/^---[ \t]*\r?\n(?=[\w"'-][^\n]*:)[\s\S]*?\r?\n(?:---|\.\.\.)[ \t]*(?:\r?\n|$)/, '');
    var html = marked.parse(src);
    return JSON.stringify({ html: html, headings: headings, math: flags.math, mermaid: flags.mermaid });
  };
})();
