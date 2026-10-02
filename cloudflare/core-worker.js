import { DurableObject } from "cloudflare:workers";

const CODE_TTL=300000,APPROVAL_TTL=120000,CONNECT_TTL=120000;
const CLOSED_RETENTION=3600000,MAX_EVENTS=512;
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
function deadline(s){if(!s)return null;if(s.state==="CODE_ACTIVE")return s.expiresAtMs;if(s.state==="PAIR_PENDING")return s.approvalExpiresAtMs||null;if(s.state==="HOST_APPROVED"||s.state==="SCREEN_READY")return s.connectExpiresAtMs||null;return null}
const pub=s=>s?{sessionId:s.sessionId,state:s.state,hostUid:s.hostId,controllerUid:s.controllerId||null,displayGeneration:s.displayGeneration||0,deadlineAtMs:deadline(s)}:null;

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
  async redeem(controllerTokenHash,controllerId,now){
    let o;
    await this.ctx.storage.transaction(async t=>{
      const s=(await t.get("session"))||null;
      if(!s){o={ok:false,status:404,code:"invalid_code"};return}
      if(s.state==="PAIR_PENDING"&&s.controllerTokenHash===controllerTokenHash){
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
          s.state="LIVE";await t.deleteAlarm();
        }else if(s.state!=="LIVE"){o={ok:false,status:409,code:"invalid_transition"};return}
      }else{o={ok:false,status:400,code:"unsupported_transition"};return}
      await t.put("session",s);o={ok:true,snapshot:pub(s)};
    });
    if(o.ok)this.broadcastSession(await this.session());
    return o;
  }
  async closeSession(h,now){
    const s=await this.session(),r=this.role(s,h);
    if(!r)return{ok:false,status:401,code:"unauthorized"};
    if(s.state!=="CLOSED"){s.state="CLOSED";s.closedAtMs=now;await this.ctx.storage.put("session",s);await this.ctx.storage.setAlarm(now+CLOSED_RETENTION);this.broadcastSession(s)}
    return{ok:true,snapshot:pub(s)};
  }
  async authorizeIce(h){
    const s=await this.session(),r=this.role(s,h);
    return{ok:Boolean(r&&["SCREEN_READY","LIVE"].includes(s.state)),role:r};
  }
  async publishEvent(h,kind,payload,now){
    const s=await this.session(),r=this.role(s,h);
    if(!r)return{ok:false,status:401,code:"unauthorized"};
    if(!["SCREEN_READY","LIVE"].includes(s.state))return{ok:false,status:409,code:"signaling_not_ready"};
    if(!["description","candidate","ice_restart","presence"].includes(kind))return{ok:false,status:400,code:"bad_event_kind"};
    if(JSON.stringify(payload||{}).length>655360)return{ok:false,status:413,code:"event_too_large"};
    let e;
    await this.ctx.storage.transaction(async t=>{
      const seq=Number((await t.get("seq"))||0)+1;
      e={seq,senderRole:r,kind,payload:payload||{},createdAtMs:now};
      await t.put("seq",seq);await t.put("e:"+String(seq).padStart(12,"0"),e);
      if(seq>MAX_EVENTS)await t.delete("e:"+String(seq-MAX_EVENTS).padStart(12,"0"));
    });
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
    if(u.pathname!=="/socket")return new Response("Not found",{status:404});
    if((request.headers.get("upgrade")||"").toLowerCase()!=="websocket")return new Response("Expected WebSocket",{status:426});
    const raw=bearer(request);if(!raw)return new Response("Unauthorized",{status:401});
    const h=await sha(raw),s=await this.session(),r=this.role(s,h);if(!r)return new Response("Unauthorized",{status:401});
    const pair=new WebSocketPair(),[client,server]=Object.values(pair);
    this.ctx.acceptWebSocket(server,[r]);server.serializeAttachment({role:r});
    server.send(JSON.stringify({kind:"session",session:pub(s)}));
    const backlog=await this.eventsAfter(h,Math.max(0,Number(u.searchParams.get("after")||0)||0));
    if(backlog.ok)for(const e of backlog.events)server.send(JSON.stringify({kind:"signal_event",event:e}));
    return new Response(null,{status:101,webSocket:client});
  }
  async webSocketMessage(ws,m){if(m==="ping")ws.send("pong")}
  async webSocketClose(ws,c,r){try{ws.close(c,r)}catch(_){}}
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
    if(d!=null&&d<=now){s.state="CLOSED";s.closedAtMs=now;await this.ctx.storage.put("session",s);this.broadcastSession(s);await this.ctx.storage.setAlarm(now+CLOSED_RETENTION)}
  }
}

const sessions=(env,id)=>env.SESSIONS.getByName(id);
const directory=env=>env.PAIRINGS.getByName("global");

export default{
  async fetch(request,env){
    try{
      const u=new URL(request.url);
      if(request.method==="GET"&&u.pathname==="/healthz"){
        return j({ok:true,service:"aaris-remote-ice",backend:"cloudflare-durable-objects",version:2});
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
        const controllerToken=String(x.controllerToken||"");
        if(!/^[A-Za-z0-9_-]{43,128}$/.test(controllerToken)){
          return fail(400,"invalid_controller_token","Controller token is invalid.");
        }
        const id=await directory(env).lookup(await sha(c),Date.now());
        if(!id)return fail(404,"invalid_code","Code expired or invalid.");
        const controllerId="c_"+token(12);
        const r=await sessions(env,id).redeem(await sha(controllerToken),controllerId,Date.now());
        if(!r.ok)return fail(r.status||400,r.code||"redeem_failed","Code expired, invalid, or already used.");
        return j({ok:true,sessionId:id,controllerToken,hostUid:r.snapshot.hostUid,controllerUid:controllerId});
      }

      const m=u.pathname.match(/^\/v1\/sessions\/([a-f0-9]{64})(?:\/([^/]+))?$/);
      if(!m)return fail(404,"not_found","Not found.");
      const id=m[1],action=m[2]||"",raw=bearer(request);
      if(!raw)return fail(401,"unauthorized","Missing session token.");
      const h=await sha(raw),room=sessions(env,id);
      if(action==="socket")return room.fetch(request);

      if(request.method==="GET"&&action===""){
        const r=await room.snapshot(h);
        return r.ok?j({ok:true,role:r.role,session:r.snapshot}):fail(401,"unauthorized","Session authorization expired.");
      }
      if(request.method==="POST"&&action==="state"){
        const x=await body(request),r=await room.transition(h,String(x.target||""),Date.now());
        return r.ok?j({ok:true,session:r.snapshot}):fail(r.status||409,r.code||"transition_failed","Session state changed or expired.");
      }
      if(request.method==="POST"&&action==="close"){
        const r=await room.closeSession(h,Date.now());
        return r.ok?j({ok:true,session:r.snapshot}):fail(401,"unauthorized","Session authorization expired.");
      }
      if(request.method==="POST"&&action==="events"){
        const x=await body(request),r=await room.publishEvent(h,String(x.kind||""),x.payload||{},Date.now());
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
