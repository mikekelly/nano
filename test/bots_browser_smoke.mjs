// Disposable test server only: BOTS_URL=http://127.0.0.1:PORT node --experimental-websocket test/bots_browser_smoke.mjs
// Uses installed Lightpanda, no npm packages. Creates bots/chats in the specified test instance.
import {spawn} from 'node:child_process'
import assert from 'node:assert/strict'
const url = process.env.BOTS_URL
if (!url || !/^http:\/\/127\.0\.0\.1:\d+$/.test(url)) throw new Error('BOTS_URL must name a disposable loopback test server')
const browser = spawn('/usr/local/bin/lightpanda', ['serve', '--host', '127.0.0.1', '--port', '0', '--log-level', 'info'])
let ws, next = 0
const pending = new Map(), errors = []
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
try {
  const port = await new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Lightpanda startup timed out')), 10000)
    const scan = data => { const match = String(data).match(/address=127\.0\.0\.1:(\d+)/); if (match) { clearTimeout(timeout); resolve(match[1]) } }
    browser.stdout.on('data', scan); browser.stderr.on('data', scan); browser.on('error', reject)
  })
  ws = new WebSocket(`ws://127.0.0.1:${port}`)
  await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject })
  ws.onmessage = ({data}) => {
    const msg = JSON.parse(String(data))
    if (msg.id && pending.has(msg.id)) { const {resolve, reject, timer} = pending.get(msg.id); pending.delete(msg.id); clearTimeout(timer); msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result) }
    if (msg.method === 'Runtime.exceptionThrown') errors.push(msg.params.exceptionDetails)
  }
  const call = (method, params = {}, sessionId) => new Promise((resolve, reject) => {
    const id = ++next, timer = setTimeout(() => { pending.delete(id); reject(new Error(`CDP timeout ${method}`)) }, 15000)
    pending.set(id, {resolve, reject, timer}); ws.send(JSON.stringify({id, method, params, ...(sessionId ? {sessionId} : {})}))
  })
  const {targetId} = await call('Target.createTarget', {url: 'about:blank'})
  const {sessionId} = await call('Target.attachToTarget', {targetId, flatten: true})
  const evaluate = async expression => {
    const result = await call('Runtime.evaluate', {expression, returnByValue: true, awaitPromise: true}, sessionId)
    if (result.exceptionDetails) throw new Error(JSON.stringify(result.exceptionDetails))
    return result.result.value
  }
  const until = async expression => {
    for (let i = 0; i < 100; i++) { if (await evaluate(expression)) return; await wait(50) }
    throw new Error(`Condition not met: ${expression}\n${await evaluate('document.body.innerText')}`)
  }
  const click = selector => evaluate(`document.querySelector(${JSON.stringify(selector)}).click()`)
  const fill = (selector, value) => evaluate(`(() => {const el = document.querySelector(${JSON.stringify(selector)}); el.value = ${JSON.stringify(value)}; el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true}));})()`)
  await call('Runtime.enable', {}, sessionId)
  await call('Page.enable', {}, sessionId)
  await call('Page.navigate', {url: `${url}/bots`}, sessionId)
  await until('!!document.querySelector("#bots-shell") && !!window.liveSocket && window.liveSocket.isConnected()')
  assert.equal(await evaluate('typeof window.BotsHooks.BotsShell.notify'), 'function')
  await click('#recipient-create')
  await until('!!document.querySelector("[role=dialog]")')
  await fill('input[name="bot[name]"]', 'Ava browser')
  await fill('textarea[name="bot[description]"]', 'Friendly planning companion')
  await evaluate('document.querySelector("input[name=\\"bot[name]\\"]").form.requestSubmit()')
  await until('!document.querySelector("[role=dialog]") && document.querySelectorAll(".bots-chip").length === 1')
  await click('#recipient-create')
  await until('!!document.querySelector("[role=dialog]")')
  await fill('input[name="bot[name]"]', 'Milo browser')
  await evaluate('document.querySelector("input[name=\\"bot[name]\\"]").form.requestSubmit()')
  await until('document.querySelectorAll(".bots-chip").length === 2')
  await evaluate('document.querySelector("[phx-click=\\"start-chat\\"]").click()')
  await until('location.pathname.startsWith("/bots/") && !!document.querySelector("#message-input")')
  await fill('#message-input', '<script>window.BOTS_XSS = true</script> hello both of you')
  await evaluate('document.querySelector("#message-input").form.requestSubmit()')
  await until('document.querySelector("#bots-messages")?.textContent.includes("hello both of you")')
  assert.equal(await evaluate('window.BOTS_XSS === true'), false)
  await click('#preferences-open')
  await until('!!document.querySelector("[role=dialog]")')
  assert.equal(await evaluate('document.querySelector("#bots-shell").dataset.notifications'), 'false')
  console.log(JSON.stringify({ok:true, path:await evaluate('location.pathname'), bots:2, messages:await evaluate('document.querySelector("#bots-messages").children.length'), jsExceptions:errors}, null, 2))
  assert.deepEqual(errors, [])
} finally {
  for (const {timer} of pending.values()) clearTimeout(timer)
  ws?.close(); browser.kill('SIGTERM')
}
