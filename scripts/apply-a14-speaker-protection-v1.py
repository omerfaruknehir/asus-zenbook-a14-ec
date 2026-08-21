#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Apply and verify the A14 WSA884x VISENSE transport to exact Linux 7.1.5.

V1 deliberately uses deterministic source transformations instead of a hand-written
unified diff. The source tree must be exact stable v7.1.5, and every pristine
anchor must match exactly once before it is replaced.
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

BASE_COMMIT = "155b42bec9cbb6b8cdc47dd9bd09503a81fbe493"

YAML = Path("Documentation/devicetree/bindings/sound/qcom,wsa8840.yaml")
DTS = Path("arch/arm64/boot/dts/qcom/x1-asus-zenbook-a14.dtsi")
SWR = Path("drivers/soundwire/qcom.c")
WSA_MACRO = Path("sound/soc/codecs/lpass-wsa-macro.c")
WSA = Path("sound/soc/codecs/wsa884x.c")
Q6PORTS = Path("sound/soc/qcom/qdsp6/q6dsp-lpass-ports.c")
MACHINE = Path("sound/soc/qcom/x1e80100.c")
TOUCHED = (YAML, DTS, SWR, WSA_MACRO, WSA, Q6PORTS, MACHINE)

EXPECTED_BLOBS = {
    YAML: "866c5e780fb0aaab844969b1040f8216783eb43a",
    DTS: "66d566808f583646e596034a86064848182727ff",
    SWR: "3d8f5a81eff19511d80e33c76f54972691ccf530",
    WSA_MACRO: "5ad0448af649da09f818b657d09327c86106063c",
    WSA: "6c6b497657d0c8512c3356fde9f91868af0154bf",
    Q6PORTS: "e5cd82f77b5520003ce597c6b70e71ad31965b04",
    MACHINE: "c81df41ace8839cf912a55514518f1d8cd3e58c1",
}


def die(msg: str) -> NoReturn:
    raise SystemExit(f"ERROR: {msg}")


def run(*args: str, cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, check=check)


def has(path: Path, text: str) -> bool:
    return text in path.read_text(errors="strict")


