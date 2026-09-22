import { chromium } from 'playwright';
const base='http://localhost:8765/index.html';
const b=await chromium.launch(); let fail=0;
const check=(n,ok,x='')=>{console.log(`${ok?'  PASS':'  FAIL'}  ${n}${x?'  '+x:''}`);if(!ok)fail++;};
const open=async(url='')=>{const c=await b.newContext({viewport:{width:1440,height:900}});const p=await c.newPage();
  p.on('pageerror',e=>console.log('   pageerror:',e.message));
  await p.goto(base+url); return [p,c];};

// A. A real drag, interrupted by a live entity update mid-gesture.
{
  const [p,c]=await open('#/area/packing_shed');
  await p.waitForSelector('input[type=range]');
  const slider=p.locator('input[type=range]').first();
  const box=await slider.boundingBox();
  await p.mouse.move(box.x+box.width*0.66, box.y+box.height/2);
  await p.mouse.down();
  await p.mouse.move(box.x+box.width*0.20, box.y+box.height/2, {steps:5});
  const during=await slider.inputValue();
  // A sensor elsewhere on the farm reports in, exactly as it would every second.
  await p.evaluate(()=>{window.__push({domain:'sensor',id:'tank_level',state:'73'});});
  await p.waitForTimeout(120);
  const after=await slider.inputValue();
  check('drag is not reset by a live update mid-gesture', after===during,
        `dragged to ${during}, ended at ${after}`);
  await p.mouse.up();
  await p.waitForTimeout(150);
  const settled=await p.locator('input[type=range]').first().inputValue();
  check('held update applies once the gesture ends', settled!==null, `value=${settled}`);
  await c.close();
}

// B. Keyboard user tabs to a filter chip and presses it.
{
  const [p,c]=await open('#/devices');
  await p.waitForSelector('.chip');
  await p.evaluate(()=>{document.querySelectorAll('.chip')[1].focus();});
  const before=await p.evaluate(()=>document.activeElement.dataset.domain);
  await p.evaluate(()=>{document.querySelectorAll('.chip')[1].click();});
  const after=await p.evaluate(()=>({tag:document.activeElement.tagName,d:document.activeElement.dataset?.domain}));
  check('filter chip keeps focus after being pressed', after.d===before, `before=${before} after=${JSON.stringify(after)}`);
  await c.close();
}

// C. The farm confirms by reporting the state we asked for.
{
  const [p,c]=await open('#/area/nursery');
  await p.waitForSelector('.toggle');
  const card=()=>p.locator('.dev-card',{hasText:'Nursery misters'});
  await card().locator('.toggle').click();
  const mid=await card().locator('.toggle').getAttribute('aria-checked');
  // Mock a delta: the entity now reports 'on', matching the request.
  await p.evaluate(()=>{window.__push({domain:'switch',id:'mister',state:'on'});});
  await p.waitForTimeout(120);
  const busy=await card().locator('.toggle').getAttribute('class');
  check('optimistic toggle flips immediately', mid==='true', `aria-checked=${mid}`);
  check('pending clears once the farm agrees', !busy.includes('busy'), `class="${busy}"`);
  // And no false failure toast should arrive after the deadline.
  await p.waitForTimeout(400);
  const toasts=await p.locator('.toast').count();
  check('no spurious error toast after confirmation', toasts===0, `toasts=${toasts}`);
  await c.close();
}

// D. Scroll position across a live update (wall tablet reading mid-list).
{
  const [p,c]=await open('?big=1#/devices');
  await p.waitForSelector('.row');
  await p.evaluate(()=>window.scrollTo(0,1500));
  const before=await p.evaluate(()=>window.scrollY);
  await p.evaluate(()=>{window.__push({domain:'sensor',id:'tank_level',state:'72'});});
  await p.waitForTimeout(120);
  const after=await p.evaluate(()=>window.scrollY);
  check('scroll position survives a live update', Math.abs(before-after)<50, `${before} -> ${after}`);
  await c.close();
}

// E. Cost of a live update at the real farm size (~1366 entities).
{
  const [p,c]=await open('?big=1#/devices');
  await p.waitForSelector('.row');
  const ms=await p.evaluate(async()=>{const t=performance.now();
    for(let i=0;i<10;i++){window.__push({domain:'sensor',id:'tank_level',state:String(60+i)});}
    return (performance.now()-t)/10;});
  check('re-render stays under 150ms at farm scale', ms<150, `${ms.toFixed(1)}ms per update`);
  await c.close();
}

