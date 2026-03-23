---
name: demo
description: |
    Interactive demo of the dev-team workflow. Scaffolds a tiny project in a temp
    worktree, injects a ticket, and runs the full agent pipeline so you can see
    real agents working. Cleans up after. Usage: /demo [orchestrate|kickoff|specs]
argument-hint: "[orchestrate|kickoff|specs]"
---

# Demo

Run a live, end-to-end demo of the dev-team plugin using a throwaway micro-project.
Real agents, real output, disposable result.

## Arguments

- `/demo` or `/demo orchestrate` — full `/orchestrate` flow (default)
- `/demo kickoff` — planning only (`/kickoff`), no implementation
- `/demo specs` — spec generation and validation (`/generate-specs` + `/check-specs`)

---

## Step 0: Preflight checks

Verify the plugin is ready:

1. Check that `.claude/memory/memory.db` exists (or `.claude/memory/` with .md files)
   - If not: tell the user to run `/init-team` first and stop
2. Check that AGENTS.md exists
   - If not: tell the user to run `/init-orchestration` first and stop
3. If demo mode is `orchestrate`, verify Agent Teams is enabled:
   - Check `.claude/settings.json` for `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`
   - If not set: tell the user to run `/init-orchestration` first and stop

Print:
```
Demo preflight: OK
Mode: <orchestrate|kickoff|specs>
```

---

## Step 1: Scaffold the demo project

Create a temporary worktree with a minimal Go project that has an obvious feature gap.

```bash
# Create branch and worktree
DEMO_BRANCH="demo/dev-team-$(date +%s)"
git worktree add "$TMPDIR/demo-project" -b "$DEMO_BRANCH"
```

Write these files into the worktree:

### `main.go`
```go
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"time"
)

// Task represents a todo item
type Task struct {
	ID        int       `json:"id"`
	Title     string    `json:"title"`
	Done      bool      `json:"done"`
	CreatedAt time.Time `json:"created_at"`
}

// TaskStore manages tasks in a JSON file
type TaskStore struct {
	path  string
	tasks []Task
}

// NewTaskStore creates a store backed by the given file path
func NewTaskStore(path string) *TaskStore {
	return &TaskStore{path: path}
}

// Load reads tasks from disk
func (s *TaskStore) Load() error {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			s.tasks = []Task{}
			return nil
		}
		return err
	}
	return json.Unmarshal(data, &s.tasks)
}

// Save writes tasks to disk
func (s *TaskStore) Save() error {
	data, err := json.MarshalIndent(s.tasks, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(s.path, data, 0644)
}

// Add creates a new task
func (s *TaskStore) Add(title string) Task {
	id := 1
	for _, t := range s.tasks {
		if t.ID >= id {
			id = t.ID + 1
		}
	}
	task := Task{
		ID:        id,
		Title:     title,
		Done:      false,
		CreatedAt: time.Now(),
	}
	s.tasks = append(s.tasks, task)
	return task
}

// Complete marks a task as done
func (s *TaskStore) Complete(id int) bool {
	for i, t := range s.tasks {
		if t.ID == id {
			s.tasks[i].Done = true
			return true
		}
	}
	return false
}

// List returns all tasks
func (s *TaskStore) List() []Task {
	return s.tasks
}

func main() {
	store := NewTaskStore("tasks.json")
	if err := store.Load(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	if len(os.Args) < 2 {
		fmt.Println("Usage: todo <add|complete|list> [args...]")
		os.Exit(1)
	}

	switch os.Args[1] {
	case "add":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "usage: todo add <title>")
			os.Exit(1)
		}
		task := store.Add(os.Args[2])
		store.Save()
		fmt.Printf("Added: #%d %s\n", task.ID, task.Title)
	case "complete":
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "usage: todo complete <id>")
			os.Exit(1)
		}
		var id int
		fmt.Sscanf(os.Args[2], "%d", &id)
		if store.Complete(id) {
			store.Save()
			fmt.Printf("Completed: #%d\n", id)
		} else {
			fmt.Fprintf(os.Stderr, "task #%d not found\n", id)
			os.Exit(1)
		}
	case "list":
		for _, t := range store.List() {
			status := "[ ]"
			if t.Done {
				status = "[x]"
			}
			fmt.Printf("%s #%d %s\n", status, t.ID, t.Title)
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", os.Args[1])
		os.Exit(1)
	}
}
```

### `main_test.go`
```go
package main

import (
	"os"
	"testing"
)

func TestTaskStore_AddAndList(t *testing.T) {
	path := t.TempDir() + "/tasks.json"
	store := NewTaskStore(path)

	task := store.Add("Buy groceries")
	if task.ID != 1 {
		t.Errorf("expected ID 1, got %d", task.ID)
	}
	if task.Title != "Buy groceries" {
		t.Errorf("expected title 'Buy groceries', got %q", task.Title)
	}

	tasks := store.List()
	if len(tasks) != 1 {
		t.Errorf("expected 1 task, got %d", len(tasks))
	}
}

func TestTaskStore_Complete(t *testing.T) {
	path := t.TempDir() + "/tasks.json"
	store := NewTaskStore(path)

	store.Add("Test task")
	if !store.Complete(1) {
		t.Error("expected Complete to return true")
	}

	tasks := store.List()
	if !tasks[0].Done {
		t.Error("expected task to be done")
	}
}

func TestTaskStore_SaveAndLoad(t *testing.T) {
	path := t.TempDir() + "/tasks.json"
	store := NewTaskStore(path)

	store.Add("Persist me")
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}

	store2 := NewTaskStore(path)
	if err := store2.Load(); err != nil {
		t.Fatal(err)
	}

	tasks := store2.List()
	if len(tasks) != 1 {
		t.Errorf("expected 1 task, got %d", len(tasks))
	}
	if tasks[0].Title != "Persist me" {
		t.Errorf("expected 'Persist me', got %q", tasks[0].Title)
	}
}

func TestTaskStore_LoadNonExistent(t *testing.T) {
	store := NewTaskStore(t.TempDir() + "/nope.json")
	if err := store.Load(); err != nil {
		t.Errorf("expected nil error for nonexistent file, got %v", err)
	}
	if len(store.List()) != 0 {
		t.Error("expected empty task list")
	}
}

func TestTaskStore_CompleteNotFound(t *testing.T) {
	store := NewTaskStore(t.TempDir() + "/tasks.json")
	if store.Complete(999) {
		t.Error("expected Complete to return false for nonexistent ID")
	}
}

func TestMain(m *testing.M) {
	os.Exit(m.Run())
}
```

