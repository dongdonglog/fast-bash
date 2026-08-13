#!/usr/bin/env python3
"""smon Web 面板 - 消费 `smon -j` 的 JSON 输出，浏览器中文可视化。

用法:  python3 web.py [smon.sh 路径] [端口]
默认:  <脚本同目录>/smon.sh  端口 8080
"""
import json
import os
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SMON = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "smon.sh")
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
REFRESH = 5  # 后台采样刷新间隔（秒）

CACHE = {"json": b"{}", "at": 0}
CACHE_LOCK = threading.Lock()

HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>smon · 服务器状态</title>
<style>
  :root{--bg:#0f1420;--panel:#161d2e;--panel2:#1d2740;--fg:#dbe4f5;--mut:#8b98b3;
        --red:#ff5c5c;--yel:#ffb020;--grn:#3ddc84;--cyn:#39b9ff;--line:#232e47;}
  *{box-sizing:border-box;margin:0;padding:0}
  body{background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,"PingFang SC","Microsoft YaHei",monospace;padding:16px}
  h1{font-size:18px;color:var(--cyn);margin-bottom:4px}
  .meta{color:var(--mut);font-size:12px;margin-bottom:16px;word-break:break-all}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(210px,1fr));gap:10px;margin-bottom:16px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:10px 12px}
  .card .t{color:var(--mut);font-size:12px;margin-bottom:6px}
  .card .v{font-size:20px;font-weight:700}
  .card .s{font-size:11px;color:var(--mut);margin-top:4px}
  .bar{height:6px;background:var(--panel2);border-radius:3px;margin-top:8px;overflow:hidden}
  .bar>i{display:block;height:100%;border-radius:3px;transition:width .4s}
  .low{color:var(--grn)} .mid{color:var(--yel)} .high{color:var(--red)}
  .alerts{margin-bottom:16px}
  .alerts .a{background:#2a1d24;border:1px solid #4a2a33;border-left:3px solid var(--red);
             color:var(--red);padding:8px 12px;border-radius:6px;margin-bottom:6px;font-size:13px}
  .ok{color:var(--grn);padding:8px 12px;background:#15221a;border:1px solid #22402f;border-radius:6px;font-size:13px}
  .tablewrap{overflow:auto;max-height:calc(100vh - 320px);border:1px solid var(--line);border-radius:8px}
  table{width:100%;border-collapse:collapse;font-size:13px;white-space:nowrap}
  thead th{position:sticky;top:0;background:var(--panel2);color:var(--mut);text-align:right;
           padding:8px 10px;cursor:pointer;user-select:none;border-bottom:1px solid var(--line)}
  thead th:first-child,tbody td:first-child{text-align:left}
  thead th:hover{color:var(--cyn)}
  tbody td{padding:6px 10px;border-bottom:1px solid #1a2338;text-align:right}
  tbody td:nth-child(1){text-align:left}
  td.cmd{text-align:left!important;color:var(--mut);max-width:520px;overflow:hidden;text-overflow:ellipsis}
  tr:hover{background:#1a2440}
  td.hl{font-weight:700}
  .foot{color:var(--mut);font-size:12px;margin-top:12px}
</style>
</head>
<body>
<h1>🖥 服务器状态 · smon</h1>
<div class="meta" id="meta">加载中…</div>

<div class="cards" id="cards"></div>

<div class="alerts" id="alerts"></div>

<div class="tablewrap">
  <table id="tbl">
    <thead><tr>
      <th data-k="pid">PID</th><th data-k="cpu">CPU%</th><th data-k="rss_mb">内存</th>
      <th data-k="read_kbs">读IO</th><th data-k="write_kbs">写IO</th><th data-k="net">连接</th>
      <th data-k="recv_kbs">收↓</th><th data-k="sent_kbs">发↑</th><th data-k="user">用户</th>
      <th data-k="cmd">命令</th>
    </tr></thead>
    <tbody id="rows"></tbody>
  </table>
</div>
<div class="foot" id="foot"></div>

<script>
let sortKey='cpu', sortDesc=true, data=null;

const fmtB=k=>{if(k>=1048576)return (k/1048576).toFixed(1)+'G';if(k>=1024)return (k/1024).toFixed(1)+'M';return k+'K';};
const lvl=p=>p>=90?['high','high']:p>=60?['mid','mid']:['low','low'];
function card(t,v,s,cls,bar){return `<div class="card"><div class="t">${t}</div><div class="v ${cls||''}">${v}</div><div class="s">${s||''}</div>${bar?`<div class="bar"><i style="width:${Math.min(100,bar)}%"></i></div>`:''}</div>`;}

function render(){
  if(!data) return;
  const c=data.cpu, m=data.memory;
  const cpuCls=(c.percent>=90?'high':c.percent>=60?'mid':'low');
  const memCls=(m.percent>=90?'high':m.percent>=60?'mid':'low');
  document.getElementById('meta').textContent =
    `主机 ${data.host} · ${data.os} · ${data.uptime} · 负载 ${c.load1}/${c.load5}/${c.load15}`;
  document.getElementById('cards').innerHTML =
    card('CPU 使用率', c.percent+'%', `负载 ${c.load1}`, cpuCls, c.percent) +
    card('内存', `${(m.used_mb/1024).toFixed(1)}G / ${(m.total_mb/1024).toFixed(1)}G`, `${m.percent}% 已用`, memCls, m.percent) +
    card('根分区 /', data.disk_root_percent+'%', '已用空间', lvl(data.disk_root_percent)[0], data.disk_root_percent) +
    card('进程数', data.processes.length, '采样进程总数');

  const aEl=document.getElementById('alerts');
  if(data.alerts&&data.alerts.length){
    aEl.innerHTML='<div class="a" style="background:none;border:none;color:var(--mut);padding:0 0 6px">⚠ 诊断建议</div>'+
      data.alerts.map(a=>`<div class="a">${a}</div>`).join('');
  } else {
    aEl.innerHTML='<div class="ok">✓ 系统各项指标正常</div>';
  }

  const rows=data.processes.slice();
  rows.sort((x,y)=>(sortDesc?-1:1)*((x[sortKey]??-1)-(y[sortKey]??-1)));
  document.getElementById('rows').innerHTML=rows.slice(0,200).map(p=>{
    const cc=lvl(p.cpu), mc=lvl(p.rss_mb/1024/(data.memory.total_mb/1024)*100);
    const nlvl = p.net>=500?'high':p.net>=200?'mid':'low';
    return `<tr>
      <td>${p.pid}</td>
      <td class="${cc[1]}">${p.cpu}%</td>
      <td class="${mc[1]}">${(p.rss_mb/1024).toFixed(1)}G</td>
      <td>${fmtB(p.read_kbs)}/s</td><td>${fmtB(p.write_kbs)}/s</td>
      <td class="${nlvl}">${p.net}</td>
      <td>${fmtB(p.recv_kbs||0)}/s</td><td>${fmtB(p.sent_kbs||0)}/s</td>
      <td>${p.user}</td><td class="cmd" title="${p.cmd}">${p.cmd}</td>
    </tr>`;
  }).join('');
  document.getElementById('foot').textContent='最后更新 '+new Date().toLocaleTimeString()+' · 每 3 秒自动刷新 · 点击表头排序';
}

document.querySelectorAll('th').forEach(th=>th.onclick=()=>{
  const k=th.dataset.k;
  if(sortKey===k)sortDesc=!sortDesc; else {sortKey=k;sortDesc=true;}
  render();
});

async function poll(){
  try{
    const r=await fetch('/api?t='+Date.now());
    data=await r.json();
  }catch(e){ data=null; }
  render();
}
poll(); setInterval(poll,5000);
</script>
</body>
</html>
"""


def collect():
    try:
        out = subprocess.run([SMON, "-j"], capture_output=True, text=True, timeout=30)
        return out.stdout.encode("utf-8")
    except Exception as e:
        return json.dumps({"host": "?", "error": str(e)}).encode()


def sampler():
    while True:
        body = collect()
        with CACHE_LOCK:
            CACHE["json"] = body
            CACHE["at"] = time.time()
        time.sleep(REFRESH)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/api":
            with CACHE_LOCK:
                body = CACHE["json"]
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
        elif path == "/health":
            body = b"ok"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
        else:
            body = HTML.encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    print(f"smon Web 面板: http://0.0.0.0:{PORT}/  (Ctrl+C 退出)")
    threading.Thread(target=sampler, daemon=True).start()
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
