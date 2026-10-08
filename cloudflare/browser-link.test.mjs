import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import { createBrowserProtocol } from './browser-protocol.js';
import { browserResponse } from './browser-console.js';

// Run the actual Worker module with only the Cloudflare host class substituted.
// The transaction stub serializes operations like Durable Object SQLite.
const source = (await fs.readFile(new URL('./core-worker.js', import.meta.url), 'utf8'))
  .replace('import { DurableObject } from "cloudflare:workers";', 'class DurableObject { constructor(ctx, env) { this.ctx=ctx; this.env=env; } }')
  .replace('"./browser-agent.js"', JSON.stringify(new URL('./browser-agent.js', import.meta.url).href))
  .replace('"./browser-console.js"', JSON.stringify(new URL('./browser-console.js', import.meta.url).href));
globalThis.WebSocketRequestResponsePair = class {};
const { default: worker, AarisSession, browserPublicOrigin } = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`);
class Storage {
  values = new Map(); queue = Promise.resolve();
  async get(k) { return structuredClone(this.values.get(k)); }
  async put(k,v) { this.values.set(k,structuredClone(v)); }
  async delete(k) { for(const key of Array.isArray(k)?k:[k])this.values.delete(key); }
  async deleteAll() { this.values.clear(); }
  async list({prefix}) { return new Map([...this.values].filter(([k])=>k.startsWith(prefix))); }
  async setAlarm(t) { this.alarm=t; }
  async deleteAlarm() { this.alarm=null; }
  transaction(fn) { const p=this.queue.then(()=>fn(this)); this.queue=p.catch(()=>{}); return p; }
}
const sha = async s => Buffer.from(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s))).toString('hex');
const sid='a'.repeat(64), host='host-token'.padEnd(43,'h'), controller='controller-token'.padEnd(43,'c');
const client=crypto.randomUUID(), instance=crypto.randomUUID();
async function fixture() {
  const sockets=[],storage=new Storage();
  const ctx={storage,getWebSockets:role=>sockets.filter(s=>!role||s.a.role===role),setWebSocketAutoResponse(){}};
  const room=new AarisSession(ctx,{}); const now=Date.now();
  const h=await sha(host), c=await sha(controller);
  await room.initBrowser(sid,h,c,now);
  const env={SESSIONS:{getByName:()=>room,get:()=>room,idFromName:x=>x}};
  const call=(path,token=controller,data,extra={})=>worker.fetch(new Request(`https://remote.test${path}`,{method:data===undefined?'GET':'POST',headers:{Authorization:`Bearer ${token}`,...(data===undefined?{}:{'Content-Type':'application/json'}),...extra},body:data===undefined?undefined:JSON.stringify(data)}),env);
  return {room,storage,h,c,now,call,sockets,env};
}
test('browser session allocation returns a stable client identity for stateless AI browsers',async()=>{
  const sockets=[],storage=new Storage();
  const ctx={storage,getWebSockets:role=>sockets.filter(s=>!role||s.a?.role===role),setWebSocketAutoResponse(){}};
  const room=new AarisSession(ctx,{});
  const env={SESSIONS:{getByName:()=>room}};
  const r=await worker.fetch(new Request('https://remote.test/v1/browser-sessions',{method:'POST'}),env);
  const value=await r.json();
  assert.equal(r.status,201);
  assert.match(value.browserClientId,/^[a-f0-9-]{36}$/);
  assert.equal((await storage.get('session')).browserLink,true);
});
test('GET previews load a token-free console without claiming or consuming a session',async()=>{
  let touched=false;
  const r=await worker.fetch(new Request('https://remote.test/remote/'),{SESSIONS:{get(){touched=true;}}});
  assert.equal(r.status,200);assert.equal(touched,false);
  const html=await r.text(); assert.match(html,/autoplay muted playsinline/); assert.doesNotMatch(html,/getUserMedia|captcha|password|Sign in/);
  assert.equal(r.headers.get('Referrer-Policy'),'no-referrer');assert.equal(r.headers.get('Cache-Control'),'no-store');
  const clientScript=await browserResponse('/remote/client.js').text();
  assert.match(clientScript,/browser_ping/);
  assert.match(clientScript,/linkClientId/);
  assert.match(clientScript,/history\.replaceState/);
});
test('browser public origin accepts only a clean HTTPS origin and otherwise falls back safely',()=>{
  const request=new Request('https://worker.example/v1/browser-sessions');
  assert.equal(browserPublicOrigin(request,{}),'https://worker.example');
  assert.equal(browserPublicOrigin(request,{BROWSER_PUBLIC_ORIGIN:'https://remote.example/'}),'https://remote.example');
  for(const value of [
    'http://remote.example',
    'https://user:pass@remote.example',
    'https://remote.example/path',
    'https://remote.example/?query=1',
    'not a url'
  ]) assert.equal(browserPublicOrigin(request,{BROWSER_PUBLIC_ORIGIN:value}),'https://worker.example');
});
test('claim is idempotent, refresh rotates epoch, another controller is refused while owner is live',async()=>{
  const f=await fixture();
  const first=await f.room.claimBrowser(f.c,client,instance,f.now);
  assert.equal(first.browserEpoch,1);
  assert.equal((await f.room.claimBrowser(f.c,client,instance,f.now+1)).browserEpoch,1);
  assert.equal((await f.room.claimBrowser(f.c,crypto.randomUUID(),crypto.randomUUID(),f.now+2)).code,'controller_busy');
  const replacement=crypto.randomUUID();
  assert.equal((await f.room.claimBrowser(f.c,client,replacement,f.now+3)).browserEpoch,2);
  assert.equal((await f.room.authorizeRequest(f.c,instance)).code,'controller_replaced');
  assert.equal((await f.room.authorizeRequest(f.c,replacement)).ok,true);
  assert.equal((await f.room.authorizeRequest(f.h,null)).ok,true);
});
test('concurrent claims admit one controller and browser heartbeat protects its live lease',async()=>{
  const f=await fixture();
  const results=await Promise.all([f.room.claimBrowser(f.c,client,instance,f.now),f.room.claimBrowser(f.c,crypto.randomUUID(),crypto.randomUUID(),f.now)]);
  assert.equal(results.filter(r=>r.ok).length,1);
  const s=await f.storage.get('session');s.browser.lastSeen=f.now-44_000;await f.storage.put('session',s);
  let pong;
  await f.room.webSocketMessage({deserializeAttachment:()=>({role:'controller',instanceId:instance}),send:v=>pong=v},'browser_ping');
  assert.equal(pong,'pong'); assert.ok((await f.storage.get('session')).browser.lastSeen>=f.now);
});
test('a concurrent old socket heartbeat cannot restore the replaced controller',async()=>{
  const f=await fixture();await f.room.claimBrowser(f.c,client,instance,f.now);
  const next=crypto.randomUUID();let closed;
  const old={deserializeAttachment:()=>({role:'controller',instanceId:instance}),send(){},close:code=>closed=code};
  await Promise.all([f.room.claimBrowser(f.c,client,next,f.now+1),f.room.webSocketMessage(old,'browser_ping')]);
  assert.equal((await f.storage.get('session')).browser.instanceId,next);
  assert.equal((await f.storage.get('session')).browser.epoch,2);assert.equal(closed,4009);
});
test('expired owner can be replaced but expired or stopped sessions cannot be resumed',async()=>{
  const f=await fixture(); await f.room.claimBrowser(f.c,client,instance,f.now);
  assert.equal((await f.room.claimBrowser(f.c,crypto.randomUUID(),crypto.randomUUID(),f.now+46_000)).ok,true);
  await f.room.closeSession(f.h,f.now+47_000);
  assert.equal((await f.room.claimBrowser(f.c,client,instance,f.now+48_000)).status,410);
  const g=await fixture();assert.equal((await g.room.claimBrowser(g.c,client,instance,g.now+300_001)).status,410);
});
test('host and browser credentials are separate; browser cannot mark its own projection ready',async()=>{
  const f=await fixture();
  assert.equal((await f.room.claimBrowser(f.h,client,instance,f.now)).status,401);
  assert.equal((await f.room.claimBrowser(f.c,client,instance,f.now)).ok,true);
  assert.equal((await f.room.transition(f.c,'SCREEN_READY',f.now)).status,403);
  assert.equal((await f.room.transition(f.h,'SCREEN_READY',f.now)).ok,true);
  assert.equal((await f.room.transition(f.h,'LIVE',f.now)).ok,true);
  assert.equal(f.storage.alarm,f.now+7_200_000);
  assert.equal((await f.call(`/v1/sessions/${sid}`,controller,undefined,{'X-Aaris-Instance':instance})).status,200);
  assert.equal((await f.call(`/v1/sessions/${sid}`,controller)).status,409);
});
test('cross-origin claim and invalid browser websocket credentials are refused',async()=>{
  const f=await fixture();
  assert.equal((await f.call(`/v1/sessions/${sid}/browser-claim`,controller,{clientId:client,instanceId:instance},{Origin:'https://evil.test'})).status,403);
  const r=await worker.fetch(new Request(`https://remote.test/v1/sessions/${sid}/socket`,{headers:{Origin:'https://evil.test','Sec-WebSocket-Protocol':`aaris-remote, auth.${controller}, instance.${instance}`}}),f.env);
  assert.equal(r.status,401);
});
test('legacy phone-to-phone approval, signaling, and close work without browser ownership',async()=>{
  const f=await fixture();await f.storage.deleteAll();
  assert.equal((await f.room.init(sid,f.h,'host',f.now,f.now+300_000)).created,true);
  assert.equal((await f.room.redeem(f.c,'controller',f.now)).ok,true);
  for(const state of ['HOST_APPROVED','SCREEN_READY','LIVE'])assert.equal((await f.room.transition(f.h,state,f.now)).ok,true);
  assert.equal((await f.room.authorizeRequest(f.c,null)).ok,true);
  assert.equal((await f.room.publishEvent(f.h,'description',{type:'offer',sdp:'v=0'},f.now)).ok,true);
  assert.equal((await f.room.closeSession(f.h,f.now)).ok,true);
  assert.equal((await f.call(`/v1/sessions/${sid}`,host)).status,200);
});
const wire=createBrowserProtocol(), hello={secret:-9007199254740997n,generation:42,width:1080,height:2400};
test('JavaScript packets match the shared fixtures decoded by Android unit tests',async()=>{
  const file=await fs.readFile(new URL('../app/src/test/resources/browser-control-v1.properties',import.meta.url),'utf8');
  const fixtures=Object.fromEntries(file.split('\n').filter(l=>l&&!l.startsWith('#')).map(l=>l.split('=')));
  for(const [name,args] of [['tap',{x:.5,y:1}],['longPress',{x:0,y:1,durationMs:600}],['swipe',{x:.2,y:.8,toX:.2,toY:.1,durationMs:350}],['back',{}],['home',{}],['recents',{}],['text',{text:'Hello नमस्ते'}],['drag',{points:[{x:0,y:1},{x:.5,y:.5},{x:1,y:0}],durationMs:700}]]) {
    assert.equal(Buffer.from(wire.command(name,hello,9007199254740999n,args)).toString('hex'),fixtures[name]);
  }
});
test('binary control preserves signed 64-bit lease and sequence and matches Android coordinate quantization',()=>{
  const b=wire.command('tap',hello,9007199254740999n,{x:.5,y:1}),v=new DataView(b);
  assert.equal(b.byteLength,26);assert.equal(v.getUint8(0),1);assert.equal(v.getUint8(1),3);
  assert.equal(v.getBigInt64(2),hello.secret);assert.equal(v.getInt32(10),42);assert.equal(v.getBigInt64(14),9007199254740999n);
  assert.equal(v.getUint16(22),32767);assert.equal(v.getUint16(24),65535);
  assert.equal(new DataView(wire.heartbeat(hello)).getBigInt64(2),hello.secret);
  assert.throws(()=>wire.command('tap',hello,1n,{x:NaN,y:.5}));
  assert.throws(()=>wire.command('text',hello,1n,{text:'😀'.repeat(513)}));
});
test('letterboxing, portrait, landscape and display rotation map to the actual visible video',()=>{
  assert.deepEqual(wire.point(320,480,{left:120,top:80,width:400,height:800},1080,2160),{x:.5,y:.5});
  const rect={left:0,top:0,width:800,height:600};
  assert.equal(wire.point(5,300,rect,1080,2400),null);
  assert.deepEqual(wire.point(400,300,rect,1080,2400),{x:.5,y:.5});
  assert.equal(wire.point(400,1,rect,2400,1080),null);
  assert.deepEqual(wire.point(400,300,rect,2400,1080),{x:.5,y:.5});
  assert.equal(wire.point(0,0,rect,0,0),null);
});
test('long press, swipe, drag and text use the existing Android v1 packet shapes',()=>{
  assert.equal(wire.command('longPress',hello,1n,{x:0,y:0,durationMs:1}).byteLength,28);
  assert.equal(new DataView(wire.command('longPress',hello,1n,{x:0,y:0,durationMs:1})).getUint16(26),250);
  assert.equal(wire.command('swipe',hello,1n,{x:0,y:0,toX:1,toY:1}).byteLength,32);
  const drag=wire.command('drag',hello,1n,{points:[{x:0,y:0},{x:1,y:1}],durationMs:400});
  assert.equal(drag.byteLength,33);assert.equal(new DataView(drag).getUint8(22),2);
  assert.equal(new DataView(drag).getUint16(31),400);
  assert.equal(wire.command('text',hello,1n,{text:'हाय'}).byteLength,24+new TextEncoder().encode('हाय').length);
});

