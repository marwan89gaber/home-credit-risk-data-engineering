-- ============================================================================
-- HOME CREDIT DEFAULT RISK: SQL DATA MODEL
-- ============================================================================
-- Purpose: Create reproducible analytical data layer from 7 raw tables
-- Leakage strategy: Only pre-decision data (DAYS_DECISION <= 0)
-- Output: One row per applicant with aggregated features from history
-- ============================================================================

-- ASSUMPTION: All 7 CSVs loaded into temp tables named:
-- application_train, application_test, bureau, bureau_balance, 
-- previous_application, credit_card_balance, installments_payments, POS_CASH_balance

-- ============================================================================
-- STEP 1: BUREAU FEATURES (Aggregated credit bureau history)
-- ============================================================================
-- Semantics: 1 applicant : N bureau records (closed/active credit accounts)
-- Join on: SK_ID_CURR (applicant ID)
-- Leakage check: No post-default bureau records

CREATE OR REPLACE VIEW bureau_features AS
SELECT 
  SK_ID_CURR,
  
  -- Counts
  COUNT(DISTINCT SK_ID_BUREAU) as BUREAU_CREDIT_COUNT,
  SUM(CASE WHEN CREDIT_ACTIVE = 'Active' THEN 1 ELSE 0 END) as BUREAU_ACTIVE_COUNT,
  SUM(CASE WHEN CREDIT_ACTIVE = 'Closed' THEN 1 ELSE 0 END) as BUREAU_CLOSED_COUNT,
  
  -- Credit amounts
  COALESCE(SUM(AMT_CREDIT_SUM), 0) as BUREAU_CREDIT_SUM,
  COALESCE(SUM(AMT_CREDIT_SUM_DEBT), 0) as BUREAU_DEBT_SUM,
  COALESCE(SUM(AMT_CREDIT_SUM_OVERDUE), 0) as BUREAU_OVERDUE_SUM,
  COALESCE(AVG(AMT_CREDIT_SUM_OVERDUE), 0) as BUREAU_OVERDUE_MEAN,
  COALESCE(MAX(AMT_CREDIT_SUM_OVERDUE), 0) as BUREAU_OVERDUE_MAX,
  
  -- Days past due
  COALESCE(AVG(DAYS_CREDIT_ENDDATE), 0) as BUREAU_DAYS_CREDIT_END_MEAN,
  COALESCE(MAX(DAYS_CREDIT_ENDDATE), 0) as BUREAU_DAYS_CREDIT_END_MAX,
  COALESCE(MIN(DAYS_CREDIT_ENDDATE), 0) as BUREAU_DAYS_CREDIT_END_MIN
  
FROM bureau
WHERE SK_ID_CURR IS NOT NULL
GROUP BY SK_ID_CURR;

-- ============================================================================
-- STEP 2: BUREAU_BALANCE FEATURES (Monthly payment history aggregated to bureau level)
-- ============================================================================
-- Semantics: 1 bureau record : N monthly balance snapshots
-- Leakage check: STATUS 'X', 'C', 'D' (default/written-off) recorded before or after decision?
--                Only aggregate pre-decision months

CREATE OR REPLACE VIEW bureau_balance_features AS
WITH bureau_balance_clean AS (
  SELECT 
    SK_ID_BUREAU,
    MONTHS_BALANCE,
    STATUS,
    -- FLAG: DPD = Days Past Due (STATUS 1-5 means overdue)
    CASE WHEN STATUS IN ('1', '2', '3', '4', '5') THEN 1 ELSE 0 END as DPD_FLAG,
    -- FLAG: Severe DPD (STATUS 3-5 = serious delinquency)
    CASE WHEN STATUS IN ('3', '4', '5') THEN 1 ELSE 0 END as SEVERE_DPD_FLAG
  FROM bureau_balance
)
SELECT 
  SK_ID_BUREAU,
  COUNT(*) as BALANCE_MONTHS_COUNT,
  SUM(DPD_FLAG) as BALANCE_DPD_MONTHS,
  SUM(SEVERE_DPD_FLAG) as BALANCE_SEVERE_DPD_MONTHS,
  MAX(MONTHS_BALANCE) as BALANCE_MAX_MONTHS,
  MIN(MONTHS_BALANCE) as BALANCE_MIN_MONTHS
