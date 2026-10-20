// Launches the CRA dev server with stdin held open by a pipe that is never
// written to nor closed. react-scripts 3.x registers
//   process.stdin.on('end', () => process.exit())
// whenever stdout is not a TTY, so a detached launcher whose stdin is a closed
// handle makes the dev server quit right after "Starting the development
// server...". Run this with tools\dev-start.ps1, or directly:
//   node spug_api/tools/dev-web.cjs
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const web = path.resolve(__dirname, '..', '..', 'spug_web');
const logs = path.resolve(__dirname, '..', 'logs');

// Raw fds rather than WriteStream objects: spawn only accepts stream entries that
// already expose a numeric .fd, and a fresh stream has fd === null.
const out = fs.openSync(path.join(logs, 'web.log'), 'w');
const err = fs.openSync(path.join(logs, 'web.err'), 'w');

const child = spawn(process.execPath, [path.join(web, 'node_modules', 'react-app-rewired', 'bin', 'index.js'), 'start'], {
  cwd: web,
  env: { ...process.env, BROWSER: 'none', PORT: '3000', NODE_OPTIONS: '--openssl-legacy-provider' },
  stdio: ['pipe', out, err],
});

child.on('exit', (code, signal) => {
  fs.appendFileSync(path.join(logs, 'web.err'), `[dev-web] react-app-rewired exited code=${code} signal=${signal}\n`);
  process.exit(code === null ? 1 : code);
});