def replace_once(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text(errors="strict")
    count = text.count(old)
    if count != 1:
        die(f"{label}: pristine anchor count is {count}, expected exactly 1 in {path}")
    path.write_text(text.replace(old, new, 1))


def replace_region(path: Path, start: str, end: str, new_region: str,
                   label: str, must_contain: tuple[str, ...] = ()) -> None:
    text = path.read_text(errors="strict")
    if text.count(start) != 1:
        die(f"{label}: start marker count is {text.count(start)}, expected 1 in {path}")
    start_i = text.index(start)
    end_i = text.find(end, start_i + len(start))
    if end_i < 0:
        die(f"{label}: end marker not found in {path}")
    region = text[start_i:end_i]
    for marker in must_contain:
        if marker not in region:
            die(f"{label}: expected marker missing from pristine region: {marker}")
    path.write_text(text[:start_i] + new_region + text[end_i:])


def replace_in_region(path: Path, start: str, end: str, old: str, new: str,
                      label: str) -> None:
    text = path.read_text(errors="strict")
    if text.count(start) != 1:
        die(f"{label}: region start count is {text.count(start)}, expected 1 in {path}")
    start_i = text.index(start)
    end_i = text.find(end, start_i + len(start))
    if end_i < 0:
        die(f"{label}: region end not found in {path}")
    region = text[start_i:end_i]
    count = region.count(old)
    if count != 1:
        die(f"{label}: anchor count inside region is {count}, expected 1")
    region = region.replace(old, new, 1)
    path.write_text(text[:start_i] + region + text[end_i:])


def transform_yaml(src: Path) -> None:
    path = src / YAML
    replace_once(path,
        "  '#sound-dai-cells':\n    const: 0\n",
        "  '#sound-dai-cells':\n"
        "    enum: [0, 1]\n"
        "    description: |\n"
        "      Zero selects the legacy speaker playback DAI. With one cell, DAI 0 is\n"
        "      speaker playback and DAI 1 is the VISENSE protection-feedback sidechain.\n",
        "WSA884x binding DAI cells")
    replace_once(path,
        "            powerdown-gpios = <&lpass_tlmm 18 GPIO_ACTIVE_LOW>;\n"
        "            #sound-dai-cells = <0>;\n"
        "            sound-name-prefix = \"SpkrRight\";\n",
        "            powerdown-gpios = <&lpass_tlmm 18 GPIO_ACTIVE_LOW>;\n"
        "            #sound-dai-cells = <1>;\n"
        "            sound-name-prefix = \"SpkrRight\";\n",
        "WSA884x binding example DAI cells")


def transform_dts(src: Path) -> None:
    path = src / DTS
    replace_once(path,
        "\t\t\t\tsound-dai = <&left_spkr>, <&right_spkr>,\n"
        "\t\t\t\t\t    <&swr0 0>, <&lpass_wsamacro 0>;\n",
        "\t\t\t\tsound-dai = <&left_spkr 0>, <&right_spkr 0>,\n"
        "\t\t\t\t\t    <&swr0 0>, <&lpass_wsamacro 0>;\n",
        "A14 WSA playback DAI selectors")

    old = """\t\twsa-dai-link {
\t\t\tlink-name = \"WSA Playback\";

\t\t\tcodec {
\t\t\t\tsound-dai = <&left_spkr 0>, <&right_spkr 0>,
\t\t\t\t\t    <&swr0 0>, <&lpass_wsamacro 0>;
\t\t\t};

\t\t\tcpu {
\t\t\t\tsound-dai = <&q6apmbedai WSA_CODEC_DMA_RX_0>;
\t\t\t};

\t\t\tplatform {
\t\t\t\tsound-dai = <&q6apm>;
\t\t\t};
\t\t};
\t};
"""
    new = """\t\twsa-dai-link {
\t\t\tlink-name = \"WSA Playback\";

\t\t\tcodec {
\t\t\t\tsound-dai = <&left_spkr 0>, <&right_spkr 0>,
\t\t\t\t\t    <&swr0 0>, <&lpass_wsamacro 0>;
\t\t\t};

\t\t\tcpu {
\t\t\t\tsound-dai = <&q6apmbedai WSA_CODEC_DMA_RX_0>;
\t\t\t};

\t\t\tplatform {
\t\t\t\tsound-dai = <&q6apm>;
\t\t\t};
\t\t};

\t\twsa-vi-dai-link {
\t\t\tlink-name = \"WSA VI Protection\";

\t\t\t/* A14 WSA8845 VISENSE -> SWR0 DIN0 -> WSA macro VI -> AudioReach TX0. */
\t\t\tcodec {
\t\t\t\tsound-dai = <&left_spkr 1>, <&right_spkr 1>,
\t\t\t\t\t    <&swr0 9>, <&lpass_wsamacro 2>;
\t\t\t};

\t\t\tcpu {
\t\t\t\tsound-dai = <&q6apmbedai WSA_CODEC_DMA_TX_0>;
\t\t\t};

\t\t\tplatform {
\t\t\t\tsound-dai = <&q6apm>;
\t\t\t};
\t\t};
\t};
"""
    replace_once(path, old, new, "A14 WSA VI DAI link")
    replace_in_region(path, "\tleft_spkr: speaker@0,0 {\n", "\n\t};",
                      "\t\t#sound-dai-cells = <0>;\n", "\t\t#sound-dai-cells = <1>;\n",
                      "A14 left WSA8845 DAI cells")
    replace_in_region(path, "\tright_spkr: speaker@0,1 {\n", "\n\t};",
                      "\t\t#sound-dai-cells = <0>;\n", "\t\t#sound-dai-cells = <1>;\n",
                      "A14 right WSA8845 DAI cells")


def transform_soundwire(src: Path) -> None:
    path = src / SWR
    replace_once(path, "\t\t\t\t       int direction)\n",
                 "\t\t\t\t       int dai_id)\n",
                 "Qualcomm SoundWire alloc direction argument")
    replace_once(path,
        "\tif (direction == SNDRV_PCM_STREAM_CAPTURE)\n\t\tsconfig.direction = SDW_DATA_DIR_TX;\n"
        "\telse\n\t\tsconfig.direction = SDW_DATA_DIR_RX;\n",
        "\t/* Direction follows the controller data port, not ASoC semantics. */\n"
        "\tif (dai_id >= ctrl->num_dout_ports)\n\t\tsconfig.direction = SDW_DATA_DIR_TX;\n"
        "\telse\n\t\tsconfig.direction = SDW_DATA_DIR_RX;\n",
        "Qualcomm SoundWire physical direction")
    replace_once(path,
        "\tret = qcom_swrm_stream_alloc_ports(ctrl, sruntime, params,\n\t\t\t\t\t   substream->stream);\n",
        "\tret = qcom_swrm_stream_alloc_ports(ctrl, sruntime, params,\n\t\t\t\t\t   dai->id);\n",
        "Qualcomm SoundWire DAI-id allocation")
    replace_once(path,
        "\t\tif (i < ctrl->num_dout_ports)\n\t\t\tstream = &dais[i].playback;\n"
        "\t\telse\n\t\t\tstream = &dais[i].capture;\n\n"
        "\t\tstream->channels_min = 1;\n\t\tstream->channels_max = 1;\n"
        "\t\tstream->rates = SNDRV_PCM_RATE_48000;\n\t\tstream->formats = SNDRV_PCM_FMTBIT_S16_LE;\n",
        "\t\tif (i < ctrl->num_dout_ports) {\n\t\t\tstream = &dais[i].playback;\n"
        "\t\t} else {\n\t\t\tstream = &dais[i].capture;\n"
        "\t\t\tdais[i].playback = (struct snd_soc_pcm_stream) {\n"
        "\t\t\t\t.channels_min = 1,\n\t\t\t\t.channels_max = 1,\n"
        "\t\t\t\t.rates = SNDRV_PCM_RATE_8000 | SNDRV_PCM_RATE_48000,\n"
        "\t\t\t\t.formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S32_LE,\n\t\t\t};\n"
        "\t\t\tdais[i].playback.stream_name = devm_kasprintf(dev, GFP_KERNEL,\n"
        "\t\t\t\t\t\t\t\t  \"SoundWire VI Protection%d\",\n"
        "\t\t\t\t\t\t\t\t  i - ctrl->num_dout_ports);\n"
        "\t\t\tif (!dais[i].playback.stream_name)\n\t\t\t\treturn -ENOMEM;\n\t\t}\n\n"
        "\t\tstream->channels_min = 1;\n\t\tstream->channels_max = 1;\n"
        "\t\tstream->rates = i < ctrl->num_dout_ports ? SNDRV_PCM_RATE_48000 :\n"
        "\t\t\t\tSNDRV_PCM_RATE_8000 | SNDRV_PCM_RATE_48000;\n"
        "\t\tstream->formats = i < ctrl->num_dout_ports ? SNDRV_PCM_FMTBIT_S16_LE :\n"
        "\t\t\t\t  SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S32_LE;\n",
        "Qualcomm SoundWire DIN companion playback DAI")


def transform_wsa_macro(src: Path) -> None:
    path = src / WSA_MACRO
    replace_once(path,
        "\tstruct wsa_macro *wsa = snd_soc_component_get_drvdata(component);\n\tint ret;\n\n"
        "\tswitch (substream->stream) {\n",
        "\tstruct wsa_macro *wsa = snd_soc_component_get_drvdata(component);\n\tint ret;\n\n"
        "\tif (dai->id == WSA_MACRO_AIF_VI) {\n\t\twsa->pcm_rate_vi = params_rate(params);\n\t\treturn 0;\n\t}\n\n"
        "\tswitch (substream->stream) {\n",
        "WSA macro VI playback hw_params")
    replace_once(path,
        "\tcase SNDRV_PCM_STREAM_CAPTURE:\n\t\tif (dai->id == WSA_MACRO_AIF_VI)\n"
        "\t\t\twsa->pcm_rate_vi = params_rate(params);\n\n\t\tbreak;\n",
        "\tcase SNDRV_PCM_STREAM_CAPTURE:\n\t\tbreak;\n",
        "WSA macro legacy VI capture assignment")
    replace_once(path,
        "\t{\n\t\t.name = \"wsa_macro_vifeedback\",\n\t\t.id = WSA_MACRO_AIF_VI,\n\t\t.capture = {\n",
        "\t{\n\t\t.name = \"wsa_macro_vifeedback\",\n\t\t.id = WSA_MACRO_AIF_VI,\n"
        "\t\t.playback = {\n\t\t\t.stream_name = \"WSA_AIF_VI Protection\",\n"
        "\t\t\t.rates = SNDRV_PCM_RATE_8000,\n\t\t\t.formats = SNDRV_PCM_FMTBIT_S32_LE,\n"
        "\t\t\t.rate_max = 8000,\n\t\t\t.rate_min = 8000,\n\t\t\t.channels_min = 1,\n"
        "\t\t\t.channels_max = 4,\n\t\t},\n\t\t.capture = {\n",
        "WSA macro VI protection playback DAI")
    replace_once(path,
        "\tSND_SOC_DAPM_AIF_OUT_E(\"WSA AIF_VI\", \"WSA_AIF_VI Capture\", 0,\n"
        "\t\t\t       SND_SOC_NOPM, WSA_MACRO_AIF_VI, 0,\n"
        "\t\t\t       wsa_macro_enable_vi_feedback,\n"
        "\t\t\t       SND_SOC_DAPM_POST_PMU | SND_SOC_DAPM_POST_PMD),\n",
        "\tSND_SOC_DAPM_AIF_OUT_E(\"WSA AIF_VI\", \"WSA_AIF_VI Capture\", 0,\n"
        "\t\t\t       SND_SOC_NOPM, WSA_MACRO_AIF_VI, 0,\n"
        "\t\t\t       wsa_macro_enable_vi_feedback,\n"
        "\t\t\t       SND_SOC_DAPM_POST_PMU | SND_SOC_DAPM_POST_PMD),\n"
        "\tSND_SOC_DAPM_AIF_IN_E(\"WSA AIF_VI Protection\", \"WSA_AIF_VI Protection\", 0,\n"
        "\t\t\t      SND_SOC_NOPM, WSA_MACRO_AIF_VI, 0,\n"
        "\t\t\t      wsa_macro_enable_vi_feedback,\n"
        "\t\t\t      SND_SOC_DAPM_POST_PMU | SND_SOC_DAPM_POST_PMD),\n",
        "WSA macro VI protection DAPM widget")


def transform_wsa884x(src: Path) -> None:
    path = src / WSA
    replace_once(path,
        "\tstruct sdw_stream_config sconfig;\n\tstruct sdw_stream_runtime *sruntime;\n"
        "\tstruct sdw_port_config port_config[WSA884X_MAX_SWR_PORTS];\n",
        "\tstruct sdw_stream_runtime *sruntime[2];\n",
        "WSA884x per-DAI stream runtime")
    replace_once(path, "\tint active_ports;\n", "", "WSA884x legacy active_ports field")

    dpn = """static struct sdw_dpn_prop wsa884x_sink_dpn_prop[] = {
\t{ .num = WSA884X_PORT_DAC + 1, .type = SDW_DPN_SIMPLE, .min_ch = 1, .max_ch = 1,
\t  .simple_ch_prep_sm = true, .read_only_wordlength = true, },
\t{ .num = WSA884X_PORT_COMP + 1, .type = SDW_DPN_SIMPLE, .min_ch = 1, .max_ch = 1,
\t  .simple_ch_prep_sm = true, .read_only_wordlength = true, },
\t{ .num = WSA884X_PORT_BOOST + 1, .type = SDW_DPN_SIMPLE, .min_ch = 1, .max_ch = 1,
\t  .simple_ch_prep_sm = true, .read_only_wordlength = true, },
\t{ .num = WSA884X_PORT_PBR + 1, .type = SDW_DPN_SIMPLE, .min_ch = 1, .max_ch = 1,
\t  .simple_ch_prep_sm = true, .read_only_wordlength = true, },
\t{ .num = WSA884X_PORT_CPS + 1, .type = SDW_DPN_SIMPLE, .min_ch = 1, .max_ch = 1,
\t  .simple_ch_prep_sm = true, .read_only_wordlength = true, },
};

static struct sdw_dpn_prop wsa884x_source_dpn_prop[] = {
\t{ .num = WSA884X_PORT_VISENSE + 1, .type = SDW_DPN_SIMPLE, .min_ch = 1, .max_ch = 1,
\t  .simple_ch_prep_sm = true, .read_only_wordlength = true, },
};

"""
    replace_region(path,
        "static struct sdw_dpn_prop wsa884x_sink_dpn_prop[WSA884X_MAX_SWR_PORTS] = {\n",
        "static const struct sdw_port_config wsa884x_pconfig[WSA884X_MAX_SWR_PORTS] = {\n",
        dpn, "WSA884x sink/source DPN split",
        must_contain=("[WSA884X_PORT_VISENSE]", "[WSA884X_PORT_CPS]"))

    hw = """static int wsa884x_hw_params(struct snd_pcm_substream *substream,
\t\t\t     struct snd_pcm_hw_params *params,
\t\t\t     struct snd_soc_dai *dai)
{
\tstruct wsa884x_priv *wsa884x = dev_get_drvdata(dai->dev);
\tstruct sdw_port_config port_config[WSA884X_MAX_SWR_PORTS];
\tstruct sdw_stream_config sconfig = { .ch_count = 1, .bps = 1, .type = SDW_STREAM_PDM };
\tint active_ports = 0;
\tint i;

\tfor (i = 0; i < WSA884X_MAX_SWR_PORTS; i++) {
\t\tif (dai->id == 0) {
\t\t\tif (!wsa884x->port_enable[i] ||
\t\t\t    (i != WSA884X_PORT_DAC && i != WSA884X_PORT_COMP && i != WSA884X_PORT_BOOST))
\t\t\t\tcontinue;
\t\t} else if (i != WSA884X_PORT_VISENSE) {
\t\t\tcontinue;
\t\t}
\t\tport_config[active_ports++] = wsa884x_pconfig[i];
\t}
\tif (!active_ports)
\t\treturn -ENODEV;

\tsconfig.frame_rate = params_rate(params);
\tsconfig.direction = dai->id == 0 ? SDW_DATA_DIR_RX : SDW_DATA_DIR_TX;
\tdev_info(dai->dev, "A14 WSA %s: rate=%u port=%u direction=%s\\n",
\t\t dai->id == 0 ? "speaker playback" : "VI feedback", sconfig.frame_rate,
\t\t port_config[0].num, sconfig.direction == SDW_DATA_DIR_TX ? "source" : "sink");
\treturn sdw_stream_add_slave(wsa884x->slave, &sconfig, port_config, active_ports,
\t\t\t\t    wsa884x->sruntime[dai->id]);
}

"""
    replace_region(path, "static int wsa884x_hw_params(", "static int wsa884x_hw_free(",
                   hw, "WSA884x dual playback/VISENSE hw_params",
                   must_contain=("wsa884x->active_ports", "sdw_stream_add_slave"))
    replace_once(path, "\tsdw_stream_remove_slave(wsa884x->slave, wsa884x->sruntime);\n",
                 "\tsdw_stream_remove_slave(wsa884x->slave, wsa884x->sruntime[dai->id]);\n",
                 "WSA884x per-DAI hw_free")
    replace_once(path, "\tstruct snd_soc_component *component = dai->component;\n\n\tif (mute) {\n",
                 "\tstruct snd_soc_component *component = dai->component;\n\n"
                 "\tif (dai->id != 0)\n\t\treturn 0;\n\n\tif (mute) {\n",
                 "WSA884x VI mute bypass")
    replace_once(path, "\twsa884x->sruntime = stream;\n",
                 "\twsa884x->sruntime[dai->id] = stream;\n",
                 "WSA884x per-DAI set_stream")

    dais = """static struct snd_soc_dai_driver wsa884x_dais[] = {
\t{
\t\t.name = "SPKR", .id = 0,
\t\t.playback = {
\t\t\t.stream_name = "SPKR Playback", .rates = WSA884X_RATES | WSA884X_FRAC_RATES,
\t\t\t.formats = WSA884X_FORMATS, .rate_min = 8000, .rate_max = 384000,
\t\t\t.channels_min = 1, .channels_max = 1,
\t\t},
\t\t.ops = &wsa884x_dai_ops,
\t},
\t{
\t\t.name = "SPKR_VI", .id = 1,
\t\t.playback = {
\t\t\t.stream_name = "SPKR VI Protection", .rates = SNDRV_PCM_RATE_8000,
\t\t\t.formats = SNDRV_PCM_FMTBIT_S32_LE, .rate_min = 8000, .rate_max = 8000,
\t\t\t.channels_min = 1, .channels_max = 1,
\t\t},
\t\t.ops = &wsa884x_dai_ops,
\t},
};

"""
    replace_region(path, "static struct snd_soc_dai_driver wsa884x_dais[] = {\n",
                   "static int wsa884x_get_temp(", dais, "WSA884x VISENSE DAI",
                   must_contain=(".name = \"SPKR\"", ".channels_max = 1"))
    replace_once(path,
        "\twsa884x->dev_mode = WSA884X_SPEAKER;\n\twsa884x->sconfig.ch_count = 1;\n"
        "\twsa884x->sconfig.bps = 1;\n\twsa884x->sconfig.direction = SDW_DATA_DIR_RX;\n"
        "\twsa884x->sconfig.type = SDW_STREAM_PDM;\n",
        "\twsa884x->dev_mode = WSA884X_SPEAKER;\n",
        "WSA884x legacy single-stream config")
    replace_once(path,
        "\tpdev->prop.sink_ports = GENMASK(WSA884X_MAX_SWR_PORTS - 1, 0);\n"
        "\tpdev->prop.simple_clk_stop_capable = true;\n\tpdev->prop.sink_dpn_prop = wsa884x_sink_dpn_prop;\n",
        "\tpdev->prop.sink_ports = BIT(WSA884X_PORT_DAC + 1) | BIT(WSA884X_PORT_COMP + 1) |\n"
        "\t\t\t\tBIT(WSA884X_PORT_BOOST + 1) | BIT(WSA884X_PORT_PBR + 1) |\n"
        "\t\t\t\tBIT(WSA884X_PORT_CPS + 1);\n"
        "\tpdev->prop.source_ports = BIT(WSA884X_PORT_VISENSE + 1);\n"
        "\tpdev->prop.simple_clk_stop_capable = true;\n\tpdev->prop.sink_dpn_prop = wsa884x_sink_dpn_prop;\n"
        "\tpdev->prop.src_dpn_prop = wsa884x_source_dpn_prop;\n",
        "WSA884x SoundWire source-port properties")


def transform_q6ports(src: Path) -> None:
    path = src / Q6PORTS
    vi = """#define Q6AFE_CDC_DMA_VI_DAI(did) {\t\t\t\t\\
\t\t.playback = {\t\t\t\t\t\t\\
\t\t\t.stream_name = #did" Protection",\t\t\\
\t\t\t.rates = SNDRV_PCM_RATE_8000,\t\t\t\\
\t\t\t.formats = SNDRV_PCM_FMTBIT_S32_LE,\t\t\\
\t\t\t.channels_min = 2, .channels_max = 2,\t\t\\
\t\t\t.rate_min = 8000, .rate_max = 8000,\t\t\\
\t\t},\t\t\t\t\t\t\t\\
\t\t.capture = {\t\t\t\t\t\t\\
\t\t\t.stream_name = #did" Capture",\t\t\t\\
\t\t\t.rates = SNDRV_PCM_RATE_8000 | SNDRV_PCM_RATE_16000 |\\
\t\t\t\tSNDRV_PCM_RATE_32000 | SNDRV_PCM_RATE_48000 |\\
\t\t\t\tSNDRV_PCM_RATE_176400,\t\t\t\\
\t\t\t.formats = SNDRV_PCM_FMTBIT_S16_LE | SNDRV_PCM_FMTBIT_S24_LE |\\
\t\t\t\t   SNDRV_PCM_FMTBIT_S32_LE,\t\t\\
\t\t\t.channels_min = 1, .channels_max = 8,\t\t\\
\t\t\t.rate_min = 8000, .rate_max = 176400,\t\t\\
\t\t},\t\t\t\t\t\t\t\\
\t\t.name = #did, .id = did,\t\t\t\t\\
\t}

"""
    replace_once(path, "#define Q6AFE_DP_RX_DAI(did) {\t\t\t\t\t\t\\\n",
                 vi + "#define Q6AFE_DP_RX_DAI(did) {\t\t\t\t\t\t\\\n",
                 "Q6DSP VI protection DAI macro")
    replace_once(path, "\tQ6AFE_CDC_DMA_TX_DAI(WSA_CODEC_DMA_TX_0),\n",
                 "\tQ6AFE_CDC_DMA_VI_DAI(WSA_CODEC_DMA_TX_0),\n",
                 "Q6DSP WSA TX0 VI DAI selection")


def transform_machine(src: Path) -> None:
    path = src / MACHINE
    replace_once(path, "#include <sound/pcm.h>\n#include <sound/jack.h>\n",
                 "#include <sound/pcm.h>\n#include <sound/pcm_params.h>\n#include <sound/jack.h>\n",
                 "X1E80100 pcm_params include")
    replace_once(path,
        "\t\tsnd_soc_limit_volume(card, \"TweeterRight PA Volume\", 6);\n\t\tbreak;\n\tcase DISPLAY_PORT_RX_0:\n",
        "\t\tsnd_soc_limit_volume(card, \"TweeterRight PA Volume\", 6);\n\t\tbreak;\n"
        "\tcase WSA_CODEC_DMA_TX_0:\n\t\treturn 0;\n\tcase DISPLAY_PORT_RX_0:\n",
        "X1E80100 VI backend init")
    replace_once(path,
        "\tstruct snd_interval *channels = hw_param_interval(params,\n\t\t\t\t\t\t\t  SNDRV_PCM_HW_PARAM_CHANNELS);\n\n"
        "\trate->min = rate->max = 48000;\n",
        "\tstruct snd_interval *channels = hw_param_interval(params,\n\t\t\t\t\t\t\t  SNDRV_PCM_HW_PARAM_CHANNELS);\n"
        "\tstruct snd_mask *format = hw_param_mask(params,\n\t\t\t\t\t\t       SNDRV_PCM_HW_PARAM_FORMAT);\n\n"
        "\trate->min = rate->max = 48000;\n",
        "X1E80100 VI format mask")
    replace_once(path,
        "\tcase TX_CODEC_DMA_TX_3:\n\t\tchannels->min = 1;\n\t\tbreak;\n\tdefault:\n",
        "\tcase TX_CODEC_DMA_TX_3:\n\t\tchannels->min = 1;\n\t\tbreak;\n"
        "\tcase WSA_CODEC_DMA_TX_0:\n\t\trate->min = rate->max = 8000;\n"
        "\t\tchannels->min = channels->max = 2;\n\t\tsnd_mask_none(format);\n"
        "\t\tsnd_mask_set_format(format, SNDRV_PCM_FORMAT_S32_LE);\n\t\tbreak;\n\tdefault:\n",
        "X1E80100 VI backend hw_params")

    prepare = """static int x1e80100_snd_prepare(struct snd_pcm_substream *substream)
{
\tstruct snd_soc_pcm_runtime *rtd = snd_soc_substream_to_rtd(substream);
\tstruct snd_soc_dai *cpu_dai = snd_soc_rtd_to_cpu(rtd, 0);
\tstruct x1e80100_snd_data *data = snd_soc_card_get_drvdata(rtd->card);
\tunsigned int channels = substream->runtime->channels;
\tunsigned int rx_slot[4], tx_slot[4];
\tint ret;

\tswitch (cpu_dai->id) {
\tcase WSA_CODEC_DMA_RX_0:
\tcase WSA_CODEC_DMA_RX_1:
\t\tret = x1e80100_snd_hw_map_channels(rx_slot, channels);
\t\tif (ret) return ret;
\t\tret = snd_soc_dai_set_channel_map(cpu_dai, 0, NULL, channels, rx_slot);
\t\tif (ret) return ret;
\t\tbreak;
\tcase WSA_CODEC_DMA_TX_0:
\t\tret = x1e80100_snd_hw_map_channels(tx_slot, channels);
\t\tif (ret) return ret;
\t\tret = snd_soc_dai_set_channel_map(cpu_dai, channels, tx_slot, 0, NULL);
\t\tif (ret) return ret;
\t\tbreak;
\tdefault:
\t\tbreak;
\t}

\tret = qcom_snd_sdw_prepare(substream, &data->stream_prepared[cpu_dai->id]);
\tif (cpu_dai->id == WSA_CODEC_DMA_TX_0)
\t\tdev_info(rtd->dev, "A14 WSA VI feedback %s\\n",
\t\t\t ret ? "unavailable" : "prepared on WSA_CODEC_DMA_TX_0");
\treturn ret;
}

"""
    replace_region(path, "static int x1e80100_snd_prepare(", "static int x1e80100_snd_hw_free(",
                   prepare, "X1E80100 VI prepare path",
                   must_contain=("qcom_snd_sdw_prepare", "WSA_CODEC_DMA_RX_0"))


def verify(src: Path) -> None:
    dts, swr, wsa_macro, wsa, q6ports, machine = (src / p for p in (DTS, SWR, WSA_MACRO, WSA, Q6PORTS, MACHINE))
    required = [
        (dts, 'link-name = "WSA VI Protection";'),
        (dts, 'sound-dai = <&left_spkr 1>, <&right_spkr 1>,'),
        (swr, 'SoundWire VI Protection%d'),
        (swr, 'if (dai_id >= ctrl->num_dout_ports)'),
        (wsa_macro, 'WSA_AIF_VI Protection'),
        (wsa, '.name = "SPKR_VI"'),
        (wsa, 'pdev->prop.source_ports = BIT(WSA884X_PORT_VISENSE + 1);'),
        (wsa, 'A14 WSA %s: rate=%u port=%u direction=%s'),
        (q6ports, '#define Q6AFE_CDC_DMA_VI_DAI(did)'),
        (q6ports, 'Q6AFE_CDC_DMA_VI_DAI(WSA_CODEC_DMA_TX_0)'),
        (machine, 'A14 WSA VI feedback %s'),
    ]
    for path, marker in required:
        if not has(path, marker):
            die(f"verification marker missing in {path.relative_to(src)}: {marker}")
    for marker in (
        'snd_soc_limit_volume(card, "WSA WSA_RX0 Digital Volume", 81);',
        'snd_soc_limit_volume(card, "WSA WSA_RX1 Digital Volume", 81);',
        'snd_soc_limit_volume(card, "SpkrLeft PA Volume", 6);',
        'snd_soc_limit_volume(card, "SpkrRight PA Volume", 6);',
    ):
        if not has(machine, marker):
            die(f"V1 safety limit missing from x1e80100.c: {marker}")
    if has(machine, 'snd_soc_limit_volume(card, "SpkrLeft PA Volume", 24);'):
        die("unsafe Surface PA operating point leaked into A14 V1")
    check = run("git", "diff", "--check", "--", *(str(p) for p in TOUCHED), cwd=src, check=False)
    if check.returncode:
        sys.stdout.write(check.stdout)
        die("git diff --check failed after V1 transforms")
    print("A14_SPEAKER_PROTECTION_V1=VERIFIED")
    print("source_transform=EXACT_ANCHORS")
    print("visense_left_master_port=10")
    print("visense_right_master_port=11")
    print("vi_backend=WSA_CODEC_DMA_TX_0:8000Hz:S32_LE:2ch")
    print("digital_gain_cap=-3dB_PRESERVED")
    print("pa_gain_cap=0dB_PRESERVED")
    print("sp_spvi_graph=NOT_ENABLED_IN_V1")


def apply_transforms(src: Path) -> None:
    for label, fn in (
        ("binding", transform_yaml), ("a14-dtsi", transform_dts),
        ("qcom-soundwire", transform_soundwire), ("wsa-macro", transform_wsa_macro),
        ("wsa884x", transform_wsa884x), ("q6dsp-ports", transform_q6ports),
        ("x1e80100-machine", transform_machine),
    ):
        fn(src)
        print(f"A14_SPKPROT_TRANSFORM={label}:OK")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("source", type=Path)
    src = ap.parse_args().source.resolve()
    if not (src / ".git").exists():
        die(f"not a git Linux source tree: {src}")
    head = run("git", "rev-parse", "HEAD", cwd=src).stdout.strip()
    if head != BASE_COMMIT:
        die(f"Linux source HEAD must be exact v7.1.5 {BASE_COMMIT}; got {head}")
    if has(src / MACHINE, "A14 WSA VI feedback %s"):
        verify(src)
        print("speaker_protection_v1=current")
        return
    for rel, expected in EXPECTED_BLOBS.items():
        actual = run("git", "hash-object", str(rel), cwd=src).stdout.strip()
        if actual != expected:
            die(f"exact v7.1.5 blob mismatch for {rel}: expected {expected}, got {actual}")
        print(f"A14_SPKPROT_PRISTINE_BLOB={rel}:{actual}")
    dirty = run("git", "diff", "--quiet", "--", *(str(p) for p in TOUCHED), cwd=src, check=False)
    if dirty.returncode != 0:
        die("refusing non-pristine touched files; reset exact v7.1.5 before applying V1")
    originals = {rel: (src / rel).read_text(errors="strict") for rel in TOUCHED}
    try:
        apply_transforms(src)
        verify(src)
    except BaseException:
        for rel, text in originals.items():
            (src / rel).write_text(text)
        raise
    print("speaker_protection_v1=applied")


if __name__ == "__main__":
    main()
