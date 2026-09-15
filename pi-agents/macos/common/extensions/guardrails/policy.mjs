// policy.mjs — the pure guardrail decision engine used by the pi extension (index.ts).
//
// Plain ESM JavaScript on purpose: pi loads it through the extension, and Node runs it
// directly for `selfcheck.mjs`, so the exact code that guards production is the code
// that is unit-tested. No dependencies.
//
// Model: every tool call the model makes passes through `evaluate(policy, toolName, input, ctx)`
// and gets back { allow: boolean, reason: string }. Bash commands are split into
// pipeline/list segments, each segment's program must be on the allowlist (and off the
// denied list, wrappers like xargs/timeout included), and each segment is matched against deny regexes (write verbs of kubectl/gcloud/gh/aws/git/…,
// redirections, command substitution, interpreters, privilege escalation). Path tools
// (read/grep/find/ls) are jailed to allowed roots and screened against secret-file globs.

import { homedir } from "node:os";
import { resolve, sep } from "node:path";

export const DEFAULT_POLICY = {
  // "ask": safe (read-only) calls run silently, risky ones prompt the user (Codex-style 3 options).
  // "audit": every call runs, the decision the policy WOULD have made is logged ("would_block").
  // "enforce": risky calls are blocked outright (read-only agent).
  mode: "ask",
  // What counts as "risky":
  //   "dangerous-only" (default) — ordinary work runs (mkdir, cp, edits in the project, git commit,
  //        npm install, kubectl get, terraform plan, docker run …); only destructive / irreversible /
  //        privileged / secret-exposing actions are risky (see `dangerous` below).
  //   "read-only" — the strict classifier: anything that mutates state is risky (allowlist below).
  profile: "dangerous-only",
  dangerous: {
    // Programs that are always risky (as the segment's program, or wrapped by xargs/timeout/…).
    programs: [
      "sudo", "doas", "su", "dd", "mkfs", "fdisk", "diskutil", "parted", "mount", "umount", "shutdown", "reboot",
      "halt", "poweroff", "launchctl", "systemctl", "crontab", "shred", "srm", "wipe", "killall", "pkill",
      "chroot", "iptables", "pfctl", "nvram", "csrutil", "spctl", "tmutil",
      // nested AI agents: unbounded actions outside these guardrails
      "claude", "opencode", "codex", "pi", "aider", "cursor", "gemini",
      // secret dumps
      "env", "printenv",
    ],
    // Regexes (per segment, quotes removed for CLIs) that make a call risky.
    patterns: [
      // filesystem: recursive/forced deletes, wiping, system paths, dangerous permission changes
      "\\brm\\b.*\\s-[a-zA-Z]*[rRf]", "\\brm\\b.*--(recursive|force|no-preserve-root)", "\\brm\\b\\s+(/|~|\\$HOME|\\*|\\.\\.?)(\\s|$)",
      "\\b(rm|mv|cp|chmod|chown|chgrp|ln|truncate|tee)\\b.*\\s/(etc|usr|bin|sbin|boot|var|System|Library|Applications|private|dev|opt/homebrew/bin)\\b",
      "\\bchmod\\b.*(-R|777|-[a-z]*R)", "\\bchown\\b.*-[a-zA-Z]*R", "\\bfind\\b.*\\s-(delete|exec\\s+rm|execdir\\s+rm)\\b",
      ">\\s*/(etc|usr|bin|sbin|boot|var|System|Library|private|dev/(sd|disk|nvme|hd))", "\\bmkfs", "\\bdd\\b.*\\bof=",
      "\\bhistory\\s+-c\\b",
      // remote code execution / piping downloads into a shell
      "\\b(curl|wget)\\b.*\\s-X\\s*(DELETE|PUT|PATCH)\\b", "\\b(curl|wget)\\b.*--request\\s*(DELETE|PUT|PATCH)\\b",
      "\\b(ba|z|da|k)?sh\\b\\s+-c\\s+.*\\b(curl|wget)\\b", "\\beval\\b.*\\$\\(",
      "\\brsync\\b.*--delete", "\\bscp\\b.*\\s-r\\b.*:/(etc|usr|var)",
      // kubernetes / helm / gitops — cluster-changing verbs
      "\\bkubectl\\b.*\\b(apply|create|delete|replace|patch|edit|scale|autoscale|rollout\\s+(restart|undo|pause|resume)|drain|cordon|uncordon|taint|label|annotate|set\\s|expose|run|exec|cp|debug|certificate\\s+(approve|deny))\\b",
      "\\bkubectl\\b.*\\bget\\s+secrets?\\b.*\\s-o\\s*(yaml|json|jsonpath|go-template)", "\\bkubectl\\s+config\\s+(delete|unset|set-credentials)\\b",
      "\\bhelm\\b.*\\b(install|upgrade|uninstall|delete|rollback)\\b", "\\b(argocd|flux|istioctl)\\b.*\\b(delete|sync\\s+--prune|uninstall|install|upgrade|suspend|reconcile\\s+.*--force)\\b",
      // cloud — create/destroy/modify + credential or secret retrieval
      "\\bgcloud\\b.*\\b(create|delete|update|deploy|deploys?|resize|start|stop|reset|suspend|resume|import|export|submit|add-iam-policy-binding|remove-iam-policy-binding|set-iam-policy|keys\\s+create|secrets\\s+versions\\s+access|auth\\s+(print-access-token|print-identity-token|activate-service-account|revoke)|components\\s+(update|remove)|config\\s+set)\\b",
      "\\b(gsutil|gcloud\\s+storage)\\b.*\\b(rm|rb|rsync\\b.*-d|mv)\\b",
      "\\baws\\b.*\\s(create|delete|update|put|terminate|stop|start|reboot|modify|attach|detach|associate|disassociate|authorize|revoke|run-instances|deregister|disable|enable|invoke|purge|assume-role|get-session-token|get-login-password|get-secret-value|decrypt|generate-data-key|set|tag|untag|remove|restore|cancel|reset|release|replace|apply|execute|batch-write|batch-delete|deploy|rollback|rotate|rm|rb)[-a-z]*\\b",
      "\\baws\\b.*\\bssm\\s+get-parameters?\\b.*--with-decryption", "\\baz\\b.*\\s(create|delete|update|deploy|start|stop|restart|scale|set|import|purge)\\b",
      // git / github — anything that rewrites or publishes history, or destroys work
      "\\bgit\\b.*\\bpush\\b", "\\bgit\\b.*\\breset\\b.*--hard", "\\bgit\\b.*\\bclean\\b.*-[a-zA-Z]*[fdx]", "\\bgit\\b.*\\bcheckout\\b.*\\s--\\s", "\\bgit\\b.*\\brestore\\b(?!.*--staged)",
      "\\bgit\\b.*\\bbranch\\b.*\\s-[a-zA-Z]*D\\b", "\\bgit\\b.*\\b(filter-branch|filter-repo|reflog\\s+expire|gc\\b.*--prune=now|update-ref\\s+-d|rebase\\b.*(-i|--interactive|--onto))",
      "\\bgit\\b.*\\bstash\\s+(drop|clear)\\b", "\\bgit\\b.*\\bremote\\s+(rm|remove|set-url)\\b", "\\bgit\\b.*\\btag\\s+-d\\b",
      "\\bgh\\b.*\\b(pr\\s+(merge|close)|issue\\s+(close|delete|transfer)|repo\\s+(delete|archive|transfer|rename|edit)|release\\s+(delete|create|upload)|workflow\\s+(run|disable)|run\\s+(cancel|rerun)|secret\\s+(set|delete|remove)|variable\\s+(set|delete)|ruleset|auth\\s+(logout|refresh)|ssh-key|gpg-key)\\b",
      "\\bgh\\s+api\\b.*(-X|--method)\\s*(DELETE|PUT|PATCH)\\b",
      // issue trackers / chat — anything that changes or posts (viewing and searching stay free)
      "\\bacli\\b.*\\b(create|delete|transition|edit|update|assign|unassign|comment\\s+(create|add|delete)|attach|link|clone|move|archive|auth\\s+(login|logout))\\b",
      "\\bjira\\b.*\\b(create|delete|transition|edit|assign|comment|move)\\b", "\\bslack\\b.*\\b(send|post|delete|kick|archive)\\b",
      // infra as code
      "\\b(terraform|terragrunt|tofu)\\b.*\\b(apply|destroy|import|taint|untaint|force-unlock|state\\s+(rm|mv|push|replace-provider)|workspace\\s+delete|run-all\\s+(apply|destroy))\\b",
      "\\b(pulumi)\\b.*\\b(up|destroy|refresh\\b.*--yes)\\b", "\\bansible(-playbook)?\\b(?!.*--check)",
      // containers / publishing
      "\\bdocker\\s+(rm|rmi|prune|kill|push|login)\\b", "\\bdocker\\s+(system|volume|network|image|container|builder)\\s+(prune|rm|remove)\\b", "\\bdocker\\s+swarm\\s+(leave|init)\\b",
      "\\bdocker\\b.*\\brun\\b.*(--privileged|-v\\s*/:|--pid=host|--net=host)",
      "\\b(npm|pnpm|yarn)\\s+(publish|unpublish|deprecate)\\b", "\\b(twine|pip)\\s+upload\\b", "\\bgem\\s+push\\b", "\\bcargo\\s+publish\\b", "\\bhelm\\s+push\\b",
      "\\b(brew\\s+(uninstall|remove|zap)|apt(-get)?\\s+(remove|purge|autoremove)|dnf\\s+remove|yum\\s+remove|npm\\s+(uninstall|rm)\\s+-g)\\b",
      // persistence & system settings
      "\\bdefaults\\s+(write|delete)\\b", "\\bnetworksetup\\b", "\\bscutil\\s+--set\\b", "\\bsysctl\\s+-w\\b",
      // process control with force
      "\\bkill\\b.*\\s-(9|KILL|SIGKILL)\\b", "\\bkill\\b.*\\s-1\\b(?!\\d)",
    ],
    // Regexes applied to the WHOLE command (quotes removed) — for things that span a pipe.
    whole_patterns: [
      "\\b(curl|wget|fetch)\\b[^|]*\\|\\s*(sudo\\s+)?(ba|z|da|k)?sh\\b",   // download piped into a shell
      "\\b(curl|wget)\\b[^|]*\\|\\s*(python3?|perl|ruby|node)\\b",      // …or into an interpreter
      ":\\(\\)\\s*\\{[^}]*:\\|:",                                         // fork bomb
    ],
    // Paths the write/edit tools (and `>` redirections) may not touch without approval.
    protected_write_globs: ["/etc/**", "/usr/**", "/bin/**", "/sbin/**", "/var/**", "/System/**", "/Library/**", "/private/etc/**",
      "**/Library/LaunchAgents/**", "**/Library/LaunchDaemons/**", "**/.ssh/**", "**/.aws/**", "**/.kube/**", "**/.gnupg/**",
      "**/.zshrc", "**/.bashrc", "**/.bash_profile", "**/.zprofile", "**/.profile", "**/.gitconfig", "**/.npmrc", "**/.pypirc", "**/.netrc"],
  },
  // Tools that can run WITHOUT approval when their arguments pass the checks below. Anything
  // else (edit/write/…) always counts as "risky" → prompt in ask mode, blocked in enforce mode.
  allowed_tools: ["read", "bash", "grep", "find", "ls"],
  // Stop the agent run after a blocked call instead of letting it try something else.
  terminate_on_block: false,
  // Hard cap on tool calls per agent run (an infinite retry loop burns tokens for nothing).
  max_tool_calls_per_run: 40,
  paths: {
    // read/grep/find/ls may only touch paths under these roots (plus the run's cwd).
    allowed_roots: ["~", "/etc", "/var/log", "/tmp", "/private/tmp", "/opt"],
    // …and never these, wherever they are.
    deny_globs: [
      "**/.ssh/**", "**/.aws/**", "**/.gnupg/**", "**/.kube/config", "**/.kube/**/config",
      "**/.docker/config.json", "**/.npmrc", "**/.pypirc", "**/.netrc", "**/.git-credentials",
      "**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/*.p12", "**/*.pfx", "**/id_rsa*",
      "**/id_ed25519*", "**/auth.json", "**/credentials", "**/credentials.json",
      "**/*credential*", "**/*secret*", "**/*.kdbx", "**/*token*", "**/.hermes/.env",
      "**/.pi/agent/auth.json", "**/.local/share/opencode/auth.json", "**/.claude/**",
    ],
  },
  bash: {
    max_command_length: 4000,
    // First word of every pipeline/list segment must be here.
    allowed_commands: [
      // cloud / platform CLIs — read verbs only (write verbs are denied below)
      "kubectl", "helm", "gcloud", "gsutil", "bq", "aws", "gh", "git", "terraform", "terragrunt",
      "docker", "istioctl", "argocd", "flux", "velero",
      // text / files (read-only)
      "cat", "head", "tail", "less", "more", "grep", "egrep", "fgrep", "rg", "find", "ls", "wc",
      "sort", "uniq", "cut", "awk", "sed", "jq", "yq", "tr", "column", "diff", "comm", "paste",
      "fold", "nl", "tac", "rev", "strings", "file", "stat", "tree", "du", "df", "realpath",
      "basename", "dirname", "readlink", "md5", "md5sum", "sha256sum", "shasum", "base32",
      // system introspection
      "echo", "printf", "date", "cal", "uptime", "hostname", "whoami", "id", "pwd", "uname",
      "which", "type", "ps", "top", "vm_stat", "free", "lsof", "netstat", "ss", "ifconfig", "ip",
      "sw_vers", "sysctl", "nproc", "arch", "getconf", "ulimit", "last", "w", "who",
      // network diagnostics (read-only)
      "dig", "nslookup", "host", "ping", "traceroute", "curl", "openssl", "nc", "mtr", "whois",
      // shell no-ops / tests
      "true", "false", "test", "[", "seq", "yes", "sleep", "timeout", "gtimeout", "xargs", "tee",
      // shell builtins that only affect the current (throw-away) shell
      "cd", "pushd", "popd", "dirs",
    ],
    // Programs that may NEVER run — not as a segment's program and not wrapped by
    // xargs/timeout/time/nice/… (the allowlist already excludes them; this list exists so
    // a future allowlist edit cannot accidentally let one back in).
    denied_programs: [
      "sudo", "doas", "su", "rm", "mv", "cp", "ln", "chmod", "chown", "chgrp", "mkdir", "rmdir", "touch",
      "dd", "mkfs", "fdisk", "diskutil", "mount", "umount", "kill", "killall", "pkill", "reboot", "shutdown",
      "halt", "systemctl", "launchctl", "crontab", "at", "nohup", "defaults", "osascript", "open",
      "python", "python3", "node", "deno", "bun", "perl", "ruby", "php", "lua", "Rscript", "swift", "java",
      "bash", "sh", "zsh", "dash", "fish", "ksh", "csh", "tcsh", "pwsh", "powershell", "cmd.exe",
      "eval", "exec", "source", ".", "env", "printenv", "export", "unset", "set", "alias", "function",
      "wget", "ssh", "scp", "sftp", "rsync", "ftp", "telnet", "nmap", "masscan",
      "brew", "apt", "apt-get", "dnf", "yum", "pacman", "apk", "snap", "npm", "npx", "pnpm", "yarn",
      "pip", "pip3", "pipx", "gem", "cargo", "go", "nix-env", "make", "vi", "vim", "nano", "emacs",
    ],
    // Allowed programs that execute their ARGUMENT — the wrapped program is checked too.
    exec_wrappers: ["xargs", "timeout", "gtimeout", "time", "nice", "ionice", "command", "stdbuf", "caffeinate"],
    // Programs whose quoted arguments are data (search patterns, text): quoted content is
    // blanked before deny-pattern matching so `grep 'kubectl delete'` over a log is fine.
    // Everything else (kubectl, gcloud, sed, awk, …) is matched with quotes REMOVED, so a
    // verb cannot be smuggled past the patterns as `kubectl "delete" pod`.
    data_arg_programs: ["grep", "egrep", "fgrep", "rg", "jq", "yq", "echo", "printf", "cut", "tr", "sort", "uniq", "column", "diff", "comm", "paste", "wc", "head", "tail", "cat", "less", "more"],
    // Segments matching one of these (quotes removed) skip the deny patterns. Keep tiny.
    segment_allow_overrides: ["^kubectl\\b.*\\bauth\\s+can-i\\b"],
    // Literals stripped before structural checks (read-only idioms that contain `>` or `-o`).
    allowed_literals: ["2>&1", "2>/dev/null", "2> /dev/null", ">/dev/null", "> /dev/null", "1>/dev/null", "1> /dev/null", "&>/dev/null", "-o /dev/null", "-o/dev/null", "--output /dev/null", "--output=/dev/null"],
    // Regexes (JS, case-insensitive) applied PER SEGMENT (see data_arg_programs) that deny it.
    deny_patterns: [
      // in-place edits and shell-out from otherwise-allowed text tools
      "\\bsed\\b[^|;&]*\\s-[a-zA-Z]*i", "\\bsed\\b.*/[wWe]\\b", "\\bsed\\b.*(^|[\\s;{])[wWe]\\s+\\S",
      "\\bawk\\b.*\\b(system\\s*\\(|getline\\s*<|print\\w*\\s*[^;{}]*?[>|]|close\\s*\\(|fflush)",
      "\\bfind\\b.*\\s-(delete|exec|execdir|ok|okdir|fprint|fprint0|fprintf|fls)\\b",
      "\\btee\\b\\s+(?!/dev/null\\b|-a\\s+/dev/null\\b)",
      "\\bcurl\\b.*\\s(-X|--request|-d|--data|--data-\\w+|-F|--form|-T|--upload-file|-o|--output|-O|--remote-name|-K|--config|-u|--user|--netrc\\w*|-E|--cert|--key)\\b",
      "\\bopenssl\\b.*\\b(req|genrsa|genpkey|rsa\\s|ec\\s|enc\\b|pkcs12|s_server)\\b", "\\bopenssl\\b.*\\s-out\\b",
      "\\bnc\\b.*\\s-(l|e|c)\\b", "\\bnetcat\\b",
      "\\bxargs\\b.*\\s-(I|J|i|o|p|r)\\b",
      "\\btimeout\\b.*\\s-s\\s*(KILL|9)\\b",
      // kubernetes — write verbs (read: get describe logs top events explain api-resources version cluster-info config view diff auth can-i)
      "\\bkubectl\\b.*\\b(apply|create|delete|edit|patch|replace|scale|autoscale|rollout\\s+(restart|undo|pause|resume)|exec|attach|cp|drain|cordon|uncordon|taint|label|annotate|set\\s|expose|run|debug|port-forward|proxy|certificate|kustomize|wait|completion|plugin|krew)\\b",
      "\\bkubectl\\s+config\\s+(set|use-context|use|rename-context|delete|unset)\\b",
      "\\bkubectl\\b.*\\s--(kubeconfig|token|as|as-group|server)\\b",
      "\\bhelm\\b.*\\b(install|upgrade|uninstall|delete|rollback|repo\\s+(add|remove|update)|plugin\\s+install|push|package|create|registry\\s+login)\\b",
      "\\b(istioctl|argocd|flux)\\b.*\\b(install|uninstall|create|delete|apply|sync|reconcile|suspend|resume|upgrade|set|patch|rollback|bootstrap|login|manifest\\s+apply)\\b",
      "\\bvelero\\b.*\\b(create|delete|install|uninstall|restore|schedule)\\b",
      // gcp — write verbs and credential minting
      "\\bgcloud\\b.*\\b(create|delete|update|deploy|deploys?|set|add|remove|attach|detach|resize|start|stop|reset|suspend|resume|ssh|scp|import|export|submit|run\\s+(deploy|services\\s+(update|delete))|auth\\s+(login|activate-service-account|revoke|application-default|print-access-token|print-identity-token|configure-docker)|config\\s+(set|unset|configurations\\s+(create|activate|delete))|components\\s+(install|update|remove)|add-iam-policy-binding|remove-iam-policy-binding|set-iam-policy|keys\\s+create|kms\\b.*\\b(decrypt|encrypt|destroy)|secrets\\s+versions\\s+access|get-credentials)\\b",
      "\\b(gsutil|gcloud\\s+storage)\\b.*\\b(cp|mv|rm|rsync|mb|rb|acl|iam|defacl|setmeta|rewrite|compose|signurl)\\b",
      "\\bbq\\b.*\\b(load|insert|mk|rm|cp|update|extract)\\b", "\\bbq\\b.*--(destination_table|replace|append_table)\\b",
      // aws — write verbs and credential retrieval
      "\\baws\\b.*\\s(create|delete|update|put|terminate|start|stop|reboot|modify|attach|detach|associate|disassociate|authorize|revoke|run-instances|register|deregister|enable|disable|import|export|invoke|send|publish|purge|assume-role|get-session-token|get-federation-token|get-login-password|get-secret-value|get-parameter\\b.*--with-decryption|decrypt|encrypt|generate-data-key|set|tag|untag|add|remove|restore|copy|cancel|reset|release|allocate|replace|apply|execute|batch-write|batch-delete|deploy|rollback|promote|reencrypt|rotate|sync|cp|mv|rm|mb|rb|configure|sso\\s+login|login)[-a-z]*\\b",
      // git — anything that mutates the working tree, index, refs, config or remote
      "\\bgit\\b.*\\b(push|commit|reset|checkout|switch|restore|rebase|merge|cherry-pick|revert|clean|stash|add|rm|mv|tag|am|apply|pull|fetch|clone|init|remote\\s+(add|remove|rm|set-url|rename|prune)|branch\\s+(-[dDmMcCu]|--delete|--move|--copy|--set-upstream)|config\\s+(?!--get|--list|-l\\b|--show-origin)|filter-branch|filter-repo|gc|prune|reflog\\s+(expire|delete)|submodule\\s+(add|update|deinit|sync)|worktree\\s+(add|remove|prune|move)|update-ref|symbolic-ref\\s+\\S+\\s+\\S|notes\\s+(add|remove|edit)|lfs\\s+(push|prune|fetch|pull|install))\\b",
      // github cli — write verbs and credential access
      "\\bgh\\b.*\\b(create|merge|close|reopen|edit|delete|comment|review|rerun|cancel|fork|clone|dispatch|enable|disable|lock|unlock|pin|unpin|transfer|archive|unarchive|rename|sync|set-default|checkout|ready|approve|login|logout|refresh|setup-git|token|ssh-key|gpg-key|secret|variable|codespace|copilot|extension\\s+(install|remove|upgrade)|release\\s+(upload|download|delete-asset)|run\\s+(rerun|cancel|watch|download)|workflow\\s+(run|enable|disable)|attestation|ruleset\\s+check)\\b",
      "\\bgh\\s+api\\b.*\\s(-X|--method|-f|-F|--field|--raw-field|--input|--hostname)\\b",
      // terraform / terragrunt / tofu — plan/show/state list/output/validate stay allowed
      "\\b(terraform|terragrunt|tofu)\\b.*\\b(apply|destroy|import|taint|untaint|force-unlock|login|logout|init\\b.*-migrate-state|state\\s+(rm|mv|push|replace-provider)|workspace\\s+(new|delete|select)|run-all\\s+(apply|destroy|import))\\b",
      // docker — anything but inspection
      "\\bdocker\\b(?!\\s+(ps|logs|inspect|images|image\\s+(ls|inspect|history)|version|info|stats|top|port|diff|history|events|system\\s+(df|info)|network\\s+(ls|inspect)|volume\\s+(ls|inspect)|context\\s+(ls|show|inspect)|container\\s+(ls|inspect|logs|top|port|diff|stats)|compose\\s+(ps|logs|config|ls|top|images|version))\\b)",
    ],
  },
};

