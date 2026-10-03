// Local browser checks only. Actual vibration must be felt on a physical phone.
// Usage: node tools/test_haptics_check.mjs <browser-CDP-websocket> <page-URL>
import assert from 'node:assert/strict';

const [socketUrl, pageUrl] = process.argv.slice(2);
assert.ok(socketUrl && pageUrl, 'Pass a browser CDP WebSocket URL and the check page URL');
const socket = new WebSocket(socketUrl);
await new Promise((resolve, reject) => {
  socket.addEventListener('open', resolve, { once: true });
  socket.addEventListener('error', reject, { once: true });
});
let next = 0, session;
const requests = new Map();
socket.addEventListener('message', event => {
  const message = JSON.parse(event.data), pending = requests.get(message.id);
  if (!pending) return;
  requests.delete(message.id);
  clearTimeout(pending.timer);
  message.error ? pending.reject(new Error(JSON.stringify(message.error))) : pending.resolve(message.result);
});
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++next;
    const timer = setTimeout(() => { requests.delete(id); reject(new Error(`Timeout: ${method}`)); }, 10000);
    requests.set(id, { resolve, reject, timer });
    socket.send(JSON.stringify({ id, method, params, ...(session ? { sessionId: session } : {}) }));
  });
}
async function evaluate(expression) {
  const response = await send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
  assert.equal(response.exceptionDetails, undefined, 'Page JavaScript must run without errors');
  return response.result.value;
}
async function tap(selector) {
  await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({block:"center"})`);
  const point = await evaluate(`(() => { const r = document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect(); return {x:r.x+r.width/2,y:r.y+r.height/2,id:0}; })()`);
  await send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [point] });
  await send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
}
try {
  const { targetInfos } = await send('Target.getTargets');
  const target = targetInfos.find(item => item.type === 'page');
  ({ sessionId: session } = await send('Target.attachToTarget', { targetId: target.targetId, flatten: true }));
  await send('Page.bringToFront');
  await send('Emulation.setFocusEmulationEnabled', { enabled: true });
  await send('Security.setIgnoreCertificateErrors', { ignore: true });
  await send('Network.enable');
  await send('Network.setBypassServiceWorker', { bypass: true });
  await send('Emulation.setDeviceMetricsOverride', { width: 390, height: 844, deviceScaleFactor: 1, mobile: true });
  await send('Emulation.setTouchEmulationEnabled', { enabled: true, maxTouchPoints: 5 });
  await send('Page.navigate', { url: pageUrl });
  await evaluate('new Promise(resolve => document.readyState === "complete" ? resolve() : window.addEventListener("load", resolve, {once:true}))');
  assert.equal(await evaluate('document.querySelectorAll("input[switch]").length'), 2, 'The phone check needs both a native switch and a direct-touch FIRE target');
  await tap('#native');
  assert.equal(await evaluate('document.querySelector("#native").checked'), true);
  assert.match(await evaluate('document.querySelector("#native-status").textContent'), /Настоящее касание/);
  await tap('#fire-switch');
  assert.equal(await evaluate('document.querySelector("#fire-switch").checked'), true);
  assert.equal(await evaluate('document.querySelector("#native").checked'), true, 'FIRE must not toggle the other control');
  assert.match(await evaluate('document.querySelector("#fire-status").textContent'), /Настоящее касание/);
  await tap('#script-press');
  assert.equal(await evaluate('document.querySelector("#native").checked'), false);
  assert.match(await evaluate('document.querySelector("#native-status").textContent'), /Вызов из скрипта/);
  await evaluate('Object.defineProperty(navigator, "vibrate", {value: undefined, configurable: true, writable: true})');
  await tap('#vibrate');
  assert.match(await evaluate('document.querySelector("#vibrate-status").textContent'), /не поддерживает/);
  await evaluate('navigator.vibrate = duration => { window.requestedDuration = duration; return true; }');
  await tap('#vibrate');
  assert.equal(await evaluate('window.requestedDuration'), 30, 'Request one short pulse');
  assert.match(await evaluate('document.querySelector("#vibrate-status").textContent'), /Запрос принят/);
  console.log('PASS: trusted touches, isolated controls, scripted comparison, unsupported API and short vibration request.');
  console.log('Actual haptic feedback still requires Safari and Chrome on the physical iPhone.');
} finally {
  socket.close();
}
