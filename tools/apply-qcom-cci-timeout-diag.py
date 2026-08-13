#!/usr/bin/env python3
import pathlib
import shutil
import sys

if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} PATH/TO/i2c-qcom-cci.c")

path = pathlib.Path(sys.argv[1]).resolve()
text = path.read_text()

old = '''\tif (!wait_for_completion_timeout(&cci->master[master].irq_complete,\n\t\t\t\t\t CCI_TIMEOUT)) {\n\t\tdev_err(cci->dev, "master %d queue %d timeout\\n",\n\t\t\tmaster, queue);\n\t\tcci_reset(cci);\n\t\tcci_init(cci);\n\t\treturn -ETIMEDOUT;\n\t}\n'''

new = '''\tif (!wait_for_completion_timeout(&cci->master[master].irq_complete,\n\t\t\t\t\t CCI_TIMEOUT)) {\n\t\tu32 irq_status, irq_mask, cur_word_cnt, exec_word_cnt;\n\t\tu32 cur_cmd, report_status;\n\n\t\t/*\n\t\t * Capture the controller state before cci_reset() destroys the\n\t\t * evidence. This is diagnostic-only and intentionally does not\n\t\t * alter timeout recovery or retry the I2C transaction.\n\t\t */\n\t\tirq_status = readl(cci->base + CCI_IRQ_STATUS_0);\n\t\tirq_mask = readl(cci->base + CCI_IRQ_MASK_0);\n\t\tcur_word_cnt = readl(cci->base +\n\t\t\t\t\tCCI_I2C_Mm_Qn_CUR_WORD_CNT(master, queue));\n\t\texec_word_cnt = readl(cci->base +\n\t\t\t\t\t CCI_I2C_Mm_Qn_EXEC_WORD_CNT(master, queue));\n\t\tcur_cmd = readl(cci->base + CCI_I2C_Mm_Qn_CUR_CMD(master, queue));\n\t\treport_status = readl(cci->base +\n\t\t\t\t\t CCI_I2C_Mm_Qn_REPORT_STATUS(master, queue));\n\n\t\tdev_err(cci->dev,\n\t\t\t"master %d queue %d timeout: irq_status=%#010x irq_mask=%#010x cur_words=%u exec_words=%u cur_cmd=%#010x report=%#010x master_status=%d rpm_active=%d\\n",\n\t\t\tmaster, queue, irq_status, irq_mask, cur_word_cnt,\n\t\t\texec_word_cnt, cur_cmd, report_status,\n\t\t\tcci->master[master].status, pm_runtime_active(cci->dev));\n\n\t\tcci_reset(cci);\n\t\tcci_init(cci);\n\t\treturn -ETIMEDOUT;\n\t}\n'''

if new in text:
    raise SystemExit("already patched")
if text.count(old) != 1:
    raise SystemExit(
        "refusing to patch: expected stock cci_run_queue() timeout block was not found exactly once"
    )

backup = path.with_name(path.name + ".pre-timeout-diag")
if backup.exists():
    raise SystemExit(f"refusing to overwrite existing backup: {backup}")
shutil.copy2(path, backup)
path.write_text(text.replace(old, new, 1))
print(f"patched: {path}")
print(f"backup:  {backup}")
