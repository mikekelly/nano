# Requires task-local websocket-client; run against isolated bootstrap only.
import sys,json,time,os
sys.path.insert(0,os.environ.get('BOTS_BROWSER_PYTHON','/tmp/altair-bots-ui-browser/python'))
import websocket
class CDP:
 def __init__(self):
  self.ws=websocket.create_connection(os.environ.get('BOTS_CDP_WS','ws://127.0.0.1:19343/'),timeout=15,suppress_origin=True);self.seq=0;self.events=[];self.sid=None
  t=self.call('Target.createTarget',{'url':'about:blank'})['targetId']
  self.sid=self.call('Target.attachToTarget',{'targetId':t,'flatten':True})['sessionId']
  self.call('Runtime.enable');self.call('Page.enable')
 def call(self,m,p={}):
  self.seq+=1; msg={'id':self.seq,'method':m,'params':p}
  if self.sid:msg['sessionId']=self.sid
  self.ws.send(json.dumps(msg))
  while True:
   r=json.loads(self.ws.recv())
   if r.get('id')==self.seq:
    if 'error' in r:raise Exception(r['error'])
    return r.get('result',{})
   self.events.append(r)
 def js(self,s):
  r=self.call('Runtime.evaluate',{'expression':s,'returnByValue':True,'awaitPromise':True})
  if 'exceptionDetails' in r:raise Exception(r)
  return r['result'].get('value',r['result'])
 def wait(self,expr):
  for _ in range(100):
   if self.js(expr):return
   time.sleep(.1)
  raise Exception('Timeout: '+expr)
c=CDP()
url=json.load(open(os.environ['BOTS_BROWSER_DIR']+'/endpoint.json'))['url']
c.call('Page.navigate',{'url':url+'/bots'})
time.sleep(5)
print(c.js('JSON.stringify({body:document.body.innerText,hook:typeof window.BotsUI,socket:!!window.liveSocket,notification:typeof Notification,hidden:document.hidden})'))
c.wait('window.liveSocket.isConnected()');print('PASS LiveView connected')
print('Capabilities',c.js('JSON.stringify({notificationPermission:Notification.permission,visibility:document.visibilityState,clipboard:typeof navigator.clipboard,animation:typeof requestAnimationFrame})'))
def fill(sel,value):
 c.js('(()=>{const el=document.querySelector('+json.dumps(sel)+');el.focus();el.value='+json.dumps(value)+';el.dispatchEvent(new Event("input",{bubbles:true}));})()')
def click(sel): c.js('document.querySelector('+json.dumps(sel)+').click()')
def key(k,code):
 c.call('Input.dispatchKeyEvent',{'type':'keyDown','key':k,'code':code,'windowsVirtualKeyCode':13 if k=='Enter' else 40})
 c.call('Input.dispatchKeyEvent',{'type':'keyUp','key':k,'code':code})
aster='Aster '+str(int(time.time()*1000)); briar='Briar '+str(int(time.time()*1000));fill('#to-query',aster)
c.wait('document.querySelector("#bot-options").textContent.includes('+json.dumps(aster)+')')
key('Enter','Enter')
c.wait('document.querySelectorAll(".recipient-chip").length === 1')
print('PASS keyboard-created Aster')
fill('#to-query',briar);c.wait('document.querySelector("#bot-options").textContent.includes('+json.dumps(briar)+')');key('Enter','Enter')
c.wait('document.querySelectorAll(".recipient-chip").length === 2')
c.js('document.querySelectorAll(".recipient-chip button")[1].click()');c.wait('document.querySelectorAll(".recipient-chip").length===1')
fill('#to-query',briar);c.wait('document.querySelectorAll("#bot-options button[role=option]").length===1');key('ArrowUp','ArrowUp');key('Enter','Enter');c.wait('document.querySelectorAll(".recipient-chip").length===2');print('PASS ArrowUp/Enter recipient selection')
click('button[phx-click=start_chat]');c.wait('!!document.querySelector("#bots-composer")')
print('PASS group'
,c.js('document.querySelector(".participants-pill").textContent'))
fill('#message-input','**Hello both** <script>window.modelLeak=true</script>')
c.js('document.querySelector("#bots-composer").requestSubmit()')
c.wait('!!document.querySelector(".message.human")')
c.wait('!window.modelLeak && document.querySelectorAll("a[href*=eval]").length === 0')
print('PASS safe consumer message',c.js('JSON.stringify({text:document.querySelector(".message-text").textContent,script:!!window.modelLeak,evalLinks:document.querySelectorAll("a[href*=eval]").length})'))
print('Final DOM',c.js('document.querySelector("#bots-ui").textContent.slice(0,1600)'))
print('Exceptions',json.dumps([e for e in c.events if e.get('method')=='Runtime.exceptionThrown']))
open(os.environ['BOTS_BROWSER_DIR']+'/browser-notes.txt','w').write('Actual browser upload content')
try:
 doc=c.call('DOM.getDocument')
 node=c.call('DOM.querySelector',{'nodeId':doc['root']['nodeId'],'selector':'input[type=file]'})['nodeId']
 c.call('DOM.setFileInputFiles',{'nodeId':node,'files':[os.environ['BOTS_BROWSER_DIR']+'/browser-notes.txt']})
 c.wait('!!document.querySelector(".upload-preview")')
 fill('#message-input','Browser uploaded notes');c.js('document.querySelector("#bots-composer").requestSubmit()')
 c.wait('!!document.querySelector("a[download]")')
 download=c.js('document.querySelector("a[download]").getAttribute("href")')
 import urllib.request
 response=urllib.request.urlopen(url+download)
 assert response.read()==b'Actual browser upload content'
 assert response.headers['Content-Type'].startswith('application/octet-stream')
 assert 'attachment' in response.headers['Content-Disposition']
 print('PASS browser file upload and download-only bytes',download)

