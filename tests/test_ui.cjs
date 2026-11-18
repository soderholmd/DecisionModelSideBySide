const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { test } = require('node:test');
const vm = require('node:vm');

const source = readFileSync(`${__dirname}/../static/app.js`, 'utf8')
  .replace(/^init\(\);$/m, '');

const classroomSource = readFileSync(`${__dirname}/../static/classroom.js`, 'utf8')
  .replace(/^init\(\);$/m, '');

function classroomContext(values = {}) {
  const context = vm.createContext({ location: { pathname: '/consistency' }, ...values });
  vm.runInContext(classroomSource, context);
  return context;
}

test('classroom metrics distinguish agreement from incomplete, invalid or failed runs', () => {
  const result = (label, model_ms, cost_usd = 0.001) => ({
    label, model_ms, cost_usd, valid: true, usage: { input_tokens: 10, output_tokens: 2 },
  });
  const context = classroomContext();
  context.results = [result('IT', 30), result('IT', 10), result('Admissions', 20)];
  let summary = vm.runInContext('summarise(results, 3)', context);
  assert.equal(summary.agreement, 2 / 3);
  assert.equal(summary.median, 20);
  assert.equal(summary.tokens, 36);
  assert.equal(summary.cost, 0.003);
  assert.equal(summary.distinct, 2);

  context.results.push({ error: 'Request failed' });
  summary = vm.runInContext('summarise(results, 4)', context);
  assert.equal(summary.agreement, null);
  assert.equal(summary.complete, false);
  assert.equal(summary.completed, 3);
  context.results = [{ ...result('Unknown', 12), valid: false }];
  assert.equal(vm.runInContext('summarise(results, 1).agreement', context), null);
  assert.equal(vm.runInContext('summarise([], 5).median', context), null);
});

test('classroom cost and token totals never substitute zero for missing measurements', () => {
  const context = classroomContext({
    results: [
      { label: 'IT', model_ms: 10, valid: true, cost_usd: 0.001, usage: { input_tokens: 5, output_tokens: 1 } },
      { label: 'IT', model_ms: 14, valid: true, cost_usd: null, usage: null },
    ],
  });
  const summary = vm.runInContext('summarise(results, 2)', context);
  assert.equal(summary.cost, null);
  assert.equal(summary.tokens, null);
  assert.equal(summary.median, 12);
  assert.equal(summary.agreement, 1);
});

test('classroom experiment plans separate exact repeats, rewording and changed facts', () => {
  const fields = {
    '#example': { value: '0' }, '#experiment': { value: 'repeat' },
    '#repetitions': { value: '5' }, '#enquiry': { value: 'Custom enquiry' },
  };
  const context = classroomContext({ document: { querySelector: (selector) => fields[selector] } });
  assert.deepEqual(Array.from(vm.runInContext('plannedTexts()', context)), Array(5).fill('Custom enquiry'));
  fields['#experiment'].value = 'reword';
  const reworded = Array.from(vm.runInContext('plannedTexts()', context));
  assert.equal(reworded.length, 3);
  assert.equal(new Set(reworded).size, 3);
  fields['#experiment'].value = 'changed';
  const changed = Array.from(vm.runInContext('plannedTexts()', context));
  assert.equal(changed.length, 2);
  assert.equal(changed[0], reworded[0]);
  assert.notEqual(changed[1], reworded[1]);
});

test('classroom renders repeatability separately from changed-fact and simulated results', () => {
  const fields = {};
  const panel = {
    querySelector(selector) {
      return fields[selector] ??= { textContent: '' };
    },
  };
  const context = classroomContext({ document: { querySelector: () => panel } });
  vm.runInContext(`state.config = {mock: false};
    state.results.openai = [
      {label: 'IT', model_ms: 10, browser_ms: 15, valid: true, cost_usd: 0.000001, usage: {input_tokens: 10, output_tokens: 2}},
      {label: 'IT', model_ms: 30, browser_ms: 35, valid: true, cost_usd: 0.000001, usage: {input_tokens: 10, output_tokens: 2}},
      {label: 'Admissions', model_ms: 20, browser_ms: 25, valid: true, cost_usd: 0.000001, usage: {input_tokens: 10, output_tokens: 2}}
    ];
    renderMetrics('openai', {texts: ['a','a','a'], mode: 'repeat'});`, context);
  assert.equal(fields['[data-field="agreement"]'].textContent, '67%');
  assert.equal(fields['[data-field="time"]'].textContent, '0.020 s');
  assert.match(fields['[data-field="cost"]'].textContent, /\$0\.00000300/);
  vm.runInContext(`renderMetrics('openai', {texts: ['a','b','c'], mode: 'changed'})`, context);
  assert.equal(fields['[data-field="agreement"]'].textContent, '2');
  vm.runInContext(`state.config.mock = true;
    renderMetrics('openai', {texts: ['a','a','a'], mode: 'repeat'});`, context);
  assert.equal(fields['[data-field="agreement"]'].textContent, 'Simulation only');
  assert.match(fields['[data-field="time"]'].textContent, /simulated/);
});

