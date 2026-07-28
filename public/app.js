const defaults = {
  requests: 1200,
  async_hops: 5,
  isolate_hops: 2,
  message_hops: 3,
  fanout: 3,
  background_task_percent: 20,
  retry_percent: 12,
  failure_percent: 8,
  baggage_fields: 6,
};

const percentFields = new Set([
  "background_task_percent",
  "retry_percent",
  "failure_percent",
]);

const form = document.querySelector("#controls");
const reset = document.querySelector("#reset");
const tabs = document.querySelector("#strategy-tabs");
let strategies = [];
let selectedPolicy = "ambient_global";
let requestSequence = 0;

function formatInteger(value) {
  return new Intl.NumberFormat("en-US").format(value);
}

function formatBytes(value) {
  if (value === 0) return "0 B";
  if (value < 1000) return `${value} B`;
  if (value < 1000000) return `${(value / 1000).toFixed(1)} KB`;
  return `${(value / 1000000).toFixed(2)} MB`;
}

function updateOutputs() {
  for (const input of form.querySelectorAll("input")) {
    const output = document.querySelector(`#${input.id}-value`);
    const suffix = percentFields.has(input.name) ? "%" : "";
    output.textContent = `${formatInteger(Number(input.value))}${suffix}`;
  }
}

function queryString() {
  const params = new URLSearchParams();
  for (const input of form.querySelectorAll("input")) {
    params.set(input.name, input.value);
  }
  return params.toString();
}

function renderTabs() {
  tabs.replaceChildren(
    ...strategies.map((strategy, index) => {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "strategy-tab";
      button.role = "tab";
      button.dataset.policy = strategy.policy;
      button.setAttribute("aria-selected", String(strategy.policy === selectedPolicy));
      button.textContent = `${String(index + 1).padStart(2, "0")} / ${strategy.name}`;
      button.addEventListener("click", () => {
        selectedPolicy = strategy.policy;
        render();
      });
      return button;
    }),
  );
}

function renderStageChart(strategy) {
  const chart = document.querySelector("#stage-chart");
  chart.replaceChildren(
    ...strategy.stages.map((stage) => {
      const column = document.createElement("div");
      column.className = "stage-column";
      column.title = `${stage.stage}: ${stage.completenessPercent}% correctly joined`;

      const bar = document.createElement("div");
      bar.className = "stage-bar";
      const total = Math.max(stage.expectedSpans, 1);
      for (const [state, value] of [
        ["joined", stage.correctSpans],
        ["orphan", stage.orphanSpans],
        ["wrong", stage.wrongParentSpans],
      ]) {
        const segment = document.createElement("div");
        segment.className = `stage-segment ${state}`;
        segment.style.height = `${(value / total) * 100}%`;
        segment.title = `${state}: ${formatInteger(value)}`;
        bar.append(segment);
      }

      const label = document.createElement("span");
      label.className = "stage-label";
      label.textContent = stage.stage;
      column.append(bar, label);
      return column;
    }),
  );
}

function renderLedger(strategy) {
  const ledger = document.querySelector("#event-ledger");
  ledger.replaceChildren(
    ...strategy.events.map((event) => {
      const row = document.createElement("tr");
      row.dataset.state = event.contextState;
      const values = [
        event.sequence,
        event.service,
        event.boundary,
        event.traceId,
        event.parentSpanId,
        event.contextSource,
      ];
      for (const value of values) {
        const cell = document.createElement("td");
        cell.textContent = value;
        row.append(cell);
      }
      const state = document.createElement("td");
      const pill = document.createElement("span");
      pill.className = "state-pill";
      pill.textContent = event.contextState;
      state.append(pill);
      row.append(state);
      return row;
    }),
  );
  document.querySelector("#ledger-policy").textContent =
    `sample request · ${strategy.name}`;
}

