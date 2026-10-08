const test=require('node:test'),assert=require('node:assert/strict'),vm=require('node:vm'),fs=require('node:fs');
function harness(report,gate) {
  const button={onclick:null};
  const panel={innerHTML:'',querySelector(selector){return selector==='#new-report'?button:null;}};
  const ctx={window:{},AbortController,Date,fetch:async ()=>{
    if(gate) await gate;
    return {ok:true,json:async()=>report};
  }};
  vm.runInNewContext(fs.readFileSync('staple_scout/static/reports.js','utf8'),ctx);
  const cleanup=ctx.window.StapleReports.mount(panel,{reportID:'saved',focusHeading:false});
  return {panel,cleanup};
}
const base={id:'saved',as_of:'2026-01-02T00:00:00Z',generated_at:'2026-01-02T01:00:00Z',
  channel:'in_store',settings_policy:'Frozen settings',shopping:[],stores:[],source_health:[],price_drops:[],comparisons:[]};
test('saved empty report has honest coverage and no manufactured discounts',async()=>{
  const {panel}=harness(base);await new Promise(setImmediate);
  assert.match(panel.innerHTML,/No staples match/);assert.match(panel.innerHTML,/No comparable price drops/);
  assert.match(panel.innerHTML,/Reopen this saved report/);
});
test('saved report surfaces stale warnings and escapes API values',async()=>{
  const offer={id:1,product_name:'<script>',price:'<svg>',unit_price:'1',quantity:'16',unit:'oz',pack_count:1,
    basis:'oz',eligible:false,exclusion_reasons:['stale'],quantity_kind:'fixed'};
  const {panel}=harness({...base,comparisons:[{staple:{name:'Rice'},gap:'no_eligible_offers',offers:[offer]}]});
  await new Promise(setImmediate);
  assert.match(panel.innerHTML,/Recorded-offer warnings: stale/);
  assert.match(panel.innerHTML,/&lt;script&gt;/);assert.doesNotMatch(panel.innerHTML,/<script>/);
});
test('cancelled report navigation never overwrites replacement view',async()=>{
  let release;const gate=new Promise(resolve=>release=resolve);
  const {panel,cleanup}=harness(base,gate);cleanup();panel.innerHTML='Replacement view';release();
  await new Promise(setImmediate);assert.equal(panel.innerHTML,'Replacement view');
});