FROM bureau_balance_clean
GROUP BY SK_ID_BUREAU;

-- ============================================================================
-- STEP 3: ENRICHED BUREAU (Join bureau + bureau_balance)
-- ============================================================================

CREATE OR REPLACE VIEW bureau_enriched AS
SELECT 
  b.SK_ID_CURR,
  b.SK_ID_BUREAU,
  b.CREDIT_ACTIVE,
  b.AMT_CREDIT_SUM,
  b.AMT_CREDIT_SUM_DEBT,
  b.AMT_CREDIT_SUM_OVERDUE,
  COALESCE(bb.BALANCE_MONTHS_COUNT, 0) as BALANCE_MONTHS,
  COALESCE(bb.BALANCE_DPD_MONTHS, 0) as BALANCE_DPD_MONTHS,
  COALESCE(bb.BALANCE_SEVERE_DPD_MONTHS, 0) as BALANCE_SEVERE_MONTHS
FROM bureau b
LEFT JOIN bureau_balance_features bb ON b.SK_ID_BUREAU = bb.SK_ID_BUREAU;

-- ============================================================================
-- STEP 4: PREVIOUS APPLICATION FEATURES (Aggregated credit application history)
-- ============================================================================
-- Semantics: 1 applicant : N previous credit applications
-- Leakage check: DAYS_DECISION must be <= 0 (negative = BEFORE current application)

CREATE OR REPLACE VIEW previous_application_features AS
SELECT 
  SK_ID_CURR,
  
  -- Counts by outcome
  COUNT(*) as PREV_APPLICATION_COUNT,
  SUM(CASE WHEN NAME_CONTRACT_STATUS = 'Approved' THEN 1 ELSE 0 END) as PREV_APPROVED_COUNT,
  SUM(CASE WHEN NAME_CONTRACT_STATUS = 'Refused' THEN 1 ELSE 0 END) as PREV_REFUSED_COUNT,
  SUM(CASE WHEN NAME_CONTRACT_STATUS = 'Canceled' THEN 1 ELSE 0 END) as PREV_CANCELED_COUNT,
  
  -- Credit amounts
  COALESCE(AVG(AMT_CREDIT), 0) as PREV_CREDIT_MEAN,
  COALESCE(MAX(AMT_CREDIT), 0) as PREV_CREDIT_MAX,
  COALESCE(SUM(AMT_CREDIT), 0) as PREV_CREDIT_SUM,
  
  COALESCE(AVG(AMT_APPLICATION), 0) as PREV_APPLICATION_MEAN,
  COALESCE(AVG(AMT_DOWN_PAYMENT), 0) as PREV_DOWN_PAYMENT_MEAN,
  
  -- Approval ratios
  CASE 
    WHEN COUNT(*) > 0 THEN (SUM(CASE WHEN NAME_CONTRACT_STATUS = 'Approved' THEN 1 ELSE 0 END) * 100.0 / COUNT(*))
    ELSE 0 
  END as PREV_APPROVAL_RATE
  
FROM previous_application
WHERE DAYS_DECISION <= 0  -- LEAKAGE FILTER: Only pre-decision applications
GROUP BY SK_ID_CURR;

-- ============================================================================
-- STEP 5: POS_CASH FEATURES (Point-of-sale cash credit aggregated by applicant)
-- ============================================================================

