#!/usr/bin/env python3
"""Test a running local Judge0 instance; no third-party Python packages needed."""
import argparse
import base64
import io
import json
import sys
import time
import urllib.request
import zipfile


def encode(value):
    return base64.b64encode(value.encode()).decode()


def request(base_url, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(
        base_url + path, data=data, headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=15) as response:
        return json.load(response)


def check(base_url, name, source, status, output=None, files=None, stdin=""):
    payload = {
        "language_id": 54,
        "source_code": encode(source),
        "stdin": encode(stdin),
        "cpu_time_limit": 2,
        "wall_time_limit": 5,
        "memory_limit": 128000,
    }
    if output is not None:
        payload["expected_output"] = encode(output)
    if files is not None:
        archive = io.BytesIO()
        with zipfile.ZipFile(archive, "w") as bundle:
            for filename, contents in files.items():
                bundle.writestr(filename, contents)
        payload["additional_files"] = base64.b64encode(archive.getvalue()).decode()
    token = request(base_url, "/submissions?base64_encoded=true&wait=false", payload)["token"]
    deadline = time.monotonic() + 60
    while True:
        result = request(base_url, f"/submissions/{token}?base64_encoded=true")
        if result["status"]["id"] > 2:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError(f"{name}: submission stayed queued or processing for 60 seconds")
        time.sleep(0.25)
    if result["status"]["id"] != status:
        raise RuntimeError(f"{name}: unexpected result: {json.dumps(result)}")
    if output is not None:
        actual = base64.b64decode(result.get("stdout") or "").decode()
        if actual != output:
            raise RuntimeError(f"{name}: expected {output!r}, received {actual!r}")
    if status == 6 and not result.get("compile_output"):
        raise RuntimeError(f"{name}: compiler diagnostics were missing")
    print(f"PASS: {name} ({result['status']['description']})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default="http://127.0.0.1:2358")
    args = parser.parse_args()
    base_url = args.base_url.rstrip("/")
    check(base_url, "C++ with stdin", '#include <iostream>\nint main(){int x; std::cin >> x; std::cout << x * 2 << "\\n";}', 3, "42\n", stdin="21\n")
    check(base_url, "Extra header file", '#include <iostream>\n#include "answer.h"\nint main(){std::cout << answer() << "\\n";}', 3, "42\n", files={"answer.h": "inline int answer(){return 42;}\n"})
    check(base_url, "Compiler diagnostics", "int main(){invalid syntax;}", 6)
    check(base_url, "Time limit", "int main(){for(;;){}}", 5)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)