// ── helpers ───────────────────────────────────────────────────────────────────
export function expandHome(p) {
  if (!p) return p;
  if (p === "~") return homedir();
  if (p.startsWith("~/")) return homedir() + p.slice(1);
  return p;
}

function escapeRegExp(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

// Minimal glob → RegExp: `**` any depth, `*` within a segment, `?` one char. Anchored.
export function globToRegExp(glob) {
  let re = "";
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === "*") {
      if (glob[i + 1] === "*") {
        // `**/` matches zero or more directories; a trailing `**` matches the rest.
        if (glob[i + 2] === "/") { re += "(?:.*/)?"; i += 2; } else { re += ".*"; i += 1; }
      } else re += "[^/]*";
    } else if (c === "?") re += "[^/]";
    else re += escapeRegExp(c);
  }
  return new RegExp("^" + re + "$", "i");
}

export function deepMerge(base, override) {
  if (!override || typeof override !== "object" || Array.isArray(override)) return override ?? base;
  const out = { ...base };
  for (const [k, v] of Object.entries(override)) {
    out[k] = (v && typeof v === "object" && !Array.isArray(v) && base && typeof base[k] === "object" && !Array.isArray(base[k]))
      ? deepMerge(base[k], v) : v;
  }
  return out;
}

export function compilePolicy(raw) {
  const p = deepMerge(DEFAULT_POLICY, raw || {});
  return {
    ...p,
    mode: p.mode === "audit" ? "audit" : p.mode === "enforce" ? "enforce" : "ask",
    profile: p.profile === "read-only" ? "read-only" : "dangerous-only",
    _dangerRes: ((p.dangerous || {}).patterns || []).map((s) => new RegExp(s, "i")),
    _dangerProgs: new Set((p.dangerous || {}).programs || []),
    _dangerWholeRes: ((p.dangerous || {}).whole_patterns || []).map((s) => new RegExp(s, "i")),
    _protectedWriteRes: ((p.dangerous || {}).protected_write_globs || []).map(globToRegExp),
    _denyRes: (p.bash.deny_patterns || []).map((s) => new RegExp(s, "i")),
    _denyGlobRes: (p.paths.deny_globs || []).map(globToRegExp),
    _roots: (p.paths.allowed_roots || []).map((r) => resolve(expandHome(r))),
    _allowedCmds: new Set(p.bash.allowed_commands || []),
    _deniedProgs: new Set(p.bash.denied_programs || []),
    _wrappers: new Set(p.bash.exec_wrappers || []),
    _dataProgs: new Set(p.bash.data_arg_programs || []),
    _overrideRes: (p.bash.segment_allow_overrides || []).map((s) => new RegExp(s, "i")),
    _allowedTools: new Set(p.allowed_tools || []),
  };
}

