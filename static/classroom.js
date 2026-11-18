const $ = (selector, root = document) => root.querySelector(selector);
const models = ['openai', 'decision'];
const consistency = location.pathname === '/consistency';
const palette = ['#1654a3', '#6439a0', '#187653', '#a35409', '#ae2760', '#537600', '#526174', '#007985', '#704430', '#5a5099'];
const experiments = [
  {
    name: 'Admissions or IT?',
    texts: [
      "I can't log in to the admissions portal because my password reset link never arrives.",
      'My admissions account is inaccessible: the email to reset my password never turns up.',
      'I need help signing into the application portal; I am not receiving the password reset email.',
    ],
    changed: 'I can log in to the admissions portal now. Which supporting documents must I submit with my application?',
  },
  {
    name: 'Funding or wellbeing?',
    texts: [
      "I'm worried about paying my tuition fees. How do I apply for a hardship grant?",
      'Tuition costs are worrying me, and I want to know how to request hardship funding.',
      'Could you explain the hardship grant application process? I am concerned about affording my fees.',
    ],
    changed: 'I have funding to pay my tuition fees now, but I still feel overwhelmed and would like a counselling appointment.',
  },
  {
    name: 'Accommodation or timetable?',
    texts: [
      'My university room contract ends before my last exam. Can I extend my stay in halls?',
      'Can I stay in my university residence longer? My final exam is after my housing contract ends.',
      'I need to extend my halls tenancy to cover my last exam. How can I arrange that?',
    ],
    changed: 'My room contract now covers all my exams. Two of my exams are listed at the same time; can the clash be resolved?',
  },
];
const state = {
  config: null, labels: [], items: [], running: false, stopped: false, loading: false,
  results: { openai: [], decision: [] }, snapshot: null,
};
const field = (model, name) => $(`[data-field="${name}"]`, $(`[data-model="${model}"]`));
const seconds = (ms) => `${(ms / 1000).toFixed(3)} s`;
const usd = (value) => `$${value.toFixed(8)}`;
const finite = (value) => typeof value === 'number' && Number.isFinite(value) && value >= 0;
const probability = (value) => finite(value) && value <= 1;
const percent = (value) => `${(value * 100).toLocaleString(undefined, { maximumSignificantDigits: 3 })}%`;

function summarise(results, expected) {
  const completed = results.filter((result) => !result.error);
  const valid = completed.filter((result) => result.valid);
  const complete = results.length === expected && valid.length === expected;
  const counts = new Map();
  for (const result of valid) counts.set(result.label, (counts.get(result.label) || 0) + 1);
  const times = completed.map((result) => result.model_ms).sort((a, b) => a - b);
  const middle = Math.floor(times.length / 2);
  const median = times.length ? (times[middle] + times[Math.floor((times.length - 1) / 2)]) / 2 : null;
  const cost = completed.length && completed.every((result) => finite(result.cost_usd))
    ? completed.reduce((sum, result) => sum + result.cost_usd, 0) : null;
  const tokens = completed.length && completed.every((result) =>
    Number.isInteger(result.usage?.input_tokens) && result.usage.input_tokens >= 0 &&
    Number.isInteger(result.usage?.output_tokens) && result.usage.output_tokens >= 0)
    ? completed.reduce((sum, result) => sum + result.usage.input_tokens + result.usage.output_tokens, 0) : null;
  return {
    complete, completed: completed.length, valid: valid.length, median, cost, tokens,
    agreement: complete ? Math.max(...counts.values()) / expected : null,
    distinct: counts.size,
  };
}

function plannedTexts() {
  if (!consistency) return [$('#enquiry').value.trim()];
  const preset = experiments[Number($('#example').value)];
  switch ($('#experiment').value) {
    case 'reword': return preset.texts;
    case 'changed': return [preset.texts[0], preset.changed];
    default: return Array(Number($('#repetitions').value)).fill($('#enquiry').value.trim());
  }
}

function lockControls(busy) {
  for (const element of document.querySelectorAll('#scenario, #example, #enquiry, #experiment, #repetitions, #category-choices button')) {
    element.disabled = busy || (consistency && element.id === 'scenario');
  }
  $('#run').disabled = busy || !state.config || !$('#enquiry').value.trim();
  $('#stop').hidden = !state.running;
  $('#explain').disabled = busy || !state.snapshot || !state.results.openai[0]?.valid;
}

