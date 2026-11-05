import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const timers = new Map(), frames = new Map(), listeners = new Map(), viewportListeners = new Map();
let nextID=0, reduced=false, host, now=0, anchorPoint={x:240,y:180};
const animations=[];
function element() {
 const classes=new Set();
 return {isConnected:false, attributes:{}, style:{setProperty(k,v){this[k]=v;}}, textContent:'',
  setAttribute(k,v){this.attributes[k]=v;}, remove(){this.isConnected=false;},
  classList:{toggle(k,on){on?classes.add(k):classes.delete(k);},contains(k){return classes.has(k);}},
  getAnimations(){return [];}, animate(keyframes,options){animations.push({keyframes,options});}};
}
const nodes=Object.fromEntries(['.cursor','.ring','.label','.badge'].map(k=>[k,element()]));
let markup='';
const document={title:'Fixture page',documentElement:{append(el){el.isConnected=true;}},createElement(){
 host=element();host.attachShadow=()=>({set innerHTML(v){markup=v;},querySelector(k){return nodes[k];}});return host;
}};
function events(map) {return {addEventListener(k,f){map.set(k,f);},removeEventListener(k,f){if(map.get(k)===f)map.delete(k);}};}
const window={visualViewport:{offsetLeft:0,offsetTop:0,width:1024,height:768,...events(viewportListeners)},
 __clinqy:{documentID:'doc1',activityPoint:()=>anchorPoint}};window.top=window;
const context=vm.createContext({window,document,innerWidth:1024,innerHeight:768,...events(listeners),
 matchMedia:()=>({matches:reduced}),performance:{now:()=>now},
 requestAnimationFrame(fn){const id=++nextID;frames.set(id,fn);return id;},cancelAnimationFrame(id){frames.delete(id);},
 setTimeout(fn,delay){const id=++nextID;timers.set(id,{fn,delay});return id;},clearTimeout(id){timers.delete(id);}});
function flushFrames(){for(const [id,fn] of [...frames]){frames.delete(id);fn();}}
function fire(map,event){map.get(event)?.({type:event});flushFrames();}
vm.runInContext(fs.readFileSync(new URL('../extension/activity.js',import.meta.url),'utf8'),context);
const activity=window.__clinqyActivity;
activity.update({kind:'working'});
assert(host.isConnected);
assert(markup.includes('role="status" aria-live="polite"'));
assert.equal(host.attributes['aria-hidden'],undefined);
assert(host.style.cssText.includes('pointer-events:none!important'));
assert.equal(document.title,'Fixture page');
assert.equal(activity.pageTitle(),'Fixture page');
assert.equal(host.style['--w'],'1024px');assert.equal(host.style['--h'],'768px');
assert.equal(nodes['.cursor'].style.transform,'translate(24px,64px)');
activity.update({kind:'click',stage:'prepare',x:240,y:180});
assert.equal(nodes['.label'].textContent,'Moving to the control');
assert.equal(nodes['.cursor'].style.transform,'translate(240px,180px)');
assert.equal(animations.length,0,'queued input must not pulse');
activity.update({kind:'click',stage:'delivered',x:240,y:180});
assert.equal(nodes['.label'].textContent,'Clicking');assert.equal(animations.length,1);
assert.equal(nodes['.ring'].style.left,'240px');assert.equal(nodes['.ring'].style.top,'180px');
activity.update({kind:'verifying'});activity.update({heartbeat:true});
assert.equal(nodes['.label'].textContent,'Checking the result','heartbeat must not overwrite phase');
activity.update({kind:'click',stage:'prepare',localIndex:2,documentID:'doc1'});
flushFrames();anchorPoint={x:950,y:40};fire(listeners,'scroll');
assert.equal(nodes['.cursor'].style.transform,'translate(950px,40px)');
assert.equal(nodes['.badge'].style.left,'12px','badge avoids active upper-right target');
assert(nodes['.cursor'].classList.contains('label-left'));
window.visualViewport.offsetLeft=20;window.visualViewport.offsetTop=30;
window.visualViewport.width=700;window.visualViewport.height=500;
fire(viewportListeners,'resize');
assert.equal(host.style['--x'],'20px');assert.equal(host.style['--y'],'30px');
assert.equal(host.style['--w'],'700px');assert.equal(host.style['--h'],'500px');
assert.equal(nodes['.cursor'].style.opacity,'0','offscreen target must not clamp to a false position');
window.__clinqy.documentID='doc2';fire(listeners,'scroll');
assert.equal(nodes['.cursor'].style.transform,'translate(44px,94px)','stale document anchor is dropped');
activity.update({kind:'click',x:200,y:200});fire(listeners,'scroll');
assert.equal(nodes['.cursor'].style.transform,'translate(44px,94px)','raw coordinates invalidate after scrolling');
activity.setCaptureHidden(true);activity.setCaptureHidden(true);assert.equal(host.style.visibility,'hidden');
activity.setCaptureHidden(false);assert.equal(host.style.visibility,'hidden','nested captures stay hidden');
activity.setCaptureHidden(false);assert.equal(host.style.visibility,'visible');
reduced=true;activity.update({kind:'type',stage:'delivered',x:400,y:200});
assert.equal(animations.at(-1).options.duration,80);
assert(animations.at(-1).keyframes.every(f=>!f.transform),'reduced motion must not scale the pulse');
activity.update({kind:'paused'});assert.equal(host.attributes['data-phase'],'paused');
activity.update({kind:'error'});assert.equal(nodes['.label'].textContent,'Clinqy needs attention');
activity.update({active:false});
assert(!host.isConnected);assert.equal(document.title,'Fixture page');
assert.equal(timers.size,0);assert.equal(frames.size,0);assert.equal(listeners.size,0);assert.equal(viewportListeners.size,0);
activity.setCaptureHidden(true);activity.update();assert.equal(host.style.visibility,'hidden','mount during capture stays hidden');
activity.setCaptureHidden(false);assert.equal(host.style.visibility,'visible');
const expiry=[...timers.values()].find(t=>t.delay===180000);
assert(expiry);expiry.fn();assert(!host.isConnected);assert.equal(timers.size,0);
console.log('PASS activity viewport geometry, exact cursor, dispatch-only pulse, anchor invalidation, truthful phases, reduced motion, nested capture hiding and complete cleanup');
