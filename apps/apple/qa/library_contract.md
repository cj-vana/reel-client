# Synthetic library fixture

`fixture_server.py` serves a 144-title synthetic library (96 movies, 48 series) on `127.0.0.1` for the library browsing tests. It makes no outside requests and uses no real media.

Sign in with username `library-demo` and password `demo`. Other usernames starting with `library-` get their own isolated copy of the data.

Titles, years, dates, genres, watched and favorite flags are generated from the title number, so many records tie on name, year and date. That is deliberate: it checks that filtering, sorting and paging stay stable and complete.

The expected behavior is enforced by `library_contract.py` and `test_library_contract.py`. Run the tests from the repository root:

```sh
python3 -B -m unittest discover -s apps/apple/qa -p 'test_*.py'
```
