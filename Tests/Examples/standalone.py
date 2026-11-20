"""Exercise the examples after installing only their executable files."""

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from Benchmarks.compare import Client


def check_installation(products, directory):
    commands = {name: shutil.copy2(products / name, directory / name) for name in ("math", "math-complex")}
    home = directory / "home"
    home.mkdir()
    environment = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
                       XDG_CACHE_HOME=str(home / ".cache"), PATH="")
    result = subprocess.check_output([commands["math-complex"], "mult", "6", "7"],
                                     cwd=directory, env=environment, text=True)
    assert result.strip() == "42", result
    assert not list(home.rglob("REPLico")), "A calculator command installed the MCP runtime"

    for name in commands:
        command = [str(commands[name])] + (["--mcp"] if name == "math-complex" else [])
        client = Client(command, environment, directory)
        try:
            assert client.initialization["serverInfo"]["name"] == name, client.initialization
            available, _ = client.request("tools/list", {})
            assert "js" in {tool["name"] for tool in available["tools"]}, available
            if name == "math":
                assert not list(home.rglob("REPLico")), "MCP discovery installed the runtime"
            response, _ = client.evaluate("nodeRepl.write(await math.mult({a: 6, b: 7}))")
            assert response["content"] == [{"type": "text", "text": "42"}], response
            assert list(home.rglob("REPLico")), "The runtime did not use the isolated user cache"
        finally:
            client.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as temporary:
        check_installation(Path(sys.argv[1]), Path(temporary))
    print("Standalone math and math-complex passed.")
