#!/usr/bin/env bash
# make-demo-repo.sh — build a small, realistic-looking git repo for demo
# recordings. Deterministic content so every re-recording looks identical.
#
# Usage: make-demo-repo.sh <target-dir>
set -euo pipefail

target="${1:?usage: make-demo-repo.sh <target-dir>}"
rm -rf "$target"
mkdir -p "$target/src"
cd "$target"

git init -q
git config user.name "Demo"
git config user.email "demo@example.com"

cat > src/tasks.ts <<'EOF'
export interface Task {
  id: string;
  title: string;
  done: boolean;
}

export function createTask(title: string): Task {
  return { id: crypto.randomUUID(), title, done: false };
}

export function completeTask(task: Task): Task {
  return { ...task, done: true };
}
EOF

cat > src/store.ts <<'EOF'
import { Task } from "./tasks";

const tasks: Task[] = [];

export function addTask(task: Task): void {
  tasks.push(task);
}

export function listTasks(): Task[] {
  return [...tasks];
}
EOF

cat > package.json <<'EOF'
{
  "name": "taskly",
  "version": "0.3.0",
  "type": "module"
}
EOF

git add . && git commit -qm "feat: task model and in-memory store"
echo "export const VERSION = \"0.3.0\";" > src/version.ts
git add . && git commit -qm "chore: add version constant"

# Working-tree changes for the demo: two modified files + one new file.
cat > src/tasks.ts <<'EOF'
export interface Task {
  id: string;
  title: string;
  done: boolean;
  dueDate?: Date;
}

export function createTask(title: string, dueDate?: Date): Task {
  return { id: crypto.randomUUID(), title, done: false, dueDate };
}

export function completeTask(task: Task): Task {
  return { ...task, done: true };
}

export function isOverdue(task: Task, now = new Date()): boolean {
  return !task.done && !!task.dueDate && task.dueDate < now;
}
EOF

cat >> src/store.ts <<'EOF'

export function overdueTasks(now = new Date()): Task[] {
  return tasks.filter((t) => !t.done && t.dueDate && t.dueDate < now);
}
EOF

cat > src/notify.ts <<'EOF'
import { Task } from "./tasks";

export function overdueSummary(tasks: Task[]): string {
  if (tasks.length === 0) return "Nothing overdue.";
  return `${tasks.length} task(s) overdue: ` + tasks.map((t) => t.title).join(", ");
}
EOF

echo "demo repo ready: $target"