function outputContext() {
  const fields = {};
  function element() {
    return {
      textContent: '', children: [], attributes: {},
      set innerHTML(value) { throw new Error('Model outputs must never be rendered as HTML.'); },
      setAttribute(name, value) { this.attributes[name] = value; },
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; },
    };
  }
  const panel = { querySelector: (selector) => fields[selector] ??= element() };
  const context = classroomContext({
    document: { querySelector: () => panel, createElement: element },
  });
  vm.runInContext(`state.config = {mock: false}; state.snapshot = {texts: ['First enquiry', 'Second enquiry']};`, context);
  return { context, fields };
}

test('returned LLM text and response JSON remain complete plain text for each call', () => {
  const { context, fields } = outputContext();
  const output = 'Label: IT Support\n<img src=x onerror=alert(1)> Full returned wording.';
  context.output = output;
  vm.runInContext(`state.results.openai = [
    {label:'IT Support', model_output:output, model_response:{choices:[{message:{content:output}}], usage:{total_tokens:12}}},
    {label:'Admissions', model_output:'A different answer', model_response:{choices:[{message:{content:'A different answer'}}]}}
  ]; renderOutput('openai', 0);`, context);
  assert.equal(fields['[data-field="output"]'].textContent, output);
  const response = JSON.parse(fields['[data-field="response"]'].textContent);
  assert.equal(response.choices[0].message.content, output);
  assert.equal(response.usage.total_tokens, 12);
  vm.runInContext(`renderOutput('openai', 1)`, context);
  assert.equal(fields['[data-field="output"]'].textContent, 'A different answer');
  assert.equal(fields['[data-field="input"]'].textContent, 'Input 2: Second enquiry');
});

test('Decision bars use returned probabilities, preserve zero, and separate confidence', () => {
  const { context, fields } = outputContext();
  vm.runInContext(`state.results.decision = [{
    label:'IT Support', confidence:0.1,
    probabilities:[{label:'Admissions',probability:0},{label:'IT Support',probability:0.7}],
    model_response:{answers:{category:{choice:'it_support',probabilities:{admissions:0,it_support:0.7},confidence:0.1}}}
  }]; renderOutput('decision', 0);`, context);
  const rows = fields['[data-field="probabilities"]'].children;
  assert.equal(rows.length, 2);
  assert.equal(rows[0].children[1].value, 0);
  assert.equal(rows[0].children[2].textContent, '0%');
  assert.equal(rows[1].children[1].value, 0.7);
  assert.equal(rows[1].children[2].textContent, '70%');
  assert.match(fields['[data-field="confidence"]'].textContent, /10%/);
  assert.match(fields['[data-field="probability-note"]'].textContent, /not rescaled/);
});

test('missing, invalid and simulated distributions never become fabricated bars', () => {
  const { context, fields } = outputContext();
  vm.runInContext(`state.results.decision = [{
    confidence:0.9, probabilities:null, probabilities_unavailable_reason:'The model declined to decide.'
  }]; renderOutput('decision', 0);`, context);
  assert.equal(fields['[data-field="probabilities"]'].children.length, 0);
  assert.match(fields['[data-field="probability-note"]'].textContent, /declined/);
  vm.runInContext(`state.results.decision[0].probabilities = [{label:'IT',probability:1.2}];
    renderOutput('decision', 0);`, context);
  assert.equal(fields['[data-field="probabilities"]'].children.length, 0);
  assert.match(fields['[data-field="probability-note"]'].textContent, /Invalid probability/);
  vm.runInContext(`state.config.mock = true;
    state.results.decision[0].probabilities = [{label:'IT',probability:0.9}];
    renderOutput('decision', 0);`, context);
  assert.equal(fields['[data-field="probabilities"]'].children.length, 0);
  assert.match(fields['[data-field="probability-note"]'].textContent, /Simulation only/);
});

