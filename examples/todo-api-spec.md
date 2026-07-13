# Example spec: Todo API

A deliberately small spec to test-drive boil-the-ocean on a disposable project.
Expect a run of ~3 sprints. Try it:

```bash
mkdir /tmp/ocean-demo && cd /tmp/ocean-demo && git init && npm init -y
cp <boil-the-ocean>/examples/todo-api-spec.md docs/SPEC.md
ocean init docs/SPEC.md --verify-cmd "npm test" --goal "ship the demo todo API"
ocean-daemon doctor && ocean-daemon start
```

---

## Goal

A minimal HTTP JSON API for managing todos, in Node.js, with tests.

## Requirements

1. **Storage**: todos persisted to a local JSON file (`data/todos.json`). Shape:
   `{ id, title, done, createdAt }`. Writes must be atomic (no corrupt file on kill).
2. **Endpoints**:
   - `GET /todos` — list, newest first; `?done=true|false` filter
   - `POST /todos` — create from `{ title }`; 400 on missing/empty title
   - `PATCH /todos/:id` — update `title` and/or `done`; 404 on unknown id
   - `DELETE /todos/:id` — remove; 404 on unknown id
3. **Quality**:
   - Test suite runnable with `npm test` (pick and justify the framework)
   - No external database; standard library HTTP or a micro-framework (justify choice)
   - README with run/test instructions and example curl calls
4. **Nice-to-have (only if all above is done and verified)**:
   - `GET /health` returning `{ status: "ok", todos: <count> }`

## Constraints

- Node 18+, no TypeScript (keep the demo dependency-light).
- Every ambiguity in this spec is yours to decide — journal it.
