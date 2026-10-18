# expect-pty Hardening Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task; verify each RED→GREEN transition.

**Goal:** 修复启动/加载安全、匹配与回收性能、异常语义，并隔离进程监管。
**Architecture:** 保留 ResourceOwner 唯一资源账本；Session 负责会话协议，独立进程对象负责启动与回收；Matcher 接收显式扫描窗口。
**Tech Stack:** Ruby 3.4+ / POSIX PTY / Minitest / RBS / RuboCop。
**Spec:** docs/superpowers/specs/2026-10-18-expect-pty-hardening-design.md

## Global Constraints

- 保留当前未提交 WIP；不提交、推送、发布。
- 默认无隐式 shell，显式 shell:true 仅允许单字符串。
- search_window 默认 nil；Numeric 时间值，deadline 允许已过期负值。
- 所有权、异步中断、清理异常优先级、流式脱敏保持。

## Review Focus

- 可执行文件名含 shell 元字符仍只作为文件名。
- 标准库 expect 与本库两种加载顺序均可用。
- exec/chdir 系统错误保持 errno，非系统错误不任意反序列化。
- UTF8窗口边界、零宽匹配、多来源优先级和消费偏移正确。
- 初始化、fork、日志回调异常下无句柄/PID泄漏。

### Task 1: Shell-safe spawn
Files: lib/expect.rb, lib/expect/session.rb, test/process_test.rb, sig/expect.rbs, README*, CHANGELOG.md.
Interfaces: Expect.spawn/Session#spawn(..., shell: false); exec_child uses explicit executable argv.
- [x] Add literal executable/single-string rejection/explicit shell/env+argv tests; run new spawn_safety_test.rb RED.
- [x] Execute default via exec(env,[program,program],*args); shell:true via /bin/sh -c, reject multiple arguments.
- [x] Run process/lifecycle/interrupt tests GREEN; update RBS/docs.

### Task 2: Unambiguous entry point
Files: remove lib/expect.rb, move body to lib/expect/pty.rb; update test_helper, script/check_api.rb, script/ci, benchmark/support.rb.
- [x] Add subprocess standard-library/PTY load-order tests RED.
- [x] Migrate relative requires and every repository runtime load; keep expect/version and redactor independent.
- [x] Run edge_case/test/API and isolated package checks GREEN.

### Task 3: Spawn error semantics
Files: entrypoint SpawnError, session child error pipe, test/process_test.rb, sig/expect.rbs.
Interfaces: SpawnError#errno -> Integer?; cause SystemCallError for errno, fixed internal error otherwise.
- [x] Assert ENOENT/EACCES/chdir error causes and child reaping RED.
- [x] Use controlled JSON payload; no Marshal or dynamic exception constant lookup; restore cause and retain outer SpawnError.
- [x] Run process/error cleanup tests GREEN.

### Task 4: Numeric time contracts
Files: lib/expect/pty.rb, sig/expect.rbs, test/session_options_test.rb, test/deadline_test.rb, docs/API.md.
- [x] Test strings, bool, symbols, Complex, NaN/Infinity invalid ArgumentError, Rational and nil valid RED.
- [x] Normalize relative duration and absolute deadline separately, retain public compatibility names.
- [x] Run options/deadline/timeout/API checks GREEN.

### Task 5: Bounded search window
Files: entrypoint, session.rb, responder.rb, matcher.rb, pattern.rb, sig/expect.rbs; test/search_window_test.rb; benchmark/matching.rb.
Interfaces: per-call Expect.expect/Session#expect/Responder#expect search_window: positive Integer? -> Result; Matcher receives same keyword.
- [x] Test literal/regexp boundaries, before/after/consume:false, UTF8 boundary, binary data, multiple sessions and responder RED.
- [x] Search independent trailing byte window; map offsets to original buffer; preserve nil path and scan caches.
- [x] Run matcher/responder/stream tests GREEN; measure same input with nil versus window (no CI time assertion).

### Task 6: Fast wait and lazy logging
Files: session.rb, logging.rb, test/process_test.rb, test/diagnostics_test.rb; benchmark/logging.rb.
- [x] Pin nonblocking reap before sleep and initial 1ms/max10ms bounded wait via deterministic test RED.
- [x] Use capped backoff on existing monotonic budget; lazy log messages avoid formatting with no logger.
- [x] Run interruption/close/logging tests GREEN and record multiple sample timing/allocations.

### Task 7: Process ownership boundary and internal interfaces
Files: lib/expect/child_process.rb (new), session.rb, resource_owner.rb, entrypoint; lifecycle/initialization/interface tests.
- [x] Pin ownership/failure behavior and supported API; extract only process responsibilities after preceding tasks pass.
- [x] Keep one ResourceOwner, preserve public Session process methods via delegation; factory owns partial construction internally.
- [x] Classify internal cross-object methods rather than blanket private/send; private_constant only where no public contract.
- [x] Run all lifecycle/interrupt/relay/matcher tests and API/RBS checks.

### Task 8: Verification and review
- [x] Run bash script/ci, inspect plain/Bundler package entry points and signatures.
- [x] Compare baseline and final hot paths with monotonic timing and allocations, preserve baseline WIP.
- [x] Fresh independent whole-change review; fix important findings RED→GREEN; report actual remaining limits.
- [x] Copy only owned changes back to original worktree with preimage checks; leave all work uncommitted.

## Execution evidence

Full gate: 596 tests / 9590 assertions; 99 linted files; API/RBS, examples, seven benchmark smokes and two isolated installs passed. Independent review findings fixed and rechecked (45 tests / 180 assertions). Timing and measured byteslice regression are recorded in docs/VERIFICATION.md. Product changes remain uncommitted; original WIP is the comparison baseline.
