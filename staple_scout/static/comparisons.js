(() => {
  "use strict";
  const esc = (value) => String(value ?? "").replace(/[&<>"']/g, c =>
    ({"&":"&amp;", "<":"&lt;", ">":"&gt;", '"':"&quot;", "'":"&#39;"})[c]);
  const money = value => value == null ? "Unknown" : `$${esc(value)}`;
  const date = value => value ? esc(new Date(value).toLocaleString()) : "Never";
  const human = value => ({in_store: "Shelf", pickup: "Pickup", online: "Online reference"})[value]
    || String(value || "").replaceAll("_", " ");
  async function get(url, signal) {
    const response = await fetch(url, {signal, headers: {Accept: "application/json"}});
    if (!response.ok) throw Error(`Local data request failed (${response.status})`);
    return response.json();
  }
  function mount(panel, options = {}) {
    const shopping = options.shopping === true;
    const controller = new AbortController();
    let generation = 0;
    let selectedStores = null;
    let initialFocus = options.focusHeading !== false;
    let state = {channel: "in_store", needed: shopping, staples: [], stores: [],
      sources: [], statuses: [], matches: {}, comparisons: []};
    const active = token => token === generation && !controller.signal.aborted;
    function render(html, focusID) {
      if (controller.signal.aborted) return;
      panel.innerHTML = html;
      panel.removeAttribute("aria-busy");
      wire();
      if (focusID) panel.querySelector(`#${focusID}`)?.focus();
      else if (initialFocus) { panel.querySelector("h2")?.focus(); initialFocus = false; }
    }
    async function load() {
      const token = ++generation;
      panel.setAttribute("aria-busy", "true");
      panel.innerHTML = '<div class="comparisons-loading" role="status">Loading your comparisons…</div>';
      try {
        const [staples, stores, sources] = await Promise.all([
          get("/api/staples", controller.signal), get("/api/stores", controller.signal),
          get("/api/sources", controller.signal)]);
        const matchLists = await Promise.all(staples.slice(0, 50).map(async staple =>
          [staple.id, await get(`/api/staples/${staple.id}/matches`, controller.signal)]));
        if (!active(token)) return;
        state = {...state, staples, stores, sources, matches: Object.fromEntries(matchLists)};
        if (selectedStores === null) selectedStores = new Set(stores.map(store => store.id));
        await refresh(token);
      } catch (error) {
        if (active(token)) render(`<div class="comparisons-error" role="alert"><h2 tabindex="-1">Couldn’t load comparisons</h2><p>${esc(error.message)}</p><button type="button" data-retry>Retry</button></div>`);
      }
    }
    async function refresh(token = ++generation, focusID) {
      if (!active(token)) return;
      if (!selectedStores.size) {
        render(shell('<div class="comparisons-empty"><h3>Select a planned store</h3><p>Choose at least one store above to compare prices.</p></div>'), focusID);
        return;
      }
      panel.setAttribute("aria-busy", "true");
      const results = panel.querySelector(".comparisons-results");
      if (results) results.innerHTML = '<p role="status">Updating comparisons…</p>';
      try {
        const query = new URLSearchParams({channel: state.channel,
          stores: [...selectedStores].sort().join(","), needed_only: String(state.needed)});
        const [comparisons, statuses] = await Promise.all([
          get(`/api/comparisons?${query}`, controller.signal),
          Promise.all(state.stores.filter(store => selectedStores.has(store.id)).map(store =>
            get(`/api/source-status?channel=${state.channel}&context_id=${store.preferred_context_id}`, controller.signal)
              .then(rows => rows.map(row => ({...row, context_id: store.preferred_context_id}))))).then(rows => rows.flat())]);
        if (!active(token)) return;
        state.comparisons = comparisons;
        state.statuses = statuses;
        render(shell(shopping ? shoppingContent() : comparisonContent()), focusID);
      } catch (error) {
        if (active(token)) render(shell(`<div class="comparisons-error" role="alert"><h2 tabindex="-1">Couldn’t update comparisons</h2><p>${esc(error.message)}</p><button type="button" data-refresh>Retry these filters</button></div>`), focusID);
      }
    }
    function sourceNotes() {
      return state.stores.filter(store => selectedStores.has(store.id)).map(store => {
        const sources = state.sources.filter(source => source.retailer === store.id);
        const relevant = sources.filter(source => source.validated && source.channels.includes(state.channel));
        const history = relevant.map(source => {
          const health = state.statuses.find(status => status.source_id === source.source_id && status.context_id === store.preferred_context_id);
          const sameContext = entry => entry?.context_id === store.preferred_context_id ? entry : null;
          const attempt = sameContext(health?.last_attempt), success = sameContext(health?.last_success), failure = sameContext(health?.last_failure);
          return `<p>${esc(source.source_id)} · last attempt ${date(attempt?.started_at)}${attempt ? ` (${esc(human(attempt.status))})` : ""} · last success ${date(success?.finished_at)} · last failure ${date(failure?.finished_at)}${failure ? ` (${esc(human(failure.error))})` : ""}</p>`;
        }).join("");
        const onlineOnly = sources.some(source => source.validated && source.channels.includes("online"));
        return `<div><strong>${esc(store.name)}</strong> · ${esc(store.location)} · ${relevant.length ? "Source connected for " + esc(human(state.channel)) : "Not connected for " + esc(human(state.channel))}. Manual observations can still qualify.${onlineOnly ? " Online reference catalog is separate; it cannot win these comparisons." : ""}${history}</div>`;
      }).join("");
    }
    function offer(item, winnerID, costWinnerID) {
      const reasons = (item.exclusion_reasons || []).map(human).join("; ");
      return `<article class="comparison-offer ${item.id === winnerID ? "is-winner" : ""}">
        <h4>${esc(item.product_name)}</h4>
        <p>${esc(item.quantity)} ${esc(item.unit)} per pack × ${esc(item.pack_count)} · package price ${money(item.price)}</p>
        <p>Unit price ${money(item.unit_price)} / ${esc(item.basis)} ${item.id === winnerID ? '<span class="comparison-badge">Lowest unit price</span>' : ""}</p>
        <p class="offer-meta">${esc(item.store_name)} · ${esc(item.store_location)} · ${esc(human(item.channel))} · observed ${date(item.observed_at)}</p>
        <p class="offer-note">${item.conditions ? `Conditions: ${esc(item.conditions)}` : "No conditions recorded."}${item.quantity_kind !== "fixed" ? ` Quantity is ${esc(human(item.quantity_kind))}; exact outlay is unsupported.` : ""}</p>
        ${item.packages_needed != null ? `<p class="offer-outlay">${esc(item.packages_needed)} whole packages · purchase cost ${money(item.purchase_cost)} · excess ${esc(item.excess_quantity)} ${esc(item.excess_unit)} ${item.id === costWinnerID ? '<span class="comparison-badge">Lowest package outlay</span>' : ""}</p>` : ""}
        ${!item.eligible ? `<p class="offer-exclusion">Excluded: ${esc(reasons)}</p>` : ""}
      </article>`;
    }
    function gap(group) {
      const matches = state.matches[group.staple.id];
      const relevant = matches?.filter(match => selectedStores.has(match.retailer));
      const explanation = !matches ? "Match status not loaded (first 50 staples only)."
        : !relevant.some(match => match.status === "approved") ? "No approved product match at your planned stores."
        : !group.offers.length ? "No observations at the current selected locations."
        : "No eligible price. Review the exclusions below.";
      return `<p class="comparison-gap">${esc(explanation)}</p>`;
    }
    function card(group, onlyWinner = false) {
      const offers = onlyWinner ? group.offers.filter(item => item.id === group.winner_id) : group.offers;
      return `<section class="comparison-card"><h3>${esc(group.staple.name)}</h3>
        ${group.staple.rules ? `<p class="offer-note">Product rules: ${esc(group.staple.rules)}</p>` : ""}
        ${group.staple.desired_quantity ? `<p class="comparison-request">Requested ${esc(group.staple.desired_quantity)} ${esc(group.staple.desired_unit)}. Unit price and whole-package outlay are separate choices.</p>` : ""}
        ${group.winner_id == null ? gap(group) : ""}
        ${offers.map(item => offer(item, group.winner_id, group.purchase_cost_winner_id)).join("")}
        ${group.staple.desired_quantity && group.purchase_cost_winner_id == null ? '<p class="comparison-gap">No eligible exact whole-package outlay.</p>' : ""}
      </section>`;
    }
    const empty = '<div class="comparisons-empty"><h3>No staples match these filters</h3><p>Add staples or turn off “Needed staples only.”</p></div>';
    function comparisonContent() {
      return state.comparisons.length ? state.comparisons.map(group => card(group)).join("") : empty;
    }
    function shoppingContent() {
      if (!state.comparisons.length) return empty;
      const groups = new Map();
      const gaps = [];
      for (const group of state.comparisons) {
        const winner = group.offers.find(item => item.id === group.winner_id && item.eligible);
        if (!winner) { gaps.push(group); continue; }
        if (!groups.has(winner.store_id)) groups.set(winner.store_id, []);
        groups.get(winner.store_id).push(group);
      }
      return [...groups].map(([storeID, items]) => `<section class="shopping-store"><h3 class="shopping-store-title">${esc(state.stores.find(store => store.id === storeID)?.name || storeID)}</h3><p>Lowest unit-price choices at this store. Package outlay may favor another offer; inspect Compare prices for all choices.</p>${items.map(group => card(group, true)).join("")}</section>`).join("")
        + (gaps.length ? `<section class="shopping-gaps"><h3>Coverage gaps (${gaps.length})</h3>${gaps.map(group => card(group)).join("")}</section>` : "");
    }
    function shell(body) {
      return `<div class="comparisons-view"><div class="comparisons-head"><h2 tabindex="-1">${shopping ? "This week’s shopping" : "Compare prices"}</h2><p>Recommendations use lowest unit price. Whole-package outlay appears separately when you request an amount.</p></div>
        <div class="comparisons-filters"><fieldset><legend>Price channel</legend>${["in_store", "pickup"].map(channel => `<label><input id="filter-${channel}" type="radio" name="comparison-channel" value="${channel}" ${state.channel === channel ? "checked" : ""}> ${esc(human(channel))}</label>`).join("")}</fieldset>
        <fieldset><legend>Stores you plan to visit</legend>${state.stores.map(store => `<label><input id="filter-${esc(store.id)}" type="checkbox" data-store-filter="${esc(store.id)}" ${selectedStores.has(store.id) ? "checked" : ""}> ${esc(store.name)}</label>`).join("")}</fieldset>
        <label class="comparison-needed"><input id="filter-needed" type="checkbox" data-needed ${state.needed ? "checked" : ""}> Needed staples only</label></div>
        <details class="comparisons-source-note"><summary>Price source status</summary>${sourceNotes()}</details>
        <div class="comparisons-results">${body}</div></div>`;
    }
    function wire() {
      panel.querySelectorAll("[data-store-filter]").forEach(input => input.onchange = () => {
        if (input.checked) selectedStores.add(input.dataset.storeFilter);
        else selectedStores.delete(input.dataset.storeFilter);
        refresh(++generation, input.id);
      });
      panel.querySelectorAll("[name=comparison-channel]").forEach(input => input.onchange = () => {
        state.channel = input.value; refresh(++generation, input.id);
      });
      panel.querySelector("[data-needed]")?.addEventListener("change", event => {
        state.needed = event.target.checked; refresh(++generation, event.target.id);
      });
      panel.querySelector("[data-retry]")?.addEventListener("click", load);
      panel.querySelector("[data-refresh]")?.addEventListener("click", () => refresh());
    }
    load();
    return () => { ++generation; controller.abort(); panel.removeAttribute("aria-busy"); };
  }
  window.StapleComparisons = {mount};
})();
