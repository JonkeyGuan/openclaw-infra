#!/bin/bash
# Clear all tracing data from MLflow experiment (SQLite backend)
set -uo pipefail

MLFLOW_NS="${MLFLOW_NS:-mlflow}"
EXPERIMENT_ID="${EXPERIMENT_ID:-0}"

MLFLOW_POD=$(oc get pods -n "$MLFLOW_NS" -l app=mlflow \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "$MLFLOW_POD" ]; then
  echo "ERROR: mlflow pod not found in $MLFLOW_NS"
  exit 1
fi

COUNT=$(oc exec "$MLFLOW_POD" -n "$MLFLOW_NS" -- \
  python3 -c "
import sqlite3
conn = sqlite3.connect('/mlflow-data/mlflow.db')
cur = conn.cursor()
cur.execute('SELECT count(*) FROM trace_info WHERE experiment_id = $EXPERIMENT_ID')
print(cur.fetchone()[0])
conn.close()
" 2>/dev/null)

echo "Found $COUNT traces in experiment $EXPERIMENT_ID"

if [ "$COUNT" -eq 0 ]; then
  echo "Nothing to delete."
  exit 0
fi

read -p "Delete all $COUNT traces? [y/N] " -r
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
  echo "Aborted."
  exit 0
fi

oc exec "$MLFLOW_POD" -n "$MLFLOW_NS" -- \
  python3 -c "
import sqlite3
conn = sqlite3.connect('/mlflow-data/mlflow.db')
cur = conn.cursor()
eid = $EXPERIMENT_ID
cur.execute('SELECT request_id FROM trace_info WHERE experiment_id = ?', (eid,))
rids = [r[0] for r in cur.fetchall()]
if rids:
    ph = ','.join('?' * len(rids))
    for t in ['trace_metrics', 'trace_tags', 'trace_request_metadata']:
        cur.execute(f'DELETE FROM {t} WHERE request_id IN ({ph})', rids)
        print(f'  {t}: {cur.rowcount} deleted')
    cur.execute(f'DELETE FROM span_metrics WHERE trace_id IN ({ph})', rids)
    print(f'  span_metrics: {cur.rowcount} deleted')
    cur.execute('DELETE FROM spans WHERE experiment_id = ?', (eid,))
    print(f'  spans: {cur.rowcount} deleted')
    cur.execute('DELETE FROM trace_info WHERE experiment_id = ?', (eid,))
    print(f'  trace_info: {cur.rowcount} deleted')
conn.commit()
conn.close()
"

echo "Done."