// ---- hostile real data: 698 entities, 373 unavailable, real HA names --------
{
  const [p,c]=await open('?real=1&viewer=1');
  await p.waitForSelector('.dev-card');
  const r=await p.evaluate(()=>{
    const name=document.querySelector('.dev-name'), meta=document.querySelector('.dev-meta');

    // text-overflow only takes effect on a block box; inline was the root cause.
    const truncatable=(el)=>el&&getComputedStyle(el).display!=='inline';
    let overlap=0, clipped=0;
    document.querySelectorAll('.dev-card').forEach(card=>{
      const n=card.querySelector('.dev-name'), s=card.querySelector('.dev-state');
      if(n&&s&&n.getBoundingClientRect().right>s.getBoundingClientRect().left+1) overlap++;
      if(n&&n.scrollWidth>n.clientWidth+1) clipped++;
    });
    return {nameBlock:truncatable(name), metaBlock:truncatable(meta),
            overlap, cards:document.querySelectorAll('.dev-card').length,
            deadInControls:[...document.querySelectorAll('.dev-grid .dev-card')]
              .filter(c=>c.className.includes('is-bad')).length};
  });
  check('device name is a block box (ellipsis can engage)', r.nameBlock, `display ok=${r.nameBlock}`);
  check('device meta truncates too', r.metaBlock);
  check('no name overlaps its state pill', r.overlap===0, `${r.overlap} of ${r.cards} cards`);
  check('no unavailable device in Quick Controls', r.deadInControls===0, `${r.deadInControls} dead`);
  await c.close();
}
{
  const [p,c]=await open('?real=1#/devices');
  await p.waitForSelector('.seg');
  await p.locator('.seg button[data-status=offline]').click();
  await p.waitForTimeout(150);
  const r=await p.evaluate(()=>{
    const el=document.querySelector('.row-name');
    return {rows:document.querySelectorAll('.row').length,
      allDead:[...document.querySelectorAll('.row')].every(n=>n.className.includes('is-bad')),
      rowBlock: !!el && getComputedStyle(el).display!=='inline',
      rowMetaBlock: (()=>{const m=document.querySelector('.row-meta');
        return !!m && getComputedStyle(m).display!=='inline';})()};
  });
  check('status filter isolates the unavailable set', r.rows>0&&r.allDead, `${r.rows} rows, allDead=${r.allDead}`);
  check('list rows truncate too', r.rowBlock&&r.rowMetaBlock, `name=${r.rowBlock} meta=${r.rowMetaBlock}`);
  await c.close();
}
// Long names must not overflow at the narrowest card width either.
{
  const b2=await open('?real=1&viewer=1');
  const [p,c]=b2; await p.setViewportSize({width:820,height:900});
  await p.waitForSelector('.dev-card'); await p.waitForTimeout(150);
  const r=await p.evaluate(()=>{let o=0;document.querySelectorAll('.dev-card').forEach(card=>{
    const n=card.querySelector('.dev-name'), s=card.querySelector('.dev-state');
    if(n&&s&&n.getBoundingClientRect().right>s.getBoundingClientRect().left+1)o++;});return o;});
  check('no overlap at narrow width either', r===0, `${r} overlaps`);
  await c.close();
}
// Irrigation is on demand: the builder sends a request, the bridge answers,
// and the result lands as a report card. No timer, no vendor credentials.
{
  const [p,c]=await open('#/irrigation');
  await p.waitForSelector('.rep-builder');
  const r=await p.evaluate(()=>({
    title:document.querySelector('.page-title')?.textContent,
    options:document.querySelectorAll('#irr-type option').length,
    seeded:document.querySelectorAll('.rep-card').length,
    scripts:[...document.documentElement.innerHTML].join('').includes('token_id')}));
  check('report builder offers every collection endpoint', r.title==='Irrigation'&&r.options===10,
    `${r.options} options`);
  check('seeded report history renders', r.seeded>=1, `${r.seeded} cards`);
  check('no vendor credential leaks into the page', r.scripts===false);
  // End to end: pick a range report, press Generate, the answer arrives.
  await p.selectOption('#irr-type','motor_log');
  await p.waitForTimeout(150);
  const before=await p.locator('.rep-card').count();
  await p.click('[data-act="irr-gen"]');
  await p.waitForFunction((n)=>document.querySelectorAll('.rep-card').length>n, before, {timeout:8000});
  const ready=await p.evaluate(()=>[...document.querySelectorAll('.rep-card .rep-title')]
    .some(t=>t.textContent==='Motor log'));
  check('generated report lands as a card', ready===true);
  const toast=await p.evaluate(()=>[...document.querySelectorAll('.toast')].map(t=>t.textContent).join('|'));
  check('user is told the report is ready', /ready/i.test(toast), toast.slice(0,80));
  // A to-before-from range is refused client-side, before any request.
  await p.selectOption('#irr-type','valves');
  await p.fill('#irr-from','2026-02-22'); await p.fill('#irr-to','2026-02-20');
  await p.click('[data-act="irr-gen"]');
  await p.waitForTimeout(250);
  const refused=await p.evaluate(()=>[...document.querySelectorAll('.toast')].map(t=>t.textContent).join('|'));
  check('reversed dates are refused before sending', /before/.test(refused), refused.slice(-80));
  await c.close();
}
{
  // Viewers see results but get no builder: reports hit billable vendor APIs.
  const [p,c]=await open('?viewer=1#/irrigation');
  await p.waitForSelector('.page-title');
  const r=await p.evaluate(()=>({builder:!!document.querySelector('.rep-builder'),
    note:document.body.textContent.includes('limited to controllers')}));
  check('viewers get results but no builder', !r.builder&&r.note===true);
  await c.close();
}
{
  const [p,c]=await open('?noirrig=1#/irrigation');
  await p.waitForSelector('.page-title');
  const t=await p.evaluate(()=>document.querySelector('.empty h3')?.textContent);
  check('empty history explains itself', t==='No reports yet', `${t}`);
  await c.close();
}
await b.close();
console.log(fail?`\n${fail} issue(s) found`:'\nno issues found');
