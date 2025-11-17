#!/usr/bin/env bash
# Auto-format Zig files after editing and emit ZLS diagnostics
# Only formats .zig files that were just edited

set -euo pipefail

# Read JSON input from stdin
input=$(cat)

# Extract file path using jq
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')

# Exit if no file path or not a Zig file
if [ -z "${file_path}" ] || [[ "${file_path}" != *.zig ]]; then
    exit 0
fi

# Check if file exists
if [ ! -f "${file_path}" ]; then
    exit 0
fi

echo "🎨 Auto-formatting Zig file: ${file_path}"

# Run zig fmt on the file
if zig fmt "${file_path}" 2>&1; then
    echo "✅ Formatted successfully"
else
    # Don't fail the hook if formatting fails, just warn
    echo "⚠️  Warning: zig fmt encountered issues (non-blocking)"
fi

run_zls_diagnostics() {
    if ! command -v zls >/dev/null 2>&1; then
        echo "ℹ️  Skipping ZLS diagnostics (zls not found in PATH)"
        return
    fi

    local project_root="${CLAUDE_PROJECT_DIR:-$PWD}"
    if ! TARGET_FILE="${file_path}" PROJECT_ROOT="${project_root}" python3 <<'PY'
import json
import os
import pathlib
import select
import subprocess
import sys
import time

file_path = pathlib.Path(os.environ["TARGET_FILE"]).resolve()
project_root = pathlib.Path(os.environ.get("PROJECT_ROOT", file_path.parent.as_posix())).resolve()
file_uri = file_path.as_uri()

try:
    file_text = file_path.read_text()
except Exception as exc:
    print(f"⚠️  Warning: unable to read file for diagnostics: {exc}")
    sys.exit(0)

proc = subprocess.Popen(
    ["zls"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
)


def send_message(message):
    data = json.dumps(message).encode("utf-8")
    header = f"Content-Length: {len(data)}\r\n\r\n".encode("ascii")
    try:
        proc.stdin.write(header + data)
        proc.stdin.flush()
    except BrokenPipeError:
        pass


def read_message(deadline):
    if proc.stdout is None:
        return None

    header_bytes = b""
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            return None
        rlist, _, _ = select.select([proc.stdout], [], [], remaining)
        if not rlist:
            continue
        chunk = proc.stdout.read(1)
        if not chunk:
            return None
        header_bytes += chunk
        if header_bytes.endswith(b"\r\n\r\n"):
            break

    header_text = header_bytes.decode("ascii", errors="ignore")
    content_length = 0
    for line in header_text.split("\r\n"):
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        if key.strip().lower() == "content-length":
            try:
                content_length = int(value.strip())
            except ValueError:
                content_length = 0
    if content_length == 0:
        return None

    body = b""
    while len(body) < content_length:
        remaining = deadline - time.time()
        if remaining <= 0:
            return None
        rlist, _, _ = select.select([proc.stdout], [], [], remaining)
        if not rlist:
            continue
        chunk = proc.stdout.read(content_length - len(body))
        if not chunk:
            return None
        body += chunk

    try:
        return json.loads(body.decode("utf-8"))
    except json.JSONDecodeError:
        return None


initialize_params = {
    "processId": None,
    "clientInfo": {"name": "claude-hooks", "version": "1.0"},
    "rootPath": str(project_root),
    "rootUri": project_root.as_uri(),
    "capabilities": {},
    "workspaceFolders": [
        {"uri": project_root.as_uri(), "name": project_root.name}
    ],
    "trace": "off",
}

send_message(
    {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": initialize_params,
    }
)

send_message({"jsonrpc": "2.0", "method": "initialized", "params": {}})

send_message(
    {
        "jsonrpc": "2.0",
        "method": "textDocument/didOpen",
        "params": {
            "textDocument": {
                "uri": file_uri,
                "languageId": "zig",
                "version": 1,
                "text": file_text,
            }
        },
    }
)

diagnostics = None
deadline = time.time() + 6.0

while time.time() < deadline:
    message = read_message(deadline)
    if message is None:
        break
    if message.get("method") == "textDocument/publishDiagnostics":
        params = message.get("params", {})
        if params.get("uri") == file_uri:
            diagnostics = params.get("diagnostics", [])
            break

send_message({"jsonrpc": "2.0", "id": 2, "method": "shutdown", "params": None})
send_message({"jsonrpc": "2.0", "method": "exit", "params": {}})

try:
    proc.stdin.close()
except Exception:
    pass

try:
    proc.terminate()
    proc.wait(timeout=1)
except Exception:
    pass

print(f"🩺 ZLS diagnostics for {file_path}")
severity_map = {1: "Error", 2: "Warning", 3: "Info", 4: "Hint"}

if diagnostics:
    for diag in diagnostics:
        rng = diag.get("range", {})
        start = rng.get("start", {})
        line = start.get("line", 0) + 1
        character = start.get("character", 0) + 1
        severity = severity_map.get(diag.get("severity"), "Info")
        source = diag.get("source") or "zls"
        code = diag.get("code")
        message = (diag.get("message") or "").strip().replace("\n", " ")
        if len(message) > 200:
            message = message[:197] + "..."
        label = f"[{source}:{code}]" if code else f"[{source}]"
        print(f"  L{line}:C{character} {severity} {label} {message}")
else:
    print("  ✅ No diagnostics reported for this file")
PY
    then
        echo "⚠️  Warning: failed to retrieve ZLS diagnostics"
        return
    fi
}

run_zls_diagnostics