function setup(fetch) {
  const fields = {};
  function element() {
    return {
      textContent: '', style: {}, children: [],
      classList: { remove() {} },
      append(...children) { this.children.push(...children); },
      replaceChildren(...children) { this.children = children; },
    };
  }
  const panels = Object.fromEntries(['openai', 'decision'].map((model) => {
    fields[model] = {};
    return [model, {
      querySelector(selector) {
        const name = selector.match(/data-field="([^"]+)"/)[1];
        return fields[model][name] ??= element();
      },
    }];
  }));
  const context = vm.createContext({
    document: {
      querySelector: (selector) => panels[selector.match(/data-model="([^"]+)"/)[1]],
      createElement: element,
    },
    TextDecoder, fetch,
  });
  vm.runInContext(source, context);
  vm.runInContext('resetPanels()', context);
  return { context, fields };
}

function eventStream() {
  const encoder = new TextEncoder();
  let controller;
  const body = new ReadableStream({ start(value) { controller = value; } });
  return {
    response: { ok: true, body },
    send(event) { controller.enqueue(encoder.encode(`${JSON.stringify(event)}\n`)); },
    close() { controller.close(); },
  };
}

const resultEvent = (overrides = {}) => ({
  type: 'result', text: 'sample', label: 'Support', model_ms: 10,
  wall_ms: 50, total: 2, cost_usd: 0.00001,
  usage: { input_tokens: 10, output_tokens: 1 },
  pricing: { input: 2, output: 10, basis: 'Standard' },
  ...overrides,
});
const flush = () => new Promise(setImmediate);

for (const model of ['openai', 'decision']) {
  test(`${model} streams prompts and totals, completing only on the server's done event`, async () => {
    const stream = eventStream();
    let requests = 0;
    const { context, fields } = setup(async (url, options) => {
      requests += 1;
      assert.equal(url, `/api/run/${model}/expenses`);
      assert.deepEqual(JSON.parse(options.body), { labels: [] });
      return stream.response;
    });
    assert.equal(fields[model].avg.textContent, '0.000 ms');
    const result = vm.runInContext(
      `runSide('${model}', 'expenses', [], { aborted: false })`, context,
    );
    stream.send({ type: 'calling', prompt: 'First request' });
    await flush();
    assert.equal(fields[model].prompt.textContent, 'First request');
    assert.equal(fields[model].calls.textContent, '0');
    assert.equal(fields[model].results.children.length, 0);
    stream.send(resultEvent());
    stream.send({ type: 'calling', prompt: 'Second request' });
    await flush();
    assert.equal(fields[model].calls.textContent, '1');
    assert.equal(fields[model].avg.textContent, '10.000 ms');
    assert.equal(fields[model].model.textContent, '0.010 s');
    assert.equal(fields[model].bar.style.width, '50%');
    assert.equal(fields[model].cost.textContent, '$0.00001000');
    assert.equal(fields[model].tokens.textContent, '11');
    assert.equal(fields[model].completion.textContent, '');
    stream.send(resultEvent({ model_ms: 25, wall_ms: 80 }));
    await flush();
    assert.equal(fields[model].avg.textContent, '17.500 ms');
    assert.equal(fields[model].model.textContent, '0.035 s');
    assert.equal(fields[model].completion.textContent, '');
    stream.send({ type: 'done', wall_ms: 85 });
    const completed = await result;
    assert.equal(completed.complete, true);
    assert.equal(completed.wallMs, 85);
    assert.equal(completed.costUsd, 0.00002);
    assert.equal(requests, 1);
    assert.equal(fields[model].wall.textContent, '0.085 s');
    assert.equal(fields[model].avg.textContent, '17.500 ms');
    assert.equal(fields[model].cost.textContent, '$0.00002000');
    assert.equal(fields[model].tokens.textContent, '22');
    assert.equal(fields[model].completion.textContent, 'Done');
    vm.runInContext('resetPanels()', context);
    assert.equal(fields[model].completion.textContent, '');
    assert.equal(fields[model].cost.textContent, '$0.00000000');
    assert.equal(fields[model].avg.textContent, '0.000 ms');
  });
}

test('both model streams start concurrently and comparisons use server times', async () => {
  const streams = { openai: eventStream(), decision: eventStream() };
  const requested = [];
  const { context, fields } = setup(async (url) => {
    const model = url.split('/')[3];
    requested.push(model);
    return streams[model].response;
  });
  const results = vm.runInContext(
    `Promise.all(['openai', 'decision'].map((model) =>
      runSide(model, 'expenses', [], { aborted: false })))`, context,
  );
  assert.deepEqual(requested, ['openai', 'decision']);
  for (const model of ['openai', 'decision']) {
    assert.equal(fields[model].calls.textContent, '0');
    assert.equal(fields[model].bar.style.width, '0');
    assert.equal(fields[model].results.children.length, 0);
    assert.equal(fields[model].completion.textContent, '');
  }
  for (const [model, wallMs, cost] of [['openai', 100, 0.002], ['decision', 200, 0.00002]]) {
    streams[model].send(resultEvent({ total: 1, cost_usd: cost }));
    streams[model].send({ type: 'done', wall_ms: wallMs });
  }
  context.results = await results;
  vm.runInContext('showRelative(results)', context);
  assert.match(fields.openai.relative.textContent, /2\.00× faster/);
  assert.match(fields.openai['relative-cost'].textContent, /100\.00× higher/);
  assert.match(fields.decision['relative-cost'].textContent, /100\.00× lower/);
});