except Exception as e:raise Exception('Browser upload failed: '+str(e))
click('button[data-notification-opt-in]');time.sleep(.5)
print('Notification permission after user action',c.js('Notification.permission'))
try:
 print('Permission override',c.call('Browser.grantPermissions',{'permissions':['notifications'],'origin':url}))
 print('Background transition',c.call('Page.setWebLifecycleState',{'state':'frozen'}))
 print('Background state',c.js('JSON.stringify({hidden:document.hidden,permission:Notification.permission})'))
except Exception as e:print('BACKGROUND/PERMISSION CAPABILITY',str(e))
print('After grant permission',c.js('Notification.permission'))
try:
 other=c.call('Target.createTarget',{'url':'about:blank'})['targetId'];c.call('Target.activateTarget',{'targetId':other})
 print('After another target activation',c.js('JSON.stringify({hidden:document.hidden,visibility:document.visibilityState})'))
except Exception as e:print('Target background unsupported',e)
print('Real Notification construct',c.js('(()=>{try{const n=new Notification("Browser acceptance probe");n.close();return "construct returned"}catch(e){return String(e)}})()'))
policy=c.js('''(()=>{
 const savedN=window.Notification, savedNow=Date.now, savedHidden=Object.getOwnPropertyDescriptor(document,"hidden");
 let hidden=false, permission="granted", now=1000000, calls=[]; const handlers={};
 function FakeNotification(title,opts){calls.push({title,opts});this.close=()=>{}};
 Object.defineProperty(FakeNotification,"permission",{get:()=>permission}); FakeNotification.requestPermission=()=>Promise.resolve("denied");
 window.Notification=FakeNotification; Date.now=()=>now; Object.defineProperty(document,"hidden",{configurable:true,get:()=>hidden});
 const hook={...window.BotsUI,el:document.querySelector("#bots-ui"),handleEvent:(name,fn)=>handlers[name]=fn,pushEvent:()=>{}};
 try{
 hook.mounted();const notify=handlers["bots:notify"], d={id:"policy1",title:"Probe",session_id:"safe",min_interval_ms:60000,max_per_hour:2};
 notify(d);const foreground=calls.length===0;
 hidden=true;permission="denied";notify(d);const denied=calls.length===0;
 permission="granted";notify(d);notify(d);const dedup=calls.length===1;
 notify({...d,id:"policy2"});const interval=calls.length===1;
 now+=61000;notify({...d,id:"policy2"});const second=calls.length===2;
 now+=61000;notify({...d,id:"policy3"});const cap=calls.length===2;
 return JSON.stringify({foreground,denied,dedup,interval,second,cap,allPassed:foreground&&denied&&dedup&&interval&&second&&cap});
 }finally{hook.destroyed();window.Notification=savedN;Date.now=savedNow;if(savedHidden)Object.defineProperty(document,"hidden",savedHidden);else delete document.hidden;}
})()''')
assert json.loads(policy)['allPassed'],policy
print('MOCKED notification policy only',policy)
