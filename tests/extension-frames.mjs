// Exercise real iframe discovery, including viewport changes, without the user's browser.
import vm from 'node:vm';
import fs from 'node:fs';
import assert from 'node:assert/strict';
function frame(src, x, y, w, h, style={}) {
 return {src,clientLeft:1,clientTop:2,clientWidth:w,clientHeight:h,
  getBoundingClientRect:()=>({left:x,top:y}),style};
}
const lab=frame('https://lab.test/editor',20,100,1000,650);
const hidden=frame('https://hidden.test',0,0,1000,650,{display:'none'});
const below=frame('https://below.test',0,1500,1000,650);
const tiny=frame('https://tiny.test',0,0,1,1);
const context=vm.createContext({MutationObserver:class{observe(){}disconnect(){}},window:{},crypto:{randomUUID:()=> 'document'},innerWidth:1280,innerHeight:900,
 document:{querySelectorAll:()=>[lab,hidden,below,tiny]},
 getComputedStyle:el=>({display:'block',visibility:'visible',opacity:'1',paddingLeft:'0',paddingTop:'0',...el.style})});
vm.runInContext(fs.readFileSync(new URL('../extension/page.js',import.meta.url),'utf8'),context);
let boxes=context.window.__clinqy.frameBoxes().frames;
assert.equal(boxes.length,1);
assert.equal(boxes[0].src,lab.src);
assert.deepEqual([boxes[0].x,boxes[0].y,boxes[0].w,boxes[0].h],[21,102,1000,650]);
const token=boxes[0].nodeToken;
context.innerHeight=1800;
boxes=context.window.__clinqy.frameBoxes().frames;
assert.equal(boxes.length,2);
assert.equal(boxes[0].nodeToken,token);
context.innerHeight=80;
assert.equal(context.window.__clinqy.frameBoxes().frames.length,0);
console.log('PASS embedded lab frame discovery, hidden/tiny/offscreen exclusion, live viewport resize and stable node identity');

const main={innerText:'Editor project content',contains:()=>false};
const dialog={innerText:'Lab Help: switch back to the old lab experience',
 getBoundingClientRect:()=>({left:0,right:500,top:0,bottom:200,width:500,height:200}),style:{}};
const hiddenDialog={...dialog,innerText:'Hidden old confirmation',style:{display:'none'}};
context.location={href:'https://course.test/lab'};
context.document.title='Course lab';context.document.body=main;
context.document.querySelector=()=>main;
context.document.querySelectorAll=selector=>selector.includes('[role="status"]') ? [] : [dialog,hiddenDialog];
const text=context.window.__clinqy.readText().text;
assert.ok(text.includes('Editor project content'));
assert.ok(text.includes('Lab Help'));
assert.ok(!text.includes('Hidden old confirmation'));
main.innerText='Long editor text '.repeat(1000);
assert.ok(context.window.__clinqy.readText().text.includes('Lab Help'));
console.log('PASS verification reads visible portalled lab dialogs alongside main content, excluding hidden confirmations');

// Same-origin inline identity is obtained from the extension's isolated-world helper.
const inline = frame('', 0, 0, 400, 200);
inline.contentWindow = {location: {href: 'about:srcdoc'}, __clinqy: {documentID: 'inline-doc'}};
context.innerHeight = 900;
context.document.querySelectorAll = () => [inline];
assert.equal(context.window.__clinqy.frameBoxes().frames[0].inlineDocumentID, 'inline-doc');
Object.defineProperty(inline, 'contentWindow', {get() { throw Error('sandboxed origin'); }});
assert.equal(context.window.__clinqy.frameBoxes().frames[0].inlineDocumentID, null);

const event = {addListener() {}};
const worker = vm.createContext({chrome: {runtime: {onStartup:event,onInstalled:event},
  alarms: {create() {},onAlarm:event}, tabs: {onRemoved:event}, debugger: {onDetach:event,onEvent:event}},
  WebSocket: class {}, navigator:{}, setTimeout, clearTimeout, setInterval() {}, console, URL});
vm.runInContext(fs.readFileSync(new URL('../extension/bridge.js', import.meta.url), 'utf8'), worker);
const subs = new Map([
 [7, {url:'about:srcdoc',documentID:'one',snapshotID:'s1',viewport:{w:400,h:200}}],
 [8, {url:'about:srcdoc',documentID:'two',snapshotID:'s2',viewport:{w:400,h:200}}],
 [9, {url:'about:blank',documentID:'three',snapshotID:'s3',viewport:{w:400,h:200}}]
]);
let match = worker.associateFrames([{inlineDocumentID:'two',w:400,h:200},{inlineDocumentID:'one',w:400,h:200}], subs, new Set());
assert.deepEqual(Array.from(match.matches, m=>m.frameId), [8,7]);
match = worker.associateFrames([{src:'about:srcdoc',w:400,h:200}], subs, new Set());
assert.equal(match.matches.length, 0, 'never associate inline frames by shared URL or size');
match = worker.associateFrames([{frameId:7,w:400,h:200}], subs, new Set());
assert.equal(match.matches.length, 0, 'frame ID alone does not establish same-origin inline access');
match = worker.associateFrames([{inlineDocumentID:'old-document',w:400,h:200}], subs, new Set());
assert.equal(match.matches.length, 0, 'navigation invalidates inline document association');
match = worker.associateFrames([{inlineDocumentID:'three',w:400,h:200}], subs, new Set());
assert.equal(match.matches[0].frameId, 9, 'about:blank requires exact helper identity too');
worker.liveBoxes = [{nodeToken:1,inlineDocumentID:'replacement',x:0,y:0,w:400,h:200}];
vm.runInContext('call = async () => ({frames: liveBoxes})', worker);
assert.equal(await worker.frameChainStable(1,{frameBoxes:{7:{nodeToken:1,inlineDocumentID:'one',parent:0,x:0,y:0,w:400,h:200}}},7),false);
console.log('PASS inline frame exact-document association, sandbox refusal, ambiguous URL/size refusal and navigation invalidation');
