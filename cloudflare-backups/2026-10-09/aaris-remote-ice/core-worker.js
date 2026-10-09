import { DurableObject } from "cloudflare:workers";
import { agentPage, agentParameters, observationResponse } from "./browser-agent.js";
import { browserResponse } from "./browser-console.js";

const CODE_TTL=300000,APPROVAL_TTL=180000,CONNECT_TTL=180000;
const CLOSED_RETENTION=3600000,MAX_EVENTS=512;
const BROWSER_WAIT_MS=300000,BROWSER_SESSION_MS=7200000,BROWSER_OWNER_MS=45000;
const j=(data,status=200)=>new Response(JSON.stringify(data),{status,headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff"}});
const fail=(status,error,message)=>j({ok:false,error,message},status);
const hex=b=>Array.from(b,x=>x.toString(16).padStart(2,"0")).join("");
function rb(n){const b=new Uint8Array(n);crypto.getRandomValues(b);return b}
function b64u(b){let s="";for(const x of b)s+=String.fromCharCode(x);return btoa(s).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/g,"")}
const token=(n=32)=>b64u(rb(n));
function code12(){let s="";while(s.length<12)for(const b of rb(24)){if(b>=250)continue;s+=String(b%10);if(s.length===12)break}return s}
async function sha(v){return hex(new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v))))}
function bearer(r){const h=r.headers.get("authorization")||"";if(!h.toLowerCase().startsWith("bearer "))return null;const v=h.slice(7).trim();return v.length>=32&&v.length<=256?v:null}
async function body(r){const x=await r.text();if(x.length>786432)throw new Error("request_too_large");return x?JSON.parse(x):{}}
function deadline(s){if(!s)return null;if(s.state==="CODE_ACTIVE")return s.expiresAtMs;if(s.state==="PAIR_PENDING")return s.approvalExpiresAtMs||null;if(s.state==="HOST_APPROVED"||s.state==="SCREEN_READY")return s.connectExpiresAtMs||null;if(s.state==="LIVE"&&s.browserLink)return s.sessionExpiresAtMs;return null}
const pub=s=>s?{sessionId:s.sessionId,state:s.state,hostUid:s.hostId,controllerUid:s.controllerId||null,displayGeneration:s.displayGeneration||0,deadlineAtMs:deadline(s),...(s.browserLink?{browserEpoch:s.browser?.epoch||0,browserLink:true}: {})}:null;
const withoutImageData=value=>value?.image?{...value,image:{...value.image,data:undefined}}:value;
const browserInstance=/^[a-f0-9-]{36}$/;
export function browserPublicOrigin(request,env){
  const fallback=new URL(request.url).origin,raw=String(env?.BROWSER_PUBLIC_ORIGIN||'').trim();
  if(!raw)return fallback;
  try{
    const u=new URL(raw);
    if(u.protocol!=='https:'||u.username||u.password||u.pathname!=='/'||u.search||u.hash)return fallback;
    return u.origin;
  }catch(_){return fallback}
}
function browserSocketRequest(request){
  const origin=new URL(request.url).origin;
  if(request.headers.get('Origin')!==origin)return null;
  const parts=(request.headers.get('Sec-WebSocket-Protocol')||'').split(',').map(x=>x.trim());
  const auth=parts.find(x=>/^auth\.[A-Za-z0-9_-]{43}$/.test(x));
  const instance=parts.find(x=>/^instance\.[a-f0-9-]{36}$/.test(x));
  if(!parts.includes('aaris-remote')||!auth||!instance)return null;
  const headers=new Headers(request.headers);
  headers.set('Authorization','Bearer '+auth.slice(5));headers.set('X-Aaris-Instance',instance.slice(9));
  return new Request(request,{headers});
}

export class PairingDirectory extends DurableObject{
  async cleanup(now=Date.now()){
    const items=await this.ctx.storage.list({prefix:"c:"});
    const expired=[];
    for(const [key,value] of items){
      if(!value||Number(value.expiresAtMs||0)<=now)expired.push(key);
    }
    if(expired.length)await this.ctx.storage.delete(expired);
  }
  async allocate(codeHash,sessionId,expiresAtMs){
    const now=Date.now();
    await this.cleanup(now);
    const key="c:"+codeHash;
    if(await this.ctx.storage.get(key))return false;
    await this.ctx.storage.put(key,{sessionId,expiresAtMs});
    const alarm=await this.ctx.storage.getAlarm();
    if(alarm==null||expiresAtMs<alarm)await this.ctx.storage.setAlarm(expiresAtMs+1000);
    return true;
  }
  async lookup(codeHash,now=Date.now()){
    const key="c:"+codeHash;
    const value=await this.ctx.storage.get(key);
    if(!value)return null;
    if(Number(value.expiresAtMs||0)<=now){
      await this.ctx.storage.delete(key);
      return null;
    }
    return value.sessionId||null;
  }
  async alarm(){
    await this.cleanup(Date.now());
    const items=await this.ctx.storage.list({prefix:"c:"});
    let next=null;
    for(const value of items.values()){
      const at=Number(value.expiresAtMs||0);
      if(at>0&&(next==null||at<next))next=at;
    }
    if(next!=null)await this.ctx.storage.setAlarm(next+1000);
  }
}

