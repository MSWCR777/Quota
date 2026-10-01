"""Offline rendering check. Never opens Codex or consumes credits."""
import os
os.environ.setdefault('QT_QPA_PLATFORM','offscreen')
from PySide6.QtWidgets import QApplication
from unittest.mock import patch
from main import Island, is_host_process

app=QApplication([])
app.setApplicationName('Quota-test')
island=Island(demo=True)
app.processEvents()
assert not island.grab().isNull()
assert island.width()==240
assert is_host_process('ChatGPT.exe')
assert is_host_process('Codex Desktop.exe')
assert not is_host_process('codex.exe', command_line=['codex.exe', 'app-server'])
assert not is_host_process('Quota.exe', r'C:\\Users\\me\\Documents\\Codex\\Quota.exe')
with patch('main.time.time', return_value=100):
    frame_a = island.grab().toImage()
with patch('main.time.time', return_value=104):
    frame_b = island.grab().toImage()
assert frame_a != frame_b, 'animated compact background did not change'
island.expanded=True
island.setFixedSize(350,350)
app.processEvents()
assert not island.grab().isNull()
with patch('main.time.time', return_value=100):
    expanded_a = island.grab().toImage()
with patch('main.time.time', return_value=104):
    expanded_b = island.grab().toImage()
assert expanded_a != expanded_b, 'animated expanded background did not change'
assert island.snapshot['windows'][0]['remaining']==80
island.tray.hide()
island.close()
print('PASS: process recognition plus animated compact and expanded rendering, demo only')
