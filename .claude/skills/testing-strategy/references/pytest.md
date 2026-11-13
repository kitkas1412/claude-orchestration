# Pytest

- Check `pyproject.toml`, `pytest.ini` and `conftest.py` for existing markers, fixtures and plugins.
- Use plain functions and `assert`. Use `pytest.mark.parametrize` for input tables.
- Keep fixtures small and scoped as narrowly as possible. Avoid `autouse` unless the repository already relies on it.
- Use `tmp_path` for files and `monkeypatch` for environment variables and attributes.
- Use `pytest.raises(..., match=...)` to assert both exception type and message.
- For async code, follow the project's existing `pytest-asyncio` or `anyio` mode.
- Freeze time with the library the project already uses. Do not add one without reporting it.
- Run one test first with `pytest path/to/test_file.py::test_name -q`, and then the full suite.
