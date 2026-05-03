#!/usr/bin/env zx
///!dep zx@8.8.5 sha512-SNgDF5L0gfN7FwVOdEFguY3orU5AkfFZm9B5YSHog/UDHv+lvmd82ZAsOenOkQixigwH2+yyH198AwNdKhj+RA==

// batman v0 - fence-based BATS wrapper.
// See docs/plans/2026-04-25-batman-v0-design.md.
//
// Pipeline:
//   1. Split argv at `--` into (batman-args, bats-args).
//   2. Walk positional paths; recurse dirs for *.bats; group by parent dir.
//   3. Require <dir>/fence.jsonc for every group; missing => log + exit 2.
//   4. Spawn `fence --settings <dir>/fence.jsonc -- bats <bats-args> <files>`
//      per group, sequentially. Stream child stdout/stderr verbatim.
//   5. Exit 0 iff every group exited 0; otherwise 1.
//
// Wrapper diagnostics never go to stderr; they are appended to
// ${XDG_LOG_HOME:-$HOME/.local/log}/batman/batman.log per xdg_log_home(7).

import { spawn } from "node:child_process";
import * as fsp from "node:fs/promises";
import * as nodePath from "node:path";

type ParsedArgs = {
  binDirs: string[];
  noTempdirCleanup: boolean;
  hidePassing: boolean;
  dryRun: boolean;
  diagnosticsStderr: boolean;
  positional: string[];
  passthrough: string[];
};

function parseArgs(argv: string[]): ParsedArgs {
  const dashIdx = argv.indexOf("--");
  const ours = dashIdx === -1 ? argv : argv.slice(0, dashIdx);
  const passthroughBase = dashIdx === -1 ? [] : argv.slice(dashIdx + 1);

  const binDirs: string[] = [];
  const positional: string[] = [];
  let noTempdirCleanup = false;
  let hidePassing = false;
  let dryRun = false;
  let diagnosticsStderr = false;

  for (let i = 0; i < ours.length; i++) {
    const a = ours[i];
    switch (a) {
      case "--bin-dir": {
        const v = ours[++i];
        if (v === undefined) {
          throw new Error("--bin-dir requires a value");
        }
        binDirs.push(v);
        break;
      }
      case "--no-tempdir-cleanup":
        noTempdirCleanup = true;
        break;
      case "--hide-passing":
        hidePassing = true;
        break;
      case "--dry-run":
        dryRun = true;
        break;
      case "--diagnostics-stderr":
        diagnosticsStderr = true;
        break;
      default:
        if (a.startsWith("--")) {
          throw new Error(`unknown batman flag: ${a}`);
        }
        positional.push(a);
    }
  }

  // --no-tempdir-cleanup is forwarded to bats too.
  const passthrough = noTempdirCleanup
    ? ["--no-tempdir-cleanup", ...passthroughBase]
    : passthroughBase;

  return {
    binDirs,
    noTempdirCleanup,
    hidePassing,
    dryRun,
    diagnosticsStderr,
    positional,
    passthrough,
  };
}

async function discover(p: string): Promise<string[]> {
  const stat = await fsp.stat(p);
  if (stat.isFile()) return p.endsWith(".bats") ? [p] : [];
  if (!stat.isDirectory()) return [];

  const entries = await fsp.readdir(p, { withFileTypes: true });
  const out: string[] = [];
  for (const e of entries) {
    const sub = nodePath.join(p, e.name);
    if (e.isDirectory()) {
      out.push(...(await discover(sub)));
    } else if (e.isFile() && sub.endsWith(".bats")) {
      out.push(sub);
    }
  }
  return out;
}

function groupByParentDir(files: string[]): Map<string, string[]> {
  // Preserve insertion order; sort basenames for stable output.
  const groups = new Map<string, string[]>();
  for (const f of files) {
    const dir = nodePath.dirname(f);
    const base = nodePath.basename(f);
    const list = groups.get(dir);
    if (list) {
      list.push(base);
    } else {
      groups.set(dir, [base]);
    }
  }
  for (const list of groups.values()) {
    list.sort();
  }
  return groups;
}

async function logDiagnostic(
  msg: string,
  opts: { stderr?: boolean } = {},
): Promise<void> {
  if (opts.stderr) {
    process.stderr.write(`batman: ${msg}\n`);
    return;
  }
  const home = process.env.HOME ?? "";
  const logHome =
    process.env.XDG_LOG_HOME && process.env.XDG_LOG_HOME.length > 0
      ? process.env.XDG_LOG_HOME
      : nodePath.join(home, ".local/log");
  const dir = nodePath.join(logHome, "batman");
  await fsp.mkdir(dir, { recursive: true });
  const ts = new Date().toISOString();
  await fsp.appendFile(nodePath.join(dir, "batman.log"), `${ts} ${msg}\n`);
}