export class AarisSession extends DurableObject{
  constructor(ctx,env){super(ctx,env);this.ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping","pong"))}
  async session(){return(await this.ctx.storage.get("session"))||null}
  role(s,h){if(!s||!h)return null;if(s.hostTokenHash===h)return"host";if(s.controllerTokenHash===h)return"controller";return null}
  broadcastSession(s){const m=JSON.stringify({kind:"session",session:pub(s)});for(const w of this.ctx.getWebSockets())try{w.send(m)}catch(_){}}
  broadcastEvent(e){const m=JSON.stringify({kind:"signal_event",event:e});for(const w of this.ctx.getWebSockets())try{w.send(m)}catch(_){}}
  async init(sessionId,hostTokenHash,hostId,now,expiresAtMs){
    const old=(await this.ctx.storage.get("session"))||null;
    if(old)return{created:false};
    const s={sessionId,state:"CODE_ACTIVE",hostTokenHash,controllerTokenHash:null,hostId,controllerId:null,createdAtMs:now,expiresAtMs,approvalExpiresAtMs:null,connectExpiresAtMs:null,closedAtMs:null,displayGeneration:0};
    await this.ctx.storage.put("session",s);
    await this.ctx.storage.put("seq",0);
    await this.ctx.storage.setAlarm(expiresAtMs+1000);
    return{created:true,snapshot:pub(s)};
  }
  async initBrowser(sessionId,hostTokenHash,controllerTokenHash,now){
    if(await this.session())return{created:false};
    // The owner explicitly starts this mode; there is no anonymous pairing-code
    // redemption. Screen capture still requires Android's projection consent.
    const s={sessionId,state:'HOST_APPROVED',hostTokenHash,controllerTokenHash,
      hostId:'h_'+token(12),controllerId:'browser',createdAtMs:now,browserLink:true,
      connectExpiresAtMs:now+BROWSER_WAIT_MS,sessionExpiresAtMs:now+BROWSER_SESSION_MS,displayGeneration:0};
    await this.ctx.storage.put('session',s);await this.ctx.storage.put('seq',0);
    await this.ctx.storage.setAlarm(s.connectExpiresAtMs);
    return{created:true,snapshot:pub(s)};
  }
  async claimBrowser(h,clientId,instanceId,now){
    if(!browserInstance.test(clientId)||!browserInstance.test(instanceId))return{ok:false,status:400,code:'bad_instance'};
    let result,updated;
    await this.ctx.storage.transaction(async t=>{
      const s=await t.get('session');
      if(!s?.browserLink||this.role(s,h)!=='controller'){result={ok:false,status:401,code:'unauthorized'};return}
      if(s.state==='CLOSED'||deadline(s)<=now){result={ok:false,status:410,code:'session_ended'};return}
      if(s.browser&&s.browser.clientId!==clientId&&now-s.browser.lastSeen<BROWSER_OWNER_MS){result={ok:false,status:409,code:'controller_busy'};return}
      const same=s.browser?.instanceId===instanceId;
      const afterSequence=same?s.browser.afterSequence:Number(await t.get('seq')||0);
      s.browser={clientId,instanceId,lastSeen:now,epoch:same?s.browser.epoch:(s.browser?.epoch||0)+1,afterSequence};
      await t.put('session',s);updated=s;
      result={ok:true,afterSequence,browserEpoch:s.browser.epoch};
    });
    if(result.ok){
      for(const ws of this.ctx.getWebSockets('controller'))if(ws.deserializeAttachment()?.instanceId!==instanceId)try{ws.close(4009,'Controller replaced')}catch(_){}
      this.broadcastSession(updated);
    }
    return result;
  }
  browserAuthorized(s,h,instanceId){
    if(!s?.browserLink||this.role(s,h)!=='controller')return true;
    return Boolean(s.browser&&s.browser.instanceId===instanceId);
  }
  async authorizeRequest(h,instanceId){
    const s=await this.session(),r=this.role(s,h);
    if(!r)return{ok:false,status:401,code:'unauthorized'};
    if(s.browserLink&&(s.state==='CLOSED'||deadline(s)<=Date.now()))return{ok:false,status:410,code:'session_ended'};
    if(!this.browserAuthorized(s,h,instanceId))return{ok:false,status:409,code:'controller_replaced'};
    return{ok:true};
  }
  // Read-only observation does not claim the browser or consume the link.
  async agentObservation(h,refresh=true,frameId=null) {
    const s=await this.session();
    if(!s?.browserLink||!this.role(s,h))return{ok:false,status:401,error:'unauthorized'};
    if(s.state==='CLOSED'||deadline(s)<=Date.now())return{ok:false,status:410,error:'session_ended'};
    let observation=await this.ctx.storage.get('agent:observation');
    if(!refresh&&frameId&&frameId!==observation?.observationId){
      const previous=await this.ctx.storage.get('agent:previous');
      if(previous?.observationId===frameId&&previous.expiresAtMs>Date.now())observation=previous;
    }
    const online=this.ctx.getWebSockets('host-agent').length>0,nativeOnline=this.ctx.getWebSockets('host').length>0;
    const captureStatus=await this.ctx.storage.get('agent:status');
    if(refresh&&online&&(!observation||Date.now()-observation.receivedAtMs>2500))await this.agentEnqueue(h,'observe',{},null);
    return{ok:true,phoneOnline:online||nativeOnline,agentOnline:online,state:s.state,observation:observation&&Date.now()-observation.receivedAtMs<90000?observation:null,
      error:online?(captureStatus?.error||'OBSERVATION_PENDING'):nativeOnline?'SCREENSHOT_ADAPTER_UNAVAILABLE':'PHONE_OFFLINE'};
  }
  async agentEnqueue(h,kind,args,instanceId) {
    let result,message;
    const id=kind==='observe'?'observe':String(args.actionId||'');
    if(kind!=='observe'&&!/^[a-zA-Z0-9_-]{8,80}$/.test(id))return{ok:false,status:400,error:'INVALID_ACTION_ID'};
    const digest=await sha(JSON.stringify(args));
    await this.ctx.storage.transaction(async t=>{
      const s=await t.get('session');
      if(!s?.browserLink||this.role(s,h)!=='controller'){result={ok:false,status:401,error:'unauthorized'};return}
      if(s.state==='CLOSED'||deadline(s)<=Date.now()){result={ok:false,status:410,error:'session_ended'};return}
      if(kind==='action'&&!this.browserAuthorized(s,h,instanceId)){result={ok:false,status:409,error:'controller_replaced'};return}
      if(!this.ctx.getWebSockets('host-agent').length){result={ok:false,status:503,error:'PHONE_OFFLINE'};return}
      const old=await t.get('agent:r:'+id);
      if(old&&(kind==='action'||(!old.result&&old.expiresAtMs>Date.now()))){
        result=kind==='action'&&old.digest!==digest?{ok:false,status:409,error:'ACTION_ID_CONFLICT'}:{ok:true,requestId:id,result:old.result||null};return;
      }
      const pending=await t.list({prefix:'agent:r:'});
      if([...pending.values()].some(x=>!x.result&&x.expiresAtMs>Date.now())){result={ok:false,status:409,error:'ACTION_IN_PROGRESS'};return}
      const now=Date.now();
      message={kind:'agent_request',requestId:id,operation:kind,args,instanceId,epoch:s.browser?.epoch||0,expiresAtMs:now+12000};
      await t.put('agent:r:'+id,{...message,digest,createdAtMs:now,dispatched:false});
      // Bound retained idempotency records. Expired actions are never replayed.
      const oldKeys=[...pending].sort((a,b)=>a[1].createdAtMs-b[1].createdAtMs);
      for(const [key] of oldKeys.slice(0,Math.max(0,oldKeys.length-63)))await t.delete(key);
      result={ok:true,requestId:id,result:null};
    });
    if(message)for(const ws of this.ctx.getWebSockets('host-agent'))try{ws.send(JSON.stringify(message))}catch(_){}
    return result;
  }
  async agentStart(h,id) {
    let result;
    await this.ctx.storage.transaction(async t=>{
      const s=await t.get('session'),r=await t.get('agent:r:'+id);
      if(!s?.browserLink||this.role(s,h)!=='host'){result={ok:false,status:401,error:'unauthorized'};return}
      if(!r||r.dispatched||r.result||r.expiresAtMs<=Date.now()||s.state==='CLOSED'||deadline(s)<=Date.now()||
        (r.operation==='action'&&(s.browser?.instanceId!==r.instanceId||s.browser?.epoch!==r.epoch))){result={ok:false,status:409,error:'REQUEST_EXPIRED_OR_USED'};return}
      r.dispatched=true;await t.put('agent:r:'+id,r);result={ok:true};
    });return result;
  }
  async agentPublish(h,result,requestId=null) {
    let outcome;
    await this.ctx.storage.transaction(async t=>{
      const s=await t.get('session');
      if(!s?.browserLink||this.role(s,h)!=='host'){outcome={ok:false,status:401,error:'unauthorized'};return}
      if(s.state==='CLOSED'||deadline(s)<=Date.now()){outcome={ok:false,status:410,error:'session_ended'};return}
      if(JSON.stringify(result).length>700000){outcome={ok:false,status:413,error:'FRAME_TOO_LARGE'};return}
      if(requestId){const r=await t.get('agent:r:'+requestId);if(!r?.dispatched||r.result){outcome={ok:false,status:409,error:'REQUEST_EXPIRED_OR_USED'};return}r.result=result;await t.put('agent:r:'+requestId,r)}
      if(result.error&&!result.observationId)await t.put('agent:status',{error:String(result.error).slice(0,100),receivedAtMs:Date.now()});
      if(result.observationId)await t.delete('agent:status');
      if(result.actionId&&!result.observationId){await t.delete('agent:observation');await t.delete('agent:previous')}
      if(result.observationId&&result.image?.mimeType==='image/jpeg'&&typeof result.image.data==='string')
        {const previous=await t.get('agent:observation');
         if(previous&&previous.observationId!==result.observationId)await t.put('agent:previous',{...previous,expiresAtMs:Date.now()+15000});
         const observation={...result,receivedAtMs:Date.now()};delete observation.error;delete observation.actionId;delete observation.applied;await t.put('agent:observation',observation)}
      outcome={ok:true};
    });return outcome;
  }
  async agentResult(h,id,instanceId) {
    const auth=await this.authorizeRequest(h,instanceId);if(!auth.ok)return auth;
    const r=await this.ctx.storage.get('agent:r:'+id);
    if(!r)return{ok:false,status:404,error:'REQUEST_NOT_FOUND'};
    if(r.operation==='action'&&r.instanceId!==instanceId)return{ok:false,status:409,error:'controller_replaced'};
    return{ok:true,result:r.result|| (r.expiresAtMs<=Date.now()?{error:r.dispatched?'OUTCOME_UNKNOWN':'REQUEST_EXPIRED',applied:null}:null)};
  }
  async redeem(controllerTokenHash,controllerId,now){
    let o;
    await this.ctx.storage.transaction(async t=>{
      const s=(await t.get("session"))||null;
      if(!s){o={ok:false,status:404,code:"invalid_code"};return}
      if(
        s.controllerTokenHash===controllerTokenHash&&
        ["PAIR_PENDING","HOST_APPROVED","SCREEN_READY","LIVE"].includes(s.state)
      ){
        o={ok:true,snapshot:pub(s)};return;
      }
      if(s.state!=="CODE_ACTIVE"){o={ok:false,status:409,code:"code_used"};return}
      if(s.expiresAtMs<=now){s.state="CLOSED";s.closedAtMs=now;await t.put("session",s);o={ok:false,status:410,code:"code_expired"};return}
      s.controllerTokenHash=controllerTokenHash;s.controllerId=controllerId;s.state="PAIR_PENDING";s.approvalExpiresAtMs=now+APPROVAL_TTL;
      await t.put("session",s);await t.setAlarm(s.approvalExpiresAtMs+1000);o={ok:true,snapshot:pub(s)};
    });
    if(o.ok)this.broadcastSession(await this.session());
    return o;
  }
  async snapshot(h){const s=await this.session(),r=this.role(s,h);return r?{ok:true,role:r,snapshot:pub(s)}:{ok:false,status:401,code:"unauthorized"}}
  async transition(h,target,now){
    let o;
    await this.ctx.storage.transaction(async t=>{
      const s=(await t.get("session"))||null,r=this.role(s,h);
      if(!r){o={ok:false,status:401,code:"unauthorized"};return}
      if(r!=="host"){o={ok:false,status:403,code:"host_required"};return}
      if(target==="HOST_APPROVED"){
        if(s.state==="PAIR_PENDING"){
          if(!s.approvalExpiresAtMs||s.approvalExpiresAtMs<=now){o={ok:false,status:410,code:"approval_expired"};return}
          s.state="HOST_APPROVED";s.connectExpiresAtMs=now+CONNECT_TTL;await t.setAlarm(s.connectExpiresAtMs+1000);
        }else if(!["HOST_APPROVED","SCREEN_READY","LIVE"].includes(s.state)){o={ok:false,status:409,code:"invalid_transition"};return}
      }else if(target==="SCREEN_READY"){
        if(s.state==="HOST_APPROVED"){
          if(!s.connectExpiresAtMs||s.connectExpiresAtMs<=now){o={ok:false,status:410,code:"connect_expired"};return}
          s.state="SCREEN_READY";
        }else if(!["SCREEN_READY","LIVE"].includes(s.state)){o={ok:false,status:409,code:"invalid_transition"};return}
      }else if(target==="LIVE"){
        if(s.state==="SCREEN_READY"){
          if(!s.connectExpiresAtMs||s.connectExpiresAtMs<=now){o={ok:false,status:410,code:"connect_expired"};return}
          s.state="LIVE";if(s.browserLink)await t.setAlarm(s.sessionExpiresAtMs);else await t.deleteAlarm();
        }else if(s.state!=="LIVE"){o={ok:false,status:409,code:"invalid_transition"};return}
      }else{o={ok:false,status:400,code:"unsupported_transition"};return}
      await t.put("session",s);o={ok:true,snapshot:pub(s)};
    });
    if(o.ok){
      console.log(JSON.stringify({
        event:"session_transition",
        target,
        state:o.snapshot.state
      }));
      this.broadcastSession(await this.session());
    }
    return o;
  }
  async clearAgentData(){const data=await this.ctx.storage.list({prefix:'agent:'});if(data.size)await this.ctx.storage.delete([...data.keys()])}
  async closeSession(h,now,instanceId=null){
    let result,updated;
    await this.ctx.storage.transaction(async t=>{
      const s=await t.get('session'),r=this.role(s,h);
      if(!r){result={ok:false,status:401,code:'unauthorized'};return}
      if(!this.browserAuthorized(s,h,instanceId)){result={ok:false,status:409,code:'controller_replaced'};return}
      if(s.state!=='CLOSED'){s.state='CLOSED';s.closedAtMs=now;await t.put('session',s);await t.setAlarm(now+CLOSED_RETENTION);updated=s}
      result={ok:true,snapshot:pub(s)};
    });
    if(updated){await this.clearAgentData();this.broadcastSession(updated)}
    return result;
  }
  async authorizeIce(h){
    const s=await this.session(),r=this.role(s,h);
    /*
     * Controller transport is intentionally pre-warmed after explicit host
     * approval, before MediaProjection consent completes. Issuing ephemeral
     * TURN credentials to that already-approved controller lets its WebRTC
     * owner and signaling socket exist before the host publishes the first
     * offer. Screen media/signaling itself remains gated by publishEvent()
     * until SCREEN_READY/LIVE, so approval does not bypass screen consent.
     */
    const controllerPrewarm=r==="controller"&&s?.state==="HOST_APPROVED";
    return{ok:Boolean(r&&(controllerPrewarm||["SCREEN_READY","LIVE"].includes(s.state))),role:r,state:s?.state||null};
  }
  async publishEvent(h,kind,payload,now,instanceId=null){
    const s=await this.session(),r=this.role(s,h);
    if(!r)return{ok:false,status:401,code:"unauthorized"};
    if(!["description","candidate","ice_restart","presence"].includes(kind))return{ok:false,status:400,code:"bad_event_kind"};
    const prewarmPresence=s.state==="HOST_APPROVED"&&r==="controller"&&kind==="presence";
    if(!prewarmPresence&&!["SCREEN_READY","LIVE"].includes(s.state))return{ok:false,status:409,code:"signaling_not_ready"};
    if(JSON.stringify(payload||{}).length>655360)return{ok:false,status:413,code:"event_too_large"};
    let e,rejected;
    await this.ctx.storage.transaction(async t=>{
      const current=await t.get('session');
      if(!this.browserAuthorized(current,h,instanceId)){rejected={ok:false,status:409,code:'controller_replaced'};return}
      if(current.state==='CLOSED'||(current.browserLink&&deadline(current)<=now)){rejected={ok:false,status:410,code:'session_ended'};return}
      const seq=Number((await t.get("seq"))||0)+1;
      e={seq,senderRole:r,kind,payload:payload||{},createdAtMs:now};
      await t.put("seq",seq);await t.put("e:"+String(seq).padStart(12,"0"),e);
      if(seq>MAX_EVENTS)await t.delete("e:"+String(seq-MAX_EVENTS).padStart(12,"0"));
    });
    if(rejected)return rejected;
    console.log(JSON.stringify({
      event:"signal_event",
      kind,
      senderRole:r,
      seq:e.seq
    }));
    this.broadcastEvent(e);return{ok:true,event:e};
  }
  async eventsAfter(h,after){
    const s=await this.session(),r=this.role(s,h);
    if(!r)return{ok:false,status:401,code:"unauthorized"};
    const all=await this.ctx.storage.list({prefix:"e:"}),events=[];
    for(const v of all.values()){if(v.seq>after)events.push(v);if(events.length>=MAX_EVENTS)break}
    events.sort((a,b)=>a.seq-b.seq);return{ok:true,role:r,events};
  }
  async fetch(request){
    const u=new URL(request.url);
    if(!u.pathname.endsWith("/socket")&&!u.pathname.endsWith("/agent-socket"))return new Response("Not found",{status:404});
    if((request.headers.get("upgrade")||"").toLowerCase()!=="websocket")return new Response("Expected WebSocket",{status:426});
    const raw=bearer(request);if(!raw)return new Response("Unauthorized",{status:401});
    const h=await sha(raw),s=await this.session(),r=this.role(s,h);if(!r)return new Response("Unauthorized",{status:401});
    const agentSocket=u.pathname.endsWith('/agent-socket');
    if(agentSocket&&(!s.browserLink||r!=='host'))return new Response('Unauthorized',{status:403});
    const instanceId=request.headers.get('X-Aaris-Instance');
    if(s.browserLink&&(s.state==='CLOSED'||deadline(s)<=Date.now()))return new Response('Ended',{status:410});
    if(!this.browserAuthorized(s,h,instanceId))return new Response('Controller replaced',{status:409});
    if(s.browserLink&&r==='controller')for(const old of this.ctx.getWebSockets('controller'))try{old.close(4009,'Socket replaced')}catch(_){}
    const pair=new WebSocketPair(),[client,server]=Object.values(pair);
    const role=agentSocket?'host-agent':r;
    if(agentSocket)for(const old of this.ctx.getWebSockets('host-agent'))try{old.close(4009,'Agent socket replaced')}catch(_){}
    this.ctx.acceptWebSocket(server,[role]);server.serializeAttachment({role,instanceId});
    console.log(JSON.stringify({
      event:"socket_open",
      role:r,
      state:s.state,
      after:Math.max(0,Number(u.searchParams.get("after")||0)||0)
    }));
    server.send(JSON.stringify({kind:"session",session:pub(s)}));
    const backlog=agentSocket?{ok:false}:await this.eventsAfter(h,Math.max(0,Number(u.searchParams.get("after")||0)||0));
    if(backlog.ok)for(const e of backlog.events)server.send(JSON.stringify({kind:"signal_event",event:e}));
    return new Response(null,{status:101,webSocket:client,...(instanceId?{headers:{'Sec-WebSocket-Protocol':'aaris-remote'}}:{})});
  }
  async webSocketMessage(ws,m){if(m==="ping"||m==="browser_ping"){
    const a=ws.deserializeAttachment();
    if(a?.role==='controller'){
      let valid=true;
      await this.ctx.storage.transaction(async t=>{
        const s=await t.get('session');
        if(!s?.browserLink)return;
        if(s.state==='CLOSED'||deadline(s)<=Date.now()||s.browser?.instanceId!==a.instanceId){valid=false;return}
        s.browser.lastSeen=Date.now();await t.put('session',s);
      });
      if(!valid){ws.close(4009,'Controller replaced');return}
    }
    ws.send('pong');
  }}
  async webSocketClose(ws,c,r){
    const a=ws.deserializeAttachment?.();
    console.log(JSON.stringify({
      event:"socket_close",
      role:a?.role||"unknown",
      code:c
    }));
    try{ws.close(c,r)}catch(_){}
  }
  async webSocketError(ws){try{ws.close(1011,"socket error")}catch(_){}}
  async alarm(){
    const s=await this.session();if(!s)return;const now=Date.now();
    if(s.state==="CLOSED"){
      if(s.closedAtMs&&s.closedAtMs+CLOSED_RETENTION<=now){
        await this.ctx.storage.deleteAll();
      }
      return;
    }
    const d=deadline(s);
    if(d!=null&&d<=now){s.state="CLOSED";s.closedAtMs=now;await this.ctx.storage.put("session",s);await this.clearAgentData();this.broadcastSession(s);await this.ctx.storage.setAlarm(now+CLOSED_RETENTION)}
  }
}

const sessions=(env,id)=>env.SESSIONS.getByName(id);
const directory=env=>env.PAIRINGS.getByName("global");

export default{
  async fetch(request,env){
    try{
      const u=new URL(request.url);
      if(request.method==='GET'&&u.pathname==='/remote/client.js')return browserResponse(u.pathname);
      if(request.method==='GET'&&['/remote','/remote/','/remote/frame','/remote/observe'].includes(u.pathname)){
        const params=agentParameters(u);
        if(!params)return u.pathname.startsWith('/remote/f')||u.pathname==='/remote/observe'?fail(401,'unauthorized','Open the complete phone link.'):browserResponse(u.pathname);
        // HTML and its inline image describe one decision ticket. Rendering an
        // existing page must not start a second capture that revokes that ticket.
        const state=await sessions(env,params.sessionId).agentObservation(await sha(params.access),u.pathname==='/remote/observe',u.searchParams.get('observationId'));
        if(u.pathname==='/remote/frame'||u.pathname==='/remote/observe')return observationResponse(u,state);
        return agentPage(u,state);
      }
      if(request.method==='POST'&&u.pathname==='/v1/browser-sessions'){
        const id=hex(rb(32)),hostToken=token(),controllerToken=token(),browserClientId=crypto.randomUUID(),now=Date.now();
        const r=await sessions(env,id).initBrowser(id,await sha(hostToken),await sha(controllerToken),now);
        return r.created?j({ok:true,sessionId:id,hostToken,controllerToken,browserClientId,expiresAtMs:now+BROWSER_SESSION_MS,browserBaseUrl:browserPublicOrigin(request,env)},201):fail(503,'allocation_failed','Try creating the link again.');
      }
      if(request.method==="GET"&&u.pathname==="/healthz"){
        return j({ok:true,service:"aaris-remote-ice",backend:"cloudflare-durable-objects",version:3});
      }

      if(request.method==="POST"&&u.pathname==="/v1/sessions"){
        for(let i=0;i<8;i++){
          const c=code12(),codeHash=await sha(c),id=hex(rb(32)),hostToken=token(),hostId="h_"+token(12),now=Date.now(),expiresAtMs=now+CODE_TTL;
          if(!(await directory(env).allocate(codeHash,id,expiresAtMs)))continue;
          const r=await sessions(env,id).init(id,await sha(hostToken),hostId,now,expiresAtMs);
          if(!r.created)continue;
          return j({ok:true,sessionId:id,code:c,hostToken,hostUid:hostId,expiresAtMs},201);
        }
        return fail(503,"allocation_failed","Could not allocate a session.");
      }

      if(request.method==="POST"&&u.pathname==="/v1/sessions/redeem"){
        const x=await body(request),c=String(x.code||"").replace(/\D/g,"");
        if(!/^\d{12}$/.test(c))return fail(400,"invalid_code","Enter a valid 12-digit code.");
        let controllerToken=String(x.controllerToken||"");
        if(controllerToken===""){
          // Backward compatibility for the first 1.8.0 Cloudflare build.
          // 1.8.1+ supplies its own stable token so an ambiguous redeem can
          // be retried idempotently.
          controllerToken=token();
        }else if(!/^[A-Za-z0-9_-]{43,128}$/.test(controllerToken)){
          return fail(400,"invalid_controller_token","Controller token is invalid.");
        }
        const id=await directory(env).lookup(await sha(c),Date.now());
        if(!id)return fail(404,"invalid_code","Code expired or invalid.");
        const controllerId="c_"+token(12);
        const r=await sessions(env,id).redeem(await sha(controllerToken),controllerId,Date.now());
        if(!r.ok)return fail(r.status||400,r.code||"redeem_failed","Code expired, invalid, or already used.");
        return j({ok:true,sessionId:id,controllerToken,hostUid:r.snapshot.hostUid,controllerUid:r.snapshot.controllerUid});
      }

      const m=u.pathname.match(/^\/v1\/sessions\/([a-f0-9]{64})(?:\/([^/]+))?$/);
      if(!m)return fail(404,"not_found","Not found.");
      const id=m[1],action=m[2]||"";
      if(action==='socket'&&!bearer(request)){
        request=browserSocketRequest(request);
        if(!request)return fail(401,'unauthorized','Invalid browser session.');
      }
      const raw=bearer(request);
      if(!raw)return fail(401,"unauthorized","Missing session token.");
      const h=await sha(raw),room=sessions(env,id);
      if(action==='browser-claim'&&request.method==='POST'){
        if(request.headers.get('Origin')&&request.headers.get('Origin')!==u.origin)return fail(403,'invalid_origin','Invalid origin.');
        const x=await body(request),r=await room.claimBrowser(h,x.clientId,x.instanceId,Date.now());
        return r.ok?j(r):fail(r.status,r.code,'Cannot join this browser session.');
      }
      if(request.method==='GET'&&action==='agent-observe'){const r=await room.agentObservation(h);return j({...r,observation:withoutImageData(r.observation)},r.ok?200:r.status||400)}
      if(request.method==='POST'&&action==='agent-publish'){
        const x=await body(request),r=await room.agentPublish(h,x.result,x.requestId||null);return j(r,r.ok?200:r.status||400);
      }
      if(request.method==='POST'&&action==='agent-start'){
        const x=await body(request),r=await room.agentStart(h,String(x.requestId||''));return j(r,r.ok?200:r.status||400);
      }
      const allowed=await room.authorizeRequest(h,request.headers.get('X-Aaris-Instance'));
      if(!allowed.ok)return fail(allowed.status,allowed.code,'Session ended or controller changed.');
      if(action==="socket"||action==='agent-socket')return room.fetch(request);
      if(request.method==='POST'&&(action==='agent-action'||action==='agent-refresh')){
        if(request.headers.get('Origin')&&request.headers.get('Origin')!==u.origin)return fail(403,'invalid_origin','Invalid origin.');
        const x=await body(request),r=await room.agentEnqueue(h,action==='agent-action'?'action':'observe',x,request.headers.get('X-Aaris-Instance'));return j(r,r.ok?202:r.status||400);
      }
      if(request.method==='GET'&&action==='agent-result'){
        const r=await room.agentResult(h,u.searchParams.get('requestId'),request.headers.get('X-Aaris-Instance'));return j({...r,result:withoutImageData(r.result)},r.ok?200:r.status||400);
      }

      if(request.method==="GET"&&action===""){
        const r=await room.snapshot(h);
        return r.ok?j({ok:true,role:r.role,session:r.snapshot}):fail(401,"unauthorized","Session authorization expired.");
      }
      if(request.method==="POST"&&action==="state"){
        const x=await body(request),r=await room.transition(h,String(x.target||""),Date.now());
        return r.ok?j({ok:true,session:r.snapshot}):fail(r.status||409,r.code||"transition_failed","Session state changed or expired.");
      }
      if(request.method==="POST"&&action==="close"){
        const r=await room.closeSession(h,Date.now(),request.headers.get('X-Aaris-Instance'));
        return r.ok?j({ok:true,session:r.snapshot}):fail(401,"unauthorized","Session authorization expired.");
      }
      if(request.method==="POST"&&action==="events"){
        const x=await body(request),r=await room.publishEvent(h,String(x.kind||""),x.payload||{},Date.now(),request.headers.get('X-Aaris-Instance'));
        return r.ok?j({ok:true,event:r.event},201):fail(r.status||400,r.code||"event_failed","Could not publish signaling event.");
      }
      if(request.method==="GET"&&action==="events"){
        const r=await room.eventsAfter(h,Number(u.searchParams.get("after")||0)||0);
        return r.ok?j({ok:true,role:r.role,events:r.events}):fail(401,"unauthorized","Session authorization expired.");
      }
      if(request.method==="POST"&&action==="ice"){
        const a=await room.authorizeIce(h);
        if(!a.ok)return fail(403,"ice_not_authorized","Session is not ready for relay.");
        if(!env.TURN_KEY_ID||!env.TURN_KEY_SECRET)return fail(503,"turn_not_configured","TURN is not configured.");
        const upstream=await fetch("https://rtc.live.cloudflare.com/v1/turn/keys/"+env.TURN_KEY_ID+"/credentials/generate-ice-servers",{
          method:"POST",
          headers:{authorization:"Bearer "+env.TURN_KEY_SECRET,"content-type":"application/json",accept:"application/json"},
          body:JSON.stringify({ttl:1800})
        });
        if(!upstream.ok)return fail(503,"turn_unavailable","TURN is temporarily unavailable.");
        console.log(JSON.stringify({
          event:"turn_issued",
          role:a.role,
          state:a.state
        }));
        return new Response(await upstream.text(),{status:200,headers:{"content-type":"application/json; charset=utf-8","cache-control":"no-store","x-content-type-options":"nosniff"}});
      }
      return fail(404,"not_found","Not found.");
    }catch(e){
      if(e&&e.message==="request_too_large")return fail(413,"request_too_large","Request too large.");
      if(e instanceof SyntaxError)return fail(400,"invalid_json","Invalid JSON.");
      console.error(JSON.stringify({level:"error",message:e instanceof Error?e.message:"internal_error"}));
      return fail(500,"internal_error","Internal server error.");
    }
  }
};
