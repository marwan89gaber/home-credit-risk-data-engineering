# Data Architecture Diagram

## Data Flow: Raw CSV → 8 Views → 1 Analytical Table

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         7 RAW CSV TABLES                                │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐               │
│  │application   │  │bureau        │  │bureau_balance    │               │
│  │_train        │  │              │  │                  │               │
│  │(307k rows)   │  │(1.7M rows)   │  │(30M rows)        │               │
│  └──────────────┘  └──────────────┘  └──────────────────┘               │
│                                                                         │
│  ┌──────────────────┐  ┌────────────────┐  ┌──────────────────┐         │
│  │previous          │  │credit_card     │  │installments      │         │
│  │_application      │  │_balance        │  │_payments         │         │
│  │(1.67M rows)      │  │(3.8M rows)     │  │(13.6M rows)      │         │
│  └──────────────────┘  └────────────────┘  └──────────────────┘         │
│                                                                         │
│  ┌──────────────────┐                                                   │
│  │POS_CASH_balance  │                                                   │
│  │(10M rows)        │                                                   │
│  └──────────────────┘                                                   │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓↓↓ SQL AGGREGATION (schema.sql)
┌─────────────────────────────────────────────────────────────────────────┐
│                       8 SQL VIEWS (Aggregations)                        │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  View 1: bureau_features                                                │
│  ├─ 1 row per applicant (LEFT JOIN bureau + aggregations)               │
│  └─ Columns: BUREAU_CREDIT_COUNT, BUREAU_ACTIVE_COUNT, ...              │
│                                                                         │
│  View 2: bureau_balance_features (nested aggregation)                   │
│  ├─ 1 row per bureau record (aggregates monthly balances)               │
│  └─ Columns: BALANCE_MONTHS_COUNT, BALANCE_DPD_MONTHS, ...              │
│                                                                         │
│  View 3: bureau_enriched (bureau + bureau_balance merged)               │
│                                                                         │
│  View 4: previous_application_features                                  │
│  ├─ 1 row per applicant                                                 │
│  ├─ LEAKAGE FILTER: WHERE DAYS_DECISION <= 0 (pre-decision only)        │
│  └─ Columns: PREV_APPLICATION_COUNT, PREV_APPROVAL_RATE, ...            │
│                                                                         │
│  View 5: pos_features (1 row per applicant)                             │
│  View 6: credit_card_features (1 row per applicant)                     │
│  View 7: installments_features (1 row per applicant)                    │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓↓↓ FINAL LEFT JOINS
┌─────────────────────────────────────────────────────────────────────────┐
│                    ANALYTICAL_DATA VIEW (Final)                         │
├─────────────────────────────────────────────────────────────────────────┤
│                                                                         │
│  1 Row per Applicant × 50+ Features                                     │
│                                                                         │
│  ┌────────────────────────────────────────────────────────────────┐     │
│  │SK_ID_CURR | TARGET | AMT_INCOME_TOTAL | BUREAU_CREDIT_COUNT    │     │
│  │... 50+ engineered features from 7 tables ...                   │     │
│  └────────────────────────────────────────────────────────────────┘     │
│                                                                         │
│  Output: analytical_data.csv (307,511 rows × ~50 columns)               │
│                                                                         │
└─────────────────────────────────────────────────────────────────────────┘
                                    ↓↓↓ EXPORT
┌─────────────────────────────────────────────────────────────────────────┐
│                  Person 2 + Person 3/4 ML Pipeline                      │
│  (EDA, Feature Engineering, ML Models, DL Models, Evaluation)           │
└─────────────────────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### 1. **Leakage Prevention Strategy**
- ✅ `previous_application`: WHERE `DAYS_DECISION <= 0` (only pre-decision apps)
- ✅ `bureau_balance`: Aggregated to bureau level (monthly snapshots risk post-default labels)
- ✅ All aggregations computed BEFORE the application decision

### 2. **Join Semantics (Handling 1:N Relationships)**

| Relationship | Handling |
|--------------|----------|
| 1 applicant : N bureau records | GROUP BY SK_ID_CURR, COUNT/SUM/AVG |
| 1 bureau : N monthly balances | GROUP BY SK_ID_BUREAU, aggregate DPD flags |
| 1 applicant : N previous apps | GROUP BY SK_ID_CURR, count approvals/refusals |
| 1 applicant : N POS records | GROUP BY SK_ID_CURR, max/mean delinquency |

### 3. **Null Handling**
- Missing aggregates → COALESCE to 0 (applicant has no historical data)
- Example: If applicant has no bureau records, `BUREAU_CREDIT_COUNT = 0`

## View Details

### View 1: `bureau_features`
**Purpose:** Aggregate credit bureau history per applicant

**Source:** `bureau` table (1.7M records)

