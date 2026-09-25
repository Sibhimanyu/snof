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
        &&c.querySelector('.rep-when').textContent.includes('2026-02-20'));
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
      note:[...document.querySelectorAll('.more-note')].map(n=>n.textContent).join(' | ')}));
    check('a room collapses wholly offline devices into one line', room.rows<40&&/Switched off|Offline/.test(room.note), `${room.rows} rows · ${room.note.slice(0,80)}`);
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
    const f=()=>{render();return {pipes:[...document.querySelectorAll('#view .flow-pipe')].map(x=>x.classList.contains('is-on')),
      ages:[...document.querySelectorAll('#view .flow-age')].map(x=>x.textContent),head:document.querySelector('#view .flow-head .card-age')?.textContent||''};};
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
  check('fresh readings flow, with the pull age in the header', r.fresh.pipes.every(Boolean)&&r.fresh.ages.length===0&&/ago|just now/.test(r.fresh.head), JSON.stringify(r.fresh));
  check('an ended Livesky session stops the river flowing', r.expired.pipes[0]===false&&r.expired.ages[0]==='not read', JSON.stringify(r.expired));
  check('Home says when water readings are off', r.off.head==='readings off', r.off.head);
  check('a failing Niagara read is not current, and ages from its last good read', r.niagaraDown.pipes[1]===false&&r.niagaraDown.ages.includes('3h ago'), JSON.stringify(r.niagaraDown));
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
await b.close();
console.log(fail?`\n${fail} issue(s) found`:'\nno issues found');
