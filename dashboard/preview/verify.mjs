import { chromium } from 'playwright';
const b=await chromium.launch(); const ctx=await b.newContext({viewport:{width:1440,height:900}});
const page=await ctx.newPage(); let fail=0;
const check=(name,ok,extra='')=>{console.log(`${ok?'  PASS ':'  FAIL '} ${name} ${extra}`); if(!ok)fail++;};

await page.goto((process.env.PREVIEW_BASE||'http://localhost:8765/index.html'));
let r=await page.evaluate(()=>({
  view:document.body.dataset.view,
  gate:getComputedStyle(document.getElementById('gate')).display,
  app:getComputedStyle(document.getElementById('app')).display,
  docH:document.documentElement.scrollHeight,
  gateH:document.getElementById('gate').getBoundingClientRect().height,
}));
check('signed in -> view is "app"', r.view==='app', JSON.stringify(r));
check('signed in -> gate is display:none', r.gate==='none');
check('signed in -> gate occupies zero height', r.gateH===0);
check('signed in -> app is displayed', r.app!=='none');

await page.goto('http://localhost:8765/index.html?gate=1');
r=await page.evaluate(()=>({
  view:document.body.dataset.view,
  gate:getComputedStyle(document.getElementById('gate')).display,
  app:getComputedStyle(document.getElementById('app')).display,
  appH:document.getElementById('app').getBoundingClientRect().height,
  scrollable:document.documentElement.scrollHeight - window.innerHeight,
}));
check('signed out -> view is "gate"', r.view==='gate', JSON.stringify(r));
check('signed out -> app is display:none', r.app==='none');
check('signed out -> app occupies zero height', r.appH===0);
check('signed out -> nothing to scroll to', r.scrollable<=0);

// Viewer tier must render no operable control anywhere.
await page.goto('http://localhost:8765/index.html?viewer=1#/area/nursery');
await page.waitForSelector('.page-title');
r=await page.evaluate(()=>({t:document.querySelectorAll('.toggle').length,s:document.querySelectorAll('input[type=range]').length}));
check('viewer tier -> no toggles or sliders', r.t===0&&r.s===0, JSON.stringify(r));

await page.goto('http://localhost:8765/index.html#/area/nursery');
await page.waitForSelector('.toggle');
r=await page.evaluate(()=>({t:document.querySelectorAll('.toggle').length}));
check('controller tier -> toggles present', r.t>0, JSON.stringify(r));

await b.close();
console.log(fail?`\n${fail} check(s) FAILED`:'\nall checks passed');
process.exit(fail?1:0);
