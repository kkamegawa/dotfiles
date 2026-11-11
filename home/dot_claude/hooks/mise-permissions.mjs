import {
  accessSync,
  constants,
  existsSync,
  lstatSync,
  mkdirSync,
  openSync,
  readFileSync,
  realpathSync,
  renameSync,
  closeSync,
  fsyncSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

const groups = ['allow', 'ask', 'deny'];

function fail(message) {
  throw new Error(message);
}

function readJsonFile(filePath, description, optional = false) {
  if (!existsSync(filePath)) {
    if (optional) return null;
    fail(`${description} does not exist: ${filePath}`);
  }
  if (!lstatSync(filePath).isFile()) fail(`${description} must be a regular file: ${filePath}`);
  try {
    return JSON.parse(readFileSync(filePath, 'utf8'));
  } catch (error) {
    fail(`Could not read ${description}: ${error.message}`);
  }
}

function readBytes(filePath) {
  if (!existsSync(filePath)) return null;
  if (!lstatSync(filePath).isFile()) fail(`Expected a regular file: ${filePath}`);
  return readFileSync(filePath);
}

function ensureRegularOrAbsent(filePath) {
  if (existsSync(filePath) && !lstatSync(filePath).isFile()) {
    fail(`Refusing to replace a non-file path: ${filePath}`);
  }
}

function writeAtomic(filePath, contents, mode = 0o600, expectedContents = undefined) {
  ensureRegularOrAbsent(filePath);
  const oldMode = existsSync(filePath) ? lstatSync(filePath).mode & 0o777 : mode;
  const temporaryPath = `${filePath}.${process.pid}.${Math.random().toString(16).slice(2)}.tmp`;
  let descriptor;
  try {
    descriptor = openSync(temporaryPath, 'wx', oldMode);
    writeFileSync(descriptor, contents);
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    if (expectedContents !== undefined && !readBytes(filePath)?.equals(expectedContents)) {
      fail(`File changed during update; refusing to replace it: ${filePath}`);
    }
    renameSync(temporaryPath, filePath);
  } catch (error) {
    if (descriptor !== undefined) closeSync(descriptor);
    rmSync(temporaryPath, { force: true });
    throw error;
  }
}

function commandNames(settings) {
  const names = new Set();
  for (const group of groups) {
    for (const rule of settings.permissions?.[group] ?? []) {
      if (typeof rule !== 'string') continue;
      const match = /^Bash\(([A-Za-z0-9_.+-]+)(?:\)| |:\*)/.exec(rule);
      if (match) names.add(match[1]);
    }
  }
  return names;
}

function ambiguousPromptNames(permissions) {
  const prefixes = new Set();
  for (const group of ['ask', 'deny']) {
    for (const rule of permissions[group] ?? []) {
      if (typeof rule !== 'string') continue;
      const match = /^Bash\(([A-Za-z0-9_.+-]+)(.*)\)$/.exec(rule);
      if (!match) continue;
      const suffix = match[2];
      if (suffix !== '' && !suffix.startsWith(' ') && !suffix.startsWith(':*')) {
        prefixes.add(match[1]);
      }
    }
  }
  return prefixes;
}

function validateBins(input, relevantNames) {
  let bins;
  try {
    bins = JSON.parse(input);
  } catch (error) {
    fail(`mise bin-paths returned invalid JSON: ${error.message}`);
  }
  if (!Array.isArray(bins)) fail('mise bin-paths JSON must be an array.');

  const validated = [];
  for (const bin of bins) {
    if (!bin || typeof bin.name !== 'string') fail('mise bin-paths contains an invalid executable name.');
    if (!relevantNames.has(bin.name)) continue;
    if (!/^[A-Za-z0-9_.+-]+$/.test(bin.name)) fail(`mise bin-paths contains an unsupported executable name: ${bin.name}`);
    if (typeof bin.path !== 'string' || !path.isAbsolute(bin.path) || path.basename(bin.path) !== bin.name) {
      fail(`mise bin-paths contains an invalid absolute path for ${bin.name}.`);
    }
    if (/[\0\r\n*?()[\]]/.test(bin.path)) fail(`mise bin-paths contains an unsafe path for ${bin.name}.`);
    try {
      if (!statSync(bin.path).isFile()) fail(`mise executable is not a file: ${bin.path}`);
      accessSync(bin.path, constants.X_OK);
    } catch {
      fail(`mise executable is missing or not executable: ${bin.path}`);
    }
    validated.push({ name: bin.name, path: bin.path });
  }
  return validated;
}

function runMise(misePath, home, args) {
  const result = spawnSync(misePath, ['-C', home, ...args], {
    cwd: home,
    encoding: 'utf8',
    env: { ...process.env, MISE_CONFIG_FILE: path.join(home, '.config', 'mise', 'config.toml') },
    maxBuffer: 32 * 1024 * 1024,
  });
  if (result.error) fail(`Could not run mise ${args[0]}: ${result.error.message}`);
  if (result.status !== 0) {
    fail(`mise ${args[0]} failed with exit code ${result.status}: ${(result.stderr || '').trim()}`);
  }
  return result.stdout;
}

function discoverBins(misePath, home) {
  const inventoryText = runMise(misePath, home, ['ls', '--installed', '--json']);
  let inventory;
  try {
    inventory = JSON.parse(inventoryText);
  } catch (error) {
    fail(`mise ls returned invalid JSON: ${error.message}`);
  }
  if (!inventory || typeof inventory !== 'object' || Array.isArray(inventory)) {
    fail('mise ls JSON must be an object keyed by tool name.');
  }

  const selectors = [];
  for (const [name, records] of Object.entries(inventory)) {
    if (!name || /[\0\r\n\t ]/.test(name) || !Array.isArray(records)) {
      fail('mise ls contains an invalid tool entry.');
    }
    for (const record of records) {
      if (!record || typeof record.version !== 'string' || typeof record.installed !== 'boolean') {
        fail(`mise ls contains an invalid installed-version record for ${name}.`);
      }
      if (!record.installed) continue;
      if (!record.version || /[\0\r\n\t ]/.test(record.version)) {
        fail(`mise ls contains an unsupported version selector for ${name}.`);
      }
      selectors.push(`${name}@${record.version}`);
    }
  }

  const active = runMise(misePath, home, ['bin-paths', '--json']);
  const versioned = selectors.length > 0
    ? runMise(misePath, home, ['bin-paths', '--json', '--', ...selectors])
    : '[]';
  let activeBins;
  let versionedBins;
  try {
    activeBins = JSON.parse(active);
    versionedBins = JSON.parse(versioned);
  } catch (error) {
    fail(`mise bin-paths returned invalid JSON: ${error.message}`);
  }
  if (!Array.isArray(activeBins) || !Array.isArray(versionedBins)) {
    fail('mise bin-paths JSON must be an array.');
  }
  return JSON.stringify([...activeBins, ...versionedBins]);
}

function executablePathToken(executablePath) {
  if (/[\0\r\n*?()[\]']/.test(executablePath)) return null;
  if (/^[A-Za-z0-9_./:+-]+$/.test(executablePath)) return executablePath;
  return `'${executablePath}'`;
}

function miseShimDirectory(home) {
  const configured = process.env.MISE_SHIMS_DIR
    ?? (process.env.MISE_DATA_DIR ? path.join(process.env.MISE_DATA_DIR, 'shims') : null)
    ?? (process.env.XDG_DATA_HOME ? path.join(process.env.XDG_DATA_HOME, 'mise', 'shims') : null)
    ?? path.join(home, '.local', 'share', 'mise', 'shims');
  return path.isAbsolute(configured) ? configured : path.resolve(home, configured);
}

function equivalentRule(rule, name, executablePath) {
  if (typeof rule !== 'string') return null;
  const match = /^Bash\((.*)\)$/.exec(rule);
  if (!match) return null;
  const command = match[1];
  if (!command.startsWith(name)) return null;
  const suffix = command.slice(name.length);
  if (suffix !== '' && !suffix.startsWith(' ') && !suffix.startsWith(':*')) return null;
  if (/[\0\r\n]/.test(suffix)) return null;
  const pathToken = executablePathToken(executablePath);
  return pathToken === null ? null : `Bash(${pathToken}${suffix})`;
}

function readOwnership(ownershipPath) {
  const ledger = readJsonFile(ownershipPath, 'ownership ledger', true);
  if (ledger === null) return [];
  if (ledger.version !== 1 || !Array.isArray(ledger.rules)) fail('Ownership ledger has an unsupported format.');
  return ledger.rules.map((entry) => {
    if (!entry || !groups.includes(entry.group) || typeof entry.rule !== 'string') {
      fail('Ownership ledger contains an invalid rule entry.');
    }
    return { group: entry.group, rule: entry.rule };
  });
}

function main() {
  const args = process.argv.slice(2);
  const discover = args[0] === '--discover';
  const [settingsPath, ownershipPath, misePath] = discover ? args.slice(1) : args;
  if (!settingsPath || !ownershipPath || (discover && !misePath) || process.argv.length !== (discover ? 6 : 4)) {
    fail('Usage: node mise-permissions.mjs <settingsPath> <ownershipPath> | --discover <settingsPath> <ownershipPath> <misePath>');
  }
  if (!path.isAbsolute(settingsPath) || !path.isAbsolute(ownershipPath)) {
    fail('Settings and ownership paths must be absolute.');
  }

  ensureRegularOrAbsent(settingsPath);
  ensureRegularOrAbsent(ownershipPath);
  const settingsBytes = readBytes(settingsPath);
  let settings;
  try {
    settings = JSON.parse(settingsBytes.toString('utf8'));
  } catch (error) {
    fail(`Could not read Claude settings: ${error.message}`);
  }
  if (!settings || typeof settings !== 'object' || Array.isArray(settings)) fail('Claude settings must be a JSON object.');
  if (settings.permissions !== undefined && (!settings.permissions || typeof settings.permissions !== 'object' || Array.isArray(settings.permissions))) {
    fail('Claude settings permissions must be a JSON object.');
  }
  const originalSettingsJson = JSON.stringify(settings);

  const oldOwnership = readOwnership(ownershipPath);
  const permissions = settings.permissions ?? {};
  for (const group of groups) {
    if (permissions[group] !== undefined && !Array.isArray(permissions[group])) {
      fail(`Claude settings permissions.${group} must be an array.`);
    }
  }
  const namesWithAmbiguousPromptRules = ambiguousPromptNames(permissions);

  const home = process.env.HOME;
  if (typeof home !== 'string' || !path.isAbsolute(home)) fail('HOME must be an absolute path.');
  const input = discover ? discoverBins(misePath, home) : readFileSync(0, 'utf8');
  const bins = validateBins(input, commandNames(settings));
  const miseExecutable = discover ? realpathSync(misePath) : null;

  for (const owned of oldOwnership) {
    const rules = permissions[owned.group];
    if (!rules) continue;
    const index = rules.indexOf(owned.rule);
    if (index >= 0) rules.splice(index, 1);
  }

  const executablePaths = new Map();
  const shimDirectory = miseShimDirectory(home);
  for (const bin of bins) {
    const equivalents = new Set(executablePaths.get(bin.name) ?? []);
    equivalents.add(bin.path);
    const shimPath = path.join(shimDirectory, bin.name);
    if (miseExecutable) {
      try {
        const shimInfo = lstatSync(shimPath);
        if (shimInfo.isSymbolicLink() && statSync(shimPath).isFile()) {
          accessSync(shimPath, constants.X_OK);
          if (realpathSync(shimPath) === miseExecutable) equivalents.add(shimPath);
        }
      } catch (error) {
        if (error.code !== 'ENOENT') throw error;
      }
    }
    executablePaths.set(bin.name, [...equivalents]);
  }

  const nextOwnership = [];
  if (settings.permissions === undefined) settings.permissions = permissions;
  for (const group of groups) {
    const existingRules = permissions[group] ?? [];
    const additions = new Set();
    for (const originalRule of existingRules) {
      if (typeof originalRule !== 'string' || !originalRule.startsWith('Bash(')) continue;
      for (const [name, paths] of executablePaths) {
        if (group === 'allow' && [...namesWithAmbiguousPromptRules].some((prefix) => name.startsWith(prefix))) continue;
        for (const executablePath of paths) {
          const generated = equivalentRule(originalRule, name, executablePath);
          if (generated && generated !== originalRule) additions.add(generated);
        }
      }
    }
    for (const rule of additions) {
      if (existingRules.includes(rule)) continue;
      existingRules.push(rule);
      nextOwnership.push({ group, rule });
    }
    if (permissions[group] !== undefined || existingRules.length > 0) permissions[group] = existingRules;
  }

  const ownershipBytes = readBytes(ownershipPath);
  const settingsChanged = JSON.stringify(settings) !== originalSettingsJson;
  const trailingNewline = settingsBytes.toString('utf8').endsWith('\n') ? '\n' : '';
  const nextSettings = `${JSON.stringify(settings, null, 2)}${trailingNewline}`;
  const nextLedger = `${JSON.stringify({ version: 1, rules: nextOwnership }, null, 2)}\n`;
  const settingsMode = lstatSync(settingsPath).mode & 0o777;

  mkdirSync(path.dirname(ownershipPath), { recursive: true });
  const previousLedger = ownershipBytes;
  const unionRules = [...new Map([...oldOwnership, ...nextOwnership].map((entry) => [`${entry.group}\0${entry.rule}`, entry])).values()];
  const unionLedger = `${JSON.stringify({ version: 1, rules: unionRules }, null, 2)}\n`;
  try {
    if (previousLedger?.toString('utf8') !== unionLedger) writeAtomic(ownershipPath, unionLedger);
    if (settingsChanged) writeAtomic(settingsPath, nextSettings, settingsMode, settingsBytes);
    if (previousLedger?.toString('utf8') !== nextLedger) writeAtomic(ownershipPath, nextLedger);
  } catch (error) {
    const currentSettings = readBytes(settingsPath);
    if (!settingsChanged || currentSettings?.equals(settingsBytes)) {
      if (previousLedger === null) rmSync(ownershipPath, { force: true });
      else if (readBytes(ownershipPath)?.toString('utf8') !== previousLedger.toString('utf8')) {
        writeAtomic(ownershipPath, previousLedger);
      }
    }
    throw error;
  }
}

try {
  main();
} catch (error) {
  console.error(`mise Claude permissions: ${error.message}`);
  process.exitCode = 1;
}
