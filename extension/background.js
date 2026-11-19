// Passes what the streaming-site tabs report to the RichPresence app on this PC (127.0.0.1 only).
const APP = 'http://127.0.0.1:47610';
const latest = {};         // per tab: number of its newest message, so a retried "stopped" never lands after a later report

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.type !== 'watching' || !msg.info) return;
  const id = `${msg.info.tab || ''}|${msg.info.service || ''}`;
  const n = latest[id] = (latest[id] || 0) + 1;
  send(msg.info, msg.stop ? 3 : 0, id, n);
});

// a "stopped" that didn't get through is tried again (3 times, 2 s apart); anything else is just dropped
function send(info, retries, id, n) {
  fetch(`${APP}/watching`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-RichPresence': '1' },
    body: JSON.stringify(info)
  }).then((r) => { if (!r.ok) throw new Error(String(r.status)); }).catch(() => {
    // RichPresence isn't running: nothing to do, unless this was a "stopped"
    if (retries > 0) setTimeout(() => { if (latest[id] === n) send(info, retries - 1, id, n); }, 2000);
  });
}
