import duckdb
import pandas as pd
import re
from pathlib import Path

# Connect to DuckDB (in-memory, no setup needed)
conn = duckdb.connect(':memory:')

# Load all 7 CSVs as DuckDB tables
project_path = Path(__file__).resolve().parent
data_path = project_path / "data"
processed_path = data_path / "processed"
processed_path.mkdir(exist_ok=True)

tables_to_load = [
    "application_train",
    "application_test",
    "bureau",
    "bureau_balance",
    "previous_application",
    "credit_card_balance",
    "installments_payments",
    "POS_CASH_balance"
]

print("=" * 80)
print("LOADING CSVs INTO DUCKDB")
print("=" * 80)

for table_name in tables_to_load:
    csv_file = data_path / f"{table_name}.csv"
    if csv_file.exists():
        conn.execute(f"""
            CREATE TABLE {table_name} AS
            SELECT * FROM read_csv('{csv_file}')
        """)
        row_count = conn.execute(f"SELECT COUNT(*) FROM {table_name}").fetchone()[0]
        print(f"✓ {table_name}: {row_count:,} rows")
    else:
        print(f"✗ {table_name} NOT FOUND")

print("\n" + "=" * 80)
print("RUNNING SCHEMA.SQL (Creating Views)")
print("=" * 80)

# Read the schema file
with open(project_path / "sql" / "scheme.sql", "r") as f:
    schema_sql = f.read()

# Remove SQL comments before splitting the file into statements.
schema_sql = re.sub(r"--.*$", "", schema_sql, flags=re.MULTILINE)

# Execute schema (creates all 8 views)
# Note: Split by semicolon to handle multiple statements
for statement in schema_sql.split(";"):
    statement = statement.strip()
    if statement:
        try:
            conn.execute(statement)
            print(f"✓ {statement[:60]}...")
        except Exception as e:
            print(f"✗ ERROR: {e}")

print("\n" + "=" * 80)
print("VALIDATE: Row counts (should match application_train)")
print("=" * 80)

app_train_count = conn.execute("SELECT COUNT(*) FROM application_train").fetchone()[0]
analytical_count = conn.execute("SELECT COUNT(*) FROM analytical_data").fetchone()[0]

print(f"application_train rows: {app_train_count:,}")
print(f"analytical_data rows: {analytical_count:,}")
print(f"Match: {app_train_count == analytical_count}")

print("\n" + "=" * 80)
print("SAMPLE: First 5 rows from analytical_data")
print("=" * 80)

sample = conn.execute("""
    SELECT SK_ID_CURR, TARGET, AMT_INCOME_TOTAL, 
           BUREAU_CREDIT_COUNT, PREV_APPLICATION_COUNT
    FROM analytical_data
    LIMIT 5
""").fetchall()

for row in sample:
    print(row)

print("\n" + "=" * 80)
print("SAVE ANALYTICAL_DATA TO CSV")
print("=" * 80)

# Export analytical_data to CSV
conn.execute("""
    COPY analytical_data 
    TO ?
""", [str(processed_path / "analytical_data.csv")])

print(f"✓ Saved to: {processed_path / 'analytical_data.csv'}")

conn.close()