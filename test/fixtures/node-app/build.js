// The build step: writes dist/built.txt, which the server reports, so a test can tell the build ran.
const fs = require("fs");
fs.mkdirSync("dist", { recursive: true });
fs.writeFileSync("dist/built.txt", "built\n");
