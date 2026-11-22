"""Look up programming documentation with the PC's dedicated Docker MCP profile."""
import asyncio
import os
import re
from shutil import which

from sweatcaster.searxng_search import _public_url


def _blocks(result):
    if result.isError:
        return ""
    return "\n".join(part.text[:16000] for part in result.content[:4] if part.type == "text")[:20000]


def excerpts(result, title):
    rows = []
    for segment in re.split(r"(?m)^-{5,}\s*$|(?m:^### )", result):
        link = re.search(r"(?m)^Source:\s*(https?://[^\s<>]+)", segment)
        if not link:
            continue
        url = _public_url(link[1].rstrip(").,"))
        body = (segment[:link.start()] + segment[link.end():]).strip()
        if url and body and not any(row["url"] == url for row in rows):
            rows.append({"title": title, "url": url, "excerpt": body[:1200]})
        if len(rows) == 3:
            break
    return rows


async def _lookup(query, library):
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    keep = {"LOCALAPPDATA", "APPDATA", "USERPROFILE", "SYSTEMROOT", "COMSPEC", "PROGRAMDATA", "PROGRAMFILES",
            "PROGRAMFILES(X86)", "PATH", "TEMP", "TMP", "DOCKER_CONFIG", "HOME"}
    env = {k: v for k, v in os.environ.items() if k.upper() in keep}
    command = StdioServerParameters(command="docker", args=["mcp", "gateway", "run", "--profile=fadedai-docs",
                                    "--tools=resolve-library-id,query-docs", "--log-calls=false", "--watch=false"], env=env)
    with open(os.devnull, "w") as log:
        async with stdio_client(command, errlog=log) as streams, ClientSession(*streams) as session:
            await session.initialize()
            match = await session.call_tool("resolve-library-id", {"libraryName": library, "query": query})
            chosen = re.search(r"(?im)^- Context7-compatible library ID: (/[-\w./]+)\s*$", _blocks(match))
            if not chosen:
                return []
            response = await session.call_tool("query-docs", {"libraryId": chosen[1], "query": query})
            return excerpts(_blocks(response), library + " · Context7")


def lookup(query, library):
    if not which("docker"):
        return []
    try:
        return asyncio.run(asyncio.wait_for(_lookup(query, library), timeout=18))
    except Exception:
        # Optional Docker profile. The caller can still use ordinary web search.
        return []
