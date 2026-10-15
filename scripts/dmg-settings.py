"""Finder layout written by dmgbuild, without driving Finder or posting UI input."""
from pathlib import Path

application = str(Path(defines["app"]).resolve())
files = [application]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
filesystem = "HFS+"
volume_name = "Easyshot"
window_rect = ((200, 200), (640, 360))
default_view = "icon-view"
background = "builtin-arrow"
icon_size = 100
text_size = 14
icon_locations = {"Easyshot.app": (140, 170), "Applications": (500, 170)}
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
