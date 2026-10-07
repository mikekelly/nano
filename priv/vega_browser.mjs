// Dependency-free Node >=22 CDP bridge. Task process-group owns this and Lightpanda.
import http from 'node:http';
import net from 'node:net';
import {spawn} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
const cfg = JSON.parse(await readFile(process.argv[2], 'utf8'));
const sleep = ms => new Promise(r => setTimeout(r, ms));
const reserve = net.createServer();
await new Promise(r => reserve.listen(0, '127.0.0.1', r));
const port = reserve.address().port;
await new Promise(r => reserve.close(r));
const args = cfg.backend==='chromium'
  ? ['--headless=new','--no-sandbox','--disable-dev-shm-usage','--no-first-run','--no-default-browser-check',`--user-data-dir=${cfg.profile}`, '--remote-debugging-address=127.0.0.1',`--remote-debugging-port=${port}`,'about:blank']
  : ['serve','--host','127.0.0.1','--port',String(port)];
const child = spawn(cfg.binary, args, {stdio: ['ignore', 'inherit', 'inherit']});
child.on('error', e => { console.error(e.message); process.exit(1); });
child.on('exit', () => process.exit(1));
let ws;
for (let i=0;i<100;i++) {
  try {
    let endpoint=`ws://127.0.0.1:${port}/`;
    if(cfg.backend==='chromium') {
      const response=await fetch(`http://127.0.0.1:${port}/json/version`);
      endpoint=(await response.json()).webSocketDebuggerUrl;
    }
    ws = new WebSocket(endpoint);
    await new Promise((resolve,reject) => { ws.onopen=resolve; ws.onerror=reject; });
    break;
  } catch { await sleep(50); }
}
if (!ws || ws.readyState !== WebSocket.OPEN) throw new Error('CDP startup timeout');
let seq=0, session;
const pending = new Map();
ws.onclose = () => process.exit(1);
ws.onmessage = e => {
  if (e.data.length > 6000000) { ws.close(); return; }
  const m = JSON.parse(e.data);
  if (!m.id || !pending.has(m.id)) return;
  const p = pending.get(m.id); pending.delete(m.id); clearTimeout(p.timer);
  if (m.error) p.reject({kind: 'cdp', method: p.method, code:m.error.code, message:m.error.message});
  else p.resolve(m.result);
};
function cdp(method, params={}, useSession=true) {
  return new Promise((resolve,reject) => {
    const id=++seq;
    const timer=setTimeout(() => {pending.delete(id); reject({kind:'timeout',method});}, 10000);
    pending.set(id,{resolve,reject,timer,method});
    ws.send(JSON.stringify({id,method,params,...(session && useSession ? {sessionId:session}: {})}));
  });
}
const {targetId} = await cdp('Target.createTarget', {url:'about:blank'}, false);
session = (await cdp('Target.attachToTarget', {targetId,flatten:true}, false)).sessionId;
await cdp('Page.enable');
await cdp('Runtime.enable');
async function evaluate(expression) {
  const r = await cdp('Runtime.evaluate', {expression,returnByValue:true,awaitPromise:true});
  if (r.exceptionDetails) throw {kind:'javascript',message:r.exceptionDetails.text,detail:r.exceptionDetails.exception?.description?.slice(0,1000)};
  return r.result.value ?? null;
}
async function run(q) {
  switch(q.op) {
    case 'navigate': {
      const r=await cdp('Page.navigate',{url:q.url});
      if(r.errorText) throw {kind:'navigation',message:r.errorText};
      for(let i=0;i<100;i++) {
        if(await evaluate('document.readyState') === 'complete') return await evaluate('({url:location.href,title:document.title})');
        await sleep(50);
      }
      throw {kind:'timeout',method:'navigate'};
    }
    case 'evaluate': return await evaluate(q.expression);
    case 'command': return await cdp(q.method,q.params || {},!q.browser_scope);
    case 'press': {
      const codes={Enter:13,Tab:9,Escape:27,Backspace:8,Delete:46,ArrowLeft:37,ArrowUp:38,ArrowRight:39,ArrowDown:40};
      const code=codes[q.key] || (q.key.length===1?q.key.toUpperCase().charCodeAt(0):0);
      const text=q.key==='Enter'?'\r':q.key.length===1?q.key:'';
      await cdp('Input.dispatchKeyEvent',{type:'keyDown',key:q.key,windowsVirtualKeyCode:code,text,modifiers:q.modifiers || 0});
      await cdp('Input.dispatchKeyEvent',{type:'keyUp',key:q.key,windowsVirtualKeyCode:code,modifiers:q.modifiers || 0});
      return true;
    }
    case 'screenshot': {
      try {return await cdp('Page.captureScreenshot',{format:'png'});}
      catch(e) {if(e.kind==='cdp' && (e.code===-32601 || /not supported|unsupported|not implemented|unknown method/i.test(e.message))) throw {...e,kind:'unsupported',feature:'screenshot'};throw e;}
    }
    default: throw {kind:'invalid_operation'};
  }
}
let busy=false;
const server=http.createServer((req,res) => {
  if(req.method!=='POST' || req.url!=='/' || req.headers.authorization!==`Bearer ${cfg.token}`) {res.writeHead(403).end();return;}
  let body='', size=0;
  req.on('data',b=>{size+=b.length;if(size>100000){req.destroy();return;}body+=b;});
  req.on('end',()=>{
    if(busy) {res.writeHead(200,{'content-type':'application/json'}).end(JSON.stringify({ok:false,error:{kind:'busy'}}));return;}
    busy=true;
    (async()=>{
      let out;
      try {out={ok:true,result:await run(JSON.parse(body))};}
      catch(e) {out={ok:false,error:e.kind ? e : {kind:'bridge',message:String(e.message || e)}};}
      let text=JSON.stringify(out);
      const max=JSON.parse(body).op==='screenshot'?6000000:50000;
      if(Buffer.byteLength(text)>max) text=JSON.stringify({ok:false,error:{kind:'result_too_large'}});
      res.writeHead(200,{'content-type':'application/json'}).end(text);
    })().catch(e=>{console.error(e);res.destroy();}).finally(()=>{busy=false;});
  });
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
await writeFile(cfg.ready,JSON.stringify({port:server.address().port}),{mode:0o600});