test('missing usage prevents partial cost totals even if later calls report cost', async () => {
  const stream = eventStream();
  const { context, fields } = setup(async () => stream.response);
  const result = vm.runInContext(
    "runSide('openai', 'expenses', [], { aborted: false })", context,
  );
  stream.send(resultEvent({ cost_usd: null, usage: null, cost_unavailable_reason: 'No usage' }));
  stream.send(resultEvent());
  stream.send({ type: 'done', wall_ms: 100 });
  const completed = await result;
  assert.equal(completed.costUsd, null);
  assert.equal(fields.openai.cost.textContent, 'Unavailable');
  assert.equal(fields.openai.tokens.textContent, 'Unavailable');
  assert.match(fields.openai.pricing.textContent, /Total unavailable: No usage/);
  context.results = [completed, { model: 'decision', wallMs: 200, complete: true, costUsd: 0.01 }];
  vm.runInContext('showRelative(results)', context);
  assert.match(fields.openai['relative-cost'].textContent, /comparison unavailable/);
});

test('NDJSON parser handles split UTF-8 characters and multiple events per chunk', async () => {
  const bytes = new TextEncoder().encode('{"type":"calling","prompt":"café"}\n{"type":"heartbeat"}\n');
  const split = bytes.indexOf(0xc3) + 1;
  const body = new ReadableStream({
    start(controller) {
      controller.enqueue(bytes.slice(0, split));
      controller.enqueue(bytes.slice(split));
      controller.close();
    },
  });
  const { context } = setup();
  context.response = { body };
  const events = await vm.runInContext(
    '(async () => { const events = []; for await (const event of readEvents(response)) events.push(event); return events; })()',
    context,
  );
  assert.equal(events[0].prompt, 'café');
  assert.equal(events[1].type, 'heartbeat');
});

for (const outcome of ['http-error', 'network-error', 'abort', 'server-error', 'truncated']) {
  test(`${outcome} does not show Done`, async () => {
    const stream = eventStream();
    const { context, fields } = setup(async () => {
      if (outcome === 'http-error') {
        return { ok: false, json: async () => ({ error: 'Model failed' }) };
      }
      if (outcome === 'network-error' || outcome === 'abort') {
        const error = new Error('Request failed');
        if (outcome === 'abort') error.name = 'AbortError';
        throw error;
      }
      return stream.response;
    });
    const result = vm.runInContext(
      "runSide('openai', 'expenses', [], { aborted: false })", context,
    );
    if (outcome === 'server-error') stream.send({ type: 'error', error: 'Model failed' });
    if (outcome === 'truncated') stream.send(resultEvent({ total: 1 }));
    if (['server-error', 'truncated'].includes(outcome)) stream.close();
    assert.equal((await result).complete, false);
    assert.equal(fields.openai.completion.textContent, '');
  });
}

for (const [a, b, expected] of [
  [0, 0, 'Same estimated cost.'],
  [0.01, 0.01, 'Same estimated cost.'],
  [0, 0.01, 'Lower estimated cost'],
]) {
  test(`cost comparison handles ${a} and ${b} without an infinite ratio`, () => {
    const { context, fields } = setup();
    context.results = [
      { model: 'openai', wallMs: 100, complete: true, costUsd: a },
      { model: 'decision', wallMs: 200, complete: true, costUsd: b },
    ];
    vm.runInContext('showRelative(results)', context);
    assert.ok(fields.openai['relative-cost'].textContent.startsWith(expected));
    assert.doesNotMatch(fields.openai['relative-cost'].textContent, /Infinity|NaN/);
  });
}

test('incomplete runs do not show comparisons', () => {
  const { context, fields } = setup();
  context.results = [
    { model: 'openai', wallMs: 100, complete: false, costUsd: 0.01 },
    { model: 'decision', wallMs: 200, complete: true, costUsd: 0.001 },
  ];
  vm.runInContext('showRelative(results)', context);
  for (const model of ['openai', 'decision']) {
    assert.equal(fields[model].relative.textContent, '');
    assert.equal(fields[model]['relative-cost'].textContent, '');
  }
});
