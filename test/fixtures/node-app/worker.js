// The worker process: logs a line every 5 seconds, and stops cleanly on SIGTERM.
const timer = setInterval(() => console.log(`worker tick ${new Date().toISOString()}`), 5000);
console.log("worker started");
process.on("SIGTERM", () => {
  clearInterval(timer);
  console.log("worker stopping");
  process.exit(0);
});
