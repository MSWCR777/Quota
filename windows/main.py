"""QuotaNook Windows desktop edition. Run --demo for a credential-free preview."""
import math
import os
from pathlib import Path
import queue
import sys
import threading
import time
import psutil
from PySide6.QtCore import Qt, QTimer, QRectF, QPointF, QStandardPaths, QLockFile
from PySide6.QtGui import QColor, QPainter, QPainterPath, QLinearGradient, QFont, QIcon, QPixmap
from PySide6.QtWidgets import QApplication, QWidget, QSystemTrayIcon, QMenu, QMessageBox
from core import Session, PendingKeys, credential_stamp, discover_codex, parse_snapshot


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
                    key = self.keys.key(snapshot['account'])
                    result = self.session.request('account/rateLimitResetCredit/consume', {'idempotencyKey': key}, timeout=25)
                    outcome = result.get('outcome', 'uncertain')
                    if outcome in ('reset', 'alreadyRedeemed', 'noCredit', 'nothingToReset'):
                        self.keys.resolve(snapshot['account'])
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
    for process in psutil.process_iter(['name', 'exe', 'cmdline']):
        try:
            name = (process.info['name'] or '').lower()
            # Desktop UI processes only; never count the child CLI app-server.
            if name in ('codex.exe', 'chatgpt.exe') and 'app-server' not in (process.info['cmdline'] or []) and 'resources' not in (process.info['exe'] or '').lower():
                return True
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
    return False


class Island(QWidget):
    def __init__(self, demo=False):
        super().__init__(None, Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setWindowTitle('QuotaNook · 余隅')
        self.setAccessibleName('QuotaNook 额度浮窗，点击展开，拖动移动')
        self.demo, self.expanded, self.busy = demo, False, False
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
        painter.setFont(QFont('Segoe UI', 20, QFont.Weight.Bold))
        painter.drawText(pix.rect(), Qt.AlignmentFlag.AlignCenter, 'Q')
        painter.end()
        self.tray = QSystemTrayIcon(QIcon(pix), self)
        self.tray.setToolTip('QuotaNook · 余隅')
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

    def refresh(self):
        if not self.demo and not self.busy:
            self.busy = True
            self.last_read = time.time()
            self.worker.commands.put((self.worker.generation, 'read', None))

    def tick(self):
        now = time.time()
        if not self.demo and now-self.last_sync >= 2:
            self.last_sync = now
            current = (host_running() or os.environ.get('QUOTANOOK_ALWAYS_SHOW') == '1', credential_stamp())
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
        def text(x,y,s,size=10,color='#eeeeee'):
            p.setPen(QColor(color))
            p.setFont(QFont('Segoe UI',size))
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
        text(15,26 if not self.expanded else 36,'Q',17)
        windows = (self.snapshot or {}).get('windows',[])
        if not self.expanded:
            if not windows:
                text(45,25,'点击查看连接状态',10)
            for i,win in enumerate(windows[:2]):
                x=45+i*96
                text(x,18,self.label(win),8,'#b2bdb5')
                text(x+43,18,f"{win['remaining']:.0f}%",10)
                bar(x,26,80,win['remaining'])
        else:
            text(43,35,'QuotaNook',16)
            text(24,55,'余隅 · '+str((self.snapshot or {}).get('plan','')),9,'#929d96')
            text(315,35,'⌃',15)
            for i,win in enumerate(windows[:2]):
                y=92+i*88
                text(24,y,self.label(win),12)
                text(235,y,f"{win['remaining']:.0f}% 剩余",12)
                bar(24,y+12,302,win['remaining'])
                text(24,y+34,f"已用 {100-win['remaining']:.0f}%",9,'#a0aaa3')
                text(264,y+34,'总量 100%',9,'#a0aaa3')
                seconds=max(0,int(win['reset']-time.time()))
                text(24,y+51,f'{seconds//3600} 小时 {seconds%3600//60} 分后恢复',9,'#87928b')
            credits=(self.snapshot or {}).get('credits')
            text(24,281,'重置卡 '+('暂未返回' if credits is None else str(credits)+' 张'),10)
            text(235,281,'处理中…' if self.busy else '使用重置卡',10,'#bbc5bd' if credits and not self.busy else '#626b65')
            text(24,311,self.message[:33],8,'#8a958e')
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

    def mouseReleaseEvent(self,event):
        self.drag_origin=None
        if self.dragged or event.button()!=Qt.MouseButton.LeftButton:
            return
        x,y=event.position().x(),event.position().y()
        if self.expanded and y>320:
            self.quit() if x>270 else self.refresh()
        elif self.expanded and 257<y<292 and x>215:
            self.reset_credit()
        elif not self.expanded or (y<65 and x>290):
            center=self.x()+self.width()//2
            self.expanded=not self.expanded
            self.setFixedSize(350,350) if self.expanded else self.setFixedSize(240,40)
            self.move(center-self.width()//2,self.y())

    def reset_credit(self):
        data=self.snapshot
        if self.demo or self.busy or not data or not data.get('account') or not (data.get('credits') or 0)>0:
            return
        if QMessageBox.question(self,'使用重置卡','确认使用当前账号的 1 张重置卡？',
            QMessageBox.StandardButton.Yes|QMessageBox.StandardButton.No,QMessageBox.StandardButton.No)==QMessageBox.StandardButton.Yes:
            self.busy=True
            self.worker.commands.put((self.worker.generation,'reset',dict(data)))

    def quit(self):
        self.worker.done.set()
        if self.worker.session:
            self.worker.session.process.terminate()
        self.tray.hide()
        QApplication.quit()


if __name__=='__main__':
    app=QApplication(sys.argv)
    app.setApplicationName('QuotaNook')
    app.setQuitOnLastWindowClosed(False)
    lock=QLockFile(str(Path(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.TempLocation))/'quotanook.lock'))
    if not lock.tryLock(100):
        sys.exit(0)
    island=Island('--demo' in sys.argv)
    sys.exit(app.exec())
