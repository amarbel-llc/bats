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
  noTempdirCleanup: boolean;
  dryRun: boolean;
  diagnosticsStderr: boolean;
  positional: string[];
  passthrough: string[];
};

function parseArgs(argv: string[]): ParsedArgs {
  const dashIdx = argv.indexOf("--");
  const ours = dashIdx === -1 ? argv : argv.slice(0, dashIdx);
  const passthroughBase = dashIdx === -1 ? [] : argv.slice(dashIdx + 1);

  const positional: string[] = [];
  let noTempdirCleanup = false;
  let fullOutput = false;
  let dryRun = false;
  let diagnosticsStderr = false;

  for (let i = 0; i < ours.length; i++) {
    const a = ours[i];
    switch (a) {
      case "--no-tempdir-cleanup":
        noTempdirCleanup = true;
        break;
      case "--no-split":
      case "--full-output":
        fullOutput = true;
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

  // Forward batman-level toggles that the bats wrapper also understands.
  const forwarded: string[] = [];
  if (noTempdirCleanup) forwarded.push("--no-tempdir-cleanup");
  if (fullOutput) forwarded.push("--no-split");
  const passthrough = [...forwarded, ...passthroughBase];

  return {
    noTempdirCleanup,
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

async function runGroup(
  dir: string,
  files: string[],
  passthrough: string[],
  diagnosticsStderr: boolean,
): Promise<number> {
  const cfg = nodePath.join(dir, "fence.jsonc");
  const fileArgs = files.map((f) => nodePath.join(dir, f));

  return new Promise((resolve) => {
    const child = spawn(
      "fence",
      ["--settings", cfg, "--", "bats", ...passthrough, ...fileArgs],
      { stdio: ["inherit", "inherit", "inherit"] },
    );

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

function printVersion(): void {
  const v = process.env;
  const headline = `batman ${v.BATMAN_VERSION ?? "dev"}+${v.BATMAN_COMMIT ?? "dirty"}`;
  const components: Array<[string, string | undefined]> = [
    ["bats (wrapper)", v.BATMAN_BATS_WRAPPER_VERSION],
    ["bats (upstream)", v.BATMAN_BATS_UPSTREAM_VERSION],
    ["bats-support", v.BATMAN_BATS_SUPPORT_VERSION],
    ["bats-assert", v.BATMAN_BATS_ASSERT_VERSION],
    ["bats-assert-additions", v.BATMAN_BATS_ASSERT_ADDITIONS_VERSION],
    ["tap-writer", v.BATMAN_TAP_WRITER_VERSION],
    ["bats-island", v.BATMAN_BATS_ISLAND_VERSION],
    ["bats-emo", v.BATMAN_BATS_EMO_VERSION],
    ["fence", v.BATMAN_FENCE_VERSION],
    ["tap-dancer", v.BATMAN_TAP_DANCER_VERSION],
  ];
  const labelWidth = Math.max(...components.map(([k]) => k.length));
  const lines = [headline, "", "components:"];
  for (const [name, ver] of components) {
    lines.push(`  ${name.padEnd(labelWidth)}  ${ver ?? "?"}`);
  }
  console.log(lines.join("\n"));
}

async function main(): Promise<number> {
  // `version` subcommand: print build identity + per-component
  // versions injected at build time via buildZxScriptFromFile's
  // runtimeEnv (see nix/packages/batman.nix). Positional keyword,
  // not a flag, so it never conflicts with bats's own --version
  // when batman forwards args downstream.
  if (process.argv[2] === "version") {
    printVersion();
    return 0;
  }

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

  const { dryRun, diagnosticsStderr, positional, passthrough } = parsed;

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

  let aggregate = 0;
  for (const [dir, files] of groups) {
    const code = await runGroup(dir, files, passthrough, diagnosticsStderr);
    if (code !== 0) aggregate = 1;
  }
  return aggregate;
}

process.exitCode = await main();
