// Tiny static file server for the repo root, so index.html and the test pages share one
// localhost origin (camera access needs a secure context, and localhost counts as one).
"use strict";
const http = require("http"), fs = require("fs"), path = require("path");
const ROOT = path.resolve(__dirname, "..");
const TYPES = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json",
  ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png", ".css": "text/css", ".mjpeg": "video/x-motion-jpeg" };

function start(port = 0) {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      const u = decodeURIComponent(req.url.split("?")[0]);
      const p = path.resolve(ROOT, "." + u);
      if (!p.startsWith(ROOT)) { res.writeHead(403); return res.end(); }
      fs.stat(p, (err, st) => {
        if (err || !st.isFile()) { res.writeHead(404); return res.end(); }
        res.writeHead(200, { "Content-Type": TYPES[path.extname(p).toLowerCase()] || "application/octet-stream", "Cache-Control": "no-store" });
        fs.createReadStream(p).pipe(res);
      });
    });
    srv.listen(port, "127.0.0.1", () => resolve({ srv, port: srv.address().port, url: `http://localhost:${srv.address().port}` }));
  });
}
module.exports = { start, ROOT };
if (require.main === module) start(+process.argv[2] || 8123).then((s) => console.log("serving", s.url));
