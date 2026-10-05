# Timing transformation checks

These focused checks document individual timing transformations, separately
from the eight recurring bounded formal harnesses.

- `scripts/timing/prove_frontend.ps1`: extracts the current redirect and pipeline
  equations and compares them with the preceding form. It creates
  `build/frontend_equivalence.sv` and a log under `results/timing/`.
- `scripts/timing/prove_cache_data.ps1`: checks the cache read-data selection
  whenever the selected output is valid. It creates
  `build/cache_data_equivalence.sv` and a log under `results/timing/`.
- `width_cast_equivalence.sv`: checks the address-row/bank width conversions
  for widths 1 through 32.

Run from the repository root with Yosys on PATH:

```powershell
powershell -ExecutionPolicy Bypass -File scripts/timing/prove_frontend.ps1
powershell -ExecutionPolicy Bypass -File scripts/timing/prove_cache_data.ps1
yosys -Q -T -p "read_verilog -formal -sv formal/experiments/width_cast_equivalence.sv; prep -top width_cast_equivalence -flatten; chformal -lower; sat -verify -prove-asserts"
```

Source checks belong here and in `scripts/timing/`; generated harnesses and
tool logs belong in `build/` and `results/`.