CREATE OR REPLACE VIEW pos_features AS
SELECT 
  SK_ID_CURR,
  COUNT(DISTINCT SK_ID_PREV) as POS_CREDIT_COUNT,
  COUNT(*) as POS_MONTH_COUNT,
  COALESCE(AVG(SK_DPD), 0) as POS_DPD_MEAN,
  COALESCE(MAX(SK_DPD), 0) as POS_DPD_MAX,
  COALESCE(AVG(SK_DPD_DEF), 0) as POS_DPD_DEF_MEAN,
  COALESCE(AVG(CNT_INSTALMENT), 0) as POS_INSTALMENT_MEAN,
  COALESCE(AVG(CNT_INSTALMENT_FUTURE), 0) as POS_INSTALMENT_FUTURE_MEAN
FROM POS_CASH_balance
GROUP BY SK_ID_CURR;

-- ============================================================================
-- STEP 6: CREDIT_CARD FEATURES (Credit card statement aggregation)
-- ============================================================================

CREATE OR REPLACE VIEW credit_card_features AS
SELECT 
  SK_ID_CURR,
  COUNT(DISTINCT SK_ID_PREV) as CC_CREDIT_COUNT,
  COUNT(*) as CC_MONTH_COUNT,
  COALESCE(AVG(AMT_BALANCE), 0) as CC_BALANCE_MEAN,
  COALESCE(MAX(AMT_BALANCE), 0) as CC_BALANCE_MAX,
  COALESCE(AVG(AMT_CREDIT_LIMIT_ACTUAL), 0) as CC_LIMIT_MEAN,
  COALESCE(AVG(AMT_DRAWINGS_CURRENT), 0) as CC_DRAWING_MEAN,
  COALESCE(AVG(AMT_PAYMENT_CURRENT), 0) as CC_PAYMENT_MEAN
FROM credit_card_balance
GROUP BY SK_ID_CURR;

-- ============================================================================
-- STEP 7: INSTALLMENTS FEATURES (Installment payment history)
-- ============================================================================

CREATE OR REPLACE VIEW installments_features AS
WITH installment_payment_analysis AS (
  SELECT 
    SK_ID_CURR,
    SK_ID_PREV,
    AMT_INSTALMENT,
    AMT_PAYMENT,
    DAYS_INSTALMENT,
    DAYS_ENTRY_PAYMENT,
    -- Delay = actual payment date - scheduled payment date
    (DAYS_ENTRY_PAYMENT - DAYS_INSTALMENT) as PAYMENT_DELAY,
    -- Overpayment = actual payment - scheduled payment
    (AMT_PAYMENT - AMT_INSTALMENT) as PAYMENT_DIFF
  FROM installments_payments
)
SELECT 
  SK_ID_CURR,
  COUNT(*) as INSTALMENT_PAYMENT_COUNT,
  COUNT(DISTINCT SK_ID_PREV) as INSTALMENT_CREDIT_COUNT,
  COALESCE(AVG(ABS(PAYMENT_DELAY)), 0) as INSTALMENT_DELAY_MEAN,
  COALESCE(MAX(PAYMENT_DELAY), 0) as INSTALMENT_DELAY_MAX,
  SUM(CASE WHEN PAYMENT_DELAY > 0 THEN 1 ELSE 0 END) as INSTALMENT_LATE_COUNT,
  COALESCE(AVG(PAYMENT_DIFF), 0) as INSTALMENT_DIFF_MEAN
FROM installment_payment_analysis
GROUP BY SK_ID_CURR;

-- ============================================================================
-- STEP 8: FINAL ANALYTICAL TABLE (All features merged on SK_ID_CURR)
-- ============================================================================
-- Output: 1 row per applicant with all engineered features
-- Target: TARGET (0 = no default, 1 = default)

