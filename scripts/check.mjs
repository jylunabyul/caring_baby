import { readFileSync, readdirSync } from 'node:fs';
import assert from 'node:assert/strict';
import vm from 'node:vm';
const html = readFileSync('app/index.html', 'utf8');
for (const match of html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)) {
  if (match[1].trim()) new vm.Script(match[1]);
}
new vm.Script(readFileSync('app/config.example.js', 'utf8'));
for (const file of readdirSync('n8n').filter(f => f.endsWith('.json'))) {
  const workflow = JSON.parse(readFileSync(`n8n/${file}`, 'utf8'));
  assert.equal(workflow.active, false, `${file}: keep imported workflows inactive`);
  const names = new Set(workflow.nodes.map(n => n.name));
  assert.equal(names.size, workflow.nodes.length);
  for (const [source, outputs] of Object.entries(workflow.connections)) {
    assert(names.has(source));
    for (const groups of Object.values(outputs)) for (const group of groups) {
      for (const edge of group) assert(names.has(edge.node), `Unknown node: ${edge.node}`);
    }
  }
  for (const node of workflow.nodes) {
    if (node.parameters.jsCode) new vm.Script('(async function(){' + node.parameters.jsCode + '\n})');
  }
  console.log(`OK: ${file}`);
}
console.log('OK: browser JavaScript syntax and example configuration');
