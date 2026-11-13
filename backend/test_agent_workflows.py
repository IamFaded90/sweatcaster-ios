import json
from datetime import datetime, timezone

import pytest

from sweatcaster.agent_workflows import AgentWorkflows
from sweatcaster.repository_library import RepositoryLibrary


class Library(RepositoryLibrary):
    def __init__(self, root):
        super().__init__(root, root / 'index.sqlite', lambda rows: [[1, 2] for _ in rows])
        self.indexed = []

    def _head(self, slug):
        return self.workspace, 'base'

    def index(self, repo):
        self.indexed.append(repo)


def test_memory_persists_and_separates_repos(tmp_path):
    library = Library(tmp_path)
    store = AgentWorkflows(tmp_path, library)
    store.remember('global', 'preference', 'Use Danish labels')
    item = store.remember('user/first', 'architecture', 'SQLite stores the inventory')
    store = AgentWorkflows(tmp_path, library)
    assert len(store.recall('user/first', 'inventory')) == 2
    assert store.recall('user/second', 'inventory') == ['Use Danish labels']
    assert store.forget(item)
    assert len(store.memories()) == 1


def test_schedule_runs_once_and_static_checks_refuse_bad_code(tmp_path):
    library = Library(tmp_path)
    store = AgentWorkflows(tmp_path, library)
    assert store.validate('job', {'app.py': 'x = 1\n'})
    with pytest.raises(SyntaxError):
        store.validate('job', {'app.py': 'if\n'})
    (tmp_path / 'routines.json').write_text(json.dumps([
        {'action': 'reindex_repository', 'repo': 'user/repo', 'hour': 2},
        {'action': 'shell', 'repo': 'user/other', 'hour': 2},
    ]))
    store.run_due(datetime(2026, 11, 8, 0, tzinfo=timezone.utc))
    assert library.indexed == []
    instant = datetime(2026, 11, 8, 2, tzinfo=timezone.utc)
    store.run_due(instant)
    AgentWorkflows(tmp_path, library).run_due(instant)
    assert library.indexed == ['user/repo']
    assert store.routine_status(instant) == [
        {'action': 'reindex_repository', 'repo': 'user/repo', 'hour': 2, 'today': 'completed'}
    ]
    with pytest.raises(ValueError):
        store.configure_routines([{'action': 'shell', 'repo': 'user/repo', 'hour': 2}])