**Aggregation:**
```sql
SELECT 
  SK_ID_CURR,
  COUNT(DISTINCT SK_ID_BUREAU) as BUREAU_CREDIT_COUNT,
  SUM(CASE WHEN CREDIT_ACTIVE = 'Active' THEN 1 ELSE 0 END) as BUREAU_ACTIVE_COUNT,
  COALESCE(MAX(AMT_CREDIT_SUM_OVERDUE), 0) as BUREAU_OVERDUE_MAX,
  ... (8 features)
FROM bureau
GROUP BY SK_ID_CURR
```

**Output:** 307,511 rows (one per applicant)

---

### View 2: `bureau_balance_features`
**Purpose:** Aggregate monthly delinquency patterns per bureau record

**Source:** `bureau_balance` table (30M records)

**Key Logic:**
- DPD_FLAG: 1 if STATUS in ('1','2','3','4','5') [Days Past Due]
- SEVERE_DPD_FLAG: 1 if STATUS in ('3','4','5') [Serious Delinquency]

**Output:** 1.7M rows (one per bureau record)

---

### View 3: `bureau_enriched`
**Purpose:** Merge bureau features with delinquency patterns

**Join Logic:**
```sql
SELECT b.*, COALESCE(bb.BALANCE_DPD_MONTHS, 0)
FROM bureau b
LEFT JOIN bureau_balance_features bb ON b.SK_ID_BUREAU = bb.SK_ID_BUREAU
```

**Note:** This is intermediate; final aggregation happens in next view

---

### View 4: `previous_application_features`
**Purpose:** Aggregate credit application history per applicant

**Source:** `previous_application` table (1.67M records)

**LEAKAGE FILTER:**
```sql
WHERE DAYS_DECISION <= 0  -- Only pre-decision applications
```

**Aggregations:**
- PREV_APPLICATION_COUNT: Total previous applications
- PREV_APPROVED_COUNT: How many were approved
- PREV_APPROVAL_RATE: Percentage approved (100 * approved / total)

**Output:** 307,511 rows

---

### View 5: `pos_features`
**Purpose:** Aggregate point-of-sale credit history

**Source:** `POS_CASH_balance` table (10M records)

**Key Metrics:**
- POS_CREDIT_COUNT: Distinct SK_ID_PREV (number of POS facilities)
- POS_DPD_MEAN: Average SK_DPD (days past due, negative = on-time)
- POS_DPD_MAX: Maximum SK_DPD (worst delinquency)

**Output:** 307,511 rows

---

### View 6: `credit_card_features`
**Purpose:** Aggregate credit card statement patterns

**Source:** `credit_card_balance` table (3.8M records)

**Key Metrics:**
- CC_CREDIT_COUNT: Number of credit cards
- CC_BALANCE_MEAN: Average monthly balance
- CC_LIMIT_MEAN: Average credit limit

**Output:** 307,511 rows

---

### View 7: `installments_features`
**Purpose:** Aggregate installment payment history

**Source:** `installments_payments` table (13.6M records)

**Key Metrics:**
```
PAYMENT_DELAY = DAYS_ENTRY_PAYMENT - DAYS_INSTALMENT
  (negative = early payment, positive = late payment)

LATE_PAYMENT_FLAG = 1 if PAYMENT_DELAY > 0
```

**Aggregations:**
- INSTALMENT_PAYMENT_COUNT: Total payment records
- INSTALMENT_DELAY_MEAN: Average payment delay
- INSTALMENT_LATE_COUNT: Number of late payments

**Output:** 307,511 rows

---

### View 8: `analytical_data` (FINAL)
**Purpose:** Single-table analytical dataset ready for ML

**Schema:**
- 307,511 rows (one per applicant)
- 50+ columns (demographics + engineered features)
- All NULLs in aggregates → 0 (safe for ML)
- No missing values in critical features (PK, TARGET)

**Final JOINs:**
```sql
SELECT 
  app.SK_ID_CURR, app.TARGET, app.AMT_INCOME_TOTAL, ...
  COALESCE(bureau.BUREAU_CREDIT_COUNT, 0),
  COALESCE(prev.PREV_APPLICATION_COUNT, 0),
  COALESCE(pos.POS_CREDIT_COUNT, 0),
  COALESCE(cc.CC_CREDIT_COUNT, 0),
  COALESCE(inst.INSTALMENT_PAYMENT_COUNT, 0)
FROM application_train app
LEFT JOIN bureau_features bureau ON app.SK_ID_CURR = bureau.SK_ID_CURR
LEFT JOIN previous_application_features prev ON app.SK_ID_CURR = prev.SK_ID_CURR
LEFT JOIN pos_features pos ON app.SK_ID_CURR = pos.SK_ID_CURR
LEFT JOIN credit_card_features cc ON app.SK_ID_CURR = cc.SK_ID_CURR
LEFT JOIN installments_features inst ON app.SK_ID_CURR = inst.SK_ID_CURR
```

---

## Data Quality Checks

### Row Count Validation
| Table | Expected Rows | Actual | Status |
|-------|---------------|--------|--------|
| application_train | 307,511 | 307,511 | ✓ |
| analytical_data | 307,511 | 307,511 | ✓ |

**Interpretation:** No row multiplication from joins. All applicants preserved.