function clearResults() {
  state.snapshot = null;
  state.results = { openai: [], decision: [] };
  for (const model of models) {
    field(model, 'answer').textContent = consistency ? 'Ready to experiment' : 'Your prediction first?';
    field(model, 'live').textContent = '';
    field(model, 'time').textContent = 'Not run';
    field(model, 'agreement').textContent = 'Not run';
    field(model, 'tiles').replaceChildren();
    field(model, 'cost').textContent = 'No completed calls.';
    field(model, 'tokens').textContent = '';
    field(model, 'timing').textContent = '';
    field(model, 'inspect').replaceChildren();
    field(model, 'inspect').hidden = true;
    field(model, 'inspect').disabled = true;
    field(model, 'inspect-label').hidden = true;
    field(model, 'input').textContent = '';
    field(model, 'response').textContent = 'No response yet.';
  }
  field('openai', 'output').textContent = 'No response yet.';
  field('openai', 'output-note').textContent = 'The timed request asks for a category only, not a written explanation.';
  field('decision', 'output-note').textContent = 'A structured answer, not a written rationale.';
  field('decision', 'probabilities').replaceChildren();
  field('decision', 'probability-note').textContent = 'No probabilities reported yet.';
  field('decision', 'confidence').textContent = 'No confidence reported yet.';
  $('#explanation').hidden = true;
  $('#explanation').textContent = '';
  $('#explanation-status').textContent = '';
  $('#explanation-metrics').textContent = '';
  $('#explanation-response').hidden = true;
  $('#explanation-json').textContent = '';
  $('#explain').disabled = true;
}

function updatePlan() {
  clearResults();
  const mode = consistency ? $('#experiment').value : 'single';
  const texts = plannedTexts();
  $('#enquiry').readOnly = consistency && mode !== 'repeat';
  $('#repetitions').hidden = mode !== 'repeat';
  $('#repetitions-label').hidden = mode !== 'repeat';
  $('#experiment-inputs').hidden = !consistency || mode === 'repeat';
  $('#experiment-inputs').replaceChildren(...(consistency && mode !== 'repeat' ? texts.map((text) => {
    const item = document.createElement('li');
    item.textContent = text;
    return item;
  }) : []));
  $('#experiment-note').textContent = {
    repeat: 'Same text and category definitions each time. Does the model repeat its answer?',
    reword: 'Three versions of the same request. Does the category stay the same? Agreement here measures sensitivity to wording, not exact-repeat reliability.',
    changed: 'The second enquiry asks for different help. A changed answer may be appropriate: consistency is not stubbornness.',
  }[mode] || '';
  $('#call-count').textContent = `${texts.length} call${texts.length === 1 ? '' : 's'} per model; ${texts.length * 2} total. ${state.config.mock ? 'Simulation only.' : 'Uses model quota and may incur charges.'}`;
  for (const element of document.querySelectorAll('[data-metric="time"]')) {
    element.textContent = consistency ? 'Median response time' : 'Response time';
  }
  for (const element of document.querySelectorAll('[data-metric="agreement"]')) {
    element.parentElement.hidden = !consistency;
    element.textContent = mode === 'reword' ? 'Same-category agreement' : mode === 'changed' ? 'Categories used' : 'Repeatability';
  }
  $('#run-status').textContent = 'Ready. Predict what will happen before running.';
  $('#run').disabled = !$('#enquiry').value.trim();
}

function chooseExample() {
  $('#enquiry').value = consistency ? experiments[Number($('#example').value)].texts[0] : state.items[Number($('#example').value)];
  $('#prediction').textContent = 'Choose a category to make your own prediction, or go straight to the models.';
  for (const button of document.querySelectorAll('#category-choices button')) button.setAttribute('aria-pressed', 'false');
  updatePlan();
}

function renderCategories() {
  $('#category-definitions').replaceChildren();
  $('#category-choices').replaceChildren();
  for (const label of state.labels) {
    const term = document.createElement('dt');
    const description = document.createElement('dd');
    term.textContent = label.name;
    description.textContent = label.description;
    $('#category-definitions').append(term, description);
    const button = document.createElement('button');
    button.textContent = label.name;
    button.title = label.description;
    button.setAttribute('aria-pressed', 'false');
    button.addEventListener('click', () => {
      for (const other of $('#category-choices').children) other.setAttribute('aria-pressed', String(other === button));
      $('#prediction').textContent = `Your prediction: ${label.name}. This is not an answer key.`;
    });
    $('#category-choices').append(button);
  }
}

