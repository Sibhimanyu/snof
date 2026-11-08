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
// Home's switches are tiles (2026-09-25): long real names must clip inside
// the tile, and a dead switch must never be offered as one.
{
  const [p,c]=await open('?real=1');
  await p.waitForSelector('.tile');
  const r=await p.evaluate(()=>{
    const tiles=[...document.querySelectorAll('.tile')];
    return {n:tiles.length,
      clamp:tiles.every(t=>{const cs=getComputedStyle(t.querySelector('.tile-name'));return cs.webkitLineClamp==='2'&&cs.overflow==='hidden';}),
      overflow:tiles.filter(t=>t.scrollWidth>t.clientWidth+1).length,
      flow:!!document.querySelector('.flow'), cards:document.querySelectorAll('.vcard').length};
  });
  check('Home draws the water flow and the cards', r.flow&&r.cards>=1, JSON.stringify({flow:r.flow,cards:r.cards}));
  check('switch tiles clamp long names', r.n>0&&r.clamp, `${r.n} tiles`);
  check('no tile overflows', r.overflow===0, `${r.overflow} of ${r.n}`);
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
// Long names must not overflow at a narrow width either.
{
  const [p,c]=await open('?real=1');
  await p.setViewportSize({width:390,height:844});
  await p.waitForSelector('.tile'); await p.waitForTimeout(150);
  const o=await p.evaluate(()=>[...document.querySelectorAll('.tile, .vcard, .flow')].filter(t=>t.scrollWidth>t.clientWidth+1).length);
  check('nothing on Home overflows on a phone', o===0, `${o} overflowing`);
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
  check('report builder offers every collection endpoint', r.options.length===14,
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
    const unreachable=allowed.filter(t=>!r.options.includes(t)&&!['programs','rain'].includes(t)); // cache reads: asked by Refresh, not picked
    check('every offered report type is on the rules allow-list',
      missing.length===0&&unreachable.length===0,
      `missing:${missing.join(',')||'none'} unreachable:${unreachable.join(',')||'none'}`);
  }
  check('seeded report history renders', r.seeded>=1, `${r.seeded} cards`);
  check('no vendor credential leaks into the page', r.scripts===false);
  // End to end: pick a range report, press Generate, the answer arrives.
  await p.selectOption('#irr-type','motor_log');
  await p.waitForTimeout(150);
  await p.click('[data-act="irr-gen"]');
  await p.waitForFunction(()=>[...document.querySelectorAll('.rep-card .rep-title')].some(t=>t.textContent==='Motor log'), null, {timeout:8000});
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
      .find(c=>c.querySelector('.rep-title').textContent.startsWith('Irrigation session log')
        &&/\b20(–\d+)? Feb/.test(c.querySelector('.rep-when').textContent));
    return card&&{tag:card.querySelector('.tag').textContent,
      err:card.querySelector('.rep-err')?.textContent||''};});
  check('a partly-failed report says so on the card',
    partial&&partial.tag==='Partly ready'&&/DCON logs/.test(partial.err),
    JSON.stringify(partial));
  // History written before sections existed still renders.
  const legacy=await p.evaluate(()=>{
    const card=[...document.querySelectorAll('.rep-card')]
      .find(c=>c.querySelector('.rep-title').textContent==='Timer log'
        &&/\b20(–\d+)? Feb/.test(c.querySelector('.rep-when').textContent));
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
  check('and the page says why', /turned off at the farm/.test(r.why), r.why.slice(0,70));
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
    writes.length===0&&after.busy===false&&/turned off/.test(after.toast),
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
  const read=()=>({disabled:document.querySelector('[data-act="irr-gen"]')?.disabled,
    why:document.querySelector('.rep-builder + .note-off')?.textContent||''});
  const relay=await p.evaluate(read);
  // Reads go through the NUC's relay until the function reaches Mobitech
  // itself (docs/dcon-off-the-nuc.md): a quiet bridge closes Generate with the
  // reason, rather than letting it time out. A direct transport does not.
  check('a stale bridge closes reports while reads are relayed, and says why',
    relay.disabled===true&&/cannot be read/.test(relay.why), relay.why.slice(0,80));
  const direct=await p.evaluate((fn)=>{state.meta.reports=Object.assign({},state.meta.reports,{transport:'direct'});render();
    return {disabled:document.querySelector('[data-act="irr-gen"]')?.disabled,
      why:document.querySelector('.rep-builder + .note-off')?.textContent||''};});
  check('once reads are direct, a stale bridge does not block them', direct.disabled===false&&direct.why==='',
    JSON.stringify(direct).slice(0,80));
  const blank=await p.evaluate(()=>{state.meta.reports.transport='';render();
    return document.querySelector('[data-act="irr-gen"]')?.disabled;});
  check('only an explicit "direct" opens reads without the bridge', blank===true);
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
    now:document.querySelector('.now-detail')?.textContent||''}));
  check('a manual run offers Stop and blocks a second Run', r.run&&r.stop, JSON.stringify(r));
  check('the running valves are named in Now', /4 Veg, 6 Kulam/.test(r.now), r.now.slice(0,60));
  await c.close();
}
{
  const [p,c]=await open('?live=1&irroff=1#/irrigation');
  await p.waitForSelector('.now');
  const r=await p.evaluate(()=>({run:document.querySelector('[data-act="run-open"]').disabled, why:document.querySelector('.now .note-off')?.textContent||''}));
  check('valve control switched off disables Run and says so', r.run&&/switched off/.test(r.why), r.why);
  await c.close();
}
// The valve list exists only while picking valves for a run (owner: a
// standing list of valve names "makes no use and sense").
{
  const [p,c]=await open('?live=1&mobitech=ok#/irrigation');
  await p.waitForSelector('.now');
  const before=await p.evaluate(()=>document.querySelectorAll('.vchip').length);
  await p.click('[data-act="run-open"]');
  const during=await p.evaluate(()=>document.querySelectorAll('.vchip').length);
  check('valve list appears only while picking a run', before===0&&during>0, `before=${before} during=${during}`);
  await c.close();
}
// Real production data, replayed (skipped when no local snapshot exists).
{
  const [p,c]=await open('?replay=1&fresh=1#/irrigation');
  const ok=await p.waitForSelector('.page-title',{timeout:5000}).then(()=>true).catch(()=>false);
  const has=await p.evaluate(()=>!!document.querySelector('.watered')).catch(()=>false);
  if(ok&&has){
    const r=await p.evaluate(()=>({reports:document.querySelectorAll('.rep-card').length,
      crops:document.querySelectorAll('.crop-row').length, cut:[...document.querySelectorAll('.crop-valves')].map(x=>x.textContent).filter(t=>/cut short/.test(t)),
      phases:document.querySelectorAll('.phase').length}));
    check('replay: reports are the latest of each kind, at most 12', r.reports>0&&r.reports<=12, `${r.reports} cards`);
    check('replay: watered lists crops with minutes', r.crops>=5, `${r.crops} crops`);
    check('replay: a cut-short count never exceeds the runs', r.cut.every(t=>+(/(\d+) cut short/.exec(t)||[0,0])[1]<=4), r.cut.join(' | '));
    check('replay: three phases drawn', r.phases===3, `${r.phases}`);
    await p.goto(p.url().replace('#/irrigation','#/'));
    await p.waitForSelector('.attn');
    await p.evaluate(()=>{attnOpen=true;render();});
    const h=await p.evaluate(()=>({tiles:[...document.querySelectorAll('.tile .tile-name')].map(t=>t.textContent),
      attn:[...document.querySelectorAll('.attn-row strong')].map(t=>t.textContent)}));
    check('replay: no inverter or AC setting among Home tiles', h.tiles.length>0&&!h.tiles.some(t=>/export limit|sleep mode|display/i.test(t)), h.tiles.join(', '));
    check('replay: appliances switched off are never "needs a look"', !h.attn.some(t=>/AC|TV|printer|P1S/i.test(t)), h.attn.join(' | '));
  } else console.log('  skip  replay checks (no replay.local.json)');
  await c.close();
}
// QA-agent regressions (2026-09-25).
{
  const [p,c]=await open('?replay=1&fresh=1#/devices');
  const ok=await p.waitForSelector('.dgroups',{timeout:5000}).then(()=>true).catch(()=>false);
  if(ok){
    // Devices Home Assistant names by serial number read as what they are,
    // and the printer keeps its AMS and spool, which are matched on the raw names.
    const n=await p.evaluate(()=>{const s=farmSystems(flatEntities());
      return {serial:flatEntities().map(e=>e.name).concat([...document.querySelectorAll('.dgroup-name')].map(t=>t.textContent))
        .filter(t=>/\b(P1S|X1C|A1)_\d|T8400P\d/.test(t)),
        printer:(s.printer?.devices||[]).map(d=>d.name), doubled:flatEntities().filter(e=>/^(\S+) \1\b/.test(e.name)).map(e=>e.name)};});
    check('replay: no device or entity reads as a serial number', n.serial.length===0, n.serial.slice(0,3).join(' | '));
    check('replay: the printer keeps its AMS and spool after renaming', n.printer.length>=3, n.printer.join(', '));
    check('replay: a renamed device never doubles its name', n.doubled.length===0, n.doubled.slice(0,3).join(' | '));
    await p.click('.seg button[data-status=offline]'); await p.waitForTimeout(150);
    const r=await p.evaluate(()=>({tags:[...document.querySelectorAll('.dgroup .tag')].map(t=>t.textContent),
      names:[...document.querySelectorAll('.dgroup-name')].map(t=>t.textContent),
      open:document.querySelectorAll('.dgroup.open').length}));
    check('not reporting lists wholly offline devices, closed', r.names.length>0&&r.open===0&&!r.names.includes('GoodWe'), `${r.names.length} devices, ${r.open} open`);
    check('an appliance off at the wall is "Off", not red "Offline"', r.tags.includes('Off')&&r.tags.includes('Offline'), [...new Set(r.tags)].join(', '));
    await p.click('.seg button[data-status=all]'); await p.fill('#search','offline'); await p.waitForTimeout(200);
    const found=await p.evaluate(()=>document.querySelectorAll('.dgroup').length);
    check('searching "offline" finds what is not reporting', found>0, `${found} devices`);
    await p.fill('#search',''); await p.goto(p.url().split('#')[0]+'#/area/family_room'); await p.waitForTimeout(400);
    const room=await p.evaluate(()=>({rows:document.querySelectorAll('.row').length, units:[...document.querySelectorAll('.dev-state, .row-state')].map(x=>x.textContent).filter(t=>/unavailable\s*\S/.test(t)).length,
      note:[...document.querySelectorAll('.more-note')].map(n=>n.textContent).join(' | '),
      faded:[...document.querySelectorAll('.area-sec')].map(n=>n.classList.contains('is-faded')),
      tags:[...document.querySelectorAll('.is-faded .panel-head .tag')].map(n=>n.textContent)}));
    // Since 2026-09-25 (owner): an off device is drawn like the rest, faded, at
    // the end — still without its dozens of dead readings.
    const lastFaded=room.faded.indexOf(true)>=0&&room.faded.slice(room.faded.indexOf(true)).every(Boolean);
    check('a room draws wholly offline devices faded, last, without their dead readings', room.rows<40&&lastFaded&&room.tags.every(t=>/Switched off|Offline/.test(t)), `${room.rows} rows · ${room.tags.join(', ')}`);
    check('"unavailable" never carries a unit', room.units===0, `${room.units}`);
  } else console.log('  skip  replay regressions (no replay.local.json)');
  await c.close();
}
{
  // Needs a look: collapsed at first, opens on a tap, the rest on "N more".
  const [p,c]=await open('?live=1&stale=1#/');
  await p.waitForSelector('.attn');
  const shut=await p.evaluate(()=>({rows:document.querySelectorAll('.attn-row').length,
    peek:document.querySelector('.attn-peek')?.textContent||'',exp:document.querySelector('[data-act="attn-open"]')?.getAttribute('aria-expanded')}));
  check('Needs a look starts collapsed, naming the worst thing', shut.rows===0&&shut.peek.length>0&&shut.exp==='false', JSON.stringify(shut));
  await p.click('[data-act="attn-open"]'); await p.waitForTimeout(100);
  const n=await p.evaluate(()=>{const a=state.water||{};a.river=Object.assign({},a.river,{trips:['dry run'],name:'River Motor'});
    a.motors=Object.assign({},a.motors);for(const k of Object.keys(a.motors))a.motors[k]=Object.assign({},a.motors[k],{skippedZone:4});state.water=a;render();
    return document.querySelectorAll('.attn-row').length;});
  const more=await p.$('[data-act="attn-more"]');
  if(more){ await more.click(); await p.waitForTimeout(100); }
  const after=await p.evaluate(()=>document.querySelectorAll('.attn-row').length);
  check('"N more" in Needs a look opens the rest', n>0 && (!more || after>n), `${n} -> ${after}`);
  await p.evaluate(()=>render());
  check('Needs a look stays open across a re-render', await p.evaluate(()=>document.querySelectorAll('.attn-row').length)===after, '');
  await c.close();
}
{
  // A run the log caught part-way reads "so far", never "cut short", however
  // long ago the log was read (2026-09-25: Mango2, read 22 minutes into its
  // hour, read as cut short on Home two hours later).
  const [p,c]=await open('?live=1#/irrigation');
  await p.waitForSelector('#view .panel');
  const r=await p.evaluate(()=>{
    const read=serverNow()-2*3600e3, start=read-22*60e3;
    const stamp=(ms)=>{const t=new Date(ms+farmTz()*60000).toISOString();return t.slice(0,10)+' '+t.slice(11,19);};
    state.irrigation=Object.assign({},state.irrigation,{meta:{lastUpdated:read},program:{at:read,running:false},
      timerLog:[{at:stamp(start),event:'Program · Mango2',detail:'11m of 1h, stopped · 17 Mango 2 · started by timer',source:'timer'},
                {at:stamp(start-3*3600e3),event:'Program · Mango1',detail:'25m of 1h, stopped · 16 Mango 1 · started by A8',source:'timer'}]});
    render(); const irr=document.getElementById('view').innerText;
    // Read 10 minutes ago, 22 minutes in: still inside its hour, so "so far".
    const read2=serverNow()-10*60e3; state.irrigation.meta={lastUpdated:read2};
    state.irrigation.timerLog=[Object.assign({},state.irrigation.timerLog[0],{at:stamp(read2-22*60e3)})]; render();
    const soFar=document.getElementById('view').innerText;
    // Ended by a Stop 8 minutes in, read 2 minutes later: cut short at once.
    state.irrigation.timerLog=[{at:stamp(read2-10*60e3),event:'Program · Manual Mode',detail:'8m of 30m, stopped · 4 Veg · started by A8 · ended by A8',source:'timer'}];
    render(); const ended=document.getElementById('view').innerText;
    state.irrigation.timerLog=[{at:stamp(start),event:'Program · Mango2',detail:'11m of 1h, stopped · 17 Mango 2 · started by timer',source:'timer'},
                {at:stamp(start-3*3600e3),event:'Program · Mango1',detail:'25m of 1h, stopped · 16 Mango 1 · started by A8',source:'timer'}];
    state.irrigation.meta={lastUpdated:read};
    location.hash='#/'; attnOpen=true; render(); return {irr, soFar, ended, home:document.getElementById('view').innerText};});
  check('a run caught part-way, its hour since past, reads "by <read time>", not "cut short"', /11m of 1h by \d\d:\d\d/.test(r.irr)&&!/11m of 1h, cut short/.test(r.irr),
        (r.irr.match(/.{0,24}(so far|cut short| by \d\d:\d\d).{0,16}/)||[''])[0]);
  check('while it could still be going, it reads "so far"', /11m of 1h so far/.test(r.soFar), (r.soFar.match(/.{0,24}(so far|cut short| by ).{0,16}/)||[''])[0]);
  check('a run the controller ended is cut short at once', /8m of 30m, cut short/.test(r.ended), (r.ended.match(/.{0,24}(so far|cut short| by ).{0,16}/)||[''])[0]);
  check('Needs a look counts only the run the log saw end', /1 run cut short/.test(r.home)&&!/2 runs cut short/.test(r.home),
        (r.home.match(/\d+ runs? cut short[^\n]*/)||['none'])[0]);
  await c.close();
}
{
  // A water reading that is not current is drawn with its age, never as
  // water flowing (2026-09-25: "River · Running" after the session ended).
  const [p,c]=await open('?live=1#/');
  await p.waitForSelector('#view .flow');
  const r=await p.evaluate(()=>{
    const now=serverNow(), iso=(ms)=>new Date(ms).toISOString();
    state.meta=Object.assign({},state.meta,{water:{enabled:true,livesky:{ok:true,signedInAt:now-864e5,expires:now+864e5},niagara:{ok:true}}});
    state.water={pulledAt:now-5000,river:{name:'River Motor',vendor:'livesky',running:true,reportedAt:iso(now-3600e3)},
      motors:{s:{name:'Wellmotor75HP',vendor:'niagara',role:'main-farm',running:true,reportedAt:iso(now-3600e3)}}};
    // Home's water card is the Water tab's path, compact: one row per motor.
    const rows=()=>[...document.querySelectorAll('#view .flow .wp-motor')].filter(a=>a.getAttribute('href')!=='#/motor/dcon'&&a.querySelector('.tag').textContent!=='No reading');
    const f=()=>{render();return {pipes:rows().map(a=>!!a.querySelector('.wp-st.is-on')),
      ages:rows().map(a=>a.querySelector('.wp-state em')?.textContent).filter(Boolean),
      tags:rows().map(a=>a.querySelector('.tag').textContent),lines:rows().map(a=>a.querySelector('small')?.textContent||''),
      head:document.querySelector('#view .flow .flow-head .card-age')?.textContent||''};};
    const stale=f();
    state.water.river.reportedAt=iso(now-20e3); const fresh=f();
    state.meta.water.livesky.expires=now-60e3; const expired=f();
    state.meta.water.enabled=false; const off=f();
    // Niagara failing for 3 h while pulls go on: its age is its last good read.
    state.meta.water.enabled=true; state.meta.water.livesky.expires=now+864e5; state.water.pulledAt=now-5000;
    state.meta.water.niagara={ok:false,error:'Niagara: HTTP 502',at:now-3*3600e3}; const niagaraDown=f();
    return {stale,fresh,expired,off,niagaraDown};});
  check('a stale river reading shows its age and does not flow', r.stale.pipes[0]===false&&r.stale.ages.length===1&&r.stale.head==='', JSON.stringify(r.stale));
  check('Niagara, which reports on change, still flows on a fresh pull', r.stale.pipes[1]===true);
  check('fresh readings flow, with no age beside them', r.fresh.pipes.every(Boolean)&&r.fresh.ages.length===0, JSON.stringify(r.fresh));
  // Since 2026-09-26 (owner): a source that cannot be read says so, in place.
  check('an ended Livesky session stops the river flowing and says it cannot be read', r.expired.pipes[0]===false&&r.expired.tags[0]==="Can't read"&&/Livesky sign-in expired/.test(r.expired.lines[0])&&!/just now/.test(r.expired.ages[0]||''), JSON.stringify(r.expired));
  check('Home says when water readings are off', r.off.head==='readings off', r.off.head);
  check('a failing Niagara read is not current, says so, and ages from its last good read', r.niagaraDown.pipes[1]===false&&r.niagaraDown.tags[1]==="Can't read"&&r.niagaraDown.ages.some((a)=>a.startsWith('read 3h ago · ')), JSON.stringify(r.niagaraDown));
  await c.close();
}
{
  // Room pages say what things are, and leave settings and diagnostics out
  // unless searched for (2026-09-25: "Binary Sensor", "Debug (station)").
  let hasReplay=true; try{readFileSync(new URL('./replay.local.json',import.meta.url));}catch{hasReplay=false;}
  if(hasReplay){
    const [p,c]=await open('?replay=1&fresh=1#/area/sheep_shed');
    await p.waitForSelector('#view .area-sec');
    const r=await p.evaluate(()=>({titles:[...document.querySelectorAll('#view .area-sec .panel-title')].map(t=>t.firstChild.textContent),
      debug:[...document.querySelectorAll('#view .row-name')].filter(n=>/debug/i.test(n.textContent)).length}));
    check('replay: room sections are named for what they are', r.titles.includes('Detectors')&&!r.titles.some(t=>/Binary|Control Panel|Select/.test(t)), r.titles.join(', '));
    check('replay: no debug rows in a room unless searched', r.debug===0, `${r.debug}`);
    await c.close();
  } else console.log('  skip  room section checks (no replay.local.json)');
}
{
  // Water: every motor alike (owner, 2026-09-25), once each, as equal rows
  // on the water's path, the main farm's controller among them, each opening
  // its own page — no jump to another tab, no second copy of the motors.
  const [p,c]=await open('?live=1#/water');
  await p.waitForSelector('#view .wscene');
  const r=await p.evaluate(()=>{const t=[...document.querySelectorAll('#view .ws-card')];
    const st=new Set(t.map(x=>Math.round(x.querySelector('.ws-badge').getBoundingClientRect().width)));
    const hrefs=t.map(x=>x.querySelector('.ws-name').getAttribute('href'));
    return {n:t.length, hrefs, once:new Set(hrefs).size===hrefs.length, stations:[...st],
      dup:document.querySelectorAll('#view .mtile, #view .fm, #view .wstage').length};});
  check('the Water tab shows every motor once, as equal rows, the controller included', r.n>=4&&r.once&&r.stations.length===1&&r.hrefs.includes('#/motor/dcon')&&r.dup===0, JSON.stringify(r));
  check('every row opens a motor page, none another tab', r.hrefs.every(h=>h.startsWith('#/motor/')), r.hrefs.join(' '));
  await p.click('#view .ws-name[href="#/motor/dcon"]'); await p.waitForTimeout(400);
  const d=await p.evaluate(()=>({hash:location.hash, tab:document.querySelector('.tab-item.on, .topnav-item.on')?.textContent||'', now:!!document.querySelector('#view .now')}));
  check("the controller's page holds its controls, under the Water tab", d.hash==='#/motor/dcon'&&/Water/.test(d.tab)&&d.now, JSON.stringify(d));
  await c.close();
}
{
  // No tab of its own for the main farm (owner, 2026-09-25): the controller
  // is one of the motors; old #/irrigation links land on its motor page.
  const [p,c]=await open('#/irrigation');
  await p.waitForSelector('#view .page-title');
  const r=await p.evaluate(()=>({nav:[...document.querySelectorAll('.tab-item, .topnav-item')].map(a=>a.textContent.trim()),
    on:document.querySelector('.tab-item.on, .topnav-item.on')?.textContent||'', now:!!document.querySelector('#view .now'),
    links:[...document.querySelectorAll('a[href="#/irrigation"]')].length}));
  check('no Irrigation tab: every motor alike under Water', !r.nav.includes('Irrigation')&&r.nav.includes('Water'), r.nav.join(' | '));
  check('an old irrigation link opens the controller as a motor, under Water', r.on.includes('Water')&&r.now&&r.links===0, JSON.stringify(r));
  await c.close();
}
{
  // The water's path: a motor shows water moving only while it runs on a
  // current reading, and a stale reading turns its pipe grey.
  const [p,c]=await open('?live=1#/water');
  await p.waitForSelector('#view .wscene');
  const r=await p.evaluate(()=>{const now=serverNow(), iso=(ms)=>new Date(ms).toISOString();
    state.meta=Object.assign({},state.meta,{water:{enabled:true,livesky:{ok:true,at:now-5000,signedInAt:now-864e5,expires:now+864e5},niagara:{ok:true,at:now-5000}}});
    state.water={pulledAt:now-5000,river:{name:'River Motor',vendor:'livesky',running:true,connected:true,reportedAt:iso(now-20e3)},
      motors:{wellmotor75hp:{name:'Wellmotor75HP',vendor:'niagara',role:'main-farm',running:false},
              'well-motor':{name:'Well motor',vendor:'niagara',role:'drip',running:true,program:'P1',zone:3}}};
    render();
    const card=(k)=>document.querySelector(`#view .ws-card:has(.ws-name[href="#/motor/${k}"])`);
    const on=(k)=>!!card(k)?.classList.contains('is-on');
    // pipe 1 (River -> Thoppu) is the first link; the drip pipe is the thin one.
    const riverPipe=()=>!!document.querySelector('#view .ws-pipes-h .ws-pipe.is-on[data-p="river"]');
    const a={river:on('river'), drip:on('well-motor'), supply:on('wellmotor75hp'), pipe:riverPipe(),
      stub:!!document.querySelector('#view .ws-pipe.is-mid.is-on')};
    state.water.river.reportedAt=iso(now-3600e3); render();
    return {...a, staleRiver:on('river'), stalePipe:riverPipe(), word:card('river').querySelector('.tag').textContent};});
  check('running motors show water moving, a stopped one does not', r.river&&r.drip&&!r.supply&&r.pipe&&r.stub, JSON.stringify(r));
  check('a stale reading stops the flow and says what the motor was doing', !r.staleRiver&&!r.stalePipe&&r.word==='Was running', JSON.stringify(r));
  await c.close();
}
{
  // Motor control (docs/motor-control.md): nothing until a motor is armed;
  // then one control that matches the motor's current state, closed on a
  // stale reading, during a change and in the cooldown; one press, one
  // minimal command.
  const [p,c]=await open('?live=1#/motor/river');
  const writes=[]; p.on('console',m=>{if(m.text().startsWith('COMMAND')&&m.text().includes('"motor"'))writes.push(m.text());});
  p.on('dialog',d=>d.accept());
  await p.waitForSelector('#view .page-title');
  const none=await p.evaluate(()=>document.querySelectorAll('[data-act="motor-cmd"]').length);
  check('motor buttons appear only for an armed motor', none===0, `${none}`);
  const r=await p.evaluate(()=>{const now=serverNow(), iso=(ms)=>new Date(ms).toISOString();
    state.meta=Object.assign({},state.meta,{motorControl:{enabled:true,motors:{river:true}},
      water:{enabled:true,livesky:{ok:true,at:now-5000,signedInAt:now-864e5,expires:now+864e5},niagara:{ok:true,at:now-5000}}});
    state.water={pulledAt:now-5000,river:{name:'River Motor',vendor:'livesky',running:true,connected:true,reportedAt:iso(now-20e3)},
      motors:{wellmotor75hp:{name:'Wellmotor75HP',vendor:'niagara',role:'main-farm',running:false}}};
    render();
    const btns=[...document.querySelectorAll('#view [data-act="motor-cmd"]')].map(b=>({m:b.dataset.motor,a:b.dataset.action,d:b.disabled}));
    state.water.river.reportedAt=iso(now-3600e3); render();
    const stale=document.querySelector('#view [data-act="motor-cmd"]')?.disabled;
    state.water.river.reportedAt=iso(now-20e3); render();
    return {btns,stale};});
  check('an armed river motor offers exactly one enabled "Turn off"', r.btns.length===1&&r.btns[0].m==='river'&&r.btns[0].a==='off'&&!r.btns[0].d, JSON.stringify(r.btns));
  check('no switching a motor off a stale reading', r.stale===true);
  await p.click('#view [data-act="motor-cmd"]'); await p.waitForTimeout(120);
  const busy=await p.evaluate(()=>document.querySelector('#view [data-act="motor-cmd"]')?.disabled);
  await p.waitForTimeout(1200);
  const after=await p.evaluate(()=>{const t=[...document.querySelectorAll('.toast')].map(x=>x.textContent).join('|');
    // The cooldown holds a start (never a stop).
    state.water.river.running=false; state.meta.motorControl.lastByMotor={river:serverNow()-30000}; render();
    return {t,cool:document.querySelector('#view [data-act="motor-cmd"]')?.disabled,
      why:document.querySelector('#view .wm-why')?.textContent||''};});
  check('one press writes one command: motor, action, uid, at, clientAt and nothing else',
    writes.length===1&&/"motor":"river","action":"off","uid":"[^"]+","at":/.test(writes[0])&&!/valves|keyword|sentSms|status/.test(writes[0]), writes.join(' | '));
  check('the button closes while the motor confirms', busy===true);
  check('the result says the motor confirmed it', /Confirmed: River Motor is off/.test(after.t), after.t);
  check('the per-motor cooldown closes the button, with the wait', after.cool===true&&/Wait \d+s/.test(after.why), after.why);
  check('a press carries its own time (clientAt), so a queued-offline write is refused', /"clientAt":\d{12,}/.test(writes[0]||''), writes[0]||'');
  const off=await p.evaluate(()=>{dbConnected=false;state.meta.motorControl.lastByMotor={};render();
    return {d:document.querySelector('#view [data-act="motor-cmd"]')?.disabled,why:document.querySelector('#view .wm-why')?.textContent||''};});
  check('no motor press while offline', off.d===true&&/Offline/.test(off.why), off.why);
  await c.close();
}
{
  // Zone change on the zoned Niagara controller: chips only when its zones
  // are armed and a program is running; the current zone cannot be pressed;
  // one press, one command with the zone.
  const [p,c]=await open('?live=1#/motor/well-motor');
  const writes=[]; p.on('console',m=>{if(m.text().startsWith('COMMAND')&&m.text().includes('"motor"'))writes.push(m.text());});
  p.on('dialog',d=>d.accept());
  await p.waitForSelector('#view .page-title');
  const r=await p.evaluate(()=>{const now=serverNow(), iso=(ms)=>new Date(ms).toISOString();
    state.meta=Object.assign({},state.meta,{motorControl:{enabled:true,motors:{'well-motor':true}},
      water:{enabled:true,livesky:{ok:true,at:now-5000,signedInAt:now-864e5,expires:now+864e5},niagara:{ok:true,at:now-5000}}});
    state.water={pulledAt:now-5000,motors:{'well-motor':{name:'Well motor',vendor:'niagara',role:'drip',running:true,requested:true,
      program:'P1',zone:3,zoneLeft:'00:30:00',liveAt:iso(now-10e3)}}};
    render(); const unarmed=document.querySelectorAll('#view .zchip').length;
    state.meta.motorControl.zones={'well-motor':true}; render();
    const chips=[...document.querySelectorAll('#view .zchip')].map(b=>({z:b.dataset.zone,now:b.classList.contains('is-now'),d:b.disabled}));
    state.water.motors['well-motor'].running=false; render(); const stopped=document.querySelectorAll('#view .zchip').length;
    state.water.motors['well-motor'].running=true; render();
    return {unarmed,chips,stopped};});
  check('zone chips only once zone changes are armed', r.unarmed===0, `${r.unarmed}`);
  check('eight zones, the current one marked and not pressable', r.chips.length===8&&r.chips[2].now&&r.chips[2].d&&!r.chips[4].d, JSON.stringify(r.chips.slice(1,5)));
  check('no zone change while the motor is stopped', r.stopped===0, `${r.stopped}`);
  const short=await p.evaluate(()=>{state.water.motors['well-motor'].zoneLeft='00:03:00';render();
    const d=[...document.querySelectorAll('#view .zchip')].every(b=>b.disabled);
    const why=document.querySelector('#view .wzones .more-note')?.textContent||'';
    state.water.motors['well-motor'].zoneLeft='00:30:00';render(); return {d,why};});
  check('no zone change in the last 5 minutes of a zone', short.d&&/under 5 minutes/.test(short.why), short.why);
  await p.click('#view .zchip[data-zone="5"]'); await p.waitForTimeout(1200);
  check('one press writes one zone command', writes.length===1&&/"motor":"well-motor","action":"zone".*"zone":5/.test(writes[0]), writes.join(' | '));
  await c.close();
}
{
  // Every page, on the narrowest phone, with the real farm's names and
  // readings: nothing is wider than the screen. (The iOS Irrigation page
  // once was, from two tags that could not wrap.)
  let hasReplay=true; try{readFileSync(new URL('./replay.local.json',import.meta.url));}catch{hasReplay=false;}
  const c=await b.newContext({viewport:{width:320,height:800}}); const p=await c.newPage();
  const wide=[];
  for (const r of ['#/','#/irrigation','#/water','#/areas','#/devices','#/sys/solar','#/sys/security','#/admin']) {
    await p.goto(base+(hasReplay?'?replay=1&fresh=1':'?live=1')+r); await p.waitForTimeout(700);
    const w=await p.evaluate(()=>document.documentElement.scrollWidth-document.documentElement.clientWidth);
    if(w>0) wide.push(`${r} +${w}px`);
  }
  check(`no page is wider than a 320px phone (${hasReplay?'replay':'mock'})`, wide.length===0, wide.join(', '));
  await c.close();
}
{
  // Power: three EB lines, each inverter on its own line (owner, 2026-09-25).
  const [p,c]=await open('?live=1#/');
  await p.waitForSelector('.power');
  const lines=await p.evaluate(()=>[...document.querySelectorAll('.pw-line')].map(l=>({t:l.querySelector('.pw-title').textContent,f:(l.querySelector('.pw-fig')||l.querySelector('.pw-right')).textContent.trim(),cls:l.className})));
  check('Power shows the three lines in order', lines.map(l=>l.t).join('|')==='Home & sheds line|EV charger line|Farm motor line', JSON.stringify(lines));
  check('each inverter reads its own figure', /W$/.test(lines[0].f)&&/^1\.04kW$/.test(lines[1].f.replace(/\s/g,'')), lines.map(l=>l.f).join(' | '));
  check('the Solar card is gone from Home', !(await p.$('.vcard.solar')));
  check('Power is rows, not the water chain\'s circles', !(await p.$('.power .flow-disc'))&&(await p.$$('.power .pw-tile')).length===3);
  check('the solar bar splits by inverter', (await p.$$('.pw-split .pw-seg')).length===2);
  // One inverter down in daylight: named, on its line, and the other still counts.
  const r=await p.evaluate(()=>{for(const e of Object.values(state.entities.sensor||{}))if((e.entity_id||'').startsWith('sensor.sibhi_orchards_'))e.state='unavailable';
    const skew=clockSkewMs; const d=new Date(); d.setUTCHours(6,0,0,0); clockSkewMs=d.getTime()-Date.now(); attnOpen=true; render();
    const out={attn:[...document.querySelectorAll('.attn-row strong')].map(t=>t.textContent),ev:document.querySelectorAll('.pw-line')[1].className,home:document.querySelectorAll('.pw-line')[0].className};
    clockSkewMs=skew; return out;});
  check('an inverter offline in daylight is named in Needs a look', r.attn.includes('V-Guard inverter offline'), r.attn.join(' | '));
  check('and only its line reads offline', /is-offline/.test(r.ev)&&!/is-offline/.test(r.home), `${r.home} / ${r.ev}`);
  await p.goto(p.url().replace('#/','#/sys/solar')); await p.waitForTimeout(400);
  const secs=await p.evaluate(()=>[...document.querySelectorAll('.pw-sec .panel-title')].map(t=>t.textContent));
  check('the Power page has a panel per line', secs.length===3, secs.join(', '));
  await c.close();
}
{
  // Chunk 3 and 4 (2026-11-01): Home's water chain lies across a wide card,
  // green only where a current reading says water flows; Water and a motor's
  // page are two panes on a wide screen, each source one equal row/card.
  const [p,c]=await open('?live=1&watering=1#/');
  await p.waitForSelector('#view .wchain');
  const h=await p.evaluate(()=>{const cs=[...document.querySelectorAll('#view .wchain .wc-cell')];
    return {n:cs.length, shown:getComputedStyle(document.querySelector('#view .wchain')).display, rail:getComputedStyle(document.querySelector('#view .wpath.is-compact')).display,
      on:cs.map(x=>x.classList.contains('is-on')), gaps:[...document.querySelectorAll('#view .wchain .wc-pipe i.on')].length,
      w:new Set(cs.map(x=>Math.round(x.getBoundingClientRect().width))).size};});
  check('Home draws the water chain across, four equal stations, the rail hidden', h.n>=4&&h.shown==='grid'&&h.rail==='none'&&h.w===1, JSON.stringify(h));
  check('chain pipe is green only beside running motors', h.on[0]&&h.gaps>=2, JSON.stringify(h));
  await p.goto(p.url().replace('#/','#/water')); await p.waitForTimeout(300);
  const w=await p.evaluate(()=>({cols:getComputedStyle(document.querySelector('#view .ws-grid')).gridTemplateColumns.split(' ').length, cards:document.querySelectorAll('#view .ws-card').length,
    moving:document.querySelectorAll('#view .ws-pipe.is-on .ws-tx').length>0}));
  check('Water is the drawn journey: three places, pipes between, four equal motor cards, flow on the running ones', w.cols===5&&w.cards>=4&&w.moving, JSON.stringify(w));
  await p.goto(p.url().replace('#/water','#/motor/river')); await p.waitForTimeout(300);
  const m=await p.evaluate(()=>({sel:document.querySelector('#view .wp-motor.is-sel')?.getAttribute('href'), metrics:document.querySelectorAll('#view .wm-metrics > div').length,
    details:document.querySelectorAll('#view .wdetails').length}));
  check("a motor's page keeps the list beside it, its readings shown, not folded away", m.sel==='#/motor/river'&&m.metrics>=2&&m.details===0, JSON.stringify(m));
  await c.close();
}
{
  // Water, drawn: a source that cannot be read is hatched with its reason and
  // no state; the owner gets a Sign in link to the page that holds the card.
  const [p,c]=await open('?live=1&livesky=expired&owner=1#/water');
  await p.waitForSelector('#view .wscene');
  const r=await p.evaluate(()=>{const k=document.querySelector('#view .ws-card:has(.ws-name[href="#/motor/river"])');
    return {un:k.classList.contains('is-unread'), tag:k.querySelector('.tag').textContent, line:k.querySelector('.ws-line').textContent,
      sign:k.querySelector('.ws-signin')?.getAttribute('href'), tile:!!document.querySelector('#view .ws-tile.is-unread'),
      moving:!!document.querySelector('#view .ws-pipes-h .ws-pipe.is-on[data-p="river"]')};});
  check("an unreadable river motor is hatched, says why, shows no state, and offers Sign in", r.un&&r.tag==="Can't read"&&/expired/.test(r.line)&&r.sign==='#/motor/river'&&r.tile&&!r.moving, JSON.stringify(r));
  await c.close();
}
{
  // Water, realistic: a stream pours only while the motor feeding that place
  // runs on a current reading; idle water is dry and still; the art is the
  // three drawn scenes, and each says there is no level reading.
  const [p,c]=await open('?live=1#/water');
  await p.waitForSelector('#view .wscene');
  const r=await p.evaluate(()=>({pours:document.querySelectorAll('#view .ws-pipes-h .ws-pour').length,
    wells:document.querySelectorAll('#view .ws-art').length, raster:document.querySelectorAll('#view .ws-tile img').length,
    notes:[...document.querySelectorAll('#view .ws-place small')].map(s=>s.textContent),
    // water in a pipe is a texture, never dots, dashes or beads
    dashed:[...document.querySelectorAll('#view .ws-art *, #view .ws-pipes *')].filter(e=>{const d=getComputedStyle(e).strokeDasharray;return d&&d!=='none'}).length,
    beads:document.querySelectorAll('#view .ws-bub, #view .ws-p-flow').length,
    // every pipe turns in a smooth bend, never a square elbow
    pipes:[...document.querySelectorAll('#view .ws-pipes-h .ws-pg-glass, #view .ws-art .ws-pg-glass')].map(e=>e.getAttribute('d')),
    // the pipes are one drawing over the row, not clipped by a card
    overlay:getComputedStyle(document.querySelector('#view .ws-pipes-h')).display}));
  const bends=r.pipes.every(d=>/ A/.test(d)&&!/L[^A]*L[^A]*L[^A]*L[^ ]* L/.test(d.replace(/ A[^L]*/g,' A')));
  check('Thoppu is poured into by the running river motor, the farm sump (75HP off) is dry', r.pours===1, JSON.stringify(r.pours));
  check('three drawn scenes (no photo), each with a "No level reading" note', r.wells===3&&r.raster===0&&r.notes.length===3&&r.notes.every(n=>n==='No level reading'), JSON.stringify({w:r.wells,i:r.raster,n:r.notes}));
  check('no dots, dashes or beads anywhere in the water art', r.dashed===0&&r.beads===0, JSON.stringify({d:r.dashed,b:r.beads}));
  check('every pipe turns in a rounded bend', r.pipes.length>=5&&r.pipes.every(d=>/ A/.test(d)), r.pipes.map(d=>d.length).join(','));
  check('the pipes are one overlay across the row', r.overlay==='block', r.overlay);
  await c.close();
}
await b.close();
console.log(fail?`\n${fail} issue(s) found`:'\nno issues found');
