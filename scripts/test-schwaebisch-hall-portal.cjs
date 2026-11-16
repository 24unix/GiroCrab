// Run the actual scripts embedded in SchwaebischHallUI.swift against a fake
// portal (synthetic data only), as for FNZ and quirion.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const source = readFileSync(new URL('../GiroCrabApp/Sources/GiroCrabUI/SchwaebischHallUI.swift', `file://${__filename}`), 'utf8');
const scripts = Object.fromEntries([...source.matchAll(/static let (\w+) = #"""\n([\s\S]*?)\n    """#/g)].map(m => [m[1], m[2]]));
const ORIGIN = 'https://www.schwaebisch-hall.de';
const DETAILS = '/content/bshweb/startseite/mein-konto/vertraege/_jcr_content/root/container/par/container/myaccount_accounts.account_details.json';
const POSTBOX = '/content/bshweb/startseite/mein-konto/nachrichten.bin.postboxmessage';

const response = (data, {status = 200, headers = {}} = {}) => ({ok: status >= 200 && status < 300, status,
  json: async () => data, arrayBuffer: async () => data, headers: {get: k => headers[k.toLowerCase()] ?? null}});

/// Runs `prelude + script` as WKWebView's callAsyncJavaScript does (an async function body).
function run(name, fetch, {origin = ORIGIN, args = {}} = {}) {
  const context = vm.createContext({fetch, location: {origin}, AbortController, setTimeout, clearTimeout,
    URLSearchParams, btoa: s => Buffer.from(s, 'binary').toString('base64'), ...args});
  return vm.runInContext(`(async()=>{${scripts.prelude}\n${scripts[name]}})()`, context);
}

const contracts = [
  {type: 'Bausparvertrag Sparphase', bsn: '217111 D 01', accountBalance: '&#43; 0,00', coreid: '217111',
   contractletter: 'D', contractnumber: '01', vtn: '0021711100101', owner: 'DO NOT EXPORT'},
  {type: 'Bausparvertrag Sparphase', bsn: '300222 A 02', accountBalance: '&#43; 1.234,56', coreid: '300222',
   contractletter: 'A', contractnumber: '02', vtn: '0030022200102'},
];

function portal(calls, overrides = {}) {
  return async (url, options = {}) => {
    calls.push({url, options});
    const u = new URL(url);
    assert.equal(u.origin, ORIGIN);
    assert.equal(options.credentials, 'same-origin');
    assert.equal(options.redirect, 'error');
    if (overrides[u.pathname]) return overrides[u.pathname](u);
    if (u.pathname === '/bin/bshweb/accountcontracts') return response({status: 'success', data: {contracts}});
    if (u.pathname === DETAILS) return response({contracttype: 'Bausparvertrag', contractphase: 'Sparphase',
      coredata: {name: 'DO NOT EXPORT', address: 'DO NOT EXPORT'}, debit: {iban: 'DO NOT EXPORT'},
      transactions: {2026: {saldo: '&#43; 50,00', Januar: [{day: '15', subject: 'Sparrate', amount: '&#43; 50,00'}]}}});
    if (u.pathname === POSTBOX) return response([
      {id: 'm1', date: '31.01.2026', title: 'Jahreskontoauszug 300222 A 02', read: false, typeName: 'Kontoauszug',
       text: '<p>Ihr Auszug</p><form target="_blank" method="get" action="/bin/bshweb/postbox/attachment"><input type="hidden" name="id" value="att-1"></form>'},
      {id: 'm2', date: '01.02.2026', title: 'Vertragsinformationen', typeName: 'Info',
       text: "<a href='/bin/bshweb/postbox/attachment?id=att%202&amp;x=1'>PDF</a> zu 217111 D 01 und 300222 A 02"},
      {id: 'm3', date: '02.02.2026', title: 'Ohne Anhang', text: '<p>Hallo</p>'},
      {id: 'm4', date: '03.02.2026', title: 'Doppelt', attachments: [{id: 'att-1'}, 'att-3']},
    ]);
    if (u.pathname === '/bin/bshweb/postbox/attachment') {
      const pdf = new TextEncoder().encode('%PDF-1.7 synthetic ' + u.searchParams.get('id')).buffer;
      return response(pdf, {headers: {'content-type': 'application/pdf'}});
    }
    return response({}, {status: 404});
  };
}

test('probe is true only with a session on the portal', async () => {
  assert.equal(await run('probe', portal([])), 'true');
  const expired = portal([], {'/bin/bshweb/accountcontracts': () =>
    response({status: 'error', errors: [{message: 'Session has a timeout', code: 'timeout'}]})});
  assert.equal(await run('probe', expired), 'false');
  assert.equal(await run('probe', async () => { throw new TypeError('redirect'); }), 'false');
  await assert.rejects(run('probe', portal([]), {origin: 'https://login.schwaebisch-hall.de'}), /^Error: bsh:session$/);
});

test('snapshot reads every contract and passes only the needed fields', async () => {
  const calls = [];
  const snap = JSON.parse(await run('snapshot', portal(calls)));
  assert.equal(snap.version, 1);
  assert.equal(snap.contracts.length, 2);
  assert.deepEqual(calls.filter(c => c.url.includes(DETAILS)).map(c => new URL(c.url).searchParams.get('vtn')),
    ['0021711100101', '0030022200102']);
  assert.deepEqual(Object.keys(snap.contracts[0].details).sort(), ['contractphase', 'contracttype', 'transactions']);
  assert.equal(snap.contracts[1].accountBalance, '&#43; 1.234,56');
  assert.ok(!JSON.stringify(snap).includes('DO NOT EXPORT'));
  // only the fields the core reads
  assert.deepEqual(Object.keys(snap.contracts[0]).sort(), ['accountBalance', 'bsn', 'details', 'type', 'vtn']);
});

test('snapshot unwraps a data envelope and stops on errors', async () => {
  const wrapped = portal([], {[DETAILS]: () => response({status: 'success', data: {contracttype: 'X', transactions: []}})});
  const snap = JSON.parse(await run('snapshot', wrapped));
  assert.deepEqual(snap.contracts[0].details, {contracttype: 'X', transactions: []});
  await assert.rejects(run('snapshot', portal([], {[DETAILS]: () => response({}, {status: 500})})), /^Error: bsh:http:500$/);
  await assert.rejects(run('snapshot', portal([], {'/bin/bshweb/accountcontracts': () =>
    response({status: 'error', errors: [{code: 'timeout'}]})})), /^Error: bsh:session$/);
  await assert.rejects(run('snapshot', portal([], {'/bin/bshweb/accountcontracts': () =>
    response({status: 'success', data: {contracts: [{vtn: '12;x'}]}})})), /^Error: bsh:invalid$/);
});

test('scripts throw only fixed codes, never browser or parser texts', async () => {
  // a redirect to the sign-in (redirect:'error') and an HTML page instead of JSON
  await assert.rejects(run('snapshot', async () => { throw new TypeError('Load failed'); }), /^Error: bsh:session$/);
  const html = portal([], {[DETAILS]: () => ({ok: true, status: 200, headers: {get: () => null},
    json: async () => JSON.parse('<html>Max Muster</html>')})});
  await assert.rejects(run('snapshot', html), e => e.message === 'bsh:session' && !e.message.includes('Muster'));
  await assert.rejects(run('snapshot', async () => { const e = new Error('The operation was aborted.'); e.name = 'AbortError'; throw e; }),
    /^Error: bsh:timeout$/);
  await assert.rejects(run('documents', portal([], {[POSTBOX]: () => response({nothing: true})})), /^Error: bsh:invalid$/);
});

test('documents find attachment ids in forms, links and fields, once each', async () => {
  const docs = JSON.parse(await run('documents', portal([])));
  assert.deepEqual(docs.map(d => d.id), ['att-1', 'att 2', 'att-3']);
  // one contract named -> vtn; two named or none -> no vtn
  assert.equal(docs[0].vtn, '0030022200102');
  assert.equal(docs[1].vtn, undefined);
  assert.equal(docs[2].vtn, undefined);
  assert.deepEqual([docs[0].date, docs[0].title], ['31.01.2026', 'Jahreskontoauszug 300222 A 02']);
  // only what the core reads
  assert.ok(docs.every(d => Object.keys(d).every(k => ['id', 'date', 'title', 'vtn'].includes(k))));
});

test('portal sample (#290): data envelope, numeric type/phase, month groups', async () => {
  const sample = {status: 'success', data: {contracttype: 1, contractphase: 1,
    coredata: {bsn: 'D02', vtn: '0000000000000', owners: ['DO NOT EXPORT']}, debit: {directdebits: [{iban: 'DO NOT EXPORT'}]},
    transactions: [{year: 2026, saldo: '&#43; 0,00', month: [
      {name: 'Nov', fullname: 'November', entries: [{amount: '&#43; 0,00', subject: 'Einzug Zahlung', day: 3}]}]}]}};
  const snap = JSON.parse(await run('snapshot', portal([], {[DETAILS]: () => response(sample)})));
  assert.deepEqual(snap.contracts[0].details, {contracttype: 1, contractphase: 1, transactions: sample.data.transactions});
  assert.ok(!JSON.stringify(snap).includes('DO NOT EXPORT'));
});

test('postbox sample (#290): the message id is the attachment of type "data" messages only', async () => {
  const messages = {status: 'success', data: {messages: [
    {id: '12345678', date: '16.01.2026', title: 'Ihr Jahreskontoauszug 2025', type: 'data', read: true, text: 'text',
     deletable: false, typeName: 'jahreskontoauszug', nbaurl: 'UrlAnfrage'},
    {id: '87654321', date: '17.01.2026', title: 'Ihre Anfrage', type: 'message', read: true, text: 'text',
     deletable: true, typeName: 'service_wop', nbaurl: 'UrlAnfrage'},
    // an explicit attachment id wins over the message id
    {id: '11111111', date: '18.01.2026', title: 'Info', type: 'data',
     text: '<form action="/bin/bshweb/postbox/attachment"><input type="hidden" name="id" value="att-9"></form>'}]}};
  const docs = JSON.parse(await run('documents', portal([], {[POSTBOX]: () => response(messages)})));
  assert.deepEqual(docs.map(d => [d.id, d.date, d.title]),
    [['12345678', '16.01.2026', 'Ihr Jahreskontoauszug 2025'], ['att-9', '18.01.2026', 'Info']]);
});

test('pdf downloads one attachment and rejects anything else', async () => {
  const calls = [];
  const b64 = await run('pdf', portal(calls), {args: {id: 'att 2'}});
  assert.match(Buffer.from(b64, 'base64').toString(), /^%PDF-1\.7 synthetic att 2$/);
  assert.equal(new URL(calls[0].url).searchParams.get('id'), 'att 2');
  const html = portal([], {'/bin/bshweb/postbox/attachment': () =>
    response(new TextEncoder().encode('<html>login</html>').buffer)});
  await assert.rejects(run('pdf', html, {args: {id: 'x'}}), /^Error: bsh:not-pdf$/);
  await assert.rejects(run('pdf', portal([]), {args: {id: ''}}), /^Error: bsh:invalid$/);
  const declared = portal([], {'/bin/bshweb/postbox/attachment': () =>
    response(new ArrayBuffer(8), {headers: {'content-length': String(26 * 1024 * 1024)}})});
  await assert.rejects(run('pdf', declared, {args: {id: 'x'}}), /^Error: bsh:too-large$/);
});

test('pdf reads in chunks and stops at 25 MB without a length', async () => {
  const chunk = new Uint8Array(1024 * 1024);
  chunk.set(new TextEncoder().encode('%PDF-'));
  let delivered = 0, cancelled = false;
  const endless = portal([], {'/bin/bshweb/postbox/attachment': () => ({ok: true, status: 200, headers: {get: () => null},
    arrayBuffer: async () => { throw new Error('must stream, not buffer'); },
    body: {getReader: () => ({
      read: async () => { delivered += chunk.length; return {done: false, value: chunk}; },
      cancel: async () => { cancelled = true; }})}})});
  await assert.rejects(run('pdf', endless, {args: {id: 'x'}}), /^Error: bsh:too-large$/);
  assert.ok(cancelled);
  assert.ok(delivered <= 26 * 1024 * 1024, `read ${delivered} bytes`);
  // a stream within the limit is joined in order
  const parts = ['%PDF-1.7 ', 'part two'].map(t => new TextEncoder().encode(t));
  const small = portal([], {'/bin/bshweb/postbox/attachment': () => ({ok: true, status: 200, headers: {get: () => null},
    body: {getReader: () => ({read: async () => parts.length ? {done: false, value: parts.shift()} : {done: true}, cancel: async () => {}})}})});
  assert.equal(Buffer.from(await run('pdf', small, {args: {id: 'x'}}), 'base64').toString(), '%PDF-1.7 part two');
});

test('the Linux flow runs exactly the scripts of the Swift file', () => {
  const qml = readFileSync(new URL('../GiroCrabLinux/qml/SchwaebischHallWebLoginFlow.qml', `file://${__filename}`), 'utf8');
  const linux = Object.fromEntries([...qml.matchAll(/readonly property string (\w+): `((?:\\[\s\S]|[^`\\])*)`/g)]
    .map(m => [m[1], vm.runInNewContext('`' + m[2] + '`')]));
  // Swift strips the closing delimiter's indentation (4 spaces) from every line.
  const dedent = s => s.split('\n').map(l => l.startsWith('    ') ? l.slice(4) : l.trimStart()).join('\n');
  assert.deepEqual(Object.keys(linux).sort(), ['documents', 'pdf', 'prelude', 'probe', 'snapshot']);
  for (const name of Object.keys(linux))
    assert.equal(linux[name], dedent(scripts[name]), `${name} differs: run python3 -I scripts/gen-schwaebisch-hall-qml.py`);
});
