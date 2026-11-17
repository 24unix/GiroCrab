// Offline WebKit-script contract tests. No bank, browser profile or credentials are used.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const source = fs.readFileSync('GiroCrabApp/Sources/GiroCrabUI/AdvanziaScripts.swift','utf8');
const hook = source.match(/static let hook = #"""\n([\s\S]*?)\n    """#/)[1];
const id = '00000000-0000-4000-8000-000000000001';
const base = '/api/accounts/' + id;
function environment({origin='https://mein.advanzia.com',status=200,balance=-12.34,accountId=id,currency='EUR'}={}) {
    const calls = [];
    const context = {location:{origin,href:origin+'/'}, URL,Request,Response,TextDecoder,AbortController,setTimeout,clearTimeout,
        performance:{getEntriesByType:()=>[{name:'https://mein.advanzia.com'+base+'/transactions'}]},
        XMLHttpRequest:class {open() {}},
        fetch:async (url,options)=>{
            calls.push([url,options]);
            const data=String(url).endsWith('/details')?{balance,accountId,currency,privateField:'invented-private-value'}:{transactions:[]};
            return new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json'}});
        }};
    context.window=context;
    vm.createContext(context);vm.runInContext(hook,context);
    return {context,calls};
}
(async()=>{
    let e=environment();assert.deepEqual(Array.from(e.context.__gcAdvanzia.discover()),[id]);
    const data=await e.context.__gcAdvanzia.collect(id);
    assert.equal(data.balance,'-12.34');assert.equal(data.bodies.length,1);
    assert(!JSON.stringify(data).includes('invented-private-value'));
    assert.equal(e.calls.length,2);
    for(const [url,options] of e.calls) {
        assert(url.startsWith(base+'/'));assert.equal(options.method,'GET');
        assert.equal(options.redirect,'error');assert.equal(options.credentials,'same-origin');
        assert(!('Authorization' in options.headers));
    }
    for(const status of [401,403]) {
        e=environment({status});e.context.__gcAdvanzia.discover();
        assert.equal((await e.context.__gcAdvanzia.collect(id)).error,'AUTH');
    }
    for(const settings of [{balance:null},{accountId:'00000000-0000-4000-8000-000000000002'},{currency:'USD'}]) {
        e=environment(settings);e.context.__gcAdvanzia.discover();
        assert.equal((await e.context.__gcAdvanzia.collect(id)).error,'BALANCE');
    }
    e=environment();assert.equal((await e.context.__gcAdvanzia.collect('not-a-card')).error,'ACCOUNT');assert.equal(e.calls.length,0);
    // Query parameters and /details must not prevent first-time account discovery.
    for(const suffix of ['/transactions?page=0','/details?refresh=true']) {
        e=environment();e.context.performance.getEntriesByType=()=>[{name:'https://mein.advanzia.com'+base+suffix}];
        assert.deepEqual(Array.from(e.context.__gcAdvanzia.discover()),[id]);
        assert.equal((await e.context.__gcAdvanzia.collect(id)).balance,'-12.34');
    }
    // A persisted, validated account can be fetched before the portal repeats a request.
    e=environment();e.context.performance.getEntriesByType=()=>[];
    assert.equal((await e.context.__gcAdvanzia.collect(id)).balance,'-12.34');
    for(const origin of ['https://id.advanzia.com','https://mein.advanzia.com.evil.invalid','http://mein.advanzia.com']) {
        e=environment({origin});assert.equal(e.context.__gcAdvanzia,undefined);assert.equal(e.calls.length,0);
    }
    const loginSource=fs.readFileSync('GiroCrabApp/Sources/GiroCrabUI/AdvanziaLoginAutomation.swift','utf8');
    const methodScript=loginSource.match(/static let method = #"""\n([\s\S]*?)\n    """#/)[1];
    function option(text) {return {textContent:text,children:[],disabled:false,clicked:0,
        closest(){return this},getBoundingClientRect(){return {width:30}},click(){this.clicked++}}}
    function choose(method,options,origin='https://id.advanzia.com') {
        return vm.runInNewContext('(function(){'+methodScript+'})()',{
            location:{origin},method,document:{querySelectorAll:()=>options},getComputedStyle:()=>({cursor:'pointer'})});
    }
    let sms=option('SMS-Versand'),app=option('Advanzia App');
    assert.equal(choose('app',[sms,app]),true);assert.equal(app.clicked,1);assert.equal(sms.clicked,0);
    sms=option('SMS-Versand');app=option('Advanzia-App');
    assert.equal(choose('sms',[sms,app]),true);assert.equal(sms.clicked,1);assert.equal(app.clicked,0);
    assert.equal(choose('app',[option('Advanzia-App'),option('Advanzia App')]),false);
    assert.equal(choose('app',[app],'https://evil.invalid'),false);
    // Actual public option label; the device subtitle stays fictional.
    sms=option('SMS-Versand');app=option('Authentifizierung über App');
    assert.equal(choose('app',[sms,app]),true);assert.equal(app.clicked,1);assert.equal(sms.clicked,0);
    sms=option('SMS-Versand');app=option('Authentifizierung über App');
    assert.equal(choose('sms',[sms,app]),true);assert.equal(sms.clicked,1);assert.equal(app.clicked,0);
    assert.equal(choose('app',[option('Authentifizierung über App'),option('Advanzia App')]),false);
    const appRow=option('Authentifizierung über App Fiktives Testgerät');appRow.onclick=()=>{};
    const appTitle=option('Authentifizierung über App');appTitle.closest=()=>null;
    appTitle.parentElement=appRow;
    assert.equal(choose('app',[appTitle,appRow]),true);assert.equal(appRow.clicked,1);assert.equal(appTitle.clicked,0);

    const credentials=loginSource.match(/static let credentials = #"""\n([\s\S]*?)\n    """#/)[1];
    class Input { constructor(type,autocomplete,name){this.type=type;this.autocomplete=autocomplete;this.name=name;this.id='';this._value='';}
        set value(v){this._value=v} get value(){return this._value} dispatchEvent(){} }
    const otp=new Input('text','one-time-code','otp'),user=new Input('text','username','username'),pwd=new Input('password','current-password','password');
    const submit=option('Anmelden');submit.type='submit';
    assert.equal(vm.runInNewContext('(function(){'+credentials+'})()',{
        location:{origin:'https://id.advanzia.com'},username:'invented-user',password:'invented-password',HTMLInputElement:Input,Event:class{},
        document:{querySelectorAll:s=>s==='input'?[otp,user,pwd]:[submit]}}),true);
    assert.equal(user.value,'invented-user');assert.equal(pwd.value,'invented-password');assert.equal(otp.value,'');
    const passwordOTP=new Input('password','one-time-code','otp');
    assert.equal(vm.runInNewContext('(function(){'+credentials+'})()',{
        location:{origin:'https://id.advanzia.com'},username:'invented-user',password:'invented-password',HTMLInputElement:Input,Event:class{},
        document:{querySelectorAll:s=>s==='input'?[user,passwordOTP]:[submit]}}),false);
    assert.equal(passwordOTP.value,'');
    const authSource=fs.readFileSync('GiroCrabApp/Sources/GiroCrabUI/AdvanziaAuthentication.swift','utf8');
    const authScript=name=>authSource.match(new RegExp('static let '+name+' = #"""\\n([\\s\\S]*?)\\n    """#'))[1];
    function field(name='otp') {
        const input=new Input('text','one-time-code',name);
        input.disabled=false; input.getBoundingClientRect=()=>({width:100,height:25});
        input.closest=()=>({querySelectorAll:()=>[confirm]});
        return input;
    }
    const confirm=option('Bestätigen');confirm.type='submit';confirm.innerText='Bestätigen';
    confirm.getBoundingClientRect=()=>({width:100,height:25});
    function auth(name,fields,{origin='https://id.advanzia.com',code='123456',labels=[],alerts=[]}={}) {
        return vm.runInNewContext('(function(){'+authScript(name)+'})()',{
            location:{origin},code,HTMLInputElement:Input,Event:class{},
            document:{querySelectorAll:s=>s==='input'?fields:s.includes('alert')?alerts:labels}});
    }
    const smsField=field();
    assert.equal(auth('inspect',[smsField]),'sms');
    assert.equal(auth('submit',[smsField]),true);assert.equal(smsField.value,'123456');assert.equal(confirm.clicked,1);
    assert.equal(auth('submit',[smsField],{origin:'https://evil.invalid'}),false);
    assert.equal(auth('submit',[smsField],{code:'12;alert(1)'}),false);
    assert.equal(auth('submit',[field(),field()]),false);
    assert.equal(auth('inspect',[field(),field()]),'unknown');
    const loginPassword=field('password'); loginPassword.type='password';loginPassword.autocomplete='current-password';
    assert.equal(auth('inspect',[loginPassword]),'credentials');
    assert.equal(auth('submit',[loginPassword]),false);assert.equal(loginPassword.value,'');
    const appHint=option('Bitte bestätigen Sie die Anmeldung in der Advanzia-App');
    appHint.getBoundingClientRect=()=>({width:100,height:25});
    assert.equal(auth('inspect',[],{labels:[appHint]}),'app');
    const actualTitle=option('Authentifizierung über App');actualTitle.children=[option('App')];
    actualTitle.getBoundingClientRect=()=>({width:100,height:25});
    assert.equal(auth('inspect',[],{labels:[actualTitle]}),'method');
    assert.equal(auth('inspect',[],{labels:[actualTitle,appHint]}),'method');

    assert.equal(auth('inspect',[],{alerts:[appHint]}),'rejected');
    assert.equal(auth('inspect',[smsField],{origin:'https://evil.invalid'}),'unknown');
    console.log('Advanzia portal: offline API, discovery, SMS/app states, explicit code submission and origin isolation passed');
})().catch(e=>{console.error(e);process.exit(1)});
