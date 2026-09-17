import duckdb
import pandas as pd
import re
from pathlib import Path

# Reconnect and reload (or keep conn open)
conn = duckdb.connect(':memory:')

# Load CSVs again (quick)
project_path = Path(__file__).resolve().parent
data_path = project_path / "data"
tables = [
    "application_train", "bureau", "bureau_balance", 
    "previous_application", "credit_card_balance", 
    "installments_payments", "POS_CASH_balance"
]

for table in tables:
    conn.execute(f"""
        CREATE TABLE {table} AS
        SELECT * FROM read_csv('{data_path / f'{table}.csv'}')
    """)

# Load schema
with open(project_path / "sql" / "scheme.sql", "r") as f:
    schema_sql = re.sub(r"--.*$", "", f.read(), flags=re.MULTILINE)
    for statement in schema_sql.split(";"):
        if statement.strip():
            conn.execute(statement)

# Now run analytical queries
with open(project_path / "sql" / "anallytical_queries.sql", "r") as f:
    queries = f.read().split(";")

print("=" * 80)
print("RUNNING 10 ANALYTICAL QUERIES")
print("=" * 80)

results = {}

for i, query in enumerate(queries, 1):
    query = query.strip()
    if not query:
        continue
    
    try:
        # Extract comment (query name)
        query_name = next(
            (
                line.replace("--", "").strip()
                for line in query.split("\n")
                if re.match(r"\s*--\s*QUERY\s+\d+\s*:", line, re.IGNORECASE)
            ),
            f"Query {i}",
        )
        query = re.sub(r"--.*$", "", query, flags=re.MULTILINE).strip()
        if not query:
            continue
        
        # Run query
        result = conn.execute(query).fetchdf()
        results[query_name] = result
        
        print(f"\n✓ {query_name}")
        print(f"  Rows: {len(result)}")
        print(f"  Columns: {result.shape[1]}")
        print(f"  Preview:\n{result.head(3)}")
        
    except Exception as e:
        print(f"\n✗ Query {i}: {str(e)[:100]}")

# Save results to CSV
output_dir = project_path / "reports" / "analytical_query_results"
output_dir.mkdir(parents=True, exist_ok=True)

for query_name, df in results.items():
    safe_name = re.sub(r"[^A-Za-z0-9]+", "_", query_name).strip("_").lower()
    df.to_csv(output_dir / f"{safe_name}.csv", index=False)
    print(f"Saved: {safe_name}.csv")

conn.close()