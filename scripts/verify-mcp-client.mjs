// Uses only the synthetic test server and token created by MCPServerTests.
import assert from 'node:assert/strict';
import { Client, StreamableHTTPClientTransport } from '../Runtime/AgentRuntime/node_modules/@modelcontextprotocol/client/dist/index.mjs';

const client = new Client({ name: 'Morrow verification', version: '1.0.0' });
const token = 'fixture-token';
const transport = new StreamableHTTPClientTransport(new URL(process.argv[2]), {
  requestInit: { headers: { Authorization: `Bearer ${token}` } },
});
const deadline = setTimeout(() => { console.error('MCP verification timed out'); process.exit(1); }, 15000);
try {
  await client.connect(transport);
  const { tools } = await client.listTools();
  assert.equal(tools.length, 8);
  assert(tools.every(tool => tool.annotations.readOnlyHint));
  await client.ping();
  const accounts = await client.callTool({ name: 'list_accounts', arguments: {} });
  assert.equal(accounts.structuredContent.accounts[0].id, 'fixture');
  const mail = await client.callTool({ name: 'get_mail', arguments: { id: 'fixture-mail' } });
  assert.equal(mail.structuredContent.next_offset, 20000);
  const missing = await client.callTool({ name: 'get_mail', arguments: { id: 'missing' } });
  assert.equal(missing.isError, true);
  console.log('Official MCP client: handshake, 8 tools verified, ping, paginated mail and tool errors passed.');
} finally {
  clearTimeout(deadline);
  await client.close();
}
