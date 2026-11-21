// Check the native room-code field in a real web export. Physical iOS keyboard
// visibility still needs the phone. Usage: node tools/test_code_field.mjs <CDP-WS> <URL>
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
async function touch(x, y) {
  await send('Input.dispatchTouchEvent', {type: 'touchStart', touchPoints: [{x, y, id: 0}]});
  await send('Input.dispatchTouchEvent', {type: 'touchEnd', touchPoints: []});
}
async function until(expression) {
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline) {
    if (await evaluate(expression)) return;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.fail(`Timed out: ${expression}`);
}
async function openCode() {
  const url = new URL(pageUrl);
  url.searchParams.set('room', 'ABC234');
  await send('Page.navigate', {url: url.href});
  await until('!!document.getElementById("room-code-field")');
}
async function target(width, margin = 16) {
  // The displayed code belongs below ROOM CODE (y=108), inside the 256-wide
  // screen with the portrait's 16-pixel top margin. Touch its visible centre.
  const point = {x: width / 2, y: (margin + 108 + 16) * width / 256};
  const hit = await evaluate(`document.elementFromPoint(${point.x}, ${point.y})?.id`);
  assert.equal(hit, 'room-code-field', 'The visible code must be the native input touch target');
  return point;
}
try {
  const {targetInfos} = await send('Target.getTargets');
  const page = targetInfos.find(item => item.type === 'page');
  ({sessionId: session} = await send('Target.attachToTarget', {targetId: page.targetId, flatten: true}));
  await send('Page.bringToFront');
  await send('Emulation.setFocusEmulationEnabled', {enabled: true});
  await send('Security.setIgnoreCertificateErrors', {ignore: true});
  await send('Network.enable');
  await send('Network.setBypassServiceWorker', {bypass: true});
  await send('Emulation.setTouchEmulationEnabled', {enabled: true, maxTouchPoints: 5});
  await send('Emulation.setDeviceMetricsOverride', {width: 390, height: 668, deviceScaleFactor: 1, mobile: true});
  await openCode();
  let point = await target(390);
  await touch(point.x, point.y);
  assert.equal(await evaluate('document.activeElement.id'), 'room-code-field', 'A direct touch must focus the code');
  assert.equal(await evaluate('document.getElementById("room-code-field").placeholder'), '', 'Focus must hide TAP HERE');
  await evaluate('document.getElementById("room-code-field").select()');
  await send('Input.dispatchKeyEvent', {type:'keyDown', key:'Backspace', code:'Backspace', windowsVirtualKeyCode:8});
  await send('Input.dispatchKeyEvent', {type:'keyUp', key:'Backspace', code:'Backspace', windowsVirtualKeyCode:8});
  assert.equal(await evaluate('document.getElementById("room-code-field").value'), '', 'Clearing the code leaves only the caret');
  assert.equal(await evaluate('document.getElementById("room-code-field").placeholder'), '', 'An empty focused field must keep the hint hidden');
  await evaluate('document.getElementById("room-code-field").blur()');
  assert.equal(await evaluate('document.getElementById("room-code-field").placeholder'), 'TAP HERE', 'Leaving an empty field restores the cue');
  await touch(point.x, point.y);
  assert.equal(await evaluate('document.activeElement.id'), 'room-code-field');
  assert.equal(await evaluate('document.getElementById("room-code-field").placeholder'), '', 'A second tap hides the cue again');
  // A code pasted with a separator keeps all six characters: cleaned first, cut after.
  await send('Input.insertText', {text:'abc-234'});
  assert.equal(await evaluate('document.getElementById("room-code-field").value'), 'ABC234', 'A pasted code lost a character');
  await evaluate('document.getElementById("room-code-field").select()');
  await send('Input.dispatchKeyEvent', {type:'keyDown', key:'Backspace', code:'Backspace', windowsVirtualKeyCode:8});
  await send('Input.dispatchKeyEvent', {type:'keyUp', key:'Backspace', code:'Backspace', windowsVirtualKeyCode:8});
  // A short code is editable and must not start a connection on Enter.
  await send('Input.insertText', {text:'AB'});
  await send('Input.dispatchKeyEvent', {type:'keyDown', key:'Enter', code:'Enter', windowsVirtualKeyCode:13});
  await send('Input.dispatchKeyEvent', {type:'keyUp', key:'Enter', code:'Enter', windowsVirtualKeyCode:13});
  assert.equal(await evaluate('document.getElementById("room-code-field")?.value'), 'AB');
  // Resize like a phone turning or its keyboard changing the viewport.
  await send('Emulation.setDeviceMetricsOverride', {width:430, height:700, deviceScaleFactor:1, mobile:true});
  await new Promise(resolve => setTimeout(resolve, 250));
  point = await target(430);
  assert.equal(await evaluate('document.activeElement.id'), 'room-code-field', 'Resize must keep focus');
  await send('Emulation.setDeviceMetricsOverride', {width:390, height:400, deviceScaleFactor:3, mobile:true});
  await new Promise(resolve => setTimeout(resolve, 250));
  await target(390, 0);
  assert.equal(await evaluate('document.activeElement.id'), 'room-code-field', 'A shorter viewport must keep focus');
  await send('Emulation.setDeviceMetricsOverride', {width:844, height:390, deviceScaleFactor:3, mobile:true});
  await new Promise(resolve => setTimeout(resolve, 250));
  assert.equal(await evaluate('document.elementFromPoint(422, 124 * 390 / 240)?.id'), 'room-code-field', 'Rotation must keep the input on the code');
  assert.equal(await evaluate('document.activeElement.id'), 'room-code-field', 'Rotation must keep focus');
  await send('Input.insertText', {text:'C234'});
  await send('Input.dispatchKeyEvent', {type:'keyDown', key:'Enter', code:'Enter', windowsVirtualKeyCode:13});
  await send('Input.dispatchKeyEvent', {type:'keyUp', key:'Enter', code:'Enter', windowsVirtualKeyCode:13});
  await until('!document.getElementById("room-code-field")');
  // Back removes the DOM field; reopening must not leave two inputs/callbacks.
  await openCode();
  await send('Input.dispatchKeyEvent', {type:'keyDown', key:'Escape', code:'Escape', windowsVirtualKeyCode:27});
  await send('Input.dispatchKeyEvent', {type:'keyUp', key:'Escape', code:'Escape', windowsVirtualKeyCode:27});
  await until('!document.getElementById("room-code-field")');
  await openCode();
  assert.equal(await evaluate('document.querySelectorAll("#room-code-field").length'), 1);
  console.log('PASS: native field at the displayed code, direct touch focus, editing, resize, submit and cleanup.');
} finally {
  socket.close();
}