function renderComparison() {
  const grid = document.querySelector("#comparison-grid");
  grid.replaceChildren(
    ...strategies.map((strategy, index) => {
      const metrics = strategy.metrics;
      const card = document.createElement("article");
      card.className = `comparison-card${strategy.recommended ? " is-recommended" : ""}`;
      card.innerHTML = `
        <span class="comparison-index">${String(index + 1).padStart(2, "0")}</span>
        <h3></h3>
        <p class="comparison-semantics"></p>
        <div class="comparison-score">
          <strong>${metrics.traceCompletenessPercent.toFixed(1)}%</strong>
          <span>trace completeness</span>
        </div>
        <div class="comparison-stat"><span>complete traces</span><b>${metrics.completeTracesPercent.toFixed(1)}%</b></div>
        <div class="comparison-stat"><span>wrong parents</span><b>${formatInteger(metrics.wrongParentSpans)}</b></div>
        <div class="comparison-stat"><span>carrier writes</span><b>${formatInteger(metrics.carrierWrites)}</b></div>
        <div class="comparison-stat"><span>encoded</span><b>${formatBytes(metrics.carrierBytes)}</b></div>
      `;
      card.querySelector("h3").textContent = strategy.name;
      card.querySelector(".comparison-semantics").textContent = strategy.semantics;
      return card;
    }),
  );
}

function render() {
  if (strategies.length === 0) return;
  const strategy =
    strategies.find((candidate) => candidate.policy === selectedPolicy) ?? strategies[0];
  selectedPolicy = strategy.policy;
  const metrics = strategy.metrics;

  renderTabs();
  document.querySelector("#strategy-kicker").textContent = strategy.kicker;
  document.querySelector("#strategy-name").textContent = strategy.name;
  document.querySelector("#strategy-description").textContent =
    `${strategy.description} ${strategy.tradeoff}`;
  document.querySelector("#recommended").hidden = !strategy.recommended;
  document.querySelector("#trace-completeness").textContent =
    `${metrics.traceCompletenessPercent.toFixed(1)}%`;
  document.querySelector("#complete-traces").textContent =
    `${metrics.completeTracesPercent.toFixed(1)}%`;
  document.querySelector("#fragment-multiplier").textContent =
    `${metrics.fragmentMultiplier.toFixed(1)}×`;
  document.querySelector("#diagnosable-failures").textContent =
    `${metrics.diagnosableFailuresPercent.toFixed(1)}%`;
  document.querySelector("#carrier-writes").textContent =
    formatInteger(metrics.carrierWrites);
  document.querySelector("#carrier-bytes").textContent = formatBytes(metrics.carrierBytes);
  document.querySelector("#context-operations").textContent =
    formatInteger(metrics.contextOperations);
  document.querySelector("#request-success").textContent =
    `${((metrics.successfulRequests / metrics.requests) * 100).toFixed(1)}%`;

  renderStageChart(strategy);
  renderComparison();
  renderLedger(strategy);
}

async function refresh() {
  const sequence = ++requestSequence;
  try {
    const response = await fetch(`/api/simulate?${queryString()}`, {
      headers: { Accept: "application/json" },
    });
    if (!response.ok) throw new Error(`model returned ${response.status}`);
    const model = await response.json();
    if (sequence !== requestSequence) return;
    strategies = model.strategies;
    render();
  } catch (error) {
    if (sequence !== requestSequence) return;
    document.querySelector("#strategy-name").textContent = "Model unavailable";
    document.querySelector("#strategy-description").textContent =
      error instanceof Error ? error.message : String(error);
  }
}

let refreshTimer;
form.addEventListener("input", () => {
  updateOutputs();
  window.clearTimeout(refreshTimer);
  refreshTimer = window.setTimeout(refresh, 80);
});

reset.addEventListener("click", () => {
  for (const [name, value] of Object.entries(defaults)) {
    form.elements.namedItem(name).value = value;
  }
  selectedPolicy = "ambient_global";
  updateOutputs();
  refresh();
});

updateOutputs();
refresh();
