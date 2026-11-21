// Check that a room link is said to be copied only once the clipboard took it.
// Runs RoomLink.SEND, read from its source, in a real browser page with no share
// sheet and a clipboard that refuses, then one that accepts.
// Usage: node tools/test_room_link_copy.mjs <browser-CDP-WS>
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const [socketUrl] = process.argv.slice(2);
assert.ok(socketUrl, 'Pass a browser CDP WebSocket URL');
const source = await readFile(new URL('../game/platform/room_link.gd', import.meta.url), 'utf8');
const open = source.indexOf('const SEND := """') + 'const SEND := """'.length;
const script = source.slice(open, source.indexOf('"""', open))
  .replaceAll('%%', '%').replace('%s', JSON.stringify('https://base13.example/?room=ABC234'));

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
  message.error ? pending.reject(new Error(JSON.stringify(message.error))) : pending.resolve(message.result);
});
function send(method, params = {}) {
  return new Promise((resolve, reject) => {
    const id = ++next;
    requests.set(id, { resolve, reject });
    socket.send(JSON.stringify({ id, method, params, ...(session ? { sessionId: session } : {}) }));
  });
}
async function overlapping() {
  // Room A's copy answers only after room B's was asked for and refused: B's
  // screen must not read A's success as its own.
  const response = await send('Runtime.evaluate', { awaitPromise: true, returnByValue: true, expression: `(async () => {
    const answers = [];
    Object.defineProperty(navigator, 'share', { value: undefined, configurable: true });
    Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: () =>
      new Promise((resolve, reject) => answers.push({ resolve, reject })) } });
    ${script};
    ${script};
    answers[1].reject();
    answers[0].resolve();
    await new Promise(resolve => setTimeout(resolve, 50));
    return window.base13LinkCopied;
  })()` });
  assert.equal(response.exceptionDetails, undefined, 'The share script must run without errors');
  return response.result.value;
}

async function copy(answer) {
  const response = await send('Runtime.evaluate', { awaitPromise: true, returnByValue: true, expression: `(async () => {
    Object.defineProperty(navigator, 'share', { value: undefined, configurable: true });
    Object.defineProperty(navigator, 'clipboard',
      { value: { writeText: () => Promise.${answer}() }, configurable: true });
    const said = ${script};
    const atOnce = window.base13LinkCopied;
    await new Promise(resolve => setTimeout(resolve, 50));
    return { said, atOnce, later: window.base13LinkCopied };
  })()` });
  assert.equal(response.exceptionDetails, undefined, 'The share script must run without errors');
  return response.result.value;
}

try {
  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  ({ sessionId: session } = await send('Target.attachToTarget', { targetId, flatten: true }));
  const refused = await copy('reject');
  assert.equal(refused.said, 'copying');
  assert.equal(refused.later, false, 'A refused clipboard was taken for a copied link');
  const taken = await copy('resolve');
  assert.equal(taken.atOnce, false, 'The link was said to be copied before the clipboard answered');
  assert.equal(taken.later, true, 'An accepted copy was never confirmed');
  assert.equal(await overlapping(), false, 'An earlier room\'s copy answered for the latest one');
  await send('Target.closeTarget', { targetId });
  console.log('PASS: LINK COPIED only after the clipboard took the link.');
} finally {
  socket.close();
}
