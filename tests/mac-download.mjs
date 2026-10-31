import assert from 'node:assert/strict';
import handler, { newestMacDownload } from '../website/api/mac-download.mjs';
import windowsHandler from '../website/api/windows-download.mjs';
import {newestReleaseAsset} from '../website/lib/release-download.mjs';
const release = (version, extra = {}) => ({ tag_name:`mac-v${version}`, assets:[{name:'Clinqy.dmg',browser_download_url:`https://github.com/Amrit-Nigam/clinqy/releases/download/mac-v${version}/Clinqy.dmg`}],...extra });
assert.match(newestMacDownload([release('0.2.3'),release('0.3.0')]),/mac-v0.3.0/);
assert.match(newestMacDownload([release('0.3.0'),release('0.10.0')]),/mac-v0.10.0/);
assert.match(newestMacDownload([release('99.0.0',{draft:true}),release('98.0.0',{prerelease:true}),release('0.2.3')]),/mac-v0.2.3/);
assert.equal(newestMacDownload([{tag_name:'windows-v9.0.0',assets:release('9.0.0').assets}]),null);
assert.equal(newestMacDownload([release('0.3.0',{assets:[]})]),null);
assert.equal(newestMacDownload([release('0.3.0',{assets:[{name:'Clinqy.dmg',browser_download_url:'https://evil.test/app'}]})]),null);
assert.equal(newestMacDownload({error:'rate limited'}),null);
const windows=(version,extra={})=>({tag_name:`windows-v${version}`,assets:['Clinqy-windows-x64.zip','install.ps1'].map(name=>({name,browser_download_url:`https://github.com/Amrit-Nigam/clinqy/releases/download/windows-v${version}/${name}`})),...extra});
assert.equal(newestReleaseAsset([release('99.0.0'),windows('0.3.2'),windows('0.3.3')],'windows').version,'0.3.3');
assert.match(newestReleaseAsset([windows('0.3.3')],'windows','installer').url,/install.ps1$/);
assert.equal(newestReleaseAsset([windows('0.3.4',{draft:true}),windows('0.3.3')],'windows').version,'0.3.3');
assert.equal(newestReleaseAsset([windows('0.3.4',{assets:windows('0.3.4').assets.slice(0,1)}),windows('0.3.3')],'windows').version,'0.3.3');
const originalFetch=globalThis.fetch;
function response(){return {status:null,headers:null,writeHead(status,headers){this.status=status;this.headers=headers;},end(){}};}
try {
 globalThis.fetch=async()=>({ok:true,json:async()=>[release('0.3.0')]});
 const newest=response();await handler({method:'GET'},newest);
 assert.equal(newest.status,302);assert.match(newest.headers.Location,/mac-v0.3.0/);assert.match(newest.headers['Cache-Control'],/s-maxage/);
 globalThis.fetch=async()=>{throw Error('offline');};
 const offline=response();await handler({method:'HEAD'},offline);
 assert.equal(offline.status,503);assert.equal(offline.headers.Location,undefined);assert.equal(offline.headers['Cache-Control'],'no-store');
 globalThis.fetch=async()=>({ok:true,json:async()=>[release('50.0.0'),windows('0.3.3')]});
 const win=response();await windowsHandler({method:'GET',url:'/api/windows-download?asset=installer'},win);
 assert.match(win.headers.Location,/windows-v0.3.3\/install.ps1$/);
 const jsonResponse=response();jsonResponse.end=function(body){this.body=body;};
 await windowsHandler({method:'GET',url:'/api/windows-download?format=json'},jsonResponse);
 assert.equal(jsonResponse.status,200);assert.equal(JSON.parse(jsonResponse.body).version,'0.3.3');
 const invalid=response();await windowsHandler({method:'GET',url:'/api/windows-download?asset=bad'},invalid);assert.equal(invalid.status,400);
 const rejected=response();await handler({method:'POST'},rejected);assert.equal(rejected.status,405);
} finally {globalThis.fetch=originalFetch;}
console.log('PASS independent Mac/Windows downloads and installers, published versions, semantic ordering, drafts, incomplete assets, safe redirects, no stale downgrades during outages, and HTTP methods');

// Keep the three copyable Windows install commands identical; a stray shell token breaks setup.
const {readFileSync}=await import('node:fs');
const promptSource=readFileSync(new URL('../website/src/site/setupPrompt.ts',import.meta.url),'utf8');
const windowsPrompt=JSON.parse(promptSource.match(/^export const SETUP_PROMPT_WINDOWS = (".*")$/m)[1]);
const installLine=windowsPrompt.split('\n').find(line=>line.includes('powershell -NoProfile')).trim();
const siteSource=readFileSync(new URL('../website/src/site/Site.tsx',import.meta.url),'utf8');
const siteInstall=siteSource.match(/const WIN_INSTALL = `([^`]+)`/)[1];
assert.equal(installLine,`powershell -NoProfile -ExecutionPolicy Bypass -Command "${siteInstall}"`);
assert.ok(readFileSync(new URL('../README.md',import.meta.url),'utf8').includes(installLine));
console.log('PASS website, README and agent prompt share the same Windows install command');
