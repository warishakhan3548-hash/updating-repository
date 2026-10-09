import { browserResponse } from './browser-console.js';
const headers={'Cache-Control':'no-store, max-age=0','Referrer-Policy':'no-referrer','X-Content-Type-Options':'nosniff'};
const escape=s=>String(s??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export function agentParameters(u){
  const sessionId=u.searchParams.get('session'),access=u.searchParams.get('access');
  return /^[a-f0-9]{64}$/.test(sessionId||'')&&/^[A-Za-z0-9_-]{43}$/.test(access||'')?{sessionId,access}:null;
}
export function observationResponse(u,state){
  if(!state.ok)return new Response(JSON.stringify(state),{status:state.status||401,headers:{...headers,'Content-Type':'application/json'}});
  const o=state.observation;
  if(u.pathname==='/remote/frame'){
    if(!o||u.searchParams.get('observationId')!==o.observationId)return new Response('No current frame. Open the observation link again.',{status:409,headers});
    const raw=atob(o.image.data),bytes=Uint8Array.from(raw,c=>c.charCodeAt(0));
    return new Response(bytes,{headers:{...headers,'Content-Type':'image/jpeg','X-Aaris-Observation':o.observationId}});
  }
  const frameUrl=new URL('/remote/frame',u);frameUrl.search=u.search;frameUrl.searchParams.set('observationId',o?.observationId||'');
  const value={...state,observation:o?{...o,image:{...o.image,data:undefined,url:frameUrl.href}}:null};
  return new Response( --- TRUNCATED --- 4,991 chars