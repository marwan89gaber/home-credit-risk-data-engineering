-- ============================================================================
-- ANALYTICAL SQL QUERIES (10+)
-- Demonstrates: JOIN, CTE, window functions, aggregation
-- ============================================================================

-- ============================================================================
-- QUERY 1: Multi-table JOIN — Applicant with bureau summary
-- ============================================================================
SELECT 
  app.SK_ID_CURR,
  app.AMT_INCOME_TOTAL,
  app.TARGET,
  COUNT(DISTINCT bureau.SK_ID_BUREAU) as n_bureau_records,
  SUM(bureau.AMT_CREDIT_SUM) as total_bureau_credit,
  MAX(bureau.AMT_CREDIT_SUM_OVERDUE) as max_overdue
FROM application_train app
LEFT JOIN bureau bureau ON app.SK_ID_CURR = bureau.SK_ID_CURR
GROUP BY app.SK_ID_CURR, app.AMT_INCOME_TOTAL, app.TARGET
LIMIT 10;

-- ============================================================================
-- QUERY 2: CTE Example — Find applicants with overdue accounts
-- ============================================================================
WITH overdue_summary AS (
  SELECT 
    SK_ID_CURR,
    COUNT(*) as n_overdue_bureau,
    SUM(AMT_CREDIT_SUM_OVERDUE) as total_overdue
  FROM bureau
  WHERE AMT_CREDIT_SUM_OVERDUE > 0
  GROUP BY SK_ID_CURR
)
SELECT 
  app.SK_ID_CURR,
  app.TARGET,
  COALESCE(overdue.n_overdue_bureau, 0) as overdue_count,
  COALESCE(overdue.total_overdue, 0) as total_overdue
FROM application_train app
LEFT JOIN overdue_summary overdue ON app.SK_ID_CURR = overdue.SK_ID_CURR
WHERE COALESCE(overdue.n_overdue_bureau, 0) > 0
LIMIT 10;

-- ============================================================================
-- QUERY 3: Window Function — Rank applicants by income within gender segment
-- ============================================================================
SELECT 
  SK_ID_CURR,
  CODE_GENDER,
  AMT_INCOME_TOTAL,
  TARGET,
  RANK() OVER (PARTITION BY CODE_GENDER ORDER BY AMT_INCOME_TOTAL DESC) as income_rank_by_gender,
  ROW_NUMBER() OVER (PARTITION BY CODE_GENDER ORDER BY AMT_INCOME_TOTAL DESC) as row_num
FROM application_train
LIMIT 10;

-- ============================================================================
-- QUERY 4: CTE + Window — Default rate by income decile
-- ============================================================================
WITH income_deciles AS (
  SELECT 
    SK_ID_CURR,
    TARGET,
    AMT_INCOME_TOTAL,
    NTILE(10) OVER (ORDER BY AMT_INCOME_TOTAL) as income_decile
  FROM application_train
)
SELECT 
  income_decile,
  COUNT(*) as count_applicants,
  SUM(TARGET) as default_count,
  ROUND(SUM(TARGET) * 100.0 / COUNT(*), 2) as default_rate
FROM income_deciles
GROUP BY income_decile
ORDER BY income_decile;

-- ============================================================================
-- QUERY 5: Multi-table aggregation — Previous applications per applicant
-- ============================================================================
SELECT 
  app.SK_ID_CURR,
  app.TARGET,
  COUNT(prev.SK_ID_PREV) as n_previous_apps,
  SUM(CASE WHEN prev.NAME_CONTRACT_STATUS = 'Approved' THEN 1 ELSE 0 END) as approved_count,
  SUM(CASE WHEN prev.NAME_CONTRACT_STATUS = 'Refused' THEN 1 ELSE 0 END) as refused_count,
  ROUND(100.0 * SUM(CASE WHEN prev.NAME_CONTRACT_STATUS = 'Approved' THEN 1 ELSE 0 END) / COUNT(prev.SK_ID_PREV), 2) as approval_rate
FROM application_train app
LEFT JOIN previous_application prev ON app.SK_ID_CURR = prev.SK_ID_CURR
  AND prev.DAYS_DECISION <= 0  -- LEAKAGE FILTER
GROUP BY app.SK_ID_CURR, app.TARGET
LIMIT 10;

-- ============================================================================
-- QUERY 6: Leakage validation — Confirm no post-decision previous apps
-- ============================================================================
SELECT 
  COUNT(*) as post_decision_records
FROM previous_application
WHERE DAYS_DECISION > 0;
-- Expected: 0 (if 0, no leakage)

