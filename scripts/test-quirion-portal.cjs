// Run the actual scripts embedded in QuirionUI.swift, as for FNZ.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const source = readFileSync(new URL('../GiroCrabApp/Sources/GiroCrabUI/QuirionUI.swift', `file://${__filename}`), 'utf8');
const hook = source.match(/static let hook = #"""\n([\s\S]*?)\n    """#/)[1];
const api = 'https://api.it-aws-prod.quirion.de/legacy/v1/';
const response = (data, status=200) => ({ok: status >= 200 && status < 300,status,json:async()=>data,text:async()=>data});
function page(fetch, origin='https://banking.quirion.de') {
  class XHR { open() {} setRequestHeader() {} addEventListener() {} }
  const window = {fetch};
  const context = vm.createContext({window,location:{origin,href:origin+'/'},Request,Headers,URL,
    XMLHttpRequest:XHR,AbortController,setTimeout,clearTimeout,Date,atob});
  vm.runInContext(hook, context);
  return window;
}
async function authenticate(window) {
  await window.fetch(api+'user', {headers:{Authorization:'Bearer synthetic-test-token'}});
  await Promise.resolve();
}
function server(calls) {
  return async (url, options={}) => {
    calls.push({url,options});
    const u=new URL(url), path=u.pathname;
    if (path.endsWith('/user')) return response({user:{passportNumber:'DO NOT EXPORT'},businessPartner:[
      {businessPartnerId:1,name:'Test Owner',status:'OPEN',balanceDate:'2026-11-13',createdAt:'2019-01-01'}]});
    if (path.endsWith('/business-partners/1')) return response({businessPartnerId:1,
      clearing:{accountHolder:'Test Owner',iban:'TEST-CLEARING',sortKey:'BA#CLEARING#1',currency:'EUR',exchangeRate:1,balance:0},
      reference:{iban:'DO NOT EXPORT'},products:[{ipsId:2,businessPartnerId:1,name:'Test Portfolio',status:'OPEN',createdAt:'2019-01-01'}]});
    if (path.endsWith('/products/2')) return response({liquid:{iban:'TEST-LIQUID'},depotItems:[]});
    if (path.endsWith('/transactions')) return response([{amount:-1,status:'CLOSED',bookingDate:'2019-01-01'}]);
    if (path.endsWith('/postbox/download')) return response(JSON.stringify(Buffer.from('%PDF-1.7 synthetic').toString('base64')));
    if (path.endsWith('/postbox')) return response({documents:[{id:'doc-1',businessPartnerId:1,displayName:'Test statement',createdAt:'2019-01-01',fileName:'DO NOT EXPORT'}]});
    throw new Error('Unexpected request '+url);
  };
}

test('full history is separate for clearing and products; secrets stay inside the page', async()=>{
  const calls=[], w=page(server(calls));
  assert.equal(w.__gcQuirion.ready(),false);
  await authenticate(w);
  assert.equal(w.__gcQuirion.ready(),true);
  calls.length=0;
  const snapshot=await w.__gcQuirion.collect(), data=JSON.parse(snapshot);
  assert.equal(data.partners.length,1);
  assert.equal(data.partners[0].products.length,1);
  assert.equal(data.partners[0].clearingTransactions.length,1);
  assert.equal(data.partners[0].products[0].transactions.length,1);
  assert(!snapshot.includes('DO NOT EXPORT'));
  assert(!snapshot.includes('synthetic-test-token'));
  const tx=calls.filter(c=>c.url.endsWith('/transactions'));
  assert.equal(tx.length,2);
  assert.equal(JSON.parse(tx[0].options.body).ipsId,undefined);
  assert.equal(JSON.parse(tx[1].options.body).ipsId,2);
  for(const c of calls) {
    assert.equal(c.options.credentials,'omit');
    assert.equal(c.options.redirect,'error');
    assert.equal(c.options.headers.Authorization,'Bearer synthetic-test-token');
  }
  for(const c of tx) {
    const body=JSON.parse(c.options.body);
    assert(body.range>=3000);
    assert.equal(body.status,'CLOSED');
    assert.equal(c.options.method,'POST');
  }
  const docs=await w.__gcQuirion.documents();
  assert(!docs.includes('DO NOT EXPORT'));
  const pdf=await w.__gcQuirion.pdf('doc-1');
  assert(Buffer.from(pdf,'base64').toString().startsWith('%PDF-'));
  const download=calls.find(c=>c.url.endsWith('/postbox/download'));
  assert.equal(download.options.body,JSON.stringify({doc:'doc-1'}));
});

test('only successful requests to the real API can establish authorization', async()=>{
  const w=page(async()=>response({},200));
  await w.fetch('https://api.it-aws-prod.quirion.de.evil.example/legacy/v1/user',{headers:{authorization:'bad'}});
  assert.equal(w.__gcQuirion.ready(),false);
  const failed=page(async()=>response({},401));
  await authenticate(failed);
  assert.equal(failed.__gcQuirion.ready(),false);
  assert.equal(page(server([]),'https://evil.example').__gcQuirion,undefined);
});

test('expired sessions and partial portfolios cannot produce an import snapshot', async()=>{
  let fail=false;
  const base=server([]);
  const w=page(async(url,options)=>fail?response({},401):base(url,options));
  await authenticate(w); fail=true;
  await assert.rejects(w.__gcQuirion.collect(),/HTTP 401/);
  assert.equal(w.__gcQuirion.ready(),false);
  const partial=page(async(url,options)=>url.includes('/products/2')?response({liquid:{}}):base(url,options));
  await authenticate(partial);
  await assert.rejects(partial.__gcQuirion.collect(),/Unvollständiges Depot/);
});

test('invalid PDF responses are rejected', async()=>{
  const base=server([]);
  const w=page(async(url,options)=>url.endsWith('/postbox/download')?response(Buffer.from('<html>login</html>').toString('base64')):base(url,options));
  await authenticate(w);
  await assert.rejects(w.__gcQuirion.pdf('doc-1'),/kein PDF/);
});
