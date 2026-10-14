// The web process: keeps notes as files in $DATA_DIR/notes. POST /notes?text=<word> adds one, and
// /health answers 200 with "notes: <word>,<word>…" in the order they were added. On every start it
// rewrites $DATA_DIR/live.txt, a file outside the notes, like a live database.
const http = require("http");
const fs = require("fs");
const path = require("path");

const dir = process.env.DATA_DIR;
if (!dir) throw new Error("DATA_DIR isn't set");
const notes = path.join(dir, "notes");
fs.mkdirSync(notes, { recursive: true });
fs.writeFileSync(path.join(dir, "live.txt"), `started ${new Date().toISOString()}\n`);

const list = () =>
  fs.readdirSync(notes).sort().map((f) => fs.readFileSync(path.join(notes, f), "utf8").trim());

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  if (req.method === "POST" && url.pathname === "/notes" && /^[a-z0-9-]+$/.test(url.searchParams.get("text") || "")) {
    const name = `${Date.now()}-${process.hrtime.bigint()}.txt`;
    fs.writeFileSync(path.join(notes, name), url.searchParams.get("text") + "\n");
    res.writeHead(201);
    res.end();
  } else if (url.pathname === "/health") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end(`notes: ${list().join(",")}\n`);
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen(Number(process.env.PORT), "127.0.0.1", () => console.log(`listening on ${process.env.PORT}`));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