### Leakage Validation
- DAYS_DECISION in previous_application: All ≤ 0 ✓
- No post-decision bureau_balance records ✓
- No future payment information ✓

### Missing Value Patterns
| Feature | Missing % | Treatment |
|---------|-----------|-----------|
| SK_ID_CURR | 0% | Required (PK) |
| TARGET | 0% | Required (label) |
| BUREAU_CREDIT_COUNT | 0% | COALESCE to 0 |
| PREV_APPLICATION_COUNT | 0% | COALESCE to 0 |

**Interpretation:** Applicants with no historical data get count=0 (correct semantics)

---

## Reproducibility

### Files Required
1. `data/raw/` — 7 CSV files (application_train, bureau, bureau_balance, previous_application, credit_card_balance, installments_payments, POS_CASH_balance)
2. `sql/schema.sql` — SQL DDL for all 8 views
3. `sql/analytical_queries.sql` — 10 proof queries
4. `load_and_validate.py` — Python script to run pipeline

### Running the Pipeline
```bash
# 1. Load CSVs + create views + validate + export
python load_and_validate.py

# 2. Run all analytical queries
python run_analytical_queries.py

# 3. Output
# - data/processed/analytical_data.csv
# - reports/analytical_query_results/*.csv
# - Validation output printed to console
```

### Expected Runtime
- DuckDB in-memory: ~2-3 minutes (first time)
- Subsequent runs: ~30 seconds (cached)

---

## Next Steps

### Person 2 (EDA + Feature Engineering)
1. Load `analytical_data.csv`
2. Cross-validate features against `DATA_DICTIONARY.csv`
3. Check for outliers, distributions, correlations
4. Perform statistical tests on key features

### Person 3/4 (ML Models)
1. Use `analytical_data.csv` as input
2. Implement baseline (Logistic Regression)
3. Compare classical models (Random Forest, XGBoost)
4. Tune hyperparameters

### Person 5 (DL + Explainability)
1. Build MLP on normalized numerical features
2. Compare against best classical model
3. Generate SHAP explanations

### Person 6 (Deployment)
1. Create Streamlit dashboard
2. Accept applicant features → predict default probability
3. Display top 3 risk factors using SHAP

---

## Design Rationale

### Why SQL Views Instead of Pandas?
- ✅ **Reproducibility:** SQL is deterministic, version-controllable
- ✅ **Auditability:** Each view is documented with formula + source
- ✅ **Scalability:** Easy to swap DuckDB for PostgreSQL/BigQuery
- ✅ **Leakage Prevention:** WHERE clauses prevent accidental post-decision data

### Why Aggregate to Applicant Level?
- ✅ **Target Alignment:** Each row = decision point (application date)
- ✅ **Feature Consistency:** 1 row = 1 label (no duplication issues)
- ✅ **ML Simplicity:** Tabular data, no complex feature engineering needed

### Why COALESCE to 0?
- ✅ **Semantic Correctness:** "No historical data" = "no credit accounts" = 0
- ✅ **ML Safety:** No NaN in tree-based models (no missing branch logic)
- ✅ **Interpretability:** BUREAU_CREDIT_COUNT=0 clearly means "no bureau records"

---

## Limitations & Future Work

### Current Limitations
1. **Time-based features:** No seasonal patterns captured (fixed aggregation)
2. **Recency bias:** Old data weighted equally to recent data
3. **Outlier handling:** No removal (left for Person 2/3/4)

### Future Enhancements
1. **Feature store:** Add version tracking + recomputation schedules
2. **Incremental updates:** Handle new applicants without full recomputation
3. **Monitoring:** Add data drift detection on new batches
4. **Optimization:** Materialize views to disk for faster re-runs

---

## Appendix: SQL Concepts Used

### CTE (Common Table Expression)
```sql
WITH overdue_accounts AS (
  SELECT SK_ID_CURR, COUNT(*) as n_overdue
  FROM bureau
  WHERE AMT_CREDIT_SUM_OVERDUE > 0
  GROUP BY SK_ID_CURR
)
SELECT * FROM overdue_accounts
```
**Use:** Name intermediate results for clarity

### Window Functions
```sql
NTILE(10) OVER (ORDER BY AMT_INCOME_TOTAL)  -- Deciles
RANK() OVER (PARTITION BY CODE_GENDER ORDER BY AMT_INCOME_TOTAL DESC)  -- Rank within gender
```
**Use:** Percentile calculations, ranking

### Conditional Aggregation
```sql
SUM(CASE WHEN CREDIT_ACTIVE = 'Active' THEN 1 ELSE 0 END) as ACTIVE_COUNT
```
**Use:** Count records matching a condition within GROUP BY

### LEFT JOIN with COALESCE
```sql
SELECT app.SK_ID_CURR, COALESCE(agg.COUNT, 0) as feature
FROM app LEFT JOIN agg ON app.SK_ID_CURR = agg.SK_ID_CURR
```
**Use:** Preserve all applicants even if they have no historical records