function buildPath(binDirs: string[]): string {
  const existing = process.env.PATH ?? "";
  // Leftmost = highest priority; preserve user-given order.
  const prefix = binDirs
    .map((d) => nodePath.resolve(d))
    .join(nodePath.delimiter);
  return prefix.length > 0
    ? `${prefix}${nodePath.delimiter}${existing}`
    : existing;
}

// hide-passing TAP filter: strip passing `ok N ...` lines and their YAML blocks.
// Mirrors the awk used by the existing bats wrapper.
function makeHidePassingFilter(): (chunk: string) => string {
  let buf = "";
  let inYaml = false;
  let show = true;
  return (chunk: string) => {
    buf += chunk;
    let out = "";
    let nl: number;
    while ((nl = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, nl);
      buf = buf.slice(nl + 1);
      if (/^  ---$/.test(line)) {
        inYaml = true;
        if (show) out += line + "\n";
        continue;
      }
      if (/^  \.\.\.$/.test(line)) {
        inYaml = false;
        if (show) out += line + "\n";
        continue;
      }
      if (inYaml) {
        if (show) out += line + "\n";
        continue;
      }
      if (/^ok /.test(line)) {
        show =
          / # [Ss][Kk][Ii][Pp]/.test(line) || / # [Tt][Oo][Dd][Oo]/.test(line);
        if (show) out += line + "\n";
        continue;
      }
      if (/^not ok /.test(line)) {
        show = true;
        out += line + "\n";
        continue;
      }
      show = true;
      out += line + "\n";
    }
    return out;
  };
}

async function runGroup(
  dir: string,
  files: string[],
  passthrough: string[],
  pathEnv: string,
  hidePassing: boolean,
  diagnosticsStderr: boolean,
): Promise<number> {
  const cfg = nodePath.join(dir, "fence.jsonc");
  const fileArgs = files.map((f) => nodePath.join(dir, f));
  const env = { ...process.env, PATH: pathEnv };

  return new Promise((resolve) => {
    const stdout = hidePassing ? "pipe" : "inherit";
    const child = spawn(
      "fence",
      ["--settings", cfg, "--", "bats", ...passthrough, ...fileArgs],
      { stdio: ["inherit", stdout, "inherit"], env },
    );

    if (hidePassing && child.stdout) {
      const filter = makeHidePassingFilter();
      child.stdout.setEncoding("utf8");
      child.stdout.on("data", (chunk: string) => {
        const out = filter(chunk);
        if (out.length > 0) process.stdout.write(out);
      });
    }

    child.on("error", (err) => {
      // Spawn failure (e.g. fence missing) - record and treat as group failure.
      void logDiagnostic(`spawn error in ${dir}: ${err.message}`, {
        stderr: diagnosticsStderr,
      });
      resolve(1);
    });
    child.on("exit", (code, signal) => {
      if (code === null) {
        resolve(signal ? 1 : 1);
      } else {
        resolve(code);
      }
    });
  });
}

async function main(): Promise<number> {
  // Pre-scan argv for --diagnostics-stderr so parse-error diagnostics
  // can also honor the flag (we can't read parsed args before parsing).
  const argv = process.argv.slice(2);
  const dashIdx = argv.indexOf("--");
  const oursPreScan = dashIdx === -1 ? argv : argv.slice(0, dashIdx);
  const preScanStderr = oursPreScan.includes("--diagnostics-stderr");

  let parsed: ParsedArgs;
  try {
    parsed = parseArgs(argv);
  } catch (e) {
    await logDiagnostic(`argv parse error: ${(e as Error).message}`, {
      stderr: preScanStderr,
    });
    return 2;
  }

  const {
    binDirs,
    hidePassing,
    dryRun,
    diagnosticsStderr,
    positional,
    passthrough,
  } = parsed;

  // Validate paths exist before discovery.
  for (const p of positional) {
    try {
      await fsp.stat(p);
    } catch {
      await logDiagnostic(`path does not exist: ${p}`, {
        stderr: diagnosticsStderr,
      });
      return 2;
    }
  }

  const found = (await Promise.all(positional.map(discover))).flat();
  const groups = groupByParentDir(found);

  if (dryRun) {
    for (const [dir, files] of groups) {
      console.log(`GROUP ${dir}: ${files.join(", ")}`);
    }
    return 0;
  }

  // Hard-error if any group has no fence.jsonc.
  for (const dir of groups.keys()) {
    const cfg = nodePath.join(dir, "fence.jsonc");
    try {
      await fsp.access(cfg);
    } catch {
      await logDiagnostic(`missing fence.jsonc: ${dir}`, {
        stderr: diagnosticsStderr,
      });
      return 2;
    }
  }

  const pathEnv = buildPath(binDirs);

  let aggregate = 0;
  for (const [dir, files] of groups) {
    const code = await runGroup(
      dir,
      files,
      passthrough,
      pathEnv,
      hidePassing,
      diagnosticsStderr,
    );
    if (code !== 0) aggregate = 1;
  }
  return aggregate;
}

const code = await main();
process.exit(code);
