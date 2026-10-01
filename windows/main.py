"""Quota Windows desktop edition. Run --demo for a credential-free preview."""
import math
import os
from pathlib import Path
import queue
import sys
import threading
import time
import ctypes
import psutil
from PySide6.QtCore import Qt, QTimer, QRectF, QPointF, QStandardPaths
from PySide6.QtGui import QColor, QPainter, QPainterPath, QLinearGradient, QFont, QFontDatabase, QIcon, QPixmap
from PySide6.QtNetwork import QLocalServer, QLocalSocket
from PySide6.QtWidgets import (QApplication, QWidget, QSystemTrayIcon, QMenu, QDialog,
    QVBoxLayout, QHBoxLayout, QLabel, QPushButton, QScrollArea, QFrame, QButtonGroup)
from core import Session, PendingKeys, credential_stamp, discover_codex, parse_snapshot


def windows_session_id():
    """Separate an automation/sandbox instance from the interactive desktop."""
    if os.name != 'nt':
        return 'portable'
    session_id = ctypes.c_ulong()
    if ctypes.windll.kernel32.ProcessIdToSessionId(os.getpid(), ctypes.byref(session_id)):
        return str(session_id.value)
    return os.environ.get('SESSIONNAME', 'desktop').replace('\\', '_')


INSTANCE_NAME = 'io.github.mswcr777.quota.' + windows_session_id()


def ui_family():
    """Keep Latin and CJK metrics consistent instead of falling back to SimSun."""
    available = set(QFontDatabase.families())
    for family in ('Microsoft YaHei UI', 'Segoe UI Variable Text', 'Segoe UI'):
        if family in available:
            return family
    return QApplication.font().family()


def ui_font(size, weight=QFont.Weight.Normal):
    font = QFont(ui_family(), size, weight)
    font.setStyleStrategy(QFont.StyleStrategy.PreferAntialias)
    return font


def notify_existing_instance():
    socket = QLocalSocket()
    socket.connectToServer(INSTANCE_NAME)
    if not socket.waitForConnected(500):
        return False
    socket.write(b'show')
    socket.flush()
    socket.waitForBytesWritten(500)
    socket.disconnectFromServer()
    return True


class Worker(threading.Thread):
    def __init__(self, events, keys):
        super().__init__(daemon=True)
        self.events, self.keys = events, keys
        self.commands = queue.Queue()
        self.done = threading.Event()
        self.session = None
        self.generation = 0

    def run(self):
        while not self.done.is_set():
            try:
                generation, action, snapshot = self.commands.get(timeout=.5)
            except queue.Empty:
                continue
            try:
                if generation != self.generation:
                    continue
                if action == 'stop':
                    if self.session:
                        self.session.close()
                    self.session = None
                    continue
                if self.session and self.session.stamp != credential_stamp():
                    self.session.close()
                    self.session = None
                if not self.session:
                    self.session = Session([discover_codex(), 'app-server'])
                if action == 'reset':
                    if not snapshot or snapshot['stamp'] != self.session.stamp or not snapshot.get('account'):
                        raise RuntimeError('账号已变化，请重新确认')
                    current = parse_snapshot(self.session.request('account/rateLimits/read'))
                    if current['account'] != snapshot['account']:
                        raise RuntimeError('账号已变化，请重新确认')
                    credit_id = snapshot.get('selected_credit')
                    if not credit_id or credit_id not in [item['id'] for item in current.get('credit_items', [])]:
                        raise RuntimeError('所选重置卡已变化，请重新选择')
                    key = self.keys.key(snapshot['account'], credit_id)
                    result = self.session.request('account/rateLimitResetCredit/consume',
                        {'idempotencyKey': key, 'creditId': credit_id}, timeout=25)
                    outcome = result.get('outcome', 'uncertain')
                    if outcome in ('reset', 'alreadyRedeemed', 'noCredit', 'nothingToReset'):
                        self.keys.resolve(snapshot['account'], credit_id)
                    self.events.put((generation, 'message', {'reset': '重置成功', 'alreadyRedeemed': '此请求已完成',
                        'noCredit': '没有可用重置卡', 'nothingToReset': '当前无需重置'}.get(outcome, '结果未确认，重试会复用原请求')))
                data = parse_snapshot(self.session.request('account/rateLimits/read'))
                data['stamp'] = self.session.stamp
                self.events.put((generation, 'snapshot', data))
            except Exception as error:
                self.events.put((generation, 'error', str(error)))
                if self.session:
                    self.session.close()
                self.session = None
        if self.session:
            self.session.close()


