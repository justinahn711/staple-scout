(() => {
  "use strict";
  const esc = value => String(value ?? "").replace(/[&<>"']/g, c =>
    ({"&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"})[c]);
  const money = value => value == null ? "Unknown" : `$${esc(value)}`;
  const human = value => ({in_store:"Shelf",pickup:"Pickup",online:"Online reference"})[value] || String(value ?? "").replaceAll("_", " ");
  const date = value => value ? esc(new Date(value).toLocaleString()) : "Never";
  async function api(url, signal, body) {
    const response = await fetch(url, {signal, method: body ? "POST" : "GET",
      headers: {"Content-Type":"application/json"}, ...(body ? {body:JSON.stringify(body)} : {})});
    const value = await response.json();
    if (!response.ok) throw Error(Array.isArray(value.detail) ? value.detail.map(item => item.msg).join("; ") : value.detail || `Request failed (${response.status})`);
    return value;
  }
  function mount(panel, options = {}) {
    const controller = new AbortController();
    let generation = 0;
    const alive = token => token === generation && !controller.signal.aborted;
    function outlay(offer) {
      return offer.packages_needed == null ? "" : `<p>${esc(offer.packages_needed)} whole packages · outlay ${money(offer.purchase_cost)} · excess ${esc(offer.excess_quantity)} ${esc(offer.excess_unit)}</p>`;
    }
    function offerHTML(offer, group) {
      return `<article class="report-offer"><h4>${esc(offer.product_name)}</h4>
        <p>${esc(offer.quantity)} ${esc(offer.unit)} per pack × ${esc(offer.pack_count)} · package price ${money(offer.price)} · unit price ${money(offer.unit_price)} / ${esc(offer.basis)}</p>
        <p>${esc(offer.store_name)} · ${esc(offer.store_location)} · ${esc(human(offer.channel))} · observed ${date(offer.observed_at)}</p>
        <p>${offer.conditions ? `Conditions: ${esc(offer.conditions)}` : "No conditions recorded."} Quantity: ${esc(human(offer.quantity_kind))}.</p>
        ${outlay(offer)}
        ${offer.id === group.winner_id ? '<p><strong>Lowest unit price</strong></p>' : ""}
        ${offer.id === group.purchase_cost_winner_id ? '<p><strong>Lowest whole-package outlay</strong></p>' : ""}
        ${!offer.eligible ? `<p class="report-warning">Excluded: ${esc(offer.exclusion_reasons.map(human).join("; "))}</p>` : ""}</article>`;
    }
    function show(report, focusHeading = true) {
      const comparisons = report.comparisons;
      const choiceCount = report.shopping.reduce((sum, store) => sum + store.choices.length, 0);
      const body = `<div class="reports-view"><h2 tabindex="-1">Weekly report</h2>
        <p>Evidence cutoff: ${date(report.as_of)} · ${esc(human(report.channel))} · generated ${date(report.generated_at)}</p>
        <p class="report-policy">${esc(report.settings_policy)}</p>
        <p><a href="/reports/${esc(report.id)}">Reopen this saved report</a> · <button type="button" id="new-report" class="button secondary">Choose report inputs</button></p>
        ${!comparisons.length ? '<div class="empty"><h3>No staples match these inputs</h3><p>Add staples or include staples not needed this week.</p></div>' : ""}
        <h3>Lowest unit-price choices (${choiceCount})</h3>
        ${report.shopping.filter(store => store.choices.length).map(store => `<section class="report-store"><h3>${esc(store.store.name)} · ${esc(store.store.location)}</h3>${store.choices.map(choice => {
          const group = comparisons.find(item => item.staple.id === choice.staple.id);
          return `<h4>${esc(choice.staple.name)}</h4>${offerHTML(choice.offer, group)}`;
        }).join("")}</section>`).join("") || '<p>No eligible choices at the selected stores.</p>'}
        <h3>Coverage and recorded offers</h3>
        <p>Warnings and excluded offers remain visible. Package outlay is a separate choice; no basket savings are calculated.</p>
        ${comparisons.map(group => `<section class="report-staple"><h4>${esc(group.staple.name)}</h4>
          ${group.staple.desired_quantity ? `<p>Requested ${esc(group.staple.desired_quantity)} ${esc(group.staple.desired_unit)}</p>` : ""}
          ${group.gap ? `<p class="report-warning">Coverage gap: ${esc(human(group.gap))}</p>` : ""}
          ${[...new Set(group.offers.flatMap(offer => offer.exclusion_reasons))].length ? `<p class="report-warning">Recorded-offer warnings: ${esc([...new Set(group.offers.flatMap(offer => offer.exclusion_reasons))].map(human).join("; "))}</p>` : ""}
          ${group.staple.desired_quantity && group.purchase_cost_winner_id == null ? '<p class="report-warning">No eligible exact package outlay.</p>' : ""}
          ${group.offers.length ? `<details><summary>Inspect ${group.offers.length} recorded offers and exclusions</summary>${group.offers.map(offer => offerHTML(offer, group)).join("")}</details>` : '<p>No observations at this cutoff.</p>'}</section>`).join("")}
        <h3>Observed package-price drops</h3>
        ${report.price_drops.map(drop => `<p>${esc(drop.product_name)} · ${esc(drop.store_id)} · ${esc(human(drop.channel))}: ${money(drop.previous_price)} (${date(drop.previous_observed_at)}, observation ${esc(drop.previous_observation_id)}) → ${money(drop.price)} (${date(drop.observed_at)}, observation ${esc(drop.observation_id)}). Same-package decrease ${money(drop.package_price_drop)}.</p>`).join("") || '<p>No comparable price drops in this history.</p>'}
        <details><summary>Source status at the cutoff</summary>${report.stores.map(store => {
          const sources = report.source_health.filter(source => source.store_id === store.id && source.relevant);
          return `<p><strong>${esc(store.name)}</strong>: ${sources.length ? sources.map(source => `${esc(source.source_id)} · last attempt ${date(source.last_attempt?.started_at)} (${esc(source.last_attempt?.status || "none")}) · last success ${date(source.last_success?.finished_at)} · last failure ${date(source.last_failure?.finished_at)} ${esc(source.last_failure?.error || "")}`).join("; ") : "No connected source for this channel. Manual observations may qualify."}</p>`;
        }).join("")}</details></div>`;
      panel.innerHTML = body;
      panel.querySelector("#new-report").onclick = () => loadForm(true);
      if (focusHeading) panel.querySelector("h2")?.focus();
    }
    async function loadForm(focusHeading = options.focusHeading !== false) {
      const token = ++generation;
      panel.innerHTML = '<p role="status">Loading report inputs…</p>';
      try {
        const stores = await api("/api/stores", controller.signal);
        if (!alive(token)) return;
        const now = new Date(); now.setMinutes(now.getMinutes() - now.getTimezoneOffset());
        panel.innerHTML = `<div class="reports-view"><h2 tabindex="-1">Generate a weekly report</h2><p>Build a saved local report from recorded evidence. Choose stores, channel and the latest observation time to include.</p>
          <form id="report-form" class="form"><div class="field"><label for="report-cutoff">Observation cutoff (your local time)</label><input id="report-cutoff" type="datetime-local" required value="${now.toISOString().slice(0,16)}"></div>
          <div class="field"><label for="report-channel">Price channel</label><select id="report-channel"><option value="in_store">Shelf</option><option value="pickup">Pickup</option></select></div>
          <fieldset><legend>Planned stores</legend>${stores.map(store => `<label class="check"><input type="checkbox" name="report-store" value="${esc(store.id)}" checked> ${esc(store.name)}</label>`).join("")}</fieldset>
          <label class="check"><input id="report-needed" type="checkbox" checked> Needed staples only</label>
          <p id="report-error" role="alert" tabindex="-1" hidden></p><button class="button" type="submit">Generate saved report</button></form></div>`;
        const form = panel.querySelector("#report-form");
        form.onsubmit = async event => {
          event.preventDefault();
          const error = panel.querySelector("#report-error"), submit = form.querySelector("button");
          error.hidden = true;
          const stores = [...form.querySelectorAll('[name="report-store"]:checked')].map(input => input.value);
          if (!stores.length) { error.textContent = "Select at least one planned store."; error.hidden = false; error.focus(); return; }
          submit.disabled = true;
          try {
            const report = await api("/api/reports", controller.signal, {
              as_of:new Date(panel.querySelector("#report-cutoff").value).toISOString(), stores,
              channel:panel.querySelector("#report-channel").value, needed_only:panel.querySelector("#report-needed").checked});
            if (alive(token)) show(report);
          } catch (err) {
            if (!alive(token)) return;
            submit.disabled = false; error.textContent = err.message; error.hidden = false; error.focus();
          }
        };
        if (focusHeading) panel.querySelector("h2")?.focus();
      } catch (error) { if (alive(token)) fail(error, loadForm); }
    }
    function fail(error, retry) {
      panel.innerHTML = `<div class="reports-view"><h2 tabindex="-1">Report unavailable</h2><p role="alert">${esc(error.message)}</p><button class="button" type="button">Retry</button></div>`;
      panel.querySelector("button").onclick = retry;
    }
    async function loadSaved() {
      const token = ++generation;
      panel.innerHTML = '<p role="status">Loading saved report…</p>';
      try {
        const report = await api(`/api/reports/${encodeURIComponent(options.reportID)}`,controller.signal);
        if (alive(token)) show(report, options.focusHeading !== false);
      } catch (error) { if (alive(token)) fail(error, loadSaved); }
    }
    if (options.reportID) loadSaved(); else loadForm();
    return () => { ++generation; controller.abort(); };
  }
  window.StapleReports = {mount};
})();
