(() => {
  "use strict";
  const panel = document.querySelector("#panel"),
    status = document.querySelector("#status"),
    errors = document.querySelector("#error-region");
  let disposeView = null;
  const state = {
    tab: ["staples", "stores", "price", "matches", "compare", "shopping"].includes(location.hash.slice(1))
      ? location.hash.slice(1) : "staples",
    staples: [],
    stores: [],
    token: 0,
    keepTabFocus: false,
  };
  const esc = (v) =>
    String(v ?? "").replace(
      /[&<>"']/g,
      (c) =>
        ({
          "&": "&amp;",
          "<": "&lt;",
          ">": "&gt;",
          '"': "&quot;",
          "'": "&#39;",
        })[c],
    );
  const api = async (url, opts = {}) => {
    const r = await fetch(url, {
      ...opts,
      headers: { "Content-Type": "application/json", ...(opts.headers || {}) },
    });
    let b;
    try {
      b = await r.json();
    } catch (_) {}
    if (!r.ok)
      throw Error(
        b?.detail?.[0]?.msg || b?.detail || `Request failed (${r.status})`,
      );
    return b;
  };
  const say = (text, kind = "") => {
    status.textContent = text;
    status.dataset.kind = kind;
  };
  const fail = (e) => {
    errors.textContent = e.message || e;
    errors.hidden = false;
    say("Action needs attention", "error");
    errors.focus();
  };
  const clear = () => {
    errors.hidden = true;
    errors.textContent = "";
  };
  const btn = (label, attrs = "", cls = "button") => {
    const submit = /^id="save(?:-price)?"$/.test(attrs);
    return `<button type="${submit ? "submit" : "button"}" class="${cls}" ${attrs}>${esc(label)}</button>`;
  };
  const focusHeading = () => {
    if (!state.keepTabFocus) panel.querySelector("h2")?.focus();
  };
  const human = (value) =>
    ({
      in_store: "Shelf (in store)",
      pickup: "Pickup",
      online: "Online reference",
      user_reported: "Chosen location",
      tentative: "Tentative location",
      unconfigured: "Choose a location",
      not_connected: "Not connected",
    })[value] || value;
  const now = () => {
    const d = new Date();
    d.setMinutes(d.getMinutes() - d.getTimezoneOffset());
    return d.toISOString().slice(0, 16);
  };
  async function load(message = "Ready") {
    disposeView?.();
    disposeView = null;
    const token = ++state.token;
    clear();
    panel.innerHTML = '<div class="loading">Loading your setup…</div>';
    try {
      const [staples, stores] = await Promise.all([
        api("/api/staples"),
        api("/api/stores"),
      ]);
      if (token !== state.token) return;
      state.staples = staples;
      state.stores = stores;
      say(message, message === "Ready" ? "" : "success");
      render();
    } catch (e) {
      if (token !== state.token) return;
      say("Could not load", "error");
      panel.innerHTML = `<div class="empty error"><h2>We couldn’t load setup</h2><p>${esc(e.message)}</p>${btn("Retry", 'id="retry"')}</div>`;
      panel.querySelector("#retry").onclick = () => load();
    }
  }
  function render() {
    document.querySelectorAll(".tab").forEach((t) => {
      t.classList.toggle("active", t.dataset.tab === state.tab);
      t.setAttribute("aria-selected", t.dataset.tab === state.tab);
      t.tabIndex = t.dataset.tab === state.tab ? 0 : -1;
      panel.setAttribute("aria-labelledby", `tab-${state.tab}`);
    });
    document.querySelector(".tab.active")?.scrollIntoView({block: "nearest", inline: "nearest"});
    ({
      staples: staplesView,
      stores: storesView,
      price: priceView,
      matches: matchesView,
      compare: () => comparisonsView(false),
      shopping: () => comparisonsView(true),
    })[state.tab]();
  }
  function comparisonsView(shopping) {
    ++state.token;
    clear();
    disposeView = window.StapleComparisons.mount(panel, {
      shopping, focusHeading: !state.keepTabFocus,
    });
  }
  function staplesView() {
    ++state.token;
    clear();
    panel.innerHTML = `<div class="section-head"><div><h2 tabindex="-1">My staples</h2><p class="lede">Define acceptable products, then record price evidence as you shop.</p></div>${btn("Add staple", 'id="add"')}</div>${state.staples.length ? `<div class="list">${state.staples.map((s) => `<article class="row"><div><h3>${esc(s.name)}</h3><p class="meta">${esc(s.basis)} · ${s.needed ? "Needed this week" : "Not needed this week"}${s.desired_quantity ? ` · Request ${esc(s.desired_quantity)} ${esc(s.desired_unit)}` : ""}</p>${s.rules ? `<p class="rules">${esc(s.rules)}</p>` : ""}</div><div class="row-actions">${btn("Edit", `data-edit="${s.id}"`, "button secondary small")}${btn("Delete", `data-delete="${s.id}"`, "button danger small")}</div></article>`).join("")}</div>` : '<div class="empty"><h3>No staples yet</h3><p>Add the groceries you buy regularly.</p></div>'}`;
    panel.querySelector("#add").onclick = () => stapleForm();
    panel
      .querySelectorAll("[data-edit]")
      .forEach(
        (b) =>
          (b.onclick = () =>
            stapleForm(
              state.staples.find((s) => String(s.id) === b.dataset.edit),
            )),
      );
    panel
      .querySelectorAll("[data-delete]")
      .forEach((b) => (b.onclick = () => deleteStaple(b.dataset.delete)));
    focusHeading();
  }
  function stapleForm(s = {}) {
    const formToken = ++state.token;
    state.keepTabFocus = false;
    clear();
    const edit = !!s.id;
    panel.innerHTML = `<div class="section-head"><div><h2 tabindex="-1">${edit ? "Edit staple" : "Add staple"}</h2><p class="lede">Changing name, unit, or rules requires product matches to be reviewed again.</p></div></div><form id="staple-form" class="form"><div class="grid"><div class="field full"><label for="name">Name</label><input id="name" required maxlength="200" value="${esc(s.name)}"></div><div class="field"><label for="basis">Comparison unit</label><select id="basis"><option value="oz">Weight (oz)</option><option value="fl_oz">Volume (fl oz)</option><option value="each">Count (each)</option></select></div><div class="field"><label for="needed">Weekly need</label><select id="needed"><option value="true">Needed</option><option value="false">Not needed</option></select></div><div class="field"><label for="desired">Requested amount <span class="hint">optional</span></label><input id="desired" inputmode="decimal" value="${esc(s.desired_quantity)}"></div><div class="field"><label for="desired-unit">Requested unit</label><select id="desired-unit"><option value="">Choose a unit</option><option>oz</option><option>lb</option><option>g</option><option>kg</option><option>fl_oz</option><option>ml</option><option>l</option><option>each</option></select></div><div class="field full"><label for="rules">Acceptable product rules</label><textarea id="rules" maxlength="2000">${esc(s.rules)}</textarea></div></div><div class="actions">${btn("Cancel", 'id="cancel"', "button secondary")}${btn(edit ? "Save changes" : "Add staple", 'id="save"')}</div></form>`;
    document.querySelector("#basis").value = s.basis || "oz";
    document.querySelector("#needed").value =
      s.needed === false ? "false" : "true";
    document.querySelector("#desired-unit").value = s.desired_unit || "";
    document.querySelector("#cancel").onclick = staplesView;
    document.querySelector("#staple-form").onsubmit = async (e) => {
      e.preventDefault();
      clear();
      const q = document.querySelector("#desired").value.trim(),
        u = document.querySelector("#desired-unit").value,
        body = {
          name: document.querySelector("#name").value,
          basis: document.querySelector("#basis").value,
          rules: document.querySelector("#rules").value,
          needed: document.querySelector("#needed").value === "true",
          desired_quantity: q || null,
          desired_unit: u || null,
        };
      const save = document.querySelector("#save");
      save.disabled = true;
      try {
        await api(edit ? `/api/staples/${s.id}` : "/api/staples", {
          method: edit ? "PATCH" : "POST",
          body: JSON.stringify(body),
        });
        if (formToken !== state.token) return;
        await load(edit ? "Staple updated" : "Staple added");
      } catch (err) {
        if (formToken === state.token) {
          save.disabled = false;
          fail(err);
        }
      }
    };
    focusHeading();
  }
  async function deleteStaple(id) {
    const token = state.token;
    const s = state.staples.find((x) => String(x.id) === String(id));
    if (!s) return;
    const dialog = document.createElement("dialog");
    dialog.className = "delete-confirm";
    dialog.setAttribute("aria-labelledby", "delete-title");
    dialog.setAttribute("aria-describedby", "delete-description");
    dialog.innerHTML = `<form method="dialog"><h2 id="delete-title">Delete ${esc(s.name)}?</h2><p id="delete-description">This permanently removes this staple, its price history, and its product reviews.</p><div class="actions"><button class="button secondary" value="cancel" autofocus>Cancel</button><button class="button danger" value="delete">Delete staple</button></div></form>`;
    document.body.append(dialog);
    const confirmed = await new Promise((resolve) => {
      dialog.addEventListener(
        "close",
        () => resolve(dialog.returnValue === "delete"),
        { once: true },
      );
      dialog.showModal();
    });
    dialog.remove();
    if (!confirmed || token !== state.token) return;
    try {
      await api(`/api/staples/${id}`, { method: "DELETE" });
      if (token !== state.token) return;
      await load("Staple deleted");
    } catch (e) {
      if (token === state.token) fail(e);
    }
  }
  function storesView() {
    ++state.token;
    clear();
    panel.innerHTML = `<div class="section-head"><div><h2 tabindex="-1">Stores and locations</h2><p class="lede">Choose the location you shop at. Past prices stay linked to where you recorded them.</p></div></div><div class="list">${state.stores.map((s) => `<article class="row"><div><h3>${esc(s.name)}</h3><p class="meta">${esc(s.location)} · ${esc(human(s.channel))} · ${esc(human(s.location_status))}</p><p class="meta">${s.location_configured ? "Configured location" : "Unconfigured; cannot win comparisons"} · Price source ${esc(human(s.source_status))}</p></div>${btn("Configure", `data-store="${esc(s.id)}"`, "button secondary small")}</article>`).join("")}</div>`;
    panel
      .querySelectorAll("[data-store]")
      .forEach(
        (b) =>
          (b.onclick = () =>
            storeForm(state.stores.find((s) => s.id === b.dataset.store))),
      );
    focusHeading();
  }
  async function storeForm(s) {
    const formToken = ++state.token;
    state.keepTabFocus = false;
    clear();
    panel.innerHTML = '<div class="loading">Loading location choices…</div>';
    let contexts;
    try {
      contexts = await api(`/api/stores/${s.id}/contexts`);
      if (formToken !== state.token) return;
    } catch (e) {
      if (formToken === state.token) fail(e);
      return;
    }
    panel.innerHTML = `<div class="section-head"><div><h2 tabindex="-1">Configure ${esc(s.name)}</h2><p class="lede">Select a saved location or add another. This does not connect or verify a price source.</p></div></div><form id="store-form" class="form"><div class="field"><label for="context">Saved location</label><select id="context"><option value="new">Add another location</option>${contexts.map((c) => `<option value="${c.id}">${esc(c.location)} · ${esc(human(c.channel))}${c.is_current_context ? " (current)" : ""}</option>`).join("")}</select></div><div id="new-context"><div class="field"><label for="location">Location label</label><input id="location" required maxlength="200" value="${esc(s.location === "Unselected" ? "" : s.location)}"></div><div class="grid"><div class="field"><label for="location-id">Retailer location ID <span class="hint">optional</span></label><input id="location-id" value="${esc(s.location_id || "")}"></div><div class="field"><label for="channel">Preferred channel</label><select id="channel"><option value="in_store">Shelf (in store)</option><option value="pickup">Pickup</option><option value="online">Online reference</option></select></div></div></div><div class="actions">${btn("Cancel", 'id="cancel"', "button secondary")}${btn("Save location", 'id="save"')}</div></form>`;
    document.querySelector("#channel").value = s.channel || "in_store";
    document.querySelector("#context").onchange = (e) => {
      const existing = e.target.value !== "new";
      document.querySelector("#new-context").hidden = existing;
      document
        .querySelectorAll("#new-context input, #new-context select")
        .forEach((field) => {
          field.disabled = existing;
        });
    };
    document.querySelector("#context").value = String(s.preferred_context_id);
    document
      .querySelector("#context")
      .onchange({ target: document.querySelector("#context") });
    document.querySelector("#cancel").onclick = storesView;
    document.querySelector("#store-form").onsubmit = async (e) => {
      e.preventDefault();
      clear();
      const save = document.querySelector("#save");
      save.disabled = true;
      const context = document.querySelector("#context").value,
        body =
          context === "new"
            ? {
                context: {
                  location: document.querySelector("#location").value,
                  location_id:
                    document.querySelector("#location-id").value || null,
                  channel: document.querySelector("#channel").value,
                  location_status: "user_reported",
                },
              }
            : { context_id: Number(context) };
      try {
        await api(`/api/stores/${s.id}`, {
          method: "PATCH",
          body: JSON.stringify(body),
        });
        if (formToken !== state.token) return;
        await load("Store location saved");
      } catch (err) {
        if (formToken === state.token) {
          save.disabled = false;
          fail(err);
        }
      }
    };
    focusHeading();
  }
  function priceView() {
    ++state.token;
    clear();
    panel.innerHTML = `<div class="section-head"><div><h2 tabindex="-1">Record a price</h2><p class="lede">Enter total purchase price, quantity per pack, pack count, channel, and the time you saw it.</p></div></div>${state.staples.length ? `<form id="price-form" class="form"><div class="grid"><div class="field full"><label for="staple">Staple</label><select id="staple">${state.staples.map((s) => `<option value="${s.id}">${esc(s.name)} · ${esc(s.rules || "no extra rules")}</option>`).join("")}</select></div><div class="field full"><label for="store">Store</label><select id="store">${state.stores.map((s) => `<option value="${s.id}">${esc(s.name)} · ${esc(s.location)}</option>`).join("")}</select></div><div class="field full"><label for="context-id">Observed location</label><select id="context-id"><option value="">Loading contexts…</option></select><span class="hint">This price stays linked to the selected location.</span></div><div class="field full"><label for="product">Product name</label><input id="product" required></div><div class="field"><label for="price">Total purchase price</label><input id="price" required inputmode="decimal"></div><div class="field"><label for="quantity">Quantity per pack</label><input id="quantity" required inputmode="decimal"></div><div class="field"><label for="unit">Package unit</label><select id="unit"><option>oz</option><option>lb</option><option>g</option><option>kg</option><option>fl_oz</option><option>ml</option><option>l</option><option>each</option></select></div><div class="field"><label for="pack-count">Pack count</label><input id="pack-count" type="number" min="1" value="1"><span class="hint">A 2 × 16 oz pack means quantity 16 and pack count 2.</span></div><div class="field"><label for="channel">Channel</label><select id="channel"><option value="in_store">Shelf (in store)</option><option value="pickup">Pickup</option><option value="online">Online reference</option></select></div><div class="field"><label for="observed">Observed at</label><input id="observed" type="datetime-local" required value="${now()}"></div><div class="field full"><label for="variant">Existing product variant <span class="hint">optional</span></label><select id="variant"><option value="">New manual product identity</option></select><span class="hint">Choose an existing product to keep its package details and review. A different size needs a new product entry.</span></div><div class="field"><label for="url">Source URL <span class="hint">optional</span></label><input id="url" type="url"></div><div class="field"><label for="conditions">Conditions <span class="hint">optional</span></label><input id="conditions"></div><label class="check"><input id="available" type="checkbox" checked> In stock</label><label class="check"><input id="approved" type="checkbox"> Approve new manual product</label></div><div class="actions">${btn("Save price", 'id="save-price"')}</div></form>` : '<div class="empty"><h3>Add a staple first</h3><p>Price evidence needs a staple to compare against.</p></div>'}`;
    if (!state.staples.length) return;
    const variant = document.querySelector("#variant"),
      store = document.querySelector("#store"),
      context = document.querySelector("#context-id");
    let variantRows = [],
      contextsReady = false,
      variantsReady = false,
      storeRequest = 0,
      saving = false;
    const viewToken = state.token;
    const updateSave = () => {
      if (viewToken === state.token)
        document.querySelector("#save-price").disabled =
          saving || !contextsReady || !variantsReady;
    };
    const currentRequest = (request, selectedStore) =>
      request === storeRequest &&
      selectedStore === store.value &&
      viewToken === state.token;
    const loadContexts = async () => {
      const request = ++storeRequest,
        selectedStore = store.value;
      contextsReady = false;
      context.disabled = true;
      updateSave();
      try {
        const rows = await api(`/api/stores/${store.value}/contexts`);
        if (
          request !== storeRequest ||
          selectedStore !== store.value ||
          viewToken !== state.token
        )
          return;
        contextsReady = true;
        context.disabled = false;
        context.innerHTML = rows
          .map(
            (c) =>
              `<option value="${c.id}"${c.is_current_context ? " selected" : ""}>${esc(c.location)} · ${esc(human(c.channel))} · ${esc(human(c.location_status))}${c.is_current_context ? " (current)" : ""}</option>`,
          )
          .join("");
        updateSave();
      } catch (e) {
        if (!currentRequest(request, selectedStore)) return;
        contextsReady = false;
        context.innerHTML =
          '<option value="">Could not load contexts; reselect store to retry</option>';
        updateSave();
        fail(e);
      }
    };
    const loadVariants = async () => {
      const request = storeRequest,
        selectedStore = store.value;
      variantsReady = false;
      variant.disabled = true;
      updateSave();
      try {
        const rows = await api(
          `/api/variants?retailer=${encodeURIComponent(store.value)}`,
        );
        if (
          request !== storeRequest ||
          selectedStore !== store.value ||
          viewToken !== state.token
        )
          return;
        variantRows = rows;
        variantsReady = true;
        variant.disabled = false;
        variant.innerHTML =
          '<option value="">New manual product identity</option>' +
          rows
            .map(
              (v) =>
                `<option value="${v.id}">${esc(v.form || v.manual_identity || v.retailer_product_id || "Manual product")} · ${esc(v.package_quantity)} ${esc(v.package_unit)} × ${v.pack_count}</option>`,
            )
            .join("");
        variant.onchange();
        updateSave();
      } catch (e) {
        if (!currentRequest(request, selectedStore)) return;
        variantsReady = false;
        updateSave();
        fail(e);
      }
    };
    variant.onchange = () => {
      const row = variantRows.find((item) => String(item.id) === variant.value);
      const reused = Boolean(row);
      ["quantity", "unit", "pack-count"].forEach((id) => {
        const field = document.querySelector(`#${id}`);
        if (row) {
          field.value =
            id === "quantity"
              ? row.package_quantity
              : id === "unit"
                ? row.package_unit
                : row.pack_count;
          field.disabled = true;
        } else field.disabled = false;
      });
      const approval = document.querySelector("#approved");
      approval.checked = false;
      approval.disabled = reused;
    };
    store.onchange = () => {
      clear();
      variant.value = "";
      variant.onchange();
      loadContexts();
      loadVariants();
    };
    loadContexts();
    loadVariants();
    document.querySelector("#price-form").onsubmit = async (e) => {
      e.preventDefault();
      const formToken = viewToken;
      clear();
      if (!contextsReady || !variantsReady) {
        fail(
          new Error(
            "Wait for store contexts and product choices to finish loading.",
          ),
        );
        return;
      }
      const v = (id) => document.querySelector(`#${id}`).value,
        save = document.querySelector("#save-price");
      saving = true;
      updateSave();
      const body = {
        staple_id: Number(v("staple")),
        store_id: v("store"),
        context_id: Number(v("context-id")),
        product_name: v("product"),
        price: v("price"),
        quantity: v("quantity"),
        unit: v("unit"),
        pack_count: Number(v("pack-count")),
        channel: v("channel"),
        observed_at: new Date(v("observed")).toISOString(),
        source_url: v("url") || null,
        conditions: v("conditions"),
        available: document.querySelector("#available").checked,
        approved: document.querySelector("#approved").checked,
      };
      if (variant.value) body.variant_id = Number(variant.value);
      try {
        await api("/api/observations", {
          method: "POST",
          body: JSON.stringify(body),
        });
        if (formToken !== state.token) return;
        say("Price recorded", "success");
        saving = false;
        const selectedContext = context.value;
        const selectedStore = store.value;
        const selectedStaple = v("staple");
        e.target.reset();
        store.value = selectedStore;
        document.querySelector("#staple").value = selectedStaple;
        document.querySelector("#observed").value = now();
        context.value = selectedContext;
        await loadVariants();
        if (formToken === state.token)
          document.querySelector("#product")?.focus();
      } catch (err) {
        if (formToken === state.token) {
          saving = false;
          updateSave();
          fail(err);
        }
      }
    };
    focusHeading();
  }
  async function matchesView() {
    const token = ++state.token;
    clear();
    panel.innerHTML = '<div class="loading">Loading product matches…</div>';
    try {
      const groups = await Promise.all(
        state.staples.map(async (s) =>
          (await api(`/api/staples/${s.id}/matches`)).map((m) => ({
            ...m,
            staple: s,
          })),
        ),
      );
      if (token !== state.token) return;
      const matches = groups.flat();
      panel.innerHTML = `<div class="section-head"><div><h2 tabindex="-1">Review product matches</h2><p class="lede">Approve only when the product meets this staple’s rules. Package and form changes require a new review.</p></div></div>${matches.length ? `<div class="list">${matches.map((m) => `<article class="row"><div><h3>${esc(m.form || m.retailer_product_id || "Manual product")}</h3><p class="meta">${esc(m.staple.name)} · ${esc(m.retailer)} · ${esc(m.package_quantity)} ${esc(m.package_unit)} × ${m.pack_count} · ${esc(m.form || "form not specified")}</p><p class="meta">${m.barcode ? `Barcode ${esc(m.barcode)} · ` : ""}Current review: <strong>${esc(m.status)}</strong></p><p class="rules">Rules: ${esc(m.staple.rules || "No extra rules")}</p></div><div class="row-actions">${btn("Approve", `data-review="approved" data-staple="${m.staple.id}" data-variant="${m.variant_id}"`, "button secondary small")}${btn("Reject", `data-review="rejected" data-staple="${m.staple.id}" data-variant="${m.variant_id}"`, "button danger small")}</div></article>`).join("")}</div>` : '<div class="empty"><h3>No product matches yet</h3><p>Record a price, then review the resulting product here.</p></div>'}`;
      panel.querySelectorAll("[data-review]").forEach(
        (b) =>
          (b.onclick = async () => {
            b.closest(".row-actions")
              .querySelectorAll("button")
              .forEach((button) => {
                button.disabled = true;
              });
            clear();
            try {
              await api(
                `/api/staples/${b.dataset.staple}/matches/${b.dataset.variant}`,
                {
                  method: "PUT",
                  body: JSON.stringify({ status: b.dataset.review }),
                },
              );
              if (token !== state.token) return;
              say(`Match ${b.dataset.review}`, "success");
              await matchesView();
            } catch (e) {
              if (token !== state.token) return;
              b.closest(".row-actions")
                .querySelectorAll("button")
                .forEach((button) => {
                  button.disabled = false;
                });
              fail(e);
            }
          }),
      );
      focusHeading();
    } catch (e) {
      if (token !== state.token) return;
      fail(e);
      panel.innerHTML = `<div class="empty error"><h2>Couldn’t load matches</h2><p>${esc(e.message)}</p>${btn("Retry", 'id="retry"')}</div>`;
      panel.querySelector("#retry").onclick = matchesView;
    }
  }
  document.querySelectorAll(".tab").forEach(
    (t) =>
      (t.onclick = () => {
        state.keepTabFocus = false;
        state.token += 1;
        state.tab = t.dataset.tab;
        history.replaceState(null, "", `#${state.tab}`);
        load();
      }),
  );
  document.querySelectorAll(".tab").forEach((tab, index, tabs) => {
    tab.id = `tab-${tab.dataset.tab}`;
    tab.setAttribute("aria-controls", "panel");
    tab.onkeydown = (event) => {
      const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
      if (!step && !["Home", "End"].includes(event.key)) return;
      event.preventDefault();
      const next =
        event.key === "Home"
          ? 0
          : event.key === "End"
            ? tabs.length - 1
            : (index + step + tabs.length) % tabs.length;
      tabs[next].click();
      state.keepTabFocus = true;
      tabs[next].focus();
    };
  });
  load();
})();