def host_running():
    desktop_pids = set()
    for process in psutil.process_iter(['name', 'exe', 'cmdline']):
        try:
            name = (process.info['name'] or '').lower()
            # Desktop UI processes only; never count the child CLI app-server.
            if name in ('codex.exe', 'chatgpt.exe') and 'app-server' not in (process.info['cmdline'] or []) and 'resources' not in (process.info['exe'] or '').lower():
                desktop_pids.add(process.pid)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    if not desktop_pids or os.name != 'nt':
        return bool(desktop_pids)

    # Match the user's visible desktop state: minimized/hidden ChatGPT should
    # hide Quota, while a restored window should reveal it within the next tick.
    visible = ctypes.c_bool(False)
    user32 = ctypes.windll.user32
    callback_type = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)

    def inspect(hwnd, _):
        pid = ctypes.c_ulong()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
        if (pid.value in desktop_pids and user32.IsWindowVisible(hwnd)
                and not user32.IsIconic(hwnd) and user32.GetWindowTextLengthW(hwnd) > 0):
            visible.value = True
            return False
        return True

    user32.EnumWindows(callback_type(inspect), 0)
    return visible.value


class ResetCreditDialog(QDialog):
    def __init__(self, items, parent=None):
        super().__init__(parent, Qt.WindowType.FramelessWindowHint | Qt.WindowType.Dialog)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setModal(True)
        self.setFixedSize(360, 390)
        self.selected = None

        card = QFrame(self)
        card.setObjectName('card')
        card.setGeometry(0, 0, 360, 390)
        layout = QVBoxLayout(card)
        layout.setContentsMargins(22, 20, 22, 20)
        layout.setSpacing(12)
        title = QLabel('选择重置卡')
        title.setObjectName('title')
        subtitle = QLabel('将同时恢复 5 小时和 7 天额度')
        subtitle.setObjectName('muted')
        layout.addWidget(title)
        layout.addWidget(subtitle)

        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QFrame.Shape.NoFrame)
        body = QWidget()
        choices = QVBoxLayout(body)
        choices.setContentsMargins(0, 4, 0, 4)
        choices.setSpacing(8)
        group = QButtonGroup(self)
        group.setExclusive(True)
        now = time.time()
        for index, item in enumerate(items):
            expiry = item.get('expires')
            validity = ('长期有效' if expiry is None else
                        '有效期至 ' + time.strftime('%Y-%m-%d %H:%M', time.localtime(expiry)))
            badge = ('长期有效' if expiry is None else
                     (f'{max(0, int((expiry-now)/86400))} 天后到期'))
            button = QPushButton(f'  第 {index+1} 张 · 全量重置\n  {validity}     {badge}')
            button.setCheckable(True)
            button.setProperty('credit_id', item['id'])
            button.setMinimumHeight(58)
            group.addButton(button)
            choices.addWidget(button)
            if index == 0:
                button.setChecked(True)
                self.selected = item['id']
        group.buttonClicked.connect(lambda button: setattr(self, 'selected', button.property('credit_id')))
        choices.addStretch()
        scroll.setWidget(body)
        layout.addWidget(scroll, 1)

        actions = QHBoxLayout()
        cancel = QPushButton('取消')
        confirm = QPushButton('确认使用所选卡')
        cancel.setObjectName('secondary')
        confirm.setObjectName('primary')
        cancel.clicked.connect(self.reject)
        confirm.clicked.connect(self.accept)
        confirm.setEnabled(bool(items))
        actions.addWidget(cancel)
        actions.addWidget(confirm)
        layout.addLayout(actions)
        self.setStyleSheet('''
            #card { background: qlineargradient(x1:0,y1:0,x2:1,y2:1, stop:0 #10231a, stop:1 #080c0a);
                    border: 1px solid rgba(150,220,180,75); border-radius: 24px; }
            QLabel { color: #f7faf8; font-family: "Microsoft YaHei UI"; }
            #title { font-size: 21px; font-weight: 600; }
            #muted { color: rgba(255,255,255,120); font-size: 11px; }
            QScrollArea, QScrollArea > QWidget > QWidget { background: transparent; }
            QPushButton { color: rgba(255,255,255,180); text-align: left; padding: 7px 12px;
                          border: 1px solid rgba(255,255,255,20); border-radius: 14px;
                          background: rgba(255,255,255,9); font-family: "Microsoft YaHei UI"; }
            QPushButton:hover { background: rgba(255,255,255,18); }
            QPushButton:checked { color: #eafff1; border-color: rgba(130,235,175,100); background: #193a28; }
            #primary, #secondary { min-height: 36px; text-align: center; font-weight: 600; }
            #primary { color: #07100c; background: #8de1ad; border: none; }
            #primary:hover { background: #a0edbd; }
            #secondary { background: rgba(255,255,255,15); }
        ''')


