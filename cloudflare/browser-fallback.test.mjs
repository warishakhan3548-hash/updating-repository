// Exercise the shipped page with no WebRTC media, using the HTTPS observation lane.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { browserResponse } from './browser-console.js';
import { agentPage } from './browser-agent.js';
const require=createRequire(import.meta.url);
let chromium;try{({chromium}=require('playwright'))}catch{({chromium}=require(process.env.CODEX_PRIMARY_RUNTIME_NODE_MODULES+'/playwright'))}
const browser=await chromium.launch({headless:true,...(process.env.BROWSER_TEST_CHROME?{executablePath:process.env.BROWSER_TEST_CHROME}:{})});
const context=await browser.newContext({viewport:{width:1000,height:900}}),page=await context.newPage();
const errors=[];page.on('pageerror',e=>errors.push(e.message));
const sid='a'.repeat(64),token='b'.repeat(43),client='0ddfe8bc-a856-4364-a8a0-5e1603ab7c11',commands=[];
const painter=await context.newPage();
const jpeg=await painter.evaluate(()=>{const c=document.createElement('canvas');c.width=360;c.height=720;const p=c.getContext('2d');p.fillStyle='#163955';p.fillRect(0,0,360,720);p.fillStyle='white';p.font='30px sans-serif';p.fillText('HTTPS phone',40,350);return c.toDataURL('image/jpeg').split(',')[1]});
const observation=version=>({observationId:`11111111-1111-4111-8111-${String(version).padStart(12,'0')}`,screenVersion:version,commandNonce:'nonce',display:{width:1080,height:2160},uiHints:[
  {text:'',clickable:true,bounds:[540,400,900,800]},
  {text:'WhatsApp',clickable:false,bounds:[600,450,840,600]},
  {text:'Read-only caption',clickable:false,bounds:[20,20,200,60]}
],image:{mimeType:'image/jpeg',width:360,height:720,data:jpeg}});
let current=observation(1),instance,result,observeReads=0;
const withoutData=value=>({...value,image:{...value.image,data:undefined}});
await page.route('https://remote.test/**',async route=>{
  const req=route.request(),u=new URL(req.url()),path=u.pathname;
  const reply=json=>route.fulfill({json});
  if(path==='/remote/frame'){assert.equal(u.searchParams.get('observationId'),current.observationId);await route.fulfill({contentType:'image/jpeg',body:Buffer.from(jpeg,'base64')});return}
  if(path.startsWith('/remote')){
    const r=path==='/remote/client.js'?browserResponse(path):await agentPage(u,{ok:true,phoneOnline:true,state:'LIVE',observation:current});
    await route.fulfill({status:r.status,headers:Object.fromEntries(r.headers),body:await r.text()});return;
  }
  if(path.endsWith('/browser-claim')){instance=req.postDataJSON().instanceId;await reply({ok:true,afterSequence:0,browserEpoch:1});return}
  if(path.endsWith('/ice')){await route.fulfill({status:503,json:{error:'TURN_UNAVAILABLE'}});return}
  if(path.endsWith('/agent-observe')){observeReads++;await reply({ok:true,phoneOnline:true,state:'LIVE',observation:withoutData(current)});return}
  if(path.endsWith('/agent-refresh')){await reply({ok:true,result:withoutData(current)});return}
  if(path.endsWith('/agent-action')){
    assert.equal(req.headers()['x-aaris-instance'],instance);
    const c=req.postDataJSON();assert.equal(c.nonce,'nonce');
    const stale=c.observationId!==current.observationId;
    commands.push(c);if(!stale)current=observation(current.screenVersion+1);
    result={...current,actionId:c.actionId,applied:!stale&&commands.length!==3,...(stale||commands.length===3?{error:'STALE_SCREEN'}:{})};await reply({ok:true,requestId:c.actionId});return;
  }
  if(path.endsWith('/agent-result')){await reply({ok:true,result:withoutData(result)});return}
  await route.fulfill({status:404,json:{error:'NOT_FOUND'}});
});
try{
  await page.goto(`https://remote.test/remote/?session=${sid}&access=${token}&client=${client}`);
  await page.locator('#fallback').waitFor({state:'visible'});
  await page.waitForFunction(()=>document.getElementById('fallback').naturalWidth===360);
  const rect=await page.locator('#surface').boundingBox();
  await page.mouse.click(rect.x+rect.width/2,rect.y+rect.height/2);
  await page.waitForFunction(()=>{const i=document.getElementById('fallback');return i.src.includes('000000000002')&&i.complete&&i.naturalWidth>0});
  assert.equal(commands.length,1);assert.equal(commands[0].action,'tap');
  assert.ok(Math.abs(commands[0].x-.5)<.01&&Math.abs(commands[0].y-.5)<.01);
  assert.equal(commands[0].durationMs,undefined,'Tap payload must satisfy the strict Android schema');
  await page.waitForFunction(()=>document.getElementById('fallback').src.includes('000000000002'));
  await page.getByRole('button',{name:'Home',exact:true}).click();
  await page.waitForFunction(()=>{const i=document.getElementById('fallback');return i.src.includes('000000000003')&&i.complete&&i.naturalWidth>0});
  assert.equal(commands.length,2);assert.equal(commands[1].action,'home');
  await page.mouse.click(rect.x+5,rect.y+rect.height/2);await page.waitForTimeout(400);
  assert.equal(commands.length,2,'Letterbox clicks must never reach the phone');
  await page.mouse.click(rect.x+rect.width/2,rect.y+rect.height/2);
  await page.waitForFunction(()=>{const i=document.getElementById('fallback');return i.src.includes('000000000004')&&i.complete&&i.naturalWidth>0});
  assert.equal(commands.length,3);assert.equal(result.applied,false,'Stale-screen refusal still returns an inspectable fresh frame');
  await page.mouse.click(rect.x+rect.width/2,rect.y+rect.height/2);
  await page.waitForFunction(()=>document.getElementById('fallback').src.includes('000000000005'));
  assert.equal(commands[3].screenVersion,4,'Next decision must use the replacement observation');
  await page.getByRole('button',{name:'Tap phone: WhatsApp (2)',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('fallback').src.includes('000000000006'));
  assert.equal(commands[4].action,'tap');
  assert.ok(Math.abs(commands[4].x-720/1080)<1e-9&&Math.abs(commands[4].y-525/2160)<1e-9,'Named child taps its actual pixel center inside the clickable parent');
  assert.equal(await page.getByRole('button',{name:/Tap phone: Read-only caption/}).count(),0);
  await page.getByLabel('AI command JSON').fill('{"action":"tap","x":540,"y":1080,"space":"pixel"}');
  await page.getByRole('button',{name:'Execute AI command',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('fallback').src.includes('000000000007'));
  assert.equal(commands[5].x,.5);assert.equal(commands[5].y,.5);
  const readsBefore=observeReads,visibleId=current.observationId;
  current=observation(99); // Phone changes while the model reasons from image 7.
  await page.getByLabel('AI command JSON').fill('{"action":"tap","x":0.73,"y":0.41}');
  await page.getByRole('button',{name:'Execute AI command',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('aiResult').textContent==='STALE_SCREEN');
  assert.equal(commands[6].observationId,visibleId,'Never authorize old coordinates using a silently refreshed ticket');
  assert.equal(observeReads,readsBefore,'Pinned AI decisions do not poll away their observation');
  await page.waitForFunction(()=>{const i=document.getElementById('fallback');return i.src.includes('000000000099')&&i.complete});
  current={...observation(100),display:{width:1080,height:1920}};
  await page.getByRole('button',{name:'Fresh screenshot',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('screenInfo').textContent.includes('Image geometry changed'));
  assert.equal(await page.getByRole('button',{name:'Execute AI command',exact:true}).isEnabled(),false);
  assert.equal(await page.getByRole('button',{name:'Tap point',exact:true}).isEnabled(),false);
  current=observation(101);
  await page.getByRole('button',{name:'Fresh screenshot',exact:true}).click();
  await page.waitForFunction(()=>document.getElementById('tapPoint').disabled===false);
  await page.reload();await page.locator('#fallback').waitFor({state:'visible'});
  assert.equal(new URL(page.url()).searchParams.get('client'),client);
  assert.deepEqual(errors,[]);console.log('PASS: full inline phone image, exact/semantic/pixel taps, pinned decisions, stale-scene refusal, geometry fence and stateless refresh without WebRTC');
}catch(error){console.error('Fallback diagnostic',JSON.stringify({commands,errors,state:await page.evaluate(()=>({status:document.getElementById('status')?.textContent,src:document.getElementById('fallback')?.src,loaded:document.getElementById('fallback')?.complete}))}));throw error}finally{await browser.close()}
