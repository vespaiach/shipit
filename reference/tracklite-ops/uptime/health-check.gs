// Google Apps Script for the external uptime check (OPS-005). Paste into a new project at
// script.google.com, set baseUrl, then run installTrigger once. checkHealth then runs every
// 5 minutes and emails the script's owner when /health or /health/worker fails twice in a row.

const baseUrl = "https://tracklite.example.com";
const checks = [
  { path: "/health", subject: "Tracklite is down" },
  { path: "/health/worker", subject: "Tracklite notifications are stuck" },
];
const failuresBeforeAlert = 2;

function checkHealth() {
  const properties = PropertiesService.getScriptProperties();
  for (const { path, subject } of checks) {
    const url = baseUrl + path;
    const key = `failures ${path}`;
    const failures = isHealthy(url) ? 0 : Number(properties.getProperty(key) ?? 0) + 1;
    properties.setProperty(key, String(failures));
    if (failures === failuresBeforeAlert) {
      MailApp.sendEmail(
        Session.getEffectiveUser().getEmail(),
        subject,
        `${url} has failed ${failures} checks in a row (5 minutes apart).`,
      );
    }
  }
}

function isHealthy(url) {
  try {
    return UrlFetchApp.fetch(url, { muteHttpExceptions: true, followRedirects: false }).getResponseCode() === 200;
  } catch {
    return false;
  }
}

function installTrigger() {
  for (const trigger of ScriptApp.getProjectTriggers()) ScriptApp.deleteTrigger(trigger);
  ScriptApp.newTrigger("checkHealth").timeBased().everyMinutes(5).create();
}