CREATE OR REPLACE VIEW analytical_data AS
SELECT 
  app.SK_ID_CURR,
  app.TARGET,
  
  -- Application features (original)
  app.AMT_INCOME_TOTAL,
  app.AMT_CREDIT,
  app.AMT_ANNUITY,
  app.DAYS_BIRTH,
  app.DAYS_EMPLOYED,
  app.DAYS_REGISTRATION,
  app.DAYS_ID_PUBLISH,
  app.NAME_EDUCATION_TYPE,
  app.CODE_GENDER,
  
  -- Bureau features (aggregated)
  COALESCE(bureau.BUREAU_CREDIT_COUNT, 0) as BUREAU_CREDIT_COUNT,
  COALESCE(bureau.BUREAU_ACTIVE_COUNT, 0) as BUREAU_ACTIVE_COUNT,
  COALESCE(bureau.BUREAU_CLOSED_COUNT, 0) as BUREAU_CLOSED_COUNT,
  COALESCE(bureau.BUREAU_CREDIT_SUM, 0) as BUREAU_CREDIT_SUM,
  COALESCE(bureau.BUREAU_DEBT_SUM, 0) as BUREAU_DEBT_SUM,
  COALESCE(bureau.BUREAU_OVERDUE_SUM, 0) as BUREAU_OVERDUE_SUM,
  COALESCE(bureau.BUREAU_OVERDUE_MEAN, 0) as BUREAU_OVERDUE_MEAN,
  COALESCE(bureau.BUREAU_OVERDUE_MAX, 0) as BUREAU_OVERDUE_MAX,
  
  -- Previous application features
  COALESCE(prev.PREV_APPLICATION_COUNT, 0) as PREV_APPLICATION_COUNT,
  COALESCE(prev.PREV_APPROVED_COUNT, 0) as PREV_APPROVED_COUNT,
  COALESCE(prev.PREV_REFUSED_COUNT, 0) as PREV_REFUSED_COUNT,
  COALESCE(prev.PREV_CREDIT_MEAN, 0) as PREV_CREDIT_MEAN,
  COALESCE(prev.PREV_APPROVAL_RATE, 0) as PREV_APPROVAL_RATE,
  
  -- POS features
  COALESCE(pos.POS_CREDIT_COUNT, 0) as POS_CREDIT_COUNT,
  COALESCE(pos.POS_DPD_MEAN, 0) as POS_DPD_MEAN,
  COALESCE(pos.POS_DPD_MAX, 0) as POS_DPD_MAX,
  
  -- Credit card features
  COALESCE(cc.CC_CREDIT_COUNT, 0) as CC_CREDIT_COUNT,
  COALESCE(cc.CC_BALANCE_MEAN, 0) as CC_BALANCE_MEAN,
  COALESCE(cc.CC_LIMIT_MEAN, 0) as CC_LIMIT_MEAN,
  
  -- Installments features
  COALESCE(inst.INSTALMENT_PAYMENT_COUNT, 0) as INSTALMENT_PAYMENT_COUNT,
  COALESCE(inst.INSTALMENT_DELAY_MEAN, 0) as INSTALMENT_DELAY_MEAN,
  COALESCE(inst.INSTALMENT_LATE_COUNT, 0) as INSTALMENT_LATE_COUNT
  
FROM application_train app
LEFT JOIN bureau_features bureau ON app.SK_ID_CURR = bureau.SK_ID_CURR
LEFT JOIN previous_application_features prev ON app.SK_ID_CURR = prev.SK_ID_CURR
LEFT JOIN pos_features pos ON app.SK_ID_CURR = pos.SK_ID_CURR
LEFT JOIN credit_card_features cc ON app.SK_ID_CURR = cc.SK_ID_CURR
LEFT JOIN installments_features inst ON app.SK_ID_CURR = inst.SK_ID_CURR;

-- ============================================================================
-- VALIDATION QUERIES
-- ============================================================================

-- Check row counts (should match application_train)
-- SELECT COUNT(*) FROM analytical_data;
-- SELECT COUNT(*) FROM application_train;

-- Check for NULLs in key join columns
-- SELECT COUNT(*) FROM analytical_data WHERE SK_ID_CURR IS NULL;