async function requestJson(url, body) {
  const response = await fetch(url, body === undefined ? undefined : {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
  });
  if (!response.ok) {
    let detail = `Request failed (HTTP ${response.status}).`;
    if (response.headers.get('content-type')?.includes('application/json')) {
      const data = await response.json();
      if (typeof data.error === 'string') detail = data.error;
    }
    throw new Error(detail);
  }
  if (!response.headers.get('content-type')?.includes('application/json')) {
    throw new Error('Expected model data but received another page. Your sign-in may have expired.');
  }
  return response.json();
}

async function loadScenario() {
  state.loading = true;
  lockControls(true);
  clearResults();
  $('#page-error').hidden = true;
  try {
    const scenario = state.config.scenarios[$('#scenario').value];
    const data = await requestJson(`/api/data/${encodeURIComponent($('#scenario').value)}`);
    if (!Array.isArray(data.items) || !data.items.length) throw new Error('This scenario has no examples.');
    state.labels = scenario.labels;
    state.items = data.items;
    $('#scenario-note').textContent = scenario.description;
    renderCategories();
    $('#example').replaceChildren(...(consistency ? experiments.map((example, index) => new Option(example.name, index))
      : data.items.map((text, index) => new Option(`${index + 1}. ${text.slice(0, 60)}${text.length > 60 ? '...' : ''}`, index))));
    chooseExample();
  } catch (error) {
    $('#page-error').textContent = `Could not load examples: ${error.message} Reload the page to retry.`;
    $('#page-error').hidden = false;
    $('#run-status').textContent = 'Examples unavailable.';
    state.config = null;
  } finally {
    state.loading = false;
    lockControls(!state.config);
  }
}

function renderMetrics(model, snapshot) {
  const results = state.results[model];
  const summary = summarise(results, snapshot.texts.length);
  const simulated = state.config.mock;
  field(model, 'time').textContent = summary.median === null ? 'Unavailable'
    : `${seconds(summary.median)}${simulated ? ' (simulated)' : ''}`;
  field(model, 'agreement').textContent = simulated ? 'Simulation only'
    : !summary.complete ? 'Incomplete'
    : snapshot.mode === 'changed' ? String(summary.distinct)
    : `${(summary.agreement * 100).toFixed(0)}%`;
  const missingCost = results.find((result) => !result.error && result.cost_unavailable_reason)?.cost_unavailable_reason;
  field(model, 'cost').textContent = simulated ? 'Simulated run: no model charges.'
    : summary.cost === null ? `Estimated cost unavailable. ${missingCost || 'Usage or a verified price was not reported.'}`
    : `Estimated cost of completed calls: ${usd(summary.cost)} USD.`;
  if (!summary.complete && !simulated) field(model, 'cost').textContent += ' Incomplete run; failed calls may also incur charges.';
  field(model, 'tokens').textContent = `Reported input + output tokens: ${summary.tokens === null ? 'unavailable' : summary.tokens}.`;
  const browserMs = results.filter((result) => !result.error).reduce((sum, result) => sum + result.browser_ms, 0);
  field(model, 'timing').textContent = `${summary.completed}/${snapshot.texts.length} responses received. ${consistency ? 'Median' : 'Response'} time is the server-measured model request, including the service network hop. Completed browser round trips total ${seconds(browserMs)}. Token counts are not a direct measure of thought.`;
}

function renderOutput(model, index) {
  const result = state.results[model][index];
  if (!result) return;
  field(model, 'input').textContent = consistency ? `Input ${index + 1}: ${state.snapshot.texts[index]}` : '';
  field(model, 'output-note').textContent = result.error ? `Call ${index + 1} failed: ${result.error}`
    : state.config.mock ? `Call ${index + 1}: simulation only. No API response was received.`
    : model === 'openai' ? `Call ${index + 1}: complete returned text, before category matching. The request asks for a category only.`
    : `Call ${index + 1}: the API's structured choice and numerical estimates.`;
  field(model, 'response').textContent = result.model_response == null
    ? 'No model response body is available for this call.'
    : JSON.stringify(result.model_response, null, 2);
  if (model === 'openai') {
    field(model, 'output').textContent = typeof result.model_output === 'string'
      ? result.model_output : 'No returned model text is available for this call.';
    return;
  }
  field(model, 'probabilities').replaceChildren();
  field(model, 'confidence').textContent = probability(result.confidence)
    ? `Reported confidence: ${percent(result.confidence)}. This is a separate API field, not a substitute for the category probabilities.`
    : 'Confidence was not reported as a number between 0 and 1.';
  const rows = result.probabilities;
  if (state.config.mock || result.error || !Array.isArray(rows) || !rows.length) {
    field(model, 'probability-note').textContent = state.config.mock ? 'Simulation only: no API probabilities were returned.'
      : result.error ? 'No probabilities are available for this failed call.'
      : result.probabilities_unavailable_reason || 'The API did not return category probabilities.';
    return;
  }
  if (!rows.every((row) => typeof row.label === 'string' && probability(row.probability))) {
    field(model, 'probability-note').textContent = 'Invalid probability data; inspect the returned response JSON.';
    return;
  }
  for (const row of rows) {
    const item = document.createElement('li');
    const label = document.createElement('span');
    const meter = document.createElement('meter');
    const value = document.createElement('span');
    label.textContent = row.label;
    meter.min = 0;
    meter.max = 1;
    meter.value = row.probability;
    meter.setAttribute('aria-label', `${row.label}: model-estimated probability`);
    value.textContent = percent(row.probability);
    if (row.label === result.label) item.className = 'selected';
    item.append(label, meter, value);
    field(model, 'probabilities').append(item);
  }
  field(model, 'probability-note').textContent = 'Reported category probabilities, not rescaled. These are model estimates, not guaranteed chances of correctness. A probability distribution is not an explanation.';
}