test('read-only query links expose phone status without claiming a controller; no GET performs actions',async()=>{
  const f=await fixture();
  const url=`https://remote.test/remote/?session=${sid}&access=${controller}&client=${client}`;
  const page=await worker.fetch(new Request(url),f.env);
  assert.equal(page.status,200);assert.match(await page.text(),/Phone offline/);
  assert.equal((await f.storage.get('session')).browser,undefined);
  const obs=await worker.fetch(new Request(url.replace('/remote/','/remote/observe')),f.env);
  assert.equal((await obs.json()).phoneOnline,false);
  assert.equal((await f.call(`/v1/sessions/${sid}/agent-action`)).status,409);
  assert.equal([...f.storage.values.keys()].filter(k=>k.startsWith('agent:r:')).length,0);
});
test('HTTP screenshot mode dispatches once, fences replaced controllers and rejects conflicting action IDs',async()=>{
  const f=await fixture();await f.room.claimBrowser(f.c,client,instance,f.now);
  const sent=[];f.sockets.push({a:{role:'host-agent'},send:x=>sent.push(JSON.parse(x))});
  const args={actionId:'unique_action_1',action:'home'};
  const first=await f.room.agentEnqueue(f.c,'action',args,instance);
  assert.equal(first.ok,true);assert.equal(sent.length,1);
  assert.equal((await f.room.agentEnqueue(f.c,'action',args,instance)).requestId,first.requestId);
  assert.equal(sent.length,1);
  assert.equal((await f.room.agentEnqueue(f.c,'action',{...args,action:'back'},instance)).error,'ACTION_ID_CONFLICT');
  assert.equal((await f.room.agentStart(f.c,first.requestId)).ok,false);
  assert.equal((await f.room.agentStart(f.h,first.requestId)).ok,true);
  assert.equal((await f.room.agentStart(f.h,first.requestId)).ok,false);
  assert.equal((await f.room.agentPublish(f.c,{applied:true},first.requestId)).ok,false);
  assert.equal((await f.room.agentPublish(f.h,{applied:true},first.requestId)).ok,true);
  assert.equal((await f.room.agentResult(f.c,first.requestId,instance)).result.applied,true);
  const next={actionId:'unique_action_2',action:'tap'};
  await f.room.agentEnqueue(f.c,'action',next,instance);
  await f.room.claimBrowser(f.c,client,crypto.randomUUID(),f.now+1);
  assert.equal((await f.room.agentStart(f.h,next.actionId)).error,'REQUEST_EXPIRED_OR_USED');
});
test('server-rendered screenshot links carry one observation and can be read without JavaScript',async()=>{
  const f=await fixture();f.sockets.push({a:{role:'host-agent'},send(){}});
  const id=crypto.randomUUID();
  await f.room.agentPublish(f.h,{observationId:id,screenVersion:1,commandNonce:'nonce',image:{mimeType:'image/jpeg',width:2,height:2,data:btoa('jpeg')},note:'<script>alert(1)</script>'});
  const url=`https://remote.test/remote/?session=${sid}&access=${controller}`;
  const html=await (await worker.fetch(new Request(url),f.env)).text();
  assert.match(html,/AARIS_ACTION_BEGIN/);assert.match(html,/View current phone screenshot/);
  assert.match(html,/data-observation-id=/);assert.ok(html.includes('src="data:image/jpeg;base64,'+btoa('jpeg')));
  assert.ok(!html.includes('<script>alert(1)</script>'));
  assert.equal((await f.storage.get('session')).browser,undefined);
  const frame=await worker.fetch(new Request(url.replace('/remote/','/remote/frame')+`&observationId=${id}`),f.env);
  assert.equal(frame.headers.get('content-type'),'image/jpeg');assert.equal(await frame.text(),'jpeg');
  assert.equal((await worker.fetch(new Request(url.replace('/remote/','/remote/frame')+'&observationId=old'),f.env)).status,409);
  await f.room.closeSession(f.h,f.now+10);
  assert.equal((await worker.fetch(new Request(url.replace('/remote/','/remote/frame')+`&observationId=${id}`),f.env)).status,410);
});

