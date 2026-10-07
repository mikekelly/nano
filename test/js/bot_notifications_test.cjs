// Run: node test/js/bot_notifications_test.cjs (mock browser, no external dependency).
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict')
const source = fs.readFileSync('lib/nano_web/layouts.ex', 'utf8')
const hook = source.slice(source.indexOf('const BotNotifications ='), source.indexOf('// Dropdowns'))
let status = '', focused = false, permission = 'default', notifications = [], sent = [], handlers = {}
const button = {dataset: {botNotifications: 'enable', sessionId: 's1'}}
const element = {contains: () => true, addEventListener: (_, cb) => {element.click = cb}, removeEventListener: () => {element.click = null}}
function Notification(title, opts) { notifications.push({title, opts}); this.close = () => {} }
Notification.permission = 'default'
Notification.requestPermission = async () => permission
const context = {Notification, document: {getElementById: () => ({set textContent(s) {status = s}}), visibilityState: 'hidden', hasFocus: () => focused}, window: {Notification, isSecureContext: true, focus: () => {}}, console}
vm.createContext(context)
vm.runInContext(hook + '\nglobalThis.hook = BotNotifications', context)
const h = Object.assign({}, context.hook, {el: element, pushEvent: (event, data) => sent.push({event, data}), handleEvent: (event, cb) => handlers[event] = cb})
h.mounted()
async function main() {
  await element.click({target: {closest: () => button}})
  assert.equal(sent.length, 0); assert.match(status, /not granted/)
  permission = 'granted'; Notification.permission = 'granted'
  await element.click({target: {closest: () => button}})
  assert.equal(sent[0].event, 'notifications'); assert.equal(sent[0].data.enabled, true); assert.equal(sent[0].data.session_id, 's1')
  handlers['bot-notification']({title: 'Team', body: '<script>literal</script>', id: 'm1', session_id: 's1'})
  assert.equal(notifications.length, 1); assert.equal(notifications[0].opts.body, '<script>literal</script>')
  context.document.visibilityState = 'visible'; focused = true
  handlers['bot-notification']({title: 'Team', body: 'ignored', id: 'm2'})
  assert.equal(notifications.length, 1)
  button.dataset.botNotifications = 'disable'
  await element.click({target: {closest: () => button}})
  assert.equal(sent.at(-1).data.enabled, false)
  button.dataset.botNotifications = 'enable'; context.window.isSecureContext = false
  await element.click({target: {closest: () => button}})
  assert.match(status, /unavailable/)
  h.destroyed(); assert.equal(element.click, null)
  console.log('BotNotifications mock browser tests passed')
}
main().catch(e => { console.error(e); process.exitCode = 1 })
