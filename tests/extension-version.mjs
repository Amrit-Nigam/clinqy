import fs from 'node:fs';
import assert from 'node:assert/strict';
const read=file=>fs.readFileSync(new URL('../'+file,import.meta.url),'utf8');
const version=JSON.parse(read('extension/manifest.json')).version;
assert.equal(read('extension/bridge.js').match(/const SCRIPT_VERSION = "([^"]+)"/)[1],version);
assert.equal(read('Sources/Clinqy/BrowserBridge.swift').match(/static let extensionVersion = "([^"]+)"/)[1],version);
assert.equal(read('windows/crates/clinqy-core/src/bridge.rs').match(/EXTENSION_VERSION: &str = "([^"]+)"/)[1],version);
console.log('PASS shared extension version matches both Mac and Windows bridge expectations');
