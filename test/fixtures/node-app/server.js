// The web process: / says hello with GREETING from the env file, and /health answers exactly 200, or
// 308 when the repo has a file named HEALTH_308 (for the unhealthy-deploy test).
const http = require("http");
const fs = require("fs");

const built = fs.readFileSync(__dirname + "/dist/built.txt", "utf8").trim();
const server = http.createServer((req, res) => {
  if (req.url === "/health" && fs.existsSync(__dirname + "/HEALTH_308")) {
    res.writeHead(308, { location: "/health/" });
    res.end();
  } else if (req.url === "/health") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end("ok\n");
  } else if (req.url === "/") {
    res.writeHead(200, { "content-type": "text/plain" });
    res.end(`Hello from node-app (${built}): ${process.env.GREETING || ""}\n`);
  } else {
    res.writeHead(404);
    res.end();
  }
});
server.listen(Number(process.env.PORT), "127.0.0.1", () => console.log(`listening on ${process.env.PORT}`));
process.on("SIGTERM", () => server.close(() => process.exit(0)));
