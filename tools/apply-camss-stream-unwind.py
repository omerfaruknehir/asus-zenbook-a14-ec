#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit(f"usage: {sys.argv[0]} /path/to/camss-video.c")

path = Path(sys.argv[1])
text = path.read_text()

marker = "static void video_unwind_started_subdevs"
if marker in text:
    print(f"already patched: {path}")
    raise SystemExit(0)

anchor = """\treturn ret;\n}\n\nstatic int video_start_streaming(struct vb2_queue *q, unsigned int count)\n"""
helper = """\treturn ret;\n}\n\nstatic void video_unwind_started_subdevs(struct camss_video *video,\n\t\t\t\t\t struct v4l2_subdev *failed_subdev)\n{\n\tstruct media_entity *entity = &video->vdev.entity;\n\tstruct media_pad *pad;\n\tstruct v4l2_subdev *subdev;\n\tint ret;\n\n\twhile (1) {\n\t\tpad = &entity->pads[0];\n\t\tif (!(pad->flags & MEDIA_PAD_FL_SINK))\n\t\t\tbreak;\n\n\t\tpad = media_pad_remote_pad_first(pad);\n\t\tif (!pad || !is_media_entity_v4l2_subdev(pad->entity))\n\t\t\tbreak;\n\n\t\tentity = pad->entity;\n\t\tsubdev = media_entity_to_v4l2_subdev(entity);\n\n\t\tif (subdev == failed_subdev)\n\t\t\tbreak;\n\n\t\tret = v4l2_subdev_call(subdev, video, s_stream, 0);\n\t\tif (ret < 0 && ret != -ENOIOCTLCMD)\n\t\t\tdev_warn(video->camss->dev,\n\t\t\t\t \"Failed to unwind video pipeline subdev: %d\\n\",\n\t\t\t\t ret);\n\t}\n}\n\nstatic int video_start_streaming(struct vb2_queue *q, unsigned int count)\n"""

start_old = """\t\tret = v4l2_subdev_call(subdev, video, s_stream, 1);\n\t\tif (ret < 0 && ret != -ENOIOCTLCMD)\n\t\t\tgoto error;\n"""
start_new = """\t\tret = v4l2_subdev_call(subdev, video, s_stream, 1);\n\t\tif (ret < 0 && ret != -ENOIOCTLCMD) {\n\t\t\tvideo_unwind_started_subdevs(video, subdev);\n\t\t\tgoto error;\n\t\t}\n"""

if text.count(anchor) != 1:
    raise SystemExit(f"refusing to patch: expected prepare/start anchor exactly once, found {text.count(anchor)}")
if text.count(start_old) != 1:
    raise SystemExit(f"refusing to patch: expected s_stream start block exactly once, found {text.count(start_old)}")

backup = path.with_name(path.name + ".pre-unwind")
if not backup.exists():
    backup.write_text(text)

text = text.replace(anchor, helper, 1)
text = text.replace(start_old, start_new, 1)
path.write_text(text)

print(f"patched: {path}")
print(f"backup:  {backup}")
