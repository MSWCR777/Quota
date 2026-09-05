"""Offline rendering check. Never opens Codex or consumes credits."""
import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
from PySide6.QtWidgets import QApplication
from main import Island

app=QApplication([])
app.setApplicationName('QuotaNook-test')
island=Island(demo=True)
app.processEvents()
assert not island.grab().isNull()
assert island.width()==240
island.expanded=True
island.setFixedSize(350,350)
app.processEvents()
assert not island.grab().isNull()
assert island.snapshot['windows'][0]['remaining']==80
island.tray.hide()
island.close()
print('PASS: compact and expanded offscreen rendering, demo only')
