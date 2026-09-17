import pandas as pd
import sys
from pathlib import Path

def test_data_pipeline():
    """Validate analytical_data.csv quality"""
    
    project_path = Path(__file__).resolve().parent
    analytical_file = project_path / "data" / "processed" / "analytical_data.csv"
    
    print("=" * 80)
    print("DATA QUALITY TESTS")
    print("=" * 80)
    
    # TEST 1: File exists
    assert analytical_file.exists(), f"✗ analytical_data.csv not found at {analytical_file}"
    print("✓ TEST 1: File exists")
    
    # TEST 2: Load data
    df = pd.read_csv(analytical_file)
    print(f"✓ TEST 2: Data loaded ({len(df):,} rows × {len(df.columns)} columns)")
    
    # TEST 3: Row count matches application_train
    expected_rows = 307511
    assert len(df) == expected_rows, f"✗ Expected {expected_rows} rows, got {len(df)}"
    print(f"✓ TEST 3: Row count valid ({len(df):,} rows)")
    
    # TEST 4: Target variable present and binary
    assert "TARGET" in df.columns, "✗ TARGET column missing"
    assert df["TARGET"].isin([0, 1]).all(), "✗ TARGET not binary"
    print(f"✓ TEST 4: TARGET valid (binary, 0/1)")
    
    # TEST 5: No leakage - check DAYS_DECISION
    data_path = project_path / "data" / "raw"
    if (data_path / "previous_application.csv").exists():
        prev_app = pd.read_csv(data_path / "previous_application.csv")
        post_decision = (prev_app["DAYS_DECISION"] > 0).sum()
        assert post_decision == 0, f"✗ Leakage detected: {post_decision} post-decision records"
        print(f"✓ TEST 5: Leakage check passed (DAYS_DECISION <= 0)")
    else:
        print("⊘ TEST 5: Skipped (raw data not available)")
    
    # TEST 6: Primary key unique
    assert df["SK_ID_CURR"].is_unique, "✗ SK_ID_CURR not unique"
    print(f"✓ TEST 6: PK unique ({df['SK_ID_CURR'].nunique():,} applicants)")
    
    # TEST 7: No critical nulls
    critical_cols = ["SK_ID_CURR", "TARGET", "AMT_INCOME_TOTAL"]
    for col in critical_cols:
        nulls = df[col].isna().sum()
        assert nulls == 0, f"✗ {col} has {nulls} NULLs"
    print(f"✓ TEST 7: Critical columns have no NULLs")
    
    # TEST 8: Data types reasonable
    assert df["TARGET"].dtype in ['int64', 'int32'], f"✗ TARGET wrong dtype: {df['TARGET'].dtype}"
    assert df["SK_ID_CURR"].dtype in ['int64', 'int32'], f"✗ SK_ID_CURR wrong dtype"
    print(f"✓ TEST 8: Data types valid")
    
    # TEST 9: Default rate ~8%
    default_rate = df["TARGET"].mean()
    assert 0.07 < default_rate < 0.09, f"✗ Default rate {default_rate:.2%} unexpected"
    print(f"✓ TEST 9: Default rate valid ({default_rate:.2%})")
    
    # TEST 10: Aggregated features have no extreme nulls
    agg_cols = [col for col in df.columns if col.startswith("BUREAU_") or col.startswith("PREV_")]
    for col in agg_cols:
        null_pct = df[col].isna().sum() / len(df) * 100
        assert null_pct < 50, f"✗ {col}: {null_pct:.1f}% missing (too high)"
    print(f"✓ TEST 10: Aggregated features have acceptable coverage")
    
    print("\n" + "=" * 80)
    print("ALL TESTS PASSED ✓")
    print("=" * 80)
    return True

if __name__ == "__main__":
    try:
        test_data_pipeline()
        sys.exit(0)
    except AssertionError as e:
        print(f"\n✗ TEST FAILED: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n✗ UNEXPECTED ERROR: {e}")
        sys.exit(1)