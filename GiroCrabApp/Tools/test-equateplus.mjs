// Offline integration tests for the exact script injected into WebKit.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
import {webcrypto} from 'node:crypto';
const source = readFileSync(new URL('../Sources/GiroCrabUI/EquatePlusUI.swift',import.meta.url),'utf8');
const hook = source.match(/static let hook = #"""\n([\s\S]*?)\n    """#/)[1];
const prefix = '/EquatePlusParticipant2/services/';
const profile = {participant:{userId:'test-user'},reportingCurrency:{code:'EUR'},privateAddress:'do not export'};
function portal(host='www.equateplus.com', options={}) {
  const calls = [];
  const document = {scripts:[],login:false,querySelector(selector) { return selector === '#loginForm' && this.login ? {} : null; }};
  class XHR {
    open() {} setRequestHeader() {}
    addEventListener(name, callback) { this[name] = callback; }
  }
  const context = vm.createContext({URL,Headers,Request,Response,AbortController,crypto:webcrypto,setTimeout,clearTimeout,btoa,
    location:new URL('https://' + host + '/EquatePlusParticipant2/'),document,XMLHttpRequest:XHR,
    fetch:async (url,init={}) => {
      const u = new URL(url,'https://' + host);
      calls.push({u,init});
      if (options.postUnsupported && u.pathname.endsWith('planSummary/get') && init.method === 'POST')
        return new Response('',{status:405});
      if (options.expired && u.pathname.endsWith('planDetails/get')) return new Response('',{status:401});
      if (u.pathname.endsWith('/download') && options.download) return options.download(u,calls.filter(x => x.u.pathname.endsWith('/download')).length);
      let data;
      if (u.pathname.endsWith('user/get')) data = options.invalidProfile ? {loginRequired:true} : profile;
      else if (u.pathname.endsWith('documents/library')) data = {documents:[{id:'doc1',date:'2011-05-26T00:00:00',description:'Test',documentType:'Dividendenbestätigung',plan:null,
        url:'/services/statements/download?documentId=doc1',secret:'do not export'}]};
      else if (u.pathname.endsWith('planSummary/get')) data = {entries:[{id:'test-plan',planModuleId:'test-module',name:'Test Programm'}]};
      else if (u.pathname.endsWith('planDetails/get')) data = {name:'Test Programm',planModuleId:'test-module',csrfpId:'rotated-token',secret:'do not export',
        totals:[{type:'TOTAL',quantity:{amount:1.25},value:{amount:125}}],
        entries:[{vehicle:'TEST',productType:'RSU',marketPrice:{amount:100,unit:{code:'EUR'}},canTrade:false,entries:[{VEHICLE:'Test RSU',LOCKED_QTY:{amount:1.25}}]}]};
      else data = {ok:true};
      return new Response(JSON.stringify(data),{headers:{'content-type':'application/json'}});
    }});
  vm.runInContext('window = globalThis',context);
  vm.runInContext(hook,context);
  return {context,document,calls};
}
for (const host of ['www.equateplus.com','www.emea.equateplus.com','www.na.equateplus.com']) {
  const {context:c,document,calls} = portal(host);
  assert.equal(c.__gcEquatePlus.ready(),false);
  await c.fetch(prefix+'config/get',{headers:{csrfpId:'test-csrf'}});
  await new Promise(resolve => setTimeout(resolve,10));
  assert.equal(c.__gcEquatePlus.ready(),false,'configuration is not a successful login');
  await c.fetch(prefix+'user/get?_cId=test-client',{headers:{csrfpId:'test-csrf','EQUATE-CSRF2-TOKEN-PARTICIPANT2':'test-csrf2'}});
  await new Promise(resolve => setTimeout(resolve,10));
  assert.equal(c.__gcEquatePlus.ready(),true);
  document.login = true;
  assert.equal(c.__gcEquatePlus.ready(),false,'2FA/login form blocks import');
  document.login = false;
  const snapshot = await c.__gcEquatePlus.collect();
  const data = JSON.parse(snapshot);
  assert.equal(data.version,2);
  assert.equal(data.plans[0].moduleId,"test-module");
  assert.equal(data.plans[0].details.entries[0].entries[0].LOCKED_QTY.amount,1.25);
  assert.equal(data.plans[0].details.totals[0].quantity.amount,1.25);
  assert.equal(data.plans[0].details.totals[0].type,'TOTAL');
  assert.equal(data.plans[0].details.entries[0].vehicle,'TEST');
  assert.equal(data.plans[0].details.entries[0].productType,'RSU');
  assert(!snapshot.includes('test-csrf') && !snapshot.includes('rotated-token') && !snapshot.includes('do not export'));
  const request = calls.find(x=>x.u.pathname.endsWith('planDetails/get'));
  assert.equal(request.u.origin,'https://'+host);
  assert.equal(request.init.headers['EQUATE-CSRF2-TOKEN-PARTICIPANT2'],'test-csrf2');
  assert.equal(request.u.searchParams.get('_cId'),'test-client');
  assert.equal(JSON.parse(request.init.body).id,'test-plan');
  assert.equal(request.init.redirect,'error');
}
for (const options of [{postUnsupported:true},{expired:true}]) {
  const {context:c,calls} = portal('www.equateplus.com',options);
  const xhr = new c.XMLHttpRequest();
  xhr.open('GET',prefix+'user/get');
  xhr.setRequestHeader('csrfpId','test-xhr-token');
  xhr.status = 200; xhr.responseText = JSON.stringify(profile); xhr.load();
  assert.equal(c.__gcEquatePlus.ready(),true,'XHR authentication response enables import');
  if (options.expired) {
    await assert.rejects(c.__gcEquatePlus.collect());
    assert.equal(c.__gcEquatePlus.ready(),false,'expired session disables import');
  } else {
    await c.__gcEquatePlus.collect();
    assert(calls.some(x=>x.u.pathname.endsWith('planSummary/get') && x.init.method === 'GET'));
  }
}
// Regression: the signed-in shell may contain bootstrap tokens but never
// make a user/get request through the installed fetch/XHR observers.
{
  const {context:c,document,calls} = portal();
  document.scripts = [{textContent:'csrfRegisterAjax("csrfpId", "bootstrap-csrf");'}];
  c.equateCsrfToken2 = 'bootstrap-csrf2';
  assert.equal(c.__gcEquatePlus.ready(),false);
  document.login = true;
  assert.equal(await c.__gcEquatePlus.probe(),false);
  assert.equal(calls.length,0,'no session probe while on a login or 2FA form');
  document.login = false;
  assert.equal(await c.__gcEquatePlus.probe(),true,'actively verifies bootstrapped login');
  assert.equal(c.__gcEquatePlus.ready(),true);
  assert.equal(calls.length,1);
  assert(calls[0].u.pathname.endsWith('user/get'));
  assert.equal(calls[0].init.headers['EQUATE-CSRF2-TOKEN-PARTICIPANT2'],'bootstrap-csrf2');
  await c.__gcEquatePlus.probe();
  assert.equal(calls.length,1,'verified session does not keep polling the server');
}
{
  const {context:c,document,calls} = portal('www.equateplus.com',{invalidProfile:true});
  document.scripts = [{textContent:'csrfRegisterAjax("csrfpId", "bootstrap-csrf");'}];
  assert.equal(await c.__gcEquatePlus.probe(),false,'a login/error payload is not authentication');
  assert.equal(c.__gcEquatePlus.ready(),false);
  await c.__gcEquatePlus.probe();
  assert.equal(calls.length,1,'unsuccessful session probes are throttled');
}
// Optional PDF import: list and download only through the portal's two download services.
{
  const pdf = () => new Response(new TextEncoder().encode('%PDF-1.4 test'),{headers:{'content-type':'application/pdf'}});
  const status = () => new Response(JSON.stringify({mimeType:'application/pdf',message:'In Bearbeitung ...'}),{headers:{'content-type':'application/json'}});
  const signedIn = options => {
    const p = portal('www.equateplus.com',options);
    p.document.scripts = [{textContent:'csrfRegisterAjax("csrfpId", "bootstrap-csrf");'}];
    p.context.equateCsrfToken2 = 'bootstrap-csrf2';
    return p;
  };
  {
    const {context:c,calls} = signedIn({download:() => pdf()});
    assert.equal(await c.__gcEquatePlus.probe(),true);
    const list = await c.__gcEquatePlus.documents();
    assert(!list.includes('do not export'),'only whitelisted fields leave the page');
    const docs = JSON.parse(list);
    assert.equal(docs[0].id,'doc1');
    const library = calls.find(x=>x.u.pathname.endsWith('documents/library'));
    assert.equal(library.init.method,'POST');
    assert.equal(JSON.parse(library.init.body).$type,'Object');
    const encoded = await c.__gcEquatePlus.pdf(docs[0].url);
    assert.equal(Buffer.from(encoded,'base64').toString('latin1'),'%PDF-1.4 test');
    const request = calls.find(x=>x.u.pathname.endsWith('statements/download'));
    assert.equal(request.u.origin,'https://www.equateplus.com');
    assert.equal(request.u.searchParams.get('documentId'),'doc1');
    assert.equal(request.u.searchParams.get('downloadType'),'attachment');
    assert.equal(request.init.redirect,'error');
    assert.equal(request.init.headers['EQUATE-CSRF2-TOKEN-PARTICIPANT2'],'bootstrap-csrf2');
    const before = calls.length;
    for (const bad of ['https://evil.example/services/documents/download?documentId=a','/services/documents/download?documentId=a&x=1',
      '/services/other/download?documentId=a','/services/documents/download?documentId=../x','',null])
      await assert.rejects(c.__gcEquatePlus.pdf(bad),bad);
    assert.equal(calls.length,before,'rejected addresses are never requested');
  }
  {
    // the portal first answers with a short status while it prepares the file
    const {context:c,calls} = signedIn({download:(u,n) => n === 1 ? status() : pdf()});
    await c.__gcEquatePlus.probe();
    const encoded = await c.__gcEquatePlus.pdf('/services/documents/download?documentId=doc2');
    assert.equal(Buffer.from(encoded,'base64').toString('latin1'),'%PDF-1.4 test');
    assert.equal(calls.filter(x=>x.u.pathname.endsWith('/download')).length,2);
  }
  {
    const {context:c} = signedIn({download:() => new Response('<html>',{headers:{'content-type':'text/html'}})});
    await c.__gcEquatePlus.probe();
    await assert.rejects(c.__gcEquatePlus.pdf('/services/documents/download?documentId=doc3'),/kein PDF \(text\/html, 6 B\)/);
  }
  {
    // a few bytes in front of the header are still a PDF
    const {context:c} = signedIn({download:() => new Response(new TextEncoder().encode('\n\n%PDF-1.4 test'),{headers:{'content-type':'application/octet-stream'}})});
    await c.__gcEquatePlus.probe();
    const encoded = await c.__gcEquatePlus.pdf('/services/documents/download?documentId=doc5');
    assert.equal(Buffer.from(encoded,'base64').toString('latin1'),'\n\n%PDF-1.4 test');
    assert.equal(c.__gcEquatePlus.lastAttempts(),'1');
  }
  {
    const {context:c} = signedIn({download:() => new Response('',{status:403})});
    await c.__gcEquatePlus.probe();
    await assert.rejects(c.__gcEquatePlus.pdf('/services/documents/download?documentId=doc4'));
    assert.equal(c.__gcEquatePlus.ready(),false,'a rejected session disables further downloads');
  }
}
for (const host of ['evil.example','www.equateplus.com.evil.example','participant.tst.equateplus.com']) {
  assert.equal(portal(host).context.__gcEquatePlus,undefined);
}
console.log('EquatePlus: snapshot, documents, login, CSRF isolation and datacenter tests passed.');
