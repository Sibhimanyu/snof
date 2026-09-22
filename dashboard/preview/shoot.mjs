import { chromium } from 'playwright';
const OUT = new URL('./shots/', import.meta.url).pathname;
const base='http://localhost:8765/index.html';
const browser=await chromium.launch();
let bad=0;
async function shot(name,{url='',scheme='dark',vp={width:1440,height:940},motion='reduce',wait='.page-title',act}={}){
  const ctx=await browser.newContext({viewport:vp,colorScheme:scheme,reducedMotion:motion,deviceScaleFactor:2});
  const page=await ctx.newPage();
  const errs=[];
  page.on('pageerror',e=>errs.push('pageerror: '+e.message));
  page.on('console',m=>{if(m.type()==='error')errs.push('console: '+m.text())});
  // Split so the cache-buster lands in the query string, never inside the hash.
  const [q,h]=url.split('#');
  await page.goto(base+(q?(q.startsWith('?')?q+'&':'?'+q+'&'):'?')+'r='+Math.random()+(h?'#'+h:''));
  await page.waitForSelector(wait,{timeout:6000});
  if(act) await act(page);
  await page.screenshot({path:`${OUT}/${name}.png`,fullPage:false});
  if(errs.length){bad++;console.log('  !!',name,errs);} else console.log('  ok',name);
  await ctx.close();
}
await shot('01-signin',{url:'?gate=1',wait:'#signin',vp:{width:1100,height:820}});
await shot('02-signin-light',{url:'?gate=1',scheme:'light',wait:'#signin',vp:{width:1100,height:820}});
await shot('03-denied',{url:'?denied=1',wait:'#signout-gate',vp:{width:1100,height:820}});
await shot('04-overview',{});
await shot('05-overview-light',{scheme:'light'});
await shot('06-areas',{url:'#/areas'});
await shot('07-area-detail',{url:'#/area/packing_shed'});
await shot('08-area-detail-light',{url:'#/area/nursery',scheme:'light'});
await shot('09-devices',{url:'#/devices'});
await shot('10-viewer-no-control',{url:'?viewer=1'});
await shot('11-loading',{url:'?nodata=1',wait:'.sk-card'});
await shot('12-big-farm',{url:'?big=1#/areas'});
await shot('13-mobile-overview',{vp:{width:390,height:844}});
await shot('14-mobile-area',{url:'#/area/cold_store',vp:{width:390,height:844}});
await shot('15-mobile-nav',{vp:{width:390,height:844},act:async p=>{await p.click('#nav-open');await p.waitForTimeout(350);}});
await shot('16-search',{act:async p=>{await p.fill('#search','pump');await p.waitForTimeout(200);await p.click('a[href="#/areas"]');await p.waitForTimeout(200);}});
await shot('18-irrigation',{url:'#/irrigation'});
// Exercise a control end to end and confirm the command payload is well formed.
{
  const ctx=await browser.newContext({viewport:{width:1440,height:940},colorScheme:'dark',deviceScaleFactor:2});
  const page=await ctx.newPage();
  const cmds=[];const errs=[];
  page.on('console',m=>{const t=m.text();if(t.startsWith('COMMAND'))cmds.push(t.slice(8));else if(m.type()==='error')errs.push(t)});
  page.on('pageerror',e=>errs.push('pageerror: '+e.message));
  await page.goto(base+'#/area/nursery');
  await page.waitForSelector('.toggle');
  await page.click('.dev-card:has-text("Nursery misters") .toggle');
  await page.waitForTimeout(150);
  const slider=page.locator('.dev-card:has-text("Grow light bank 1") input[type=range]');
  await slider.fill('64'); await slider.dispatchEvent('change');
  await page.waitForTimeout(150);
  await page.screenshot({path:`${OUT}/17-control-pending.png`});
  console.log('  commands:',cmds);
  if(errs.length){bad++;console.log('  !! control',errs);} else console.log('  ok 17-control-pending');
  await ctx.close();
}
await browser.close();
console.log(bad?`FAILED: ${bad} page(s) with errors`:'all pages clean');
