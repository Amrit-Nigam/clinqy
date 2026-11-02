import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const timers = new Map(); let nextTimer=0, reduced=false, host;
const animations=[];
function element() {
 const classes=new Set();
 return {isConnected:false, attributes:{}, style:{setProperty(k,v){this[k]=v;}}, textContent:'',
  setAttribute(k,v){this.attributes[k]=v;}, remove(){this.isConnected=false;},
  classList:{toggle(k,on){on?classes.add(k):classes.delete(k);},remove(k){classes.delete(k);},contains(k){return classes.has(k);}},
  getBoundingClientRect(){return {left:32,top:64};}, getAnimations(){return [];},
  animate(frames,options){animations.push({frames,options});},querySelector(){return this;}};
}
const nodes={'.cursor':element(),'.ring':element(),'.label':element()};
let markup='';
const document={title:'Fixture page',head:{},documentElement:{append(el){el.isConnected=true;}},createElement(){
 host=element();host.attachShadow=()=>({set innerHTML(v){markup=v;},querySelector(k){return nodes[k];}});return host;
}};
const window={};window.top=window;
const context=vm.createContext({window,document,innerWidth:1024,innerHeight:768,
 matchMedia:()=>({matches:reduced}),MutationObserver:class{observe(){}disconnect(){}},
 setTimeout(fn,delay){const id=++nextTimer;timers.set(id,{fn,delay});return id;},clearTimeout(id){timers.delete(id);}});
vm.runInContext(fs.readFileSync(new URL('../extension/activity.js',import.meta.url),'utf8'),context);
const activity=window.__clinqyActivity;
activity.update({kind:'working'});
assert(host.isConnected);
assert(!markup.includes('.edge, .badge { display:none'));
assert(markup.includes('opacity:1'));
assert(markup.includes('role="status" aria-live="polite"'));
assert.equal(host.attributes['aria-hidden'],undefined);
assert(host.style.cssText.includes('pointer-events:none!important'));
assert.equal(document.title,'◉ Clinqy · Fixture page');
assert(nodes['.cursor'].style.transform.includes('839px'));
activity.update({kind:'click',x:240,y:180});
assert.equal(nodes['.label'].textContent,'Clinqy is clicking');
assert.equal(nodes['.cursor'].style.transform,'translate(243px,183px)');
assert(animations.length>=2);
activity.setCaptureHidden(true);assert.equal(host.style.visibility,'hidden');
activity.setCaptureHidden(false);assert.equal(host.style.visibility,'visible');
reduced=true;
activity.update({kind:'type',x:400,y:200});
assert(!nodes['.cursor'].classList.contains('typing'));
assert(markup.includes('.edge, .cursor.typing svg { animation:none; }'));
activity.update({active:false});
assert(!host.isConnected);assert.equal(document.title,'Fixture page');assert.equal(timers.size,0);
activity.update();
const expiry=[...timers.values()].find(t=>t.delay===180000);
assert(expiry);expiry.fn();assert(!host.isConnected);assert.equal(document.title,'Fixture page');
console.log('PASS visible working state, action cursor, accessible status, reduced motion, capture hiding, cleanup and stale-session expiry');
