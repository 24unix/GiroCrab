// Exercise the actual raw JavaScript embedded in the Swift web view.
const {test} = require('node:test');
const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const source = readFileSync(new URL('../GiroCrabApp/Sources/GiroCrabUI/FnzUI.swift', `file://${__filename}`), 'utf8');
const scripts = Object.fromEntries([...source.matchAll(/static let (\w+) = #"""\n([\s\S]*?)\n    """#/g)].map(m=>[m[1],m[2]]));
function run(name, fetch, extra={}) {
  const context = vm.createContext({fetch, location:{hostname:'portal.fnz.de',origin:'https://portal.fnz.de',pathname:'/(test)/portal.fnz.de/EOY/EL/39/'},
    crypto:require('node:crypto').webcrypto, btoa:s=>Buffer.from(s,'binary').toString('base64'), ...extra});
  return vm.runInContext(`(async()=>{${scripts[name]}})()`, context);
}
const response = data=>({ok:true,json:async()=>data});

test('login probe requires FNZ, authenticated route and completed approval',()=>{
  const probe=(hostname,pathname,hash,text,links=[])=>vm.runInNewContext(scripts.probe,
    {location:{hostname,pathname,hash},document:{body:{innerText:text},querySelector:selector=>links.includes(selector)?{}:null}});
  assert.equal(probe('portal.fnz.de','/EOY/EL/39/','#/eo/home','Abmelden Depot'),true);
  assert.equal(probe('other.example','/EOY/EL/39/','#/eo/home','Abmelden Depot'),false);
  assert.equal(probe('portal.fnz.de','/EOY/EL/1/','#/login','Bitte in FNZsecure freigeben'),false);
  assert.equal(probe('portal.fnz.de','/EOY/EL/39/','#/eo/home','Anmeldung wird bestätigt'),false);
  assert.equal(probe('portal.fnz.de','/EOY/EL/39/','#/eo/home','Depot Konto flex Bestand',
    ['a[href*="#/eo/bestand/"]']),true);
  assert.equal(probe('portal.fnz.de','/EOY/EL/39/','#/eo/home','Depot Bestand',
    ['a[href*="/services/logout"]']),true);
  assert.equal(probe('portal.fnz.de','/EOY/EL/1/','#/login','Depot',
    ['a[href*="/services/logout"]']),false);
});

test('mailbox reads every page and archive, deduplicating across both',async()=>{
  const calls=[];
  const first=Array.from({length:100},(_,i)=>({id:`doc-${i}`}));
  const result=JSON.parse(await run('documents',async(url,options)=>{
    const body=JSON.parse(options.body); calls.push({url,options,body});
    return response({documents:body.postboxCategoryAndStateFilter.archived?[{id:'doc-0'},{id:'archived'}]:body.indexFrom==='0'?first:[{id:'last'}]});
  }));
  assert.equal(result.length,102);
  assert.equal(calls.length,3);
  assert.equal(calls[1].body.indexFrom,'100');
  assert.equal(calls[2].body.postboxCategoryAndStateFilter.archived,true);
  for(const {url,options} of calls){
    assert.equal(url,'https://portal.fnz.de/(test)/portal.fnz.de/EOY/EL/39/eox/rest/postbox/getCustomerPostboxForCustomer');
    assert.equal(options.credentials,'include');
    assert.equal(options.headers['X-EOX-CLIENT-VERSION'],'26.4.01');
  }
});

test('mailbox rejects HTTP, malformed and endlessly repeated pages',async()=>{
  await assert.rejects(run('documents',async()=>({ok:false,status:403})),/HTTP 403/);
  await assert.rejects(run('documents',async()=>response({documents:[{}]})),/ohne ID/);
  await assert.rejects(run('documents',async()=>response({documents:{}})),/Dokumentenliste/);
  const repeated=Array.from({length:100},(_,i)=>({id:`doc-${i}`}));
  await assert.rejects(run('documents',async()=>response({documents:repeated})),/Wiederholte/);
});

test('overview requires the authenticated account schema',async()=>{
  const result=JSON.parse(await run('overview',async(url,options)=>{
    assert.ok(url.endsWith('/depot/getDepotOverviewDataForEndCustomer'));
    assert.equal(options.credentials,'include');
    return response({ownerGroups:[]});
  }));
  assert.ok(Array.isArray(result.ownerGroups));
  await assert.rejects(run('overview',async()=>({ok:false,status:401})),/HTTP 401/);
  await assert.rejects(run('overview',async()=>response({login:true})),/Kontoübersicht/);
});

test('PDF uses the current session prefix and safely encodes the document ID',async()=>{
  const pdf=Buffer.from('%PDF-1.7\nsynthetic');
  const result=await run('pdf',async(url,options)=>{
    assert.equal(url,'https://portal.fnz.de/(test)/portal.fnz.de/p/postkorb.aspx?docId=a%26b%3D%22&download=true');
    assert.equal(options.credentials,'include');
    return {ok:true,headers:{get:()=> 'Application/PDF; charset=binary'},arrayBuffer:async()=>pdf};
  },{id:'a&b="'});
  assert.deepEqual(Buffer.from(result,'base64'),pdf);
});

test('PDF rejects expired-session HTML, HTTP errors and non-PDF bytes',async()=>{
  for(const [ok,ct,bytes] of [[false,'application/pdf','%PDF-1.7'],[true,'text/html','<html>login</html>'],[true,'application/pdf','<html>login</html>']]){
    await assert.rejects(run('pdf',async()=>({ok,headers:{get:()=>ct},arrayBuffer:async()=>Buffer.from(bytes)}),{id:'test'}),/FNZ:/);
  }
});

function snapshotPortal({repeat=false, changingTotal=false, unavailable=false}={}) {
  const calls=[];
  const account=(ref,id)=>({depotOrCashAccount:{externalDepotNumber:{externalDepotNumber:ref},depotOrCashAccountId:{depotId:{id}}}});
  const group=id=>({investmentDepots:[account(`D${id}`,id)],cashAccounts:[account(`C${id}`,id)],managedDepots:[],stockDepots:[],preciousMetalDepots:[]});
  const fetch=async(url,options)=>{
    const path=url.split('eox/rest/')[1], body=options.body?JSON.parse(options.body):null;
    calls.push({path,body,options});
    if(path==='depot/getDepotOverviewDataForEndCustomer') return response({ownerGroups:[group('1'),group('2')]});
    if(path.startsWith('depot-inventory/')) return response({resourceIsUnavailable:unavailable,investmentDepotInventories:[]});
    if(path.includes('getMigratedAabTransactionOverview')) return response({migratedAabTransactions:[],totalTransactions:0});
    const page=Number(body.pagination.page);
    if(path.startsWith('cash-account-transaction/')) return response({cashAccountId:{id:body.cashAccountId},iban:{iban:'TEST'},cashAccountTransactions:[],totalCashAccountTransactions:0});
    if(path.startsWith('order-transaction/')) return response({orderTransactions:[{orderTransactionId:{orderId:{orderDate:'2025-01-01',orderNumber:repeat?'same':String(page)},orderTransactionKindId:'1',optional:null,discriminator:''}}],totalOrderTransactions:changingTotal && page>0?3:2});
    throw new Error(`Unexpected path ${path}`);
  };
  return {fetch,calls};
}

test('snapshot fetches every owner, cash and depot with complete history filters and pagination',async()=>{
  const portal=snapshotPortal();
  const result=JSON.parse(await run('snapshot',portal.fetch));
  assert.equal(result.version,1);
  assert.equal(result.details.length,4);
  assert.equal(result.totalsOnly,0);
  assert.deepEqual(result.details.map(d=>d.accountRef),['D1','C1','D2','C2']);
  for(const d of result.details.filter(d=>d.kind==='investment')) {
    assert.equal(d.transactions.length,2); assert.equal(d.historicalTransactions.length,0);
  }
  const transactions=portal.calls.filter(c=>c.body?.dateFrom);
  assert.equal(transactions.length,6);
  for(const {body,options} of transactions) {
    assert.equal(body.dateFrom,'2000-01-01');
    assert.match(body.dateTo,/^\d{4}-\d{2}-\d{2}$/);
    assert.equal(body.showIngoingTransactions,true); assert.equal(body.showOutgoingTransactions,true);
    assert.equal(body.pagination.pageSize,'100');
    assert.equal(options.method,'POST'); assert.equal(options.credentials,'include');
    if(body.depotId) {
      assert.equal(body.showTaxTransactions,true); assert.equal(body.showOtherTransactions,true);
      assert.equal(body.includeCanceledTransactions,true); assert.equal(body.showTransactionsOnDepotLevel,true);
    }
  }
  assert.equal(portal.calls.filter(c=>c.path.includes('getMigratedAab')).length,2);
});

test('snapshot refuses repeated pages, changed totals, unavailable inventories and HTTP errors',async()=>{
  await assert.rejects(run('snapshot',snapshotPortal({repeat:true}).fetch),/Wiederholte/);
  await assert.rejects(run('snapshot',snapshotPortal({changingTotal:true}).fetch),/Unvollständige/);
  await assert.rejects(run('snapshot',snapshotPortal({unavailable:true}).fetch),/nicht verfügbar/);
  await assert.rejects(run('snapshot',async()=>({ok:false,status:401})),/HTTP 401/);
  await assert.rejects(run('snapshot',async()=>response({ownerGroups:[{}]})),/Unvollständige/);
});
