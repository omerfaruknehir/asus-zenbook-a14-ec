#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location(
    "a14_resources_repair", ROOT / "repair-a14-cpu-info.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

BROKEN_PAGE = """#[derive(CompositeTemplate)]
#[template(resource = \"/net/nokyan/Resources/ui/pages/cpu.ui\")]
pub struct ResCPU {
    #[template_child]
    pub architecture: TemplateChild<adw::ActionRow>,
    pub microarchitecture: TemplateChild<adw::ActionRow>,
}
"""

UI = """<interface>
<object class=\"AdwActionRow\" id=\"microarchitecture\"/>
</interface>
"""


def main() -> None:
    with tempfile.TemporaryDirectory() as raw:
        repo = Path(raw)
        page = repo / MODULE.CPU_PAGE
        ui = repo / MODULE.CPU_UI
        page.parent.mkdir(parents=True)
        ui.parent.mkdir(parents=True)
        page.write_text(BROKEN_PAGE)
        ui.write_text(UI)

        assert MODULE.apply(repo, False) == 0
        repaired = page.read_text()
        assert repaired.count("#[template_child]") == 2
        assert "#[template_child]\n    pub microarchitecture" in repaired

        assert MODULE.apply(repo, False) == 0
        assert page.read_text() == repaired


if __name__ == "__main__":
    main()