// Split a shell command into segments on unquoted  ;  |  ||  &&  &  and newlines.
// Quotes are honoured so `grep "a|b"` stays one segment. Returns trimmed segments.
export function splitSegments(command) {
  const segs = [];
  let cur = "", q = null;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (q) {
      cur += c;
      if (c === "\\" && q === '"' && i + 1 < command.length) { cur += command[++i]; continue; }
      if (c === q) q = null;
      continue;
    }
    if (c === "'" || c === '"') { q = c; cur += c; continue; }
    if (c === "\\" && i + 1 < command.length) { cur += c + command[++i]; continue; }
    if (c === "\n" || c === ";" || c === "|" || c === "&") {
      segs.push(cur); cur = "";
      if ((c === "|" || c === "&") && command[i + 1] === c) i++;
      continue;
    }
    cur += c;
  }
  segs.push(cur);
  return segs.map((s) => s.trim()).filter(Boolean);
}

// First real word of a segment: skips `FOO=bar` assignments and known benign wrappers.
const WRAPPERS = new Set(["time", "nice", "ionice", "command", "stdbuf", "caffeinate"]);
// `{ … }` groups, `( … )` subshells and `!` negation carry no program of their own.
const GROUPING = new Set(["{", "}", "(", ")", "!"]);
export function programOf(segment) {
  const words = segment.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || [];
  let i = 0;
  while (i < words.length && (/^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i]) || GROUPING.has(words[i]))) i++;
  while (i < words.length && WRAPPERS.has(words[i])) {
    i++;
    while (i < words.length && words[i].startsWith("-")) i++;
  }
  if (i >= words.length) return "";
  let w = words[i].replace(/^["']|["']$/g, "");
  if (w.includes("/")) w = w.slice(w.lastIndexOf("/") + 1); // /usr/bin/kubectl → kubectl
  return w;
}

// Replace the CONTENT of quoted strings with nothing (quotes kept) or drop the quote
// characters (content kept). Escapes inside double quotes are honoured.
export function transformQuoted(command, mode /* "blank" | "unquote" */, which = "both") {
  let out = "", q = null;
  for (let i = 0; i < command.length; i++) {
    const c = command[i];
    if (q) {
      if (c === "\\" && q === '"' && i + 1 < command.length) { if (mode === "unquote") out += command[i + 1]; i++; continue; }
      if (c === q) { q = null; if (mode === "blank") out += c; continue; }
      if (mode === "unquote") out += c;
      continue;
    }
    if ((c === "'" && which !== "double") || (c === '"' && which !== "single")) {
      q = c;
      if (mode === "blank") out += c;
      continue;
    }
    out += c;
  }
  return out;
}

function stripLiterals(text, literals) {
  let out = text;
  for (const lit of literals || []) out = out.split(lit).join(" ");
  return out;
}

function wordsOf(segment) {
  return (segment.match(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g) || []).map((w) => w.replace(/^["']|["']$/g, ""));
}

const VALUE_FLAGS = new Set(["-n", "-c", "-k", "-I", "-J", "-P", "-d", "-L", "-s", "-E", "-t", "-i", "-u", "--signal", "-o", "-e", "-a", "-p"]);

// For `xargs kubectl …`, `timeout 30 gcloud …`, `time git …`: the program being wrapped.
export function wrappedProgram(segment, wrappers) {
  const words = wordsOf(segment);
  let i = 0;
  while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i])) i++;
  if (i >= words.length) return "";
  let prog = words[i].includes("/") ? words[i].slice(words[i].lastIndexOf("/") + 1) : words[i];
  if (!wrappers.has(prog)) return "";
  i++;
  while (i < words.length && words[i].startsWith("-")) { if (VALUE_FLAGS.has(words[i])) i++; i++; }
  if ((prog === "timeout" || prog === "gtimeout") && i < words.length && /^\d+(\.\d+)?[smhd]?$/.test(words[i])) i++;
  if (i >= words.length) return "";
  const w = words[i];
  return w.includes("/") ? w.slice(w.lastIndexOf("/") + 1) : w;
}

function checkProgram(policy, prog) {
  if (!prog) return "segment has no program";
  if (policy._deniedProgs.has(prog)) return `\`${prog}\` changes the system (not read-only)`;
  if (!policy._allowedCmds.has(prog)) return `\`${prog}\` is not on the read-only allowlist`;
  return "";
}

export function evaluateBash(policy, command) {
  const cmd = String(command ?? "");
  if (!cmd.trim()) return { allow: false, reason: "empty command" };
  if (cmd.length > policy.bash.max_command_length)
    return { allow: false, reason: `command longer than ${policy.bash.max_command_length} chars` };

  // Structural checks on quote-aware views of the command.
  const noQuotes = stripLiterals(transformQuoted(cmd, "blank", "both"), policy.bash.allowed_literals);
  if (/>/.test(noQuotes)) return { allow: false, reason: "output redirection is not allowed (read-only agent)" };
  if (/<<</.test(noQuotes) || /<<-?\s*['"\\]?\w/.test(noQuotes))
    return { allow: false, reason: "heredocs/herestrings are not allowed" };
  const noSingle = transformQuoted(cmd, "blank", "single"); // $(…) and `…` still expand inside "…"
  if (/\$\(|`|<\(|>\(|\$\{[^}]*[`$(]/.test(noSingle))
    return { allow: false, reason: "command/process substitution is not allowed" };

  const segments = splitSegments(stripLiterals(cmd, policy.bash.allowed_literals))
    .filter((seg) => !/^[\s{}()!]*$/.test(seg)); // a lone `}` or `)` closing a group is not a command
  if (!segments.length) return { allow: false, reason: "no executable segment" };
  // Name the real culprit first: a denied program anywhere beats an allowlist miss elsewhere.
  for (const seg of segments) {
    const prog = programOf(seg);
    if (prog && policy._deniedProgs.has(prog)) return { allow: false, reason: checkProgram(policy, prog) };
  }
  for (const seg of segments) {
    const prog = programOf(seg);
    const bad = checkProgram(policy, prog);
    if (bad) return { allow: false, reason: bad };
    // Anything that executes its argument must wrap an allowed program as well.
    let inner = wrappedProgram(seg, policy._wrappers);
    let hops = 0;
    while (inner && hops++ < 4) {
      const badInner = checkProgram(policy, inner);
      if (badInner) return { allow: false, reason: `\`${prog}\` wraps ${badInner}` };
      const rest = seg.slice(seg.indexOf(inner) + inner.length);
      inner = policy._wrappers.has(inner) ? wrappedProgram(inner + rest, policy._wrappers) : "";
    }
    const unquoted = transformQuoted(seg, "unquote");
    if (policy._overrideRes.some((re) => re.test(unquoted))) continue;
    const text = policy._dataProgs.has(prog) ? transformQuoted(seg, "blank") : unquoted;
    for (const re of policy._denyRes) {
      if (re.test(text)) return { allow: false, reason: `mutating or sensitive operation (policy pattern /${re.source.slice(0, 40)}${re.source.length > 40 ? "…" : ""}/)` };
    }
  }
  return { allow: true, reason: "ok" };
}

export function evaluatePath(policy, rawPath, cwd) {
  const p = String(rawPath ?? "").replace(/^@/, "");
  if (!p) return { allow: true, reason: "no path (defaults to cwd)" };
  const abs = resolve(cwd || process.cwd(), expandHome(p));
  const roots = [resolve(cwd || process.cwd()), ...policy._roots];
  const inside = roots.some((r) => abs === r || abs.startsWith(r.endsWith(sep) ? r : r + sep));
  if (!inside) return { allow: false, reason: `path ${abs} is outside the allowed roots` };
  for (const re of policy._denyGlobRes) {
    if (re.test(abs)) return { allow: false, reason: `\`${abs}\` looks like a secret/credential file` };
  }
  return { allow: true, reason: "ok" };
}

// ── "dangerous-only" profile ───────────────────────────────────────────────────
export function evaluateBashDangerous(policy, command) {
  const cmd = String(command ?? "");
  if (!cmd.trim()) return { allow: false, reason: "empty command" };
  if (cmd.length > policy.bash.max_command_length)
    return { allow: false, reason: `command longer than ${policy.bash.max_command_length} chars` };
  const whole = transformQuoted(cmd, "unquote");
  for (const re of policy._dangerWholeRes) {
    if (re.test(whole)) return { allow: false, reason: `destructive or irreversible operation (${describeDanger(re, whole)})` };
  }
  const segments = splitSegments(stripLiterals(cmd, policy.bash.allowed_literals))
    .filter((seg) => !/^[\s{}()!]*$/.test(seg));
  for (const seg of segments) {
    const prog = programOf(seg);
    if (prog && policy._dangerProgs.has(prog)) return { allow: false, reason: `\`${prog}\` is a dangerous/privileged program` };
    let inner = wrappedProgram(seg, policy._wrappers), hops = 0;
    while (inner && hops++ < 4) {
      if (policy._dangerProgs.has(inner)) return { allow: false, reason: `\`${prog}\` wraps \`${inner}\` (dangerous/privileged)` };
      const rest = seg.slice(seg.indexOf(inner) + inner.length);
      inner = policy._wrappers.has(inner) ? wrappedProgram(inner + rest, policy._wrappers) : "";
    }
  }
  // Patterns: CLIs are matched with quotes removed (no smuggling); text tools with quoted data blanked.
  for (const seg of segments) {
    const prog = programOf(seg);
    const text = policy._dataProgs.has(prog) ? transformQuoted(seg, "blank") : transformQuoted(seg, "unquote");
    for (const re of policy._dangerRes) {
      if (re.test(text)) return { allow: false, reason: `destructive or irreversible operation (${describeDanger(re, text)})` };
    }
  }
  // Redirecting output into a protected location counts as a write there.
  const unq = transformQuoted(cmd, "unquote");
  for (const m of unq.matchAll(/(?:^|[^&\d])>{1,2}\s*([^\s;|&)]+)/g)) {
    const target = m[1];
    if (target.startsWith("/dev/")) continue;
    const abs = resolve(expandHome(target));
    if (policy._protectedWriteRes.some((re) => re.test(abs))) return { allow: false, reason: `writes to protected path \`${abs}\`` };
  }
  return { allow: true, reason: "ok" };
}

function describeDanger(re, text) {
  const m = text.match(re);
  const hit = (m && m[0] ? m[0] : re.source).replace(/\s+/g, " ").trim();
  return "`" + (hit.length > 60 ? hit.slice(0, 59) + "…" : hit) + "`";
}

export function evaluatePathDangerous(policy, rawPath, cwd, writing) {
  const p = String(rawPath ?? "").replace(/^@/, "");
  if (!p) return { allow: true, reason: "no path" };
  const abs = resolve(cwd || process.cwd(), expandHome(p));
  for (const re of policy._denyGlobRes) {
    if (re.test(abs)) return { allow: false, reason: `\`${abs}\` looks like a secret/credential file` };
  }
  if (writing) {
    for (const re of policy._protectedWriteRes) {
      if (re.test(abs)) return { allow: false, reason: `\`${abs}\` is a protected system/config path` };
    }
  }
  return { allow: true, reason: "ok" };
}

export function evaluateDangerous(policy, toolName, input, ctx = {}) {
  const tool = String(toolName || "");
  const inp = input && typeof input === "object" ? input : {};
  if (tool === "bash") return evaluateBashDangerous(policy, inp.command);
  if (tool === "powershell") return evaluateBashDangerous(policy, inp.command);
  if (tool === "write" || tool === "edit") return evaluatePathDangerous(policy, inp.path, ctx.cwd, true);
  if (tool === "read" || tool === "ls" || tool === "grep" || tool === "find") return evaluatePathDangerous(policy, inp.path, ctx.cwd, false);
  return { allow: true, reason: "ok" };
}

// The single entry point the extension calls.
export function evaluate(policy, toolName, input, ctx = {}) {
  if (policy.profile === "dangerous-only") return evaluateDangerous(policy, toolName, input, ctx);
  const tool = String(toolName || "");
  if (!policy._allowedTools.has(tool))
    return { allow: false, reason: `\`${tool}\` is not a pre-approved tool` };
  const inp = input && typeof input === "object" ? input : {};
  if (tool === "bash" || tool === "powershell") {
    return tool === "bash" ? evaluateBash(policy, inp.command) : { allow: false, reason: "powershell is not permitted" };
  }
  if (tool === "read" || tool === "ls") return evaluatePath(policy, inp.path, ctx.cwd);
  if (tool === "grep" || tool === "find") {
    // grep/find search under `path`; the pattern itself is harmless.
    return evaluatePath(policy, inp.path, ctx.cwd);
  }
  if (tool === "edit" || tool === "write") return { allow: false, reason: `\`${tool}\` modifies files` };
  return { allow: true, reason: "ok" }; // an allowlisted custom tool we know nothing about
}

export function summarize(policy) {
  if (policy.profile === "dangerous-only") return [
    "Guardrails: ordinary work runs without asking. Destructive, irreversible, privileged or secret-exposing actions ",
    "(rm -rf, sudo, disk/service changes, kubectl apply/delete, helm upgrade, terraform apply/destroy, cloud create/delete, ",
    "git push / reset --hard / clean, gh pr merge, docker prune, curl | sh, secret retrieval, writes to system paths, nested AI CLIs) ",
    "are held for the user's approval. When a call is held you receive the reason; do NOT retry variants — ask the user.",
  ].join("");
  return [
    `Permitted tools: ${[...policy._allowedTools].join(", ")}.`,
    "The bash tool is READ-ONLY: only allowlisted programs run, and any command that writes, deletes, ",
    "redirects output, escalates privileges, opens a shell/interpreter, or uses a mutating verb of kubectl/helm/",
    "gcloud/aws/gh/git/terraform/docker is blocked before execution. File tools cannot leave the allowed roots ",
    "or open secret-bearing files (.env, keys, kubeconfig, auth.json, …).",
    "When a call is blocked you receive the reason; do NOT retry variants of the same mutation — explain what a ",
    "human operator would need to run instead.",
  ].join("");
}