### `go.mod`
```
module demo-todo

go 1.22
```

### `README.md`
```markdown
# demo-todo

A minimal CLI todo app used for dev-team plugin demos.
```

Commit the scaffold:

```bash
cd "$TMPDIR/demo-project"
git add -A
git commit -m "scaffold: demo-todo CLI app"
```

Print:
```
Demo project scaffolded at $TMPDIR/demo-project
Branch: <DEMO_BRANCH>
Files: main.go, main_test.go, go.mod, README.md
Tests: 5 passing
```

Verify tests pass:
```bash
cd "$TMPDIR/demo-project" && go test ./...
```

If tests fail, fix the scaffold before proceeding.

---

## Step 2: Define the demo ticket

The demo ticket adds a feature that's missing from the scaffold: **CSV export of tasks**.

```
DEMO-001: Export Tasks to CSV
As a user, I want to export my task list to a CSV file so I can
share it or import it into a spreadsheet.

Acceptance Criteria:
AC1: `todo export <path>` writes all tasks to a CSV file
AC2: CSV includes columns: id, title, done, created_at
AC3: If no tasks exist, print "No tasks to export" and exit with code 0
AC4: If the file already exists, overwrite it without prompting
```

Print the ticket to the user:
```
Demo ticket:
  DEMO-001: Export Tasks to CSV
  ACs: export command, 4 CSV columns, empty-list message, overwrite behavior
```

---

## Step 3: Run the selected demo mode

Change to the demo worktree before running any commands:

```bash
cd "$TMPDIR/demo-project"
```

### Mode: `orchestrate` (default)

Tell the user:
```
Starting /orchestrate demo. You'll see real agents working.
Approve at each gate — or type "skip" to auto-approve all gates.

The orchestrator will:
1. Assess scope (Gate 1)
2. Surface questions if any (Gate 2)
3. Plan and create task graph (Gate 3)
4. Dispatch agents to implement (Gate 4-5)
5. Present PR-ready diff (Gate 6)
```

Run the full orchestrate flow. Pass the ticket text inline:

```
/orchestrate DEMO-001 "Export Tasks to CSV. As a user, I want to export my task list to a CSV file so I can share it or import it into a spreadsheet. AC1: todo export <path> writes all tasks to a CSV file. AC2: CSV includes columns: id, title, done, created_at. AC3: If no tasks exist, print 'No tasks to export' and exit with code 0. AC4: If the file already exists, overwrite it without prompting."
```

**Important**: Do NOT actually invoke `/orchestrate` as a skill — instead, execute the
orchestrate workflow manually using the same agent dispatch pattern:

1. Present the scope assessment (Gate 1) and wait for user confirmation
2. Run PM agent to check for ambiguities (Gate 2)
3. Run Tech Lead agent to write a spec and plan (Gate 3) — wait for user approval
4. Create tasks via TaskCreate
5. Dispatch IC4 agent to implement the export feature (TDD — tests first)
6. Run QA agent to validate against ACs
7. Present the final diff summary (Gate 6)

At each gate, pause and show the user what's happening. This is a teaching moment.

### Mode: `kickoff`

Tell the user:
```
Starting /kickoff demo. PM and Tech Lead will plan the feature.
No implementation — just spec + task graph.
```

Run the kickoff flow:

1. Run PM agent to review the ticket, confirm ACs
2. Run Tech Lead agent to write a spec and produce a task graph
3. Create tasks via TaskCreate
4. Present the plan summary

### Mode: `specs`

Tell the user:
```
Starting /generate-specs demo. Tech Lead will read the codebase and write specs.
```

Run the specs flow:

1. Run Tech Lead agent to read main.go and main_test.go
2. Write a spec for the existing TaskStore behavior (SPEC-001-task-store.md)
3. Run `/check-specs SPEC-001` to validate the spec against code
4. Show the MATCH/MISSING/DIFFERS report

---

## Step 4: Summary and cleanup

After the demo completes (or the user cancels), print a summary:

```
Demo complete!

What you saw:
- <mode-specific summary of what agents did>

To try this on your own project:
- /orchestrate <TICKET-ID>    — full autopilot
- /kickoff <TICKET-ID>        — planning only
- /generate-specs             — spec baseline

Runbooks: docs/runbooks/
```

Ask the user:
```
Clean up the demo worktree? (y/n)
```

If yes:
```bash
# Return to original directory first
cd <original working directory>
git worktree remove "$TMPDIR/demo-project" --force
git branch -D "$DEMO_BRANCH"
```

If no:
```
Demo project left at: $TMPDIR/demo-project
Branch: <DEMO_BRANCH>
Clean up later: git worktree remove $TMPDIR/demo-project && git branch -D <DEMO_BRANCH>
```
