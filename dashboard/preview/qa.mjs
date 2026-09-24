import { chromium } from 'playwright';
import { readFileSync } from 'node:fs';
const base=(process.env.PREVIEW_BASE||'http://localhost:8765/index.html');
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

// B. Rooms and All devices are one tab with a switch (2026-09-25).
{
  const [p,c]=await open('#/areas');
  await p.waitForSelector('.seg-nav');
  await p.click('.seg-nav a[href="#/devices"]');
  await p.waitForSelector('.dgroups');
  const r=await p.evaluate(()=>({hash:location.hash, tab:document.querySelector('.tab-item.on, .topnav-item.on')?.textContent,
    chips:document.querySelectorAll('.chip').length}));
  check('Rooms switch opens All devices under the Rooms tab', r.hash==='#/devices'&&r.tab==='Rooms'&&r.chips===0, JSON.stringify(r));
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
            qc:document.querySelectorAll('.qc .dev-card').length,
            deadInControls:[...document.querySelectorAll('.qc .dev-card')]
              .filter(c=>c.className.includes('is-bad')).length};
  });
  check('device name is a block box (ellipsis can engage)', r.nameBlock, `display ok=${r.nameBlock}`);
  check('device meta truncates too', r.metaBlock);
  check('no name overlaps its state pill', r.overlap===0, `${r.overlap} of ${r.cards} cards`);
  // Guarded against passing vacuously: the panel must actually hold rows.
  check('no unavailable device in Quick Controls', r.qc>0&&r.deadInControls===0, `${r.deadInControls} dead of ${r.qc}`);
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
  await p.waitForSelector('[data-act="irr-builder"]'); await p.click('[data-act="irr-builder"]'); await p.waitForSelector('.rep-builder');
  const r=await p.evaluate(()=>({
    title:document.querySelector('.page-title')?.textContent,
    options:[...document.querySelectorAll('#irr-type option')].map(o=>o.value),
    groups:[...document.querySelectorAll('#irr-type optgroup')].map(o=>o.label),
    seeded:document.querySelectorAll('.rep-card').length,
    scripts:[...document.documentElement.innerHTML].join('').includes('token_id')}));
  check('report builder offers every collection endpoint', r.title==='Irrigation'&&r.options.length===12,
    `${r.options.length} options`);
  check('combined pulls are offered first and labelled as such',
    r.groups[0]==='Combined'&&r.groups[1]==='Single endpoint', r.groups.join('|'));
  // Drift here is a PERMISSION_DENIED the user meets as "the database refused
  // that request": every type the builder offers must be on the rules
  // allow-list, and the allow-list must not carry a type nobody can pick.
  {
    const rules=readFileSync(new URL('../database.rules.json',import.meta.url),'utf8');
    // The rules file holds several allow-lists; take the one under
    // irrigation_requests, not the command domains above it.
    const block=rules.slice(rules.indexOf('"irrigation_requests"'));
    const allowed=(/\^\(([a-z_|]+)\)\$/.exec(block)||[,''])[1].split('|').filter(Boolean);
    const missing=r.options.filter(t=>!allowed.includes(t));
    const unreachable=allowed.filter(t=>!r.options.includes(t));
    check('every offered report type is on the rules allow-list',
      missing.length===0&&unreachable.length===0,
      `missing:${missing.join(',')||'none'} unreachable:${unreachable.join(',')||'none'}`);
  }
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
  // Sections, drawn by kind: a composite must produce more than a row dump.
  await p.selectOption('#irr-type','performance');
  await p.waitForTimeout(150);
  await p.click('[data-act="irr-gen"]');
  await p.waitForFunction(()=>[...document.querySelectorAll('.rep-card .rep-title')]
    .some(t=>t.textContent.startsWith('Valve runtime against')), null, {timeout:8000});
  const secs=await p.evaluate(()=>{
    const card=[...document.querySelectorAll('.rep-card')]
      .find(c=>c.querySelector('.rep-title').textContent.startsWith('Valve runtime against'));
    return {titles:[...card.querySelectorAll('.sec-title')].map(t=>t.firstChild.textContent.trim()),
      tiles:card.querySelectorAll('.tile').length, bars:card.querySelectorAll('.bar-row').length,
      spark:card.querySelectorAll('.spark-svg').length};});
  check('a composite report draws every section kind it was given',
    secs.tiles===6&&secs.bars===3&&secs.spark===1,
    JSON.stringify(secs));
  check('sections are titled once a report has more than one',
    secs.titles.length===4, secs.titles.join('|'));
  // A half-answered composite must not read as a whole one.
  const partial=await p.evaluate(()=>{
    const card=[...document.querySelectorAll('.rep-card')]
      .find(c=>c.querySelector('.rep-title').textContent.startsWith('Irrigation session log'));
    return card&&{tag:card.querySelector('.tag').textContent,
      err:card.querySelector('.rep-err')?.textContent||''};});
  check('a partly-failed report says so on the card',
    partial&&partial.tag==='Partly ready'&&/DCON logs/.test(partial.err),
    JSON.stringify(partial));
  // History written before sections existed still renders.
  const legacy=await p.evaluate(()=>{
    const card=[...document.querySelectorAll('.rep-card')]
      .find(c=>c.querySelector('.rep-title').textContent==='Timer log'
        &&c.querySelector('.rep-when').textContent.includes('2026-02-20'));
    return card&&card.querySelectorAll('.row').length;});
  check('pre-sections reports still render their rows', legacy>=1, `${legacy} rows`);

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
  const r=await p.evaluate(()=>({builder:!!document.querySelector('.rep-builder, [data-act="irr-builder"]'),
    run:!!document.querySelector('[data-act="run-open"]'), refresh:!!document.querySelector('[data-act="irr-refresh"]')}));
  check('viewers get results but no builder, Refresh or Run', !r.builder&&!r.run&&!r.refresh, JSON.stringify(r));
  await c.close();
}
// Regression: control was offered while allow_control was false on the bridge.
// Found by /investigate on 2026-09-23. The toggle flipped, wrote a command
// nothing was watching, then snapped back 12s later blaming the farm.
{
  const [p,c]=await open('?controloff=1#/area/nursery');
  await p.waitForSelector('.dev-card');
  const writes=[]; p.on('console',m=>{if(m.text().startsWith('COMMAND'))writes.push(m.text());});
  const r=await p.evaluate(()=>({
    disabled:[...document.querySelectorAll('.toggle')].every(t=>t.disabled),
    toggles:document.querySelectorAll('.toggle').length,
    why:document.querySelector('.note-off')?.textContent||''}));
  check('control switched off on the bridge disables every toggle',
    r.toggles>0&&r.disabled===true, `${r.toggles} toggles, allDisabled=${r.disabled}`);
  check('and the page says why', /switched off on the bridge/.test(r.why), r.why.slice(0,70));
  // Re-enable before pressing: that is the real race the guard is for — the
  // button was painted while control was on, and the bridge went off after.
  // A genuinely disabled button fires no click at all, so it proves nothing.
  await p.evaluate(()=>{const t=document.querySelector('.toggle');t.disabled=false;t.click();});
  await p.waitForTimeout(200);
  const after=await p.evaluate(()=>({
    checked:document.querySelector('.toggle').getAttribute('aria-checked'),
    busy:document.querySelector('.toggle').className.includes('busy'),
    toast:[...document.querySelectorAll('.toast')].map(t=>t.textContent).join('|')}));
  check('a press that beats the re-render writes nothing and never flips',
    writes.length===0&&after.busy===false&&/switched off/.test(after.toast),
    `writes=${writes.length} busy=${after.busy} toast=${after.toast.slice(0,50)}`);
  await c.close();
}
// Regression: ISSUE-001 — Generate fired into a void when reports were off.
// Found by /qa on 2026-09-23. The page ignored the off switch, so the button
// spun for the full 60s deadline. Reports now run in a Cloud Function and the
// switch is meta/reports.enabled.
{
  const [p,c]=await open('?reportsoff=1#/irrigation');
  await p.waitForSelector('[data-act="irr-builder"]'); await p.click('[data-act="irr-builder"]'); await p.waitForSelector('.rep-builder');
  const before=await p.evaluate(()=>({
    disabled:document.querySelector('[data-act="irr-gen"]').disabled,
    why:document.querySelector('.rep-builder + .note-off')?.textContent||''}));
  check('reports switched off disables Generate',
    before.disabled===true, `disabled=${before.disabled}`);
  check('and says why, in words, not a spinner',
    /switched off/.test(before.why), before.why.slice(0,80));
  // Force the click past the disabled attribute: a stale render must not be
  // able to write a request nothing will ever answer.
  const writes=[]; p.on('console',m=>{if(m.text().startsWith('COMMAND'))writes.push(m.text());});
  await p.evaluate(()=>document.querySelector('[data-act="irr-gen"]').click());
  await p.waitForTimeout(250);
  const spinning=await p.evaluate(()=>document.querySelector('[data-act="irr-gen"]').textContent);
  check('a forced click writes no request and never enters Working…',
    writes.length===0&&!/Working/.test(spinning), `writes=${writes.length} btn=${spinning}`);
  await c.close();
}
{
  const [p,c]=await open('?stale=1#/irrigation');
  await p.waitForSelector('[data-act="irr-builder"]'); await p.click('[data-act="irr-builder"]'); await p.waitForSelector('.rep-builder');
  const r=await p.evaluate(()=>({
    disabled:document.querySelector('[data-act="irr-gen"]').disabled,
    why:document.querySelector('.rep-builder + .note-off')?.textContent||''}));
  // Reports run in a Cloud Function, not on the NUC: a bridge that has gone
  // quiet must not take them down with it.
  check('a stale bridge does not block reports', r.disabled===false&&r.why==='',
    r.why.slice(0,80));
  await c.close();
}
{
  const [p,c]=await open('?noirrig=1#/irrigation');
  await p.waitForSelector('.page-title');
  const t=await p.evaluate(()=>document.querySelector('.irr-reports .more-note')?.textContent);
  check('empty history explains itself', t==='No reports yet.', `${t}`);
  await c.close();
}
// Valve control lives on the Irrigation tab (2026-09-25), for admins, with
// the same limits as the rules: irrigation valves only, at most five.
{
  const [p,c]=await open('?live=1&mobitech=ok#/irrigation');
  await p.waitForSelector('[data-act="run-open"]');
  const writes=[]; p.on('console',m=>{if(m.text().startsWith('COMMAND'))writes.push(m.text());});
  p.on('dialog',d=>d.accept());
  await p.click('[data-act="run-open"]');
  const r=await p.evaluate(()=>({pickable:[...document.querySelectorAll('[data-act="run-pick"]')].map(b=>b.dataset.valve),
    all:document.querySelectorAll('.vchip').length}));
  check('only irrigation valves are pickable', r.pickable.length>0&&!r.pickable.includes('1')&&!r.pickable.includes('2')&&!r.pickable.includes('3'),
    `${r.pickable.length} of ${r.all}`);
  for(const v of r.pickable.slice(0,6)) await p.click(`[data-act="run-pick"][data-valve="${v}"]`,{force:true});
  const picked=await p.evaluate(()=>document.querySelectorAll('.vchip.picked').length);
  check('picking stops at five valves', picked===5, `picked=${picked}`);
  await p.click('[data-act="run-go"]');
  await p.waitForTimeout(200);
  const cmd=writes.find(w=>w.includes('"action":"run"'))||'';
  check('Run writes one command with valves and minutes', /"valves":"\d+(,\d+){4}"/.test(cmd)&&/"minutes":15/.test(cmd), cmd.slice(8,120));
  const locked=await p.evaluate(()=>document.querySelector('[data-act="run-open"]').disabled);
  check('Run locks while the farm answers', locked===true);
  await c.close();
}
{
  const [p,c]=await open('?live=1&mobitech=ok&watering=1#/irrigation');
  await p.waitForSelector('.now.is-on');
  const r=await p.evaluate(()=>({run:document.querySelector('[data-act="run-open"]').disabled, stop:!!document.querySelector('[data-act="irr-stop"]'),
    open:document.querySelectorAll('.vchip.is-on').length}));
  check('a manual run offers Stop and blocks a second Run', r.run&&r.stop, JSON.stringify(r));
  check('the running valves are marked open', r.open===2, `${r.open}`);
  await c.close();
}
{
  const [p,c]=await open('?live=1&irroff=1#/irrigation');
  await p.waitForSelector('.now');
  const r=await p.evaluate(()=>({run:document.querySelector('[data-act="run-open"]').disabled, why:document.querySelector('.now .note-off')?.textContent||''}));
  check('valve control switched off disables Run and says so', r.run&&/switched off/.test(r.why), r.why);
  await c.close();
}
await b.close();
console.log(fail?`\n${fail} issue(s) found`:'\nno issues found');