-- ============================================================================
-- QUERY 7: CTE + JOIN — Credit bureau health score by applicant
-- ============================================================================
WITH bureau_health AS (
  SELECT 
    SK_ID_CURR,
    COUNT(DISTINCT SK_ID_BUREAU) as n_accounts,
    SUM(CASE WHEN CREDIT_ACTIVE = 'Active' THEN 1 ELSE 0 END) as active_accounts,
    SUM(CASE WHEN CREDIT_ACTIVE = 'Closed' THEN 1 ELSE 0 END) as closed_accounts,
    COALESCE(MAX(AMT_CREDIT_SUM_OVERDUE), 0) as max_overdue,
    COALESCE(SUM(AMT_CREDIT_SUM_OVERDUE), 0) as total_overdue
  FROM bureau
  GROUP BY SK_ID_CURR
)
SELECT 
  app.SK_ID_CURR,
  app.TARGET,
  health.n_accounts,
  health.active_accounts,
  health.closed_accounts,
  health.max_overdue,
  health.total_overdue,
  CASE 
    WHEN health.total_overdue > 0 THEN 'At Risk'
    WHEN health.active_accounts > 3 THEN 'Moderate Risk'
    ELSE 'Low Risk'
  END as bureau_health_category
FROM application_train app
LEFT JOIN bureau_health health ON app.SK_ID_CURR = health.SK_ID_CURR
WHERE health.total_overdue > 0 OR health.n_accounts > 5
LIMIT 10;

-- ============================================================================
-- QUERY 8: Window function — Running total of defaults by income band
-- ============================================================================
WITH income_bands AS (
  SELECT 
    SK_ID_CURR,
    TARGET,
    AMT_INCOME_TOTAL,
    CASE 
      WHEN AMT_INCOME_TOTAL < 100000 THEN '< 100k'
      WHEN AMT_INCOME_TOTAL < 250000 THEN '100k - 250k'
      WHEN AMT_INCOME_TOTAL < 500000 THEN '250k - 500k'
      ELSE '> 500k'
    END as income_band
  FROM application_train
)
SELECT 
  income_band,
  COUNT(*) as n_applicants,
  SUM(TARGET) as defaults,
  ROUND(100.0 * SUM(TARGET) / COUNT(*), 2) as default_rate,
  SUM(SUM(TARGET)) OVER (ORDER BY income_band) as running_default_total
FROM income_bands
GROUP BY income_band
ORDER BY income_band;

-- ============================================================================
-- QUERY 9: Complex JOIN — Applicants with both bureau AND previous app data
-- ============================================================================
SELECT 
  app.SK_ID_CURR,
  app.TARGET,
  COUNT(DISTINCT bureau.SK_ID_BUREAU) as n_bureau,
  COUNT(DISTINCT prev.SK_ID_PREV) as n_previous_apps,
  COALESCE(MAX(bureau.AMT_CREDIT_SUM_OVERDUE), 0) as max_bureau_overdue,
  COALESCE(SUM(CASE WHEN prev.NAME_CONTRACT_STATUS = 'Approved' THEN 1 ELSE 0 END), 0) as approved_prev_apps
FROM application_train app
LEFT JOIN bureau bureau ON app.SK_ID_CURR = bureau.SK_ID_CURR
LEFT JOIN previous_application prev ON app.SK_ID_CURR = prev.SK_ID_CURR
  AND prev.DAYS_DECISION <= 0
GROUP BY app.SK_ID_CURR, app.TARGET
HAVING COUNT(DISTINCT bureau.SK_ID_BUREAU) > 0 AND COUNT(DISTINCT prev.SK_ID_PREV) > 0
LIMIT 10;

-- ============================================================================
-- QUERY 10: CTE + window function — Percentile rank of debt-to-income ratio
-- ============================================================================
WITH debt_analysis AS (
  SELECT 
    app.SK_ID_CURR,
    app.TARGET,
    app.AMT_INCOME_TOTAL,
    COALESCE(SUM(bureau.AMT_CREDIT_SUM_DEBT), 0) as total_bureau_debt,
    COALESCE(SUM(bureau.AMT_CREDIT_SUM_DEBT), 0) / NULLIF(app.AMT_INCOME_TOTAL, 0) as debt_to_income_ratio
  FROM application_train app
  LEFT JOIN bureau bureau ON app.SK_ID_CURR = bureau.SK_ID_CURR
  GROUP BY app.SK_ID_CURR, app.TARGET, app.AMT_INCOME_TOTAL
)
SELECT 
  SK_ID_CURR,
  TARGET,
  AMT_INCOME_TOTAL,
  total_bureau_debt,
  ROUND(debt_to_income_ratio, 4) as debt_to_income,
  PERCENT_RANK() OVER (ORDER BY debt_to_income_ratio) as debt_ratio_percentile
FROM debt_analysis
WHERE debt_to_income_ratio IS NOT NULL
ORDER BY debt_to_income_ratio DESC
LIMIT 10;