class Island(QWidget):
    def __init__(self, demo=False):
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setWindowTitle('Quota')
        self.setAccessibleName('Quota 额度浮窗，点击展开，拖动移动')
        self.demo, self.expanded, self.busy = demo, False, False
        self.force_visible_until = 0
        self.hovered_control = None
        self.setMouseTracking(True)
        self.motion = True
        self.snapshot = None
        self.message = '正在连接…'
        self.drag_origin = None
        self.dragged = False
        self.events = queue.Queue()
        folder = Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppLocalDataLocation))
        self.worker = Worker(self.events, PendingKeys(folder / 'pending-resets.json'))
        if not demo:
            self.worker.start()
        self.state = None
        self.last_read = 0
        self.setFixedSize(240, 40)
        area = QApplication.primaryScreen().availableGeometry()
        self.move(area.center().x()-120, area.top()+12)
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.tick)
        self.timer.start(40)
        self.last_sync = 0
        pix = QPixmap(32, 32)
        pix.fill(QColor('#163426'))
        painter = QPainter(pix)
        painter.setPen(Qt.GlobalColor.white)
        painter.setFont(ui_font(20, QFont.Weight.Bold))
        painter.drawText(pix.rect(), Qt.AlignmentFlag.AlignCenter, 'Q')
        painter.end()
        self.tray = QSystemTrayIcon(QIcon(pix), self)
        self.tray.setToolTip('Quota')
        menu = QMenu()
        menu.addAction('刷新额度', self.refresh)
        motion = menu.addAction('动态效果')
        motion.setCheckable(True)
        motion.setChecked(True)
        motion.toggled.connect(self.set_motion)
        menu.addAction('退出', self.quit)
        self.tray.setContextMenu(menu)
        self.tray.show()
        if demo:
            self.snapshot = {'windows': [{'remaining': 80, 'duration': 300, 'reset': time.time()+16000},
                {'remaining': 97, 'duration': 10080, 'reset': time.time()+580000}], 'credits': 0, 'plan': 'DEMO'}
            self.message = '示例数据'
            self.show()

    def set_motion(self, enabled):
        self.motion = enabled

    def reveal(self):
        """Bring the existing instance into the user's current desktop session."""
        self.force_visible_until = time.time() + 15
        self.show()
        self.setWindowState(self.windowState() & ~Qt.WindowState.WindowMinimized)
        self.raise_()
        self.activateWindow()
        QApplication.alert(self, 0)

    def refresh(self):
        if not self.demo and not self.busy:
            self.busy = True
            self.last_read = time.time()
            self.worker.commands.put((self.worker.generation, 'read', None))

    def tick(self):
        now = time.time()
        if not self.demo and now-self.last_sync >= 2:
            self.last_sync = now
            should_show = (host_running() or os.environ.get('QUOTANOOK_ALWAYS_SHOW') == '1'
                           or now < self.force_visible_until)
            current = (should_show, credential_stamp())
            if current != self.state:
                self.state = current
                self.worker.generation += 1
                self.snapshot = None
                self.busy = False
                self.message = '正在连接…'
                self.worker.commands.put((self.worker.generation, 'stop', None))
                self.setVisible(current[0])
                if current[0]:
                    self.refresh()
            if current[0] and now-self.last_read >= 45:
                self.refresh()
        while not self.events.empty():
            generation, kind, value = self.events.get_nowait()
            if generation != self.worker.generation:
                continue
            if kind == 'snapshot':
                self.snapshot = value
                self.busy = False
                if self.message == '正在连接…':
                    self.message = '已连接 · 每 45 秒刷新'
            else:
                self.message = value
                if kind == 'error':
                    self.snapshot = None
                    self.busy = False
        if self.isVisible():
            self.update()

    def paintEvent(self, event):
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        boundary = QPainterPath()
        boundary.addRoundedRect(QRectF(self.rect()).adjusted(.5,.5,-.5,-.5), 24 if self.expanded else 20, 24 if self.expanded else 20)
        p.setClipPath(boundary)
        background = QLinearGradient(0,0,self.width(),self.height())
        background.setColorAt(0, QColor('#101d17'))
        background.setColorAt(1, QColor('#0b0e0c'))
        p.fillPath(boundary, background)
        p.setPen(QColor('#395146'))
        p.drawPath(boundary)
        t = time.time() if self.motion else 0
        for i in range(12):
            x = ((i*.618+t*.008)%1)*self.width()
            y = 3+math.sin(t*.55+i)*1.5 if i%2 else self.height()-4
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(175,220,186,85))
            p.drawEllipse(QPointF(x,y), .8,.8)
        def text(x,y,s,size=10,color='#eeeeee',weight=QFont.Weight.Normal):
            p.setPen(QColor(color))
            p.setFont(ui_font(size, weight))
            p.drawText(x,y,s)
        def bar(x,y,w,value):
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor('#3d403e'))
            p.drawRoundedRect(QRectF(x,y,w,5),2,2)
            fill = w*value/100
            if fill <= 0:
                return
            gradient = QLinearGradient(x,y,x+w,y)
            gradient.setColorAt(0,QColor('#47ad78'))
            gradient.setColorAt(1,QColor('#b8e8bf'))
            p.setBrush(gradient)
            p.drawRoundedRect(QRectF(x,y,fill,5),2,2)
            if self.motion:
                p.save()
                p.setClipRect(QRectF(x,y,fill,5))
                shine = x-20+(w+40)*((t%5)/5)
                glow = QLinearGradient(shine,y,shine+20,y)
                glow.setColorAt(0,QColor(255,255,255,0))
                glow.setColorAt(.5,QColor(255,255,255,110))
                glow.setColorAt(1,QColor(255,255,255,0))
                p.fillRect(QRectF(shine,y,20,5),glow)
                p.restore()
        text(15,26 if not self.expanded else 36,'Q',17,'#ffffff',QFont.Weight.Bold)
        windows = (self.snapshot or {}).get('windows',[])
        if not self.expanded:
            if not windows:
                text(45,25,'点击查看连接状态',10)
            for i,win in enumerate(windows[:2]):
                x=45+i*96
                text(x,18,self.label(win),8,'#b2bdb5')
                text(x+43,18,f"{win['remaining']:.0f}%",10,'#ffffff',QFont.Weight.DemiBold)
                bar(x,26,80,win['remaining'])
        else:
            text(43,35,'Quota',16,'#ffffff',QFont.Weight.DemiBold)
            text(24,55,str((self.snapshot or {}).get('plan','')),9,'#929d96')
            for name, cx, glyph in (('refresh', 276, '↻'), ('collapse', 316, '⌃')):
                p.setPen(Qt.PenStyle.NoPen)
                p.setBrush(QColor(255,255,255,30 if self.hovered_control == name else 18))
                p.drawEllipse(QPointF(cx,28),14,14)
                p.setPen(QColor('#f2f6f3'))
                p.setFont(ui_font(12, QFont.Weight.DemiBold))
                p.drawText(QRectF(cx-14,14,28,28),Qt.AlignmentFlag.AlignCenter,glyph)
            for i,win in enumerate(windows[:2]):
                y=92+i*88
                text(24,y,self.label(win),12,'#f5f7f5',QFont.Weight.Medium)
                text(235,y,f"{win['remaining']:.0f}% 剩余",12,'#ffffff',QFont.Weight.DemiBold)
                bar(24,y+12,302,win['remaining'])
                text(24,y+34,f"已用 {100-win['remaining']:.0f}%",9,'#a0aaa3')
                text(264,y+34,'总量 100%',9,'#a0aaa3')
                seconds=max(0,int(win['reset']-time.time()))
                text(24,y+51,f'{seconds//3600} 小时 {seconds%3600//60} 分后恢复',9,'#87928b')
            credits=(self.snapshot or {}).get('credits')
            selectable = bool((self.snapshot or {}).get('credit_items'))
            text(24,281,'重置卡 '+('暂未返回' if credits is None else str(credits)+' 张'),10)
            text(235,281,'处理中…' if self.busy else '使用重置卡',10,
                 '#bbc5bd' if selectable and not self.busy else '#626b65')
            if credits and not selectable:
                text(24,297,'服务未返回每张卡的明细，暂时无法安全选择。',7,'#c78a48')
            status = self.message[:33]
            if self.snapshot and self.message.startswith(('已连接', '正在连接')):
                updated = time.strftime('%H:%M', time.localtime(self.snapshot.get('updated', time.time())))
                status = f'实时连接 · 更新于 {updated}'
            text(24,311,status,8,'#8a958e')
            text(24,334,'刷新',9,'#a0aaa3')
            text(295,334,'退出',9,'#a0aaa3')
        p.end()

    @staticmethod
    def label(win):
        minutes=win['duration']
        return f'{minutes//1440} 天' if minutes>=1440 else f'{minutes//60} 小时'

    def mousePressEvent(self,event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.drag_origin=(event.globalPosition().toPoint(),self.pos())
            self.dragged=False

    def mouseMoveEvent(self,event):
        if self.drag_origin:
            delta=event.globalPosition().toPoint()-self.drag_origin[0]
            if delta.manhattanLength()>3:
                self.dragged=True
                self.move(self.drag_origin[1]+delta)
        elif self.expanded:
            x,y=event.position().x(),event.position().y()
            hovered = 'refresh' if 260<=x<=292 and 12<=y<=45 else ('collapse' if 300<=x<=332 and 12<=y<=45 else None)
            if hovered != self.hovered_control:
                self.hovered_control = hovered
                self.setCursor(Qt.CursorShape.PointingHandCursor if hovered else Qt.CursorShape.ArrowCursor)
                self.update()

    def leaveEvent(self,event):
        self.hovered_control = None
        self.setCursor(Qt.CursorShape.ArrowCursor)
        self.update()
        super().leaveEvent(event)

    def mouseReleaseEvent(self,event):
        self.drag_origin=None
        if self.dragged or event.button()!=Qt.MouseButton.LeftButton:
            return
        x,y=event.position().x(),event.position().y()
        if self.expanded and y>320:
            self.quit() if x>270 else self.refresh()
        elif self.expanded and 257<y<292 and x>215 and (self.snapshot or {}).get('credit_items'):
            self.reset_credit()
        elif self.expanded and y<52 and 258<x<296:
            self.refresh()
        elif not self.expanded or (self.expanded and y<52 and x>298):
            center=self.x()+self.width()//2
            self.expanded=not self.expanded
            self.setFixedSize(350,350) if self.expanded else self.setFixedSize(240,40)
            self.move(center-self.width()//2,self.y())

    def reset_credit(self):
        data=self.snapshot
        if self.demo or self.busy or not data or not data.get('account') or not (data.get('credits') or 0)>0:
            return
        dialog = ResetCreditDialog(data.get('credit_items') or [], self)
        if dialog.exec() == QDialog.DialogCode.Accepted and dialog.selected:
            request = dict(data)
            request['selected_credit'] = dialog.selected
            self.busy=True
            self.worker.commands.put((self.worker.generation,'reset',request))

    def quit(self):
        self.worker.done.set()
        if self.worker.session:
            self.worker.session.process.terminate()
        self.tray.hide()
        QApplication.quit()


if __name__=='__main__':
    app=QApplication(sys.argv)
    app.setApplicationName('Quota')
    app.setFont(ui_font(10))
    app.setQuitOnLastWindowClosed(False)
    if notify_existing_instance():
        sys.exit(0)
    QLocalServer.removeServer(INSTANCE_NAME)
    instance_server = QLocalServer()
    if not instance_server.listen(INSTANCE_NAME):
        sys.exit(1)
    island=Island('--demo' in sys.argv)
    def receive_activation():
        while instance_server.hasPendingConnections():
            connection = instance_server.nextPendingConnection()
            connection.waitForReadyRead(100)
            connection.readAll()
            island.reveal()
            connection.disconnectFromServer()
    instance_server.newConnection.connect(receive_activation)
    sys.exit(app.exec())