function addOutputCall(model, index) {
  const select = field(model, 'inspect');
  select.add(new Option(`Call ${index + 1}`, String(index)));
  select.value = String(index);
  select.hidden = state.results[model].length < 2;
  select.disabled = false;
  field(model, 'inspect-label').hidden = select.hidden;
  renderOutput(model, index);
}

async function runSide(model, snapshot) {
  for (let index = 0; index < snapshot.texts.length && !state.stopped; index++) {
    const started = performance.now();
    const progress = `Call ${index + 1}/${snapshot.texts.length}`;
    field(model, 'live').textContent = `${progress} - waiting...`;
    const timer = setInterval(() => {
      field(model, 'live').textContent = `${progress} - ${seconds(performance.now() - started)} elapsed`;
    }, 100);
    try {
      const result = await requestJson(`/api/classify/${model}`, { text: snapshot.texts[index], labels: snapshot.labels });
      if (typeof result.label !== 'string' || !finite(result.model_ms)) throw new Error('The model response is missing a category or valid timing.');
      result.browser_ms = performance.now() - started;
      result.valid = snapshot.labels.some((label) => label.name === result.label);
      state.results[model].push(result);
      field(model, 'answer').textContent = result.valid ? result.label : 'No valid category';
      const tile = document.createElement('li');
      tile.textContent = `${index + 1}. ${result.label}`;
      tile.title = snapshot.texts[index];
      tile.style.setProperty('--category-color', palette[snapshot.labels.findIndex((label) => label.name === result.label) % palette.length] || '#b51e33');
      if (!result.valid) {
        tile.className = 'error';
        tile.textContent += ' (not one of the categories)';
      }
      field(model, 'tiles').append(tile);
    } catch (error) {
      state.results[model].push({ error: error.message });
      field(model, 'answer').textContent = 'Request failed';
      const tile = document.createElement('li');
      tile.className = 'error';
      tile.textContent = `${index + 1}. ${error.message}`;
      field(model, 'tiles').append(tile);
      break;
    } finally {
      clearInterval(timer);
      addOutputCall(model, state.results[model].length - 1);
      renderMetrics(model, snapshot);
    }
  }
  const summary = summarise(state.results[model], snapshot.texts.length);
  field(model, 'live').textContent = summary.complete ? 'Complete' : 'Incomplete - no result was substituted for a missing or invalid answer.';
}

async function run() {
  if (state.running || state.loading) return;
  const texts = plannedTexts();
  if (texts.some((text) => !text)) return;
  clearResults();
  state.running = true;
  state.stopped = false;
  state.snapshot = { texts, labels: state.labels.map((label) => ({ ...label })), mode: consistency ? $('#experiment').value : 'single' };
  lockControls(true);
  $('#stop').disabled = false;
  $('#run-status').textContent = state.config.mock ? 'Running a simulation, not a model benchmark...' : 'Both models receive the same inputs and category definitions.';
  await Promise.all(models.map((model) => runSide(model, state.snapshot)));
  state.running = false;
  lockControls(false);
  const complete = models.every((model) => summarise(state.results[model], texts.length).complete);
  $('#run-status').textContent = !complete ? 'Incomplete experiment. Inspect each panel before drawing conclusions.'
    : state.config.mock ? 'Simulation complete. These results do not demonstrate real model speed or consistency.'
    : state.snapshot.mode === 'changed' ? 'Complete. Did each model respond appropriately to the changed request? A different answer can be correct.'
    : consistency ? 'Complete. Agreement means the same category was returned, not that it was correct.'
    : 'Complete. Compare the predictions and measurements; neither model is assumed to win.';
}

