"""Run local repository routines with per-step recovery after a PC restart."""
from contextlib import closing, contextmanager
import sqlite3
from typing import TypedDict


class Routine(TypedDict):
    repo: str
    action: str
    refreshed: bool
    indexed: bool


@contextmanager
def worker_lock(root, name="routine-worker.sqlite3"):
    # A separate short-lived database connection releases its lock on process exit.
    with closing(sqlite3.connect(root / name, timeout=0)) as connection:
        try:
            connection.execute("BEGIN IMMEDIATE")
        except sqlite3.OperationalError as error:
            if error.sqlite_errorcode not in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
                raise
            yield False
        else:
            try:
                yield True
            finally:
                connection.rollback()


def run(root, key, library, repo, action):
    try:
        from langgraph.checkpoint.sqlite import SqliteSaver
        from langgraph.graph import END, START, StateGraph
    except ImportError:
        if action == "refresh_repository":
            library.refresh(repo)
        library.index(repo)
        return

    def refresh(state):
        library.refresh(state["repo"])
        return {"refreshed": True}

    def index(state):
        library.index(state["repo"])
        return {"indexed": True}

    graph = StateGraph(Routine)
    graph.add_node("refresh", refresh)
    graph.add_node("index", index)
    graph.add_conditional_edges(START, lambda s: "refresh" if s["action"] == "refresh_repository" else "index",
                                ["refresh", "index"])
    graph.add_edge("refresh", "index")
    graph.add_edge("index", END)
    config = {"configurable": {"thread_id": key}}
    with SqliteSaver.from_conn_string(str(root / "routine-steps.sqlite3")) as saver:
        runner = graph.compile(checkpointer=saver)
        start = None if saver.get_tuple(config) else {"repo": repo, "action": action, "refreshed": False, "indexed": False}
        state = runner.get_state(config)
        if start is not None or state.next:
            runner.invoke(start, config=config, durability="sync")
        if not runner.get_state(config).values.get("indexed"):
            raise RuntimeError("Indekseringen blev ikke bekræftet.")


def forget(root, key):
    path = root / "routine-steps.sqlite3"
    if not path.is_file():
        return
    try:
        from langgraph.checkpoint.sqlite import SqliteSaver
    except ImportError:
        return
    with SqliteSaver.from_conn_string(str(path)) as saver:
        saver.delete_thread(key)
