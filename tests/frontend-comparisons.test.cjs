const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

function harness(responses, options = {}) {
  const calls = [];
  const controls = {};
  const panel = { _html: '', set innerHTML(value) { this._html = value; }, get innerHTML() { return this._html; }, setAttribute() {}, removeAttribute() {}, querySelector(selector) { if (selector === "[data-retry]" || selector === "[data-refresh]") return controls[selector]; return null; }, querySelectorAll(selector) { return controls[selector] || []; } };
  let aborted = false;
  class AbortControllerFake { constructor() { this.signal = { aborted: false }; } abort() { aborted = true; this.signal.aborted = true; } }
  const context = { window: {}, console, AbortController: AbortControllerFake, URLSearchParams, fetch: async (url, init) => { calls.push(String(url)); if (options.gate) await options.gate; let value = responses.slice().sort((a, b) => b[0].length - a[0].length).find(([prefix]) => String(url).startsWith(prefix))?.[1]; if (typeof value === "function") value = await value(String(url)); if (value instanceof Error) throw value; return { ok: true, json: async () => value }; } };
  vm.runInNewContext(fs.readFileSync('staple_scout/static/comparisons.js', 'utf8'), context);
  return { panel, calls, context, controls, wasAborted: () => aborted };
}

const staples = [{ id: 1, name: 'Rice', basis: 'oz', needed: true, rules: 'plain' }];
const stores = [{ id: 'wegmans', name: 'Wegmans', location: 'Chantilly' }];
const sources = [{ source_id: 'fixture', retailer: 'wegmans', channels: ['in_store'], validated: true }];
const statuses = [{ source_id: 'fixture', last_attempt: { context_id: 1, status: 'succeeded' }, last_success: { context_id: 1, finished_at: '2026-01-01' }, last_failure: null }];

test('excluded cheaper offer is rendered as excluded and never marked winner', async () => {
  const comparison = [{ staple: staples[0], winner_id: 2, purchase_cost_winner_id: null, offers: [{ id: 1, product_name: 'Cheap <bad>', price: '1', unit_price: '0.01', quantity: '16', unit: 'oz', pack_count: 1, store_name: 'Wegmans', store_location: 'Chantilly', channel: 'in_store', observed_at: '2026-01-01', eligible: false, exclusion_reasons: ['not_approved'] }, { id: 2, product_name: 'Approved', price: '3', unit_price: '0.20', quantity: '16', unit: 'oz', pack_count: 1, store_name: 'Wegmans', store_location: 'Chantilly', channel: 'in_store', observed_at: '2026-01-01', eligible: true, exclusion_reasons: [] }] }];
  const h = harness([['/api/staples', staples], ['/api/stores', stores], ['/api/sources', sources], ['/api/staples/1/matches', [{ status: 'approved', retailer: 'wegmans' }]], ['/api/comparisons', comparison], ['/api/source-status', statuses]]);
  h.context.window.StapleComparisons.mount(h.panel, { focusHeading: false }); await new Promise(setImmediate);
  assert.match(h.panel.innerHTML, /Approved/); assert.match(h.panel.innerHTML, /not approved/); assert.doesNotMatch(h.panel.innerHTML, /Cheap &lt;bad&gt;.*Lowest unit price/);
});

test('shopping groups backend winners by store and leaves coverage gaps visible', async () => {
  const comparison = [{ staple: staples[0], winner_id: 2, offers: [{ id: 2, product_name: 'Approved', price: '3', unit_price: '0.20', quantity: '16', unit: 'oz', pack_count: 1, store_id: 'wegmans', store_name: 'Wegmans', store_location: 'Chantilly', channel: 'in_store', observed_at: '2026-01-01', eligible: true, exclusion_reasons: [] }] }, { staple: { id: 2, name: 'Milk', basis: 'oz', rules: '' }, winner_id: null, gap: 'no_observations', offers: [] }];
  const h = harness([['/api/staples/1/matches', [{ status: 'approved', retailer: 'wegmans' }]], ['/api/staples/2/matches', []], ['/api/staples', [...staples, { id: 2, name: 'Milk', basis: 'oz', needed: true }]], ['/api/stores', stores], ['/api/sources', sources], ['/api/comparisons', comparison], ['/api/source-status', statuses]]);
  h.context.window.StapleComparisons.mount(h.panel, { shopping: true, focusHeading: false }); await new Promise(setImmediate);
  assert.match(h.panel.innerHTML, /shopping-store-title/); assert.match(h.panel.innerHTML, /Coverage gaps/); assert.match(h.panel.innerHTML, /Wegmans/);
});