test('a connected host exposes capture failures instead of a permanent Connecting screen',async()=>{
  const f=await fixture();f.sockets.push({a:{role:'host-agent'},send(){}});
  await f.room.agentPublish(f.h,{error:'DEVICE_LOCKED_OR_ACCESSIBILITY_OFF',applied:false});
  const result=await f.room.agentObservation(f.c);
  assert.equal(result.phoneOnline,true);assert.equal(result.error,'DEVICE_LOCKED_OR_ACCESSIBILITY_OFF');
  const html=await (await worker.fetch(new Request(`https://remote.test/remote/?session=${sid}&access=${controller}`),f.env)).text();
  assert.match(html,/Unlock the phone or restore Accessibility/);
  await f.room.closeSession(f.h,f.now+1);
  assert.equal([...f.storage.values.keys()].filter(k=>k.startsWith('agent:')).length,0);
});

test('observation reads refresh old frames once; image downloads do not invalidate their coordinates',async()=>{
  const f=await fixture(),sent=[];f.sockets.push({a:{role:'host-agent'},send:x=>sent.push(JSON.parse(x))});
  const id=crypto.randomUUID(),image={mimeType:'image/jpeg',width:2,height:2,data:btoa('jpeg')};
  await f.room.agentPublish(f.h,{observationId:id,screenVersion:1,commandNonce:'nonce',image});
  const stored=await f.storage.get('agent:observation');stored.receivedAtMs=Date.now()-5000;await f.storage.put('agent:observation',stored);
  const query=`?session=${sid}&access=${controller}`;
  await worker.fetch(new Request(`https://remote.test/remote/${query}`),f.env);
  assert.equal(sent.length,0,'Rendering an existing image cannot start a capture that invalidates its action ticket');
  const frame=await worker.fetch(new Request(`https://remote.test/remote/frame${query}&observationId=${id}`),f.env);
  assert.equal(frame.status,200);assert.equal(await frame.text(),'jpeg');assert.equal(sent.length,0);
  const observation=await worker.fetch(new Request(`https://remote.test/remote/observe${query}`),f.env);
  assert.equal((await observation.json()).observation.observationId,id);assert.equal(sent.length,1);assert.equal(sent[0].operation,'observe');
  await Promise.all([f.room.agentObservation(f.c),f.room.agentObservation(f.c)]);
  assert.equal(sent.length,1,'Concurrent reads coalesce while the phone captures');
  await f.room.agentStart(f.h,'observe');
  const next=crypto.randomUUID();await f.room.agentPublish(f.h,{observationId:next,screenVersion:2,commandNonce:'nonce',image},'observe');
  assert.equal((await f.room.agentObservation(f.c)).observation.observationId,next);assert.equal(sent.length,1);
  const prior=await worker.fetch(new Request(`https://remote.test/remote/frame${query}&observationId=${id}`),f.env);
  assert.equal(prior.status,200);assert.equal(prior.headers.get('X-Aaris-Observation'),id,'A slow image download retains exactly its requested frame');
  const previous=await f.storage.get('agent:previous');previous.expiresAtMs=Date.now()-1;await f.storage.put('agent:previous',previous);
  assert.equal((await worker.fetch(new Request(`https://remote.test/remote/frame${query}&observationId=${id}`),f.env)).status,409);
});
