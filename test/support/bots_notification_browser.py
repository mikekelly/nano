# Actual browser storage/reload tests; Notification/visibility are mocked, never OS delivery.
import os,json,time
exec(open(os.path.join(os.path.dirname(__file__),'bots_browser_client.py')).read().split('c=CDP()')[0])
c=CDP();url=json.load(open(os.environ['BOTS_BROWSER_DIR']+'/endpoint.json'))['url']
c.call('Page.navigate',{'url':url+'/bots'});time.sleep(2)
c.wait('!!window.BotsNotificationPolicy')
print('Native lock capability',c.js('typeof navigator.locks'))
setup='''(()=>{
 window.notificationCalls=[];window.testNow=1000000;Date.now=()=>window.testNow;
 window.testHidden=true;Object.defineProperty(document,"hidden",{configurable:true,get:()=>window.testHidden});
 function FakeNotification(title){window.notificationCalls.push(title);this.close=()=>{}};
 FakeNotification.permission="granted";window.Notification=FakeNotification;
})()'''
c.js(setup)
key='nano:bots:notifications:v1'
c.js('localStorage.removeItem('+json.dumps(key)+')')
# Missing locks deliberately suppress rather than fall back to racing storage.
c.js('Object.defineProperty(navigator,"locks",{configurable:true,value:undefined})')
assert c.js('window.BotsNotificationPolicy.notify({id:"unsupported",title:"No lock"})') is False
assert c.js('notificationCalls.length')==0
print('PASS unsupported-lock fail closed')
# Serialized lock mock exercises browser storage budget logic. Not a Web Locks proof.
locks='''Object.defineProperty(navigator,"locks",{configurable:true,value:{request:async(name,opts,fn)=>fn({name})}})'''
c.js(locks)
data={'id':'persist-one','title':'One','session_id':'safe','max_per_hour':2,'min_interval_ms':60000}
def notify(d):return c.js('window.BotsNotificationPolicy.notify('+json.dumps(d)+')')
assert notify(data) is True
assert notify(data) is False
assert notify({**data,'id':'interval'}) is False
print('PASS actual localStorage dedup/interval',c.js('localStorage.getItem('+json.dumps(key)+')'))
# Same-origin navigation creates a fresh hook/policy but must not reset reservations.
c.call('Page.navigate',{'url':url+'/bots?policy-reload=1'});time.sleep(2);c.wait('!!window.BotsNotificationPolicy')
c.js(setup);c.js(locks)
assert notify(data) is False
assert notify({**data,'id':'after-reload'}) is False
c.js('window.testNow+=61000')
assert notify({**data,'id':'second'}) is True
c.js('window.testNow+=61000')
assert notify({**data,'id':'hour-cap'}) is False
print('PASS real page navigation keeps dedup/hour budget')
# Another actual tab in the same origin sees reservations from the first tab.
tab=CDP(context=c.context);tab.call('Page.navigate',{'url':url+'/bots'});time.sleep(2);tab.wait('!!window.BotsNotificationPolicy')
tab.js(setup);tab.js(locks);tab.js('window.testNow+=122000')
shared = tab.js('localStorage.getItem('+json.dumps(key)+')')
if shared is None:
 print('LIMITATION Lightpanda target localStorage is isolated despite same browserContextId; cross-tab storage sharing not proven. Real unsupported-lock path suppresses.')
else:
 assert tab.js('window.BotsNotificationPolicy.notify('+json.dumps({**data,'id':'other-tab'})+')') is False
 print('PASS real second tab shares stored hourly budget (serialized lock mocked)')
# Corrupt stored state suppresses; it is not automatically cleared to reset limits.
c.js('localStorage.setItem('+json.dumps(key)+',"broken")')
assert notify({**data,'id':'corrupt'}) is False
assert c.js('localStorage.getItem('+json.dumps(key)+')')=='broken'
c.js('localStorage.removeItem('+json.dumps(key)+')')
c.js('window.testHidden=false')
assert notify({**data,'id':'foreground'}) is False
c.js('window.testHidden=true;Notification.permission="denied"')
assert notify({**data,'id':'denied'}) is False
print('PASS corrupt/foreground/denied fail closed')
# Storage read/write exceptions must not call Notification.
c.js('Notification.permission="granted";Object.defineProperty(window,"localStorage",{configurable:true,value:{getItem(){throw Error("blocked")}}});true')
assert notify({**data,'id':'blocked'}) is False
print('PASS storage access failure suppresses')
# Quota exhaustion while reserving is equally fail-closed.
c.js('Object.defineProperty(window,"localStorage",{configurable:true,value:{getItem(){return null},setItem(){throw Error("quota")}}});true')
assert notify({**data,'id':'quota'}) is False
# A tab that cannot obtain the exclusive lock suppresses instead of racing.
c.js('Object.defineProperty(navigator,"locks",{configurable:true,value:{request:async(name,opts,fn)=>fn(null)}});true')
assert notify({**data,'id':'busy'}) is False
print('PASS storage quota and unavailable exclusive lock suppress')