test('cleanup aborts requests and stale response does not replace panel', async () => {
  let release; const gate = new Promise(resolve => { release = resolve; });
  const h = harness([['/api/staples', staples], ['/api/stores', stores], ['/api/sources', sources]], { gate });
  const cleanup = h.context.window.StapleComparisons.mount(h.panel, { focusHeading: false }); cleanup(); release(); await new Promise(setImmediate);
  assert.equal(h.wasAborted(), true); assert.match(h.panel.innerHTML, /Loading your comparisons/);
});

test('selected channel and planned stores are included in comparison URL', async () => {
  const h = harness([['/api/staples', staples], ['/api/stores', stores], ['/api/sources', sources], ['/api/staples/1/matches', []], ['/api/comparisons', []], ['/api/source-status', statuses]]);
  h.context.window.StapleComparisons.mount(h.panel, { shopping: true, focusHeading: false }); await new Promise(setImmediate);
  assert.ok(h.calls.some(url => url.includes('/api/comparisons?') && url.includes('channel=in_store') && url.includes('stores=wegmans') && url.includes('needed_only=true')));
});

test('initial comparison defaults to shelf mode', async () => {
  const h = harness([['/api/staples/1/matches', []], ['/api/staples', staples], ['/api/stores', stores], ['/api/sources', sources], ['/api/comparisons', []], ['/api/source-status', statuses]]);
  h.context.window.StapleComparisons.mount(h.panel, { focusHeading: false }); await new Promise(setImmediate);
  assert.ok(h.calls.some(url => url.includes('/api/comparisons?') && url.includes('channel=in_store')));
});

function control(properties = {}) {
  return {...properties, events:{}, focus() {}, addEventListener(name, fn) {this.events[name]=fn;}};
}
function baseResponses(comparisons = []) {
  return [['/api/staples/1/matches', []], ['/api/staples', staples], ['/api/stores', stores],
    ['/api/sources', sources], ['/api/comparisons', comparisons], ['/api/source-status', statuses]];
}
const tick = () => new Promise(setImmediate);

test('changing channel sends pickup and empty planned stores never means all stores', async () => {
  const h=harness(baseResponses());
  const pickup=control({value:'pickup',id:'filter-pickup'});
  const store=control({dataset:{storeFilter:'wegmans'},checked:true,id:'filter-wegmans'});
  h.controls['[name=comparison-channel]']=[pickup]; h.controls['[data-store-filter]']=[store];
  h.context.window.StapleComparisons.mount(h.panel,{focusHeading:false}); await tick();
  pickup.onchange(); await tick();
  assert.match(h.calls.filter(url=>url.startsWith('/api/comparisons')).at(-1),/channel=pickup/);
  const count=h.calls.length; store.checked=false; store.onchange(); await tick();
  assert.equal(h.calls.length,count); assert.match(h.panel.innerHTML,/Select a planned store/);
});

test('failed refresh retries the preserved filters', async () => {
  const responses=baseResponses(); const h=harness(responses);
  const pickup=control({value:'pickup',id:'filter-pickup'}),retry=control();
  h.controls['[name=comparison-channel]']=[pickup]; h.controls['[data-refresh]']=retry;
  h.context.window.StapleComparisons.mount(h.panel,{focusHeading:false}); await tick();
  responses.find(row=>row[0]==='/api/comparisons')[1]=Error('offline');
  pickup.onchange(); await tick(); assert.match(h.panel.innerHTML,/Couldn’t update comparisons/);
  responses.find(row=>row[0]==='/api/comparisons')[1]=[];
  retry.events.click(); await tick();
  assert.match(h.calls.filter(url=>url.startsWith('/api/comparisons')).at(-1),/channel=pickup/);
});

test('money and product API strings are escaped', async () => {
  const offer={id:1,product_name:'<img src=x>',price:'<script>',unit_price:'<svg>',basis:'oz',
    eligible:false,exclusion_reasons:['stale'],quantity_kind:'fixed'};
  const h=harness(baseResponses([{staple:staples[0],offers:[offer],winner_id:null}]));
  h.context.window.StapleComparisons.mount(h.panel,{focusHeading:false}); await tick();
  assert.match(h.panel.innerHTML,/\$&lt;script&gt;/); assert.doesNotMatch(h.panel.innerHTML,/<img src=x>/);
});
