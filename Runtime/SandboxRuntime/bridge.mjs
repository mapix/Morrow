import { SandboxManager, SandboxRuntimeConfigSchema } from '@anthropic-ai/sandbox-runtime';
import { spawn } from 'node:child_process';
import { realpath, stat, lstat, readdir, readFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { randomUUID } from 'node:crypto';

let input = '';
const installed = JSON.parse(await readFile(new URL('./node_modules/@anthropic-ai/sandbox-runtime/package.json', import.meta.url), 'utf8'));
if (installed.version !== '0.0.81') throw new Error('Pinned sandbox runtime version mismatch');
for await (const data of process.stdin) { input += data.toString('utf8'); if (Buffer.byteLength(input) > 65536) throw new Error('Sandbox request too large'); }
const request = JSON.parse(input);
const root = await realpath(request.workspace);
const metadata = await stat(root);
if (!/MorrowResponder-[a-z0-9_-]+$/i.test(root) || metadata.uid !== process.getuid() || (metadata.mode & 0o077) !== 0) throw new Error('Unowned responder workspace');
if (typeof request.command !== 'string' || Buffer.byteLength(request.command) > 16384) throw new Error('Invalid command');
const domains = request.allowedDomains ?? [];
if (domains.length > 20 || domains.some(d => typeof d !== 'string' || !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(d) || d.endsWith('.localhost'))) throw new Error('Invalid network allowlist');
const timeout = Math.min(60, Math.max(1, Number(request.timeoutSeconds) || 15));
const mailSocket = join(root, 'input', 'mail-data.sock');
if (request.mailData === true && !(await lstat(mailSocket)).isSocket()) throw new Error('Missing host mail data socket');
const python = request.pythonExecutable ? await realpath(request.pythonExecutable) : null;
if (python && !(await stat(python)).isFile()) throw new Error('Invalid Python runtime');
// Keep SDK proxy plumbing; never inherit the desktop's credentials, shell
// startup hooks or other process environment into executable tools.
const safeEnv = { PATH: process.env.PATH ?? '/usr/bin:/bin', HOME: root, TMPDIR: join(root, 'tmp'), CLAUDE_CODE_TMPDIR: join(root, 'tmp'), LANG: 'en_US.UTF-8' };
for (const key of Object.keys(process.env)) delete process.env[key];
Object.assign(process.env, safeEnv);
const config = SandboxRuntimeConfigSchema.parse({
  network: { allowedDomains: domains.map(domain => domain + ':443'), deniedDomains: [], strictAllowlist: true, allowLocalBinding: false, allowUnixSockets: request.mailData === true ? [mailSocket] : [] },
  filesystem: {
    denyRead: ['/Users', '/Volumes', '/private/var', '/var', '/private/tmp', '/tmp', '/etc', '/private/etc', '/Library/Keychains', '/Library/Application Support', '/opt', '/usr/local'],
    allowRead: [root, process.execPath, ...(python ? [python, dirname(dirname(python))] : []), '/private/var/select/sh', '/private/etc/ssl', '/private/etc/resolv.conf'],
    allowWrite: [join(root, 'output'), join(root, 'tmp')],
    denyWrite: [join(root, 'input')]
  },
  enableWeakerNetworkIsolation: false,
  enableWeakerNestedSandbox: false,
  allowAppleEvents: false
});
let child;
// Decode only the pinned SDK's quote() grammar into argv. No shell expansion
// is performed, and an unfamiliar wrapper fails closed on an SDK upgrade.
function sdkArgv(text) {
  const words = []; let word = '', active = false;
  for (let i = 0; i < text.length;) {
    const c = text[i];
    if (/\s/.test(c)) { if (active) { words.push(word); word = ''; active = false; } i++; continue; }
    active = true;
    if (c === "'") { const end = text.indexOf("'", i + 1); if (end < 0) throw new Error('Invalid SDK quoting'); word += text.slice(i + 1, end); i = end + 1; continue; }
    if (text.slice(i, i + 3) === `"'"`) { word += "'"; i += 3; continue; }
    if (!/[A-Za-z0-9_./:=@+,-]/.test(c)) throw new Error('Unsupported SDK wrapper grammar');
    word += c; i++;
  }
  if (active) words.push(word);
  if (words[0] !== 'env') throw new Error('Unexpected SDK wrapper executable');
  const p = words.indexOf('-p');
  if (p < 1 || words[p - 1] !== '/usr/bin/sandbox-exec' || !words[p + 1].startsWith('(version 1)')) throw new Error('Missing SRT Seatbelt profile');
  // SRT's general developer profile allows Keychain RPC. Responders receive
  // an additional denial in the SAME profile; macOS cannot nest sandboxes.
  words[p + 1] += '\n(deny mach-lookup (global-name-prefix "com.apple.securityd"))\n(deny mach-lookup (global-name "com.apple.securityd.xpc"))\n(deny mach-lookup (global-name "com.apple.SecurityServer"))\n(deny appleevent-send)\n';
  return words;
}
function stop() { if (child?.pid) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} } }
async function checkFileBudget() {
  let total = 0, count = 0;
  async function visit(path, depth = 0) {
    if (depth > 8) throw new Error('depth');
    for (const name of await readdir(path)) {
      if (++count > 128) throw new Error('files');
      const entry = join(path, name), info = await lstat(entry);
      if (info.isDirectory()) await visit(entry, depth + 1);
      else if (info.isFile()) { total += info.size; if (total > 16 * 1024 * 1024) throw new Error('bytes'); }
    }
  }
  await visit(join(root, 'output')); await visit(join(root, 'tmp'));
}
process.on('SIGTERM', () => { stop(); process.exit(143); });
process.on('SIGINT', () => { stop(); process.exit(130); });
try {
  await SandboxManager.initialize(config);
  const id = randomUUID();
  const quote = text => "'" + text.replaceAll("'", "'\\''") + "'";
  const command = `ulimit -t ${timeout}; ulimit -f 8192; exec /bin/sh -c ${quote(request.command)}`;
  const wrapped = await SandboxManager.wrapWithSandbox(command, '/bin/sh', undefined, undefined, { commandId: id, commandText: request.command });
  const argv = sdkArgv(wrapped);
  const result = await new Promise((resolve, reject) => {
    let out = [], err = [], size = 0, timedOut = false, truncated = false, fileBudgetExceeded = false, inspecting = false;
    child = spawn('/usr/bin/env', argv.slice(1), { cwd: root, detached: true, stdio: ['ignore', 'pipe', 'pipe'], env: safeEnv });
    const timer = setTimeout(() => { timedOut = true; stop(); }, timeout * 1000);
    const quotaTimer = setInterval(async () => {
      if (inspecting) return; inspecting = true;
      try {
        await checkFileBudget();
      } catch { fileBudgetExceeded = true; stop(); }
      finally { inspecting = false; }
    }, 100);
    const capture = destination => data => {
      if (size + data.length > 131072) { truncated = true; stop(); return; }
      size += data.length; destination.push(data);
    };
    child.stdout.on('data', capture(out)); child.stderr.on('data', capture(err));
    child.on('error', error => { clearTimeout(timer); clearInterval(quotaTimer); reject(error); });
    child.on('close', async (exitCode, signal) => {
      clearTimeout(timer); clearInterval(quotaTimer); stop();
      try { await checkFileBudget(); } catch { fileBudgetExceeded = true; }
      const stderr = Buffer.concat(err).toString('utf8');
      const violations = SandboxManager.getSandboxViolationStore().getViolationsForCommand(id).slice(0, 10);
      resolve({ exitCode: fileBudgetExceeded ? -1 : exitCode ?? -1, signal, stdout: Buffer.concat(out).toString('utf8'), stderr: fileBudgetExceeded ? 'Responder output file budget exceeded' : stderr, timedOut, truncated, violations: violations.length, runtime: 'anthropic-srt/0.0.81' });
    });
  });
  process.stdout.write(JSON.stringify(result));
} catch (error) {
  process.stdout.write(JSON.stringify({ exitCode: -1, stdout: '', stderr: String(error.message).slice(0, 2000), timedOut: false, truncated: false, violations: 0, runtime: 'anthropic-srt/0.0.81', unavailable: true }));
  process.exitCode = 1;
} finally { stop(); await SandboxManager.reset(); }
