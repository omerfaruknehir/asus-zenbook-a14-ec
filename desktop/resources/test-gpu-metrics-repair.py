#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "a14_resources_gpu_metrics", ROOT / "repair-a14-gpu-metrics.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

MSM = r'''use anyhow::{Result, bail};

impl GpuImpl for MsmGpu {
    fn encode_usage(&self) -> Result<f64> {
        Ok(0.0)
    }

    fn decode_usage(&self) -> Result<f64> {
        // A separate video block exists, but this is not a real utilization reading.
        Ok(0.0)
    }

    fn power_usage(&self) -> Result<f64> {
        self.hwmon_power_usage()
    }

    fn vram_frequency(&self) -> Result<f64> {
        bail!("VRAM clock not exposed for MSM/Adreno")
    }
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory() as raw:
        repo = Path(raw)
        path = repo / MODULE.MSM_RS
        path.parent.mkdir(parents=True)
        path.write_text(MSM)

        assert MODULE.apply(repo, False) == 0
        changed = path.read_text()
        assert 'bail!("encode usage not exposed for MSM/Adreno")' in changed
        assert 'bail!("decode usage not exposed for MSM/Adreno")' in changed
        assert "Ok(0.0)" not in changed
        assert "self.hwmon_power_usage()" in changed
        assert "VRAM clock not exposed" in changed

        assert MODULE.apply(repo, False) == 0
        assert path.read_text() == changed


if __name__ == "__main__":
    main()
