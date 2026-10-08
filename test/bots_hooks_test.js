// Run with: node --test test/bots_hooks_test.js. No npm dependencies or browser globals leaked.
const {test} = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const vm = require('node:vm')
const source = fs.readFileSync('priv/static/bots.js', 'utf8')

function fixture() {
  const notices = [], sent = [], storage = new Map(), elements = new Map()
  let now = 1_800_000_000_000
  class Clock extends Date { static now() { return now } }
  class Notification {
    static permission = 'granted'
    static requestPermission() { throw new Error('must never request permission implicitly') }
    constructor(title, options) { this.title = title; this.options = options; notices.push(this) }
    close() { this.closed = true; this.onclose?.() }
  }
  const document = {hidden: true, activeElement: null}
  const window = {Notification, focus() {}, location: {assign(url) { window.location.last = url }}}
  const localStorage = {getItem(key) { return storage.get(key) ?? null }, setItem(key, value) { storage.set(key, value) }}
  vm.runInNewContext(source, {window, document, Notification, localStorage, navigator: {}, Date: Clock, console})
  const hook = Object.assign({}, window.BotsHooks.BotsShell, {
    el: {dataset: {notifications: 'true', maxHour: '6', cooldown: '300'}, querySelector: key => elements.get(key), querySelectorAll: () => []},
    notifications: new Set(), pickerIndex: -1, pushEvent: (name, payload) => sent.push({name, payload})
  })
  const event = {id: 'request-1', session_id: 'session-1', title: 'Ava', body: 'Needs a decision'}
  return {hook, event, notices, sent, storage, elements, document, window, Notification, advance(ms) { now += ms }}
}

function key(id, key, extra = {}) {
  return {key, target: {id}, preventDefault() { this.prevented = true }, ...extra}
}

test('notifications are opt-in, background only, and never request permission implicitly', () => {
  const f = fixture()
  f.hook.el.dataset.notifications = 'false'; f.hook.notify(f.event)
  f.hook.el.dataset.notifications = 'true'; f.document.hidden = false; f.hook.notify(f.event)
  f.document.hidden = true; f.Notification.permission = 'denied'; f.hook.notify(f.event)
  assert.equal(f.notices.length, 0)
  f.Notification.permission = 'granted'; f.hook.notify(f.event)
  assert.equal(f.notices.length, 1)
})

test('notifications enforce deduplication, cooldown, hourly cap, and zero allowance', () => {
  const f = fixture(); f.hook.el.dataset.maxHour = '2'
  f.hook.notify(f.event); f.hook.notify(f.event)
  f.hook.notify({...f.event, id: 'request-2'}); assert.equal(f.notices.length, 1)
  f.advance(300001); f.hook.notify({...f.event, id: 'request-2'}); assert.equal(f.notices.length, 2)
  f.advance(300001); f.hook.notify({...f.event, id: 'request-3'}); assert.equal(f.notices.length, 2)
  f.advance(3600001); f.hook.notify({...f.event, id: 'request-3'}); assert.equal(f.notices.length, 3)
  f.hook.el.dataset.maxHour = '0'; f.advance(3600001); f.hook.notify({...f.event, id: 'request-4'})
  assert.equal(f.notices.length, 3)
})

test('notification text stays text, click navigation cannot leave Bots route', () => {
  const f = fixture()
  f.hook.notify({...f.event, session_id: '//evil.example/<script>', title: '<img onerror=alert(1)>', body: '<script>alert(1)</script>'})
  assert.equal(f.notices[0].title, '<img onerror=alert(1)>')
  assert.equal(f.notices[0].options.body, '<script>alert(1)</script>')
  f.notices[0].onclick()
  assert.equal(f.window.location.last, '/bots/%2F%2Fevil.example%2F%3Cscript%3E')
  assert.equal(f.hook.notifications.size, 0)
})

test('malformed notification events do not display', () => {
  const f = fixture()
  for (const event of [null, {}, {id: 1, session_id: 's'}, {id: 'x', session_id: {bad: true}}]) f.hook.notify(event)
  assert.equal(f.notices.length, 0)
})

test('corrupt browser storage cannot crash notification delivery', () => {
  const f = fixture(); f.storage.set('nano-bots-notifications-v1', '{broken')
  f.hook.notify(f.event)
  assert.equal(f.notices.length, 1)
})

test('composer Enter submits once, Shift+Enter and IME do not submit', () => {
  const f = fixture(); let submits = 0
  const target = {id: 'message-input', value: 'hello', form: {requestSubmit() { submits++ }}}
  const enter = key('message-input', 'Enter', {target})
  f.hook.keydown(enter); assert.equal(submits, 1); assert.ok(enter.prevented)
  f.hook.keydown(key('message-input', 'Enter', {target, shiftKey: true}))
  f.hook.keydown(key('message-input', 'Enter', {target, isComposing: true}))
  target.value = '  '; f.hook.keydown(key('message-input', 'Enter', {target}))
  assert.equal(submits, 1)
})

test('recipient arrows wrap and Enter picks highlighted bot', () => {
  const f = fixture(); const clicked = []
  const options = [0, 1, 2].map(i => ({id: `option-${i}`, dataset: {botShortcut: String(i + 1)}, click() { clicked.push(i) }, scrollIntoView() {}}))
  f.hook.options = () => options; f.hook.highlight = () => {}
  f.hook.keydown(key('recipient-input', 'ArrowUp')); assert.equal(f.hook.pickerIndex, 2)
  f.hook.keydown(key('recipient-input', 'ArrowDown')); assert.equal(f.hook.pickerIndex, 0)
  f.hook.keydown(key('recipient-input', 'Enter')); assert.deepEqual(clicked, [0])
  assert.equal(f.hook.pickerIndex, -1)
})

test('command/control numeric shortcuts choose bots but not behind modal', () => {
  const f = fixture(); let clicks = 0
  f.elements.set('[data-bot-shortcut="2"]', {click() { clicks++ }})
  f.hook.keydown(key('recipient-input', '2', {metaKey: true})); assert.equal(clicks, 1)
  f.hook.modal = {}; f.hook.keydown(key('recipient-input', '2', {ctrlKey: true})); assert.equal(clicks, 1)
})
