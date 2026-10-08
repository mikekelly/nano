const fs=require('fs'),vm=require('vm'),assert=require('assert');
(async()=>{
const sent=[];
const context={window:{},document:{readyState:'loading',addEventListener(){},querySelector(){return {content:'dummy-csrf'}}},AbortController,console,fetch:async(endpoint,opts)=>{sent.push({endpoint,opts});return {ok:true}}};
vm.createContext(context);vm.runInContext(fs.readFileSync(require('path').join(__dirname, '../../priv/static/bots.js'),'utf8'),context);
function make(){const field={value:'dummy-not-a-real-key'},button={disabled:false},status={textContent:''};const el={dataset:{endpoint:'/bots/requests/r_test/setting'},querySelector(s){return s.startsWith('input')?field:s==='[data-save-setting]'?button:status},addEventListener(){},removeEventListener(){}};const hook=Object.assign({el,pushEvent(){throw Error('secret must never use LiveView')}},context.window.BotsHooks.BotsSetting);hook.mounted();return {hook,field,button,status};}
let h=make();await h.hook.save();assert.equal(sent.length,1);assert.equal(sent[0].opts.method,'POST');assert.equal(sent[0].opts.credentials,'same-origin');assert.equal(sent[0].opts.headers['x-csrf-token'],'dummy-csrf');assert.deepEqual(JSON.parse(sent[0].opts.body),{password:'dummy-not-a-real-key'});assert.equal(h.field.value,'');assert.equal(h.status.textContent,'Credential saved.');
context.fetch=async()=>{throw Error('dummy-not-a-real-key')};h=make();await h.hook.save();assert.equal(h.field.value,'');assert(!h.status.textContent.includes('dummy'));assert.equal(h.button.disabled,false);
h=make();h.hook.destroyed();assert.equal(h.field.value,'');
let finish;context.fetch=()=>new Promise(resolve=>{finish=resolve});h=make();const pending=h.hook.save();h.hook.destroyed();assert.equal(h.field.value,'');finish({ok:true});await pending;assert.equal(h.field.value,'');assert.notEqual(h.status.textContent,'Credential saved.');
h=make();h.hook.el.dataset.endpoint='https://evil.invalid/';let calls=0;context.fetch=async()=>{calls++;return {ok:true}};await h.hook.save();assert.equal(calls,0);assert.equal(h.field.value,'');
console.log('PASS credential hook: JSON+CSRF, no LiveView secret, clear success/error/destroy, generic errors, endpoint gate');
})().catch(e=>{console.error(e);process.exit(1)});