async function explain() {
  if (state.running || !state.snapshot || !state.results.openai[0]?.valid) return;
  lockControls(true);
  $('#explanation').hidden = true;
  $('#explanation-status').textContent = 'Generating a separate public-facing justification...';
  $('#explanation-metrics').textContent = '';
  $('#explanation-response').hidden = true;
  $('#explanation-json').textContent = '';
  try {
    const result = await requestJson('/api/explain', {
      text: state.snapshot.texts[0], labels: state.snapshot.labels, label: state.results.openai[0].label,
    });
    if (typeof result.explanation !== 'string' || !result.explanation.trim() || !finite(result.model_ms)) {
      throw new Error('The explanation response was empty or had invalid timing.');
    }
    $('#explanation').textContent = result.explanation;
    $('#explanation').hidden = false;
    $('#explanation-json').textContent = result.model_response == null
      ? 'No API response body: this was a simulation.'
      : JSON.stringify(result.model_response, null, 2);
    $('#explanation-response').hidden = false;
    $('#explanation-status').textContent = result.refusal
      ? 'The LLM declined to explain. Its returned refusal is shown below.'
      : 'Generated explanation - not an internal reasoning trace.';
    const tokenCount = Number.isInteger(result.usage?.input_tokens) && Number.isInteger(result.usage?.output_tokens)
      ? result.usage.input_tokens + result.usage.output_tokens : 'unavailable';
    $('#explanation-metrics').textContent = `Separate extra call: ${seconds(result.model_ms)}${state.config.mock ? ' (simulated)' : ''}; reported tokens: ${tokenCount}; estimated cost: ${finite(result.cost_usd) ? `${usd(result.cost_usd)} USD` : 'unavailable'}. Not included in classification metrics.`;
  } catch (error) {
    $('#explanation-status').textContent = `Explanation failed: ${error.message}`;
  } finally {
    lockControls(false);
  }
}

async function init() {
  for (const model of models) {
    field(model, 'inspect').addEventListener('change', () => renderOutput(model, Number(field(model, 'inspect').value)));
  }
  for (const link of document.querySelectorAll('nav a')) {
    if (link.getAttribute('href') === location.pathname) link.setAttribute('aria-current', 'page');
  }
  if (consistency) {
    document.title = 'Does it stick? | AI decisions';
    $('#page-title').textContent = 'Does it stick to its answer?';
    $('#page-intro').textContent = 'Repeat an enquiry, reword it, then change what matters. Consistency is not the same as correctness.';
    $('#experiment-controls').hidden = false;
    $('#experiment-note').hidden = false;
    $('#run').textContent = 'Run experiment';
    $('#discussion-title').textContent = 'Consistency, or stubbornness?';
    $('#discussion-question').textContent = 'When should an answer stay the same, and when should it change? Who decides which differences matter?';
  } else {
    document.title = 'One decision | AI decisions';
    $('#explanation-section').hidden = false;
  }
  $('#scenario').addEventListener('change', loadScenario);
  $('#example').addEventListener('change', chooseExample);
  $('#enquiry').addEventListener('input', updatePlan);
  $('#experiment').addEventListener('change', () => {
    $('#enquiry').value = experiments[Number($('#example').value)].texts[0];
    updatePlan();
  });
  $('#repetitions').addEventListener('change', updatePlan);
  $('#run').addEventListener('click', run);
  $('#stop').addEventListener('click', () => {
    state.stopped = true;
    $('#stop').disabled = true;
    $('#run-status').textContent = 'Stopping after the in-flight calls finish. Those calls may still incur charges.';
  });
  $('#explain').addEventListener('click', explain);
  try {
    state.config = await requestJson('/api/config');
    if (!state.config.scenarios?.students) throw new Error('Student enquiry scenario is unavailable.');
    $('#mock-notice').hidden = !state.config.mock;
    for (const model of models) field(model, 'name').textContent = state.config[`${model}_model`];
    $('#scenario').replaceChildren(...Object.entries(state.config.scenarios).map(([key, scenario]) => new Option(scenario.name, key)));
    $('#scenario').value = 'students';
    await loadScenario();
  } catch (error) {
    $('#page-error').textContent = `Could not initialise the demo: ${error.message} Reload the page to retry.`;
    $('#page-error').hidden = false;
    $('#run-status').textContent = 'Demo unavailable.';
    lockControls(true);
  }
}

init();
