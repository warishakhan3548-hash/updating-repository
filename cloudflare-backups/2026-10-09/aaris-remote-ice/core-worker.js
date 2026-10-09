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
function bearer(r){const h=r.headers.get("authorization")||"";if(!h.toLowerCase().startsWith("bearer "))return null;const v=h.slice(7).trim();return --- TRUNCATED --- 33,284 chars