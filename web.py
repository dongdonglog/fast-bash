#!/usr/bin/env python3
"""smon Web panel backed by the JSON output of smon.sh."""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

_DIR = os.path.dirname(os.path.abspath(__file__))
_SMON_CANDIDATES = [os.path.join(_DIR, "smon.sh"), os.path.join(_DIR, "smon")]
SMON = sys.argv[1] if len(sys.argv) > 1 else next(
    (path for path in _SMON_CANDIDATES if os.path.exists(path)), _SMON_CANDIDATES[0]
)
try:
    PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8080
except ValueError:
    PORT = 8080
REFRESH = 1

CACHE = {"json": b'{"status":"sampling"}', "at": 0}
CACHE_LOCK = threading.Lock()
STOP = threading.Event()
NET_PROCESS = None
NET_PROCESS_LOCK = threading.Lock()
MONITOR_PIDS = set()
NET_ERROR = "smon-net 快照尚未就绪"

HTML = r"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>smon 服务器诊断</title>
<style>
  :root{--bg:#111311;--surface:#181b18;--surface2:#202420;--line:#303630;--fg:#e7ece7;
    --muted:#9ba59b;--green:#55c47a;--yellow:#e4b454;--red:#ef6a67;--cyan:#58b7c6}
  *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,
    BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;letter-spacing:0}
  main{max-width:1600px;margin:0 auto;padding:16px}h1{font-size:19px;margin:0 0 3px;color:var(--fg)}
  h2{font-size:14px;margin:18px 0 8px}.meta{font-size:12px;color:var(--muted);word-break:break-word}
  .warnings{margin:12px 0}.warning{padding:8px 10px;margin:6px 0;border:1px solid #604e29;
    border-left:3px solid var(--yellow);background:#282318;color:#f1c86e;border-radius:4px}
  .metrics{display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:8px;margin:14px 0}
  .metric,.hotbox{background:var(--surface);border:1px solid var(--line);border-radius:6px;padding:10px}
  .metric .label,.hotbox .label{font-size:12px;color:var(--muted)}.metric .value{font-size:19px;font-weight:650;margin:3px 0}
  .metric .detail{font-size:11px;color:var(--muted);min-height:32px;word-break:break-word}
  .bar{height:5px;background:#292e29;margin-top:7px;overflow:hidden}.bar i{display:block;height:100%;background:var(--green)}
  .low{color:var(--green)}.mid{color:var(--yellow)}.high{color:var(--red)}
  .findings{display:grid;gap:7px}.finding{border:1px solid var(--line);border-left:3px solid var(--yellow);
    background:var(--surface);padding:9px 10px;border-radius:4px}.finding.critical{border-left-color:var(--red)}
  .finding .summary{font-weight:650}.evidence{display:flex;gap:6px;flex-wrap:wrap;margin-top:5px}
  .evidence span{font-size:12px;color:var(--muted);background:var(--surface2);padding:2px 6px;border-radius:3px}
  .actions{display:flex;gap:6px;flex-wrap:wrap;margin-top:7px}.action{display:flex;align-items:center;max-width:100%;
    border:1px solid var(--line);background:#131513;border-radius:4px;overflow:hidden}.action code{padding:5px 7px;
    color:#c8d4c8;white-space:normal;overflow-wrap:anywhere}.copy{align-self:stretch;border:0;border-left:1px solid var(--line);
    background:var(--surface2);color:var(--cyan);padding:4px 8px;cursor:pointer}.copy:hover{background:#2b312b}
  .ok{color:var(--green);border:1px solid #285538;background:#17231a;padding:8px 10px;border-radius:4px}
  .hotspots{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}.hotitem{display:grid;
    grid-template-columns:minmax(0,1fr) auto;gap:10px;padding:7px 0;border-bottom:1px solid var(--line)}
  .hotitem:last-child{border:0}.hotname{min-width:0}.hotname strong,.hotname span{display:block;overflow:hidden;
    text-overflow:ellipsis;white-space:nowrap}.hotname span{font-size:11px;color:var(--muted)}
  .sectionhead{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:18px}
  .sectionhead h2{margin:0}.segments{display:flex;border:1px solid var(--line);border-radius:5px;overflow:hidden}
  .segments button{border:0;border-right:1px solid var(--line);background:var(--surface);color:var(--muted);
    padding:5px 10px;cursor:pointer}.segments button:last-child{border:0}.segments button.active{background:#2a312b;color:var(--fg)}
  .tablewrap{overflow:auto;border:1px solid var(--line);border-radius:6px;margin-top:8px;max-height:55vh}
  table{width:100%;border-collapse:collapse;white-space:nowrap;font-size:12px}th{position:sticky;top:0;z-index:1;
    background:var(--surface2);color:var(--muted);padding:7px 8px;text-align:right;border-bottom:1px solid var(--line);
    cursor:pointer}td{padding:6px 8px;text-align:right;border-bottom:1px solid #252925}tr:hover td{background:#1c201c}
  th.left,td.left{text-align:left}.workload{max-width:340px;overflow:hidden;text-overflow:ellipsis}.cmd{max-width:480px;
    overflow:hidden;text-overflow:ellipsis;color:var(--muted)}.diskwrap{overflow:auto;border:1px solid var(--line);border-radius:6px}
  .foot{font-size:11px;color:var(--muted);margin:9px 0 20px}
  @media(max-width:760px){main{padding:10px}.metrics{grid-template-columns:repeat(2,minmax(0,1fr))}
    .hotspots{grid-template-columns:1fr}.sectionhead{align-items:flex-start;flex-direction:column}.tablewrap{max-height:60vh}}
</style>
</head>
<body><main>
  <h1>smon 服务器诊断</h1><div id="meta" class="meta">正在采样...</div>
  <div id="warnings" class="warnings"></div><div id="metrics" class="metrics"></div>
  <section id="diagnostics"><h2>诊断结论</h2><div id="findings" class="findings"></div></section>
  <section id="hotspotSection" hidden><h2>网络热点</h2><div id="hotspots" class="hotspots"></div></section>
  <section><h2>活跃磁盘设备</h2><div class="diskwrap"><table><thead><tr><th class="left">设备</th><th>读/写</th>
    <th>读/写 IOPS</th><th>busy</th><th>读/写等待</th><th>队列深度</th></tr></thead><tbody id="diskrows"></tbody></table></div></section>
  <section><div class="sectionhead"><h2>进程与工作负载</h2><div class="segments" id="filters">
    <button data-filter="all" class="active">全部</button><button data-filter="host">宿主</button><button data-filter="pod">Pod</button>
  </div></div><div class="tablewrap"><table id="mainTable"><thead><tr>
    <th class="left" data-key="workload_label">范围 / 工作负载</th><th data-key="pid_sort">PID</th>
    <th data-key="cpu">CPU%</th><th data-key="rss_mb">内存</th><th data-key="read_kbs">读 IO</th>
    <th data-key="write_kbs">写 IO</th><th data-key="net">连接</th><th data-key="recv_kbs">收</th>
    <th data-key="sent_kbs">发</th><th class="left" data-key="user">用户</th><th class="left" data-key="cmd">命令</th>
  </tr></thead><tbody id="rows"></tbody></table></div></section>
  <div class="foot" id="foot"></div>
</main><script>
let state=null, sortKey='cpu', sortDesc=true, scopeFilter='all';
const esc=value=>String(value??'').replace(/[&<>"']/g,ch=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
const number=value=>Number(value)||0;
const size=value=>{let k=Math.max(0,number(value));if(k>=1048576)return(k/1048576).toFixed(1)+'G';if(k>=1024)return(k/1024).toFixed(1)+'M';return Math.round(k)+'K'};
const level=value=>number(value)>=90?'high':number(value)>=60?'mid':'low';
function metric(label,value,detail,cls='',bar){const width=Math.max(0,Math.min(100,number(bar)));
  return `<div class="metric"><div class="label">${esc(label)}</div><div class="value ${esc(cls)}">${esc(value)}</div>`+
    `<div class="detail">${esc(detail)}</div>${bar===undefined?'':`<div class="bar"><i style="width:${width}%"></i></div>`}</div>`}
function workload(entity){if(entity.scope==='pod'||entity.kind==='container'){
  const pod=[entity.namespace,entity.pod].filter(Boolean).join('/');return [pod,entity.container].filter(Boolean).join(' · ')||'Pod 容器'}return '宿主进程'}
function normalize(data){const processes=Array.isArray(data.processes)?data.processes:[];
  const entities=Array.isArray(data.network_entities)?data.network_entities:[];return processes.concat(entities).map(item=>({
    kind:item.kind||'process',scope:item.scope||'host',pid:item.pid??null,pid_sort:item.pid??-1,namespace:item.namespace||'',
    pod:item.pod||'',container:item.container||'',container_id:item.container_id||'',attribution:item.attribution||'',
    cpu:number(item.cpu),rss_mb:number(item.rss_mb),read_kbs:number(item.read_kbs),write_kbs:number(item.write_kbs),
    net:number(item.net),recv_kbs:number(item.recv_kbs),sent_kbs:number(item.sent_kbs),user:item.user||'',cmd:item.cmd||'',
    workload_label:workload(item)}))}
function renderWarnings(data){const na=data.net_attribution||{}, warnings=[];
  if(data.privileged===0||data.privileged===false)warnings.push('当前非 root，进程、容器 IO 与网络归属可能不完整。');
  if(na.status&&na.status!=='ok')warnings.push('网络归属已降级：'+(na.reason||na.source||'采集器不可用'));
  if(number(na.dropped_packets)>0)warnings.push(`网络采集本轮丢弃 ${number(na.dropped_packets)} 个包，热点速率可能偏低。`);
  if(number(data.cache_age_ms)>5000)warnings.push('采样数据已超过 5 秒未更新。');
  document.getElementById('warnings').innerHTML=warnings.map(item=>`<div class="warning">${esc(item)}</div>`).join('')}
function sourceName(source){return ({ebpf_cgroup:'eBPF cgroup',af_packet_fallback:'AF_PACKET 降级',af_packet:'AF_PACKET',ss_tcp_info:'ss TCP_INFO'})[source]||source||'不可用'}
function renderFindings(data){let findings=Array.isArray(data.findings)?data.findings:[];
  if(!findings.length&&Array.isArray(data.alerts))findings=data.alerts.map(summary=>({severity:'warning',summary,evidence:[],actions:[]}));
  const target=document.getElementById('findings');if(!findings.length){target.innerHTML='<div class="ok">本轮未发现达到阈值的资源异常</div>';return}
  target.innerHTML=findings.map(item=>{const evidence=(item.evidence||[]).map(value=>`<span>${esc(value)}</span>`).join('');
    const actions=(item.actions||[]).map(action=>{const encoded=encodeURIComponent(String(action.command||''));return `<div class="action"><code>${esc(action.command)}</code>`+
      `<button class="copy" data-command="${esc(encoded)}" title="复制命令">${esc(action.label||'复制')}</button></div>`}).join('');
    return `<article class="finding ${item.severity==='critical'?'critical':''}"><div class="summary">${esc(item.summary)}</div>`+
      `<div class="evidence">${evidence}</div><div class="actions">${actions}</div></article>`}).join('')}
function hotspot(title,key,items){const rows=items.filter(item=>number(item[key])>0).sort((a,b)=>number(b[key])-number(a[key])).slice(0,5);
  if(!rows.length)return '';return `<div class="hotbox"><div class="label">${esc(title)}</div>`+rows.map(item=>
    `<div class="hotitem"><div class="hotname"><strong>${esc(item.workload_label)}${item.pid?` · PID ${esc(item.pid)}`:''}</strong>`+
    `<span>${esc(item.cmd)}</span></div><b>${esc(size(item[key]))}/s</b></div>`).join('')+'</div>'}
function renderRows(items){const visible=items.filter(item=>scopeFilter==='all'||(scopeFilter==='pod'?(item.scope==='pod'||item.kind==='container'):item.scope!=='pod'));
  visible.sort((left,right)=>{const a=left[sortKey]??'',b=right[sortKey]??'';const result=typeof a==='number'&&typeof b==='number'?a-b:String(a).localeCompare(String(b));return(sortDesc?-1:1)*result});
  document.getElementById('rows').innerHTML=visible.slice(0,300).map(item=>{const bw=item.recv_kbs+item.sent_kbs;
    return `<tr><td class="left workload" title="${esc(item.workload_label)}">${esc(item.workload_label)}</td><td>${item.pid===null?'-':esc(item.pid)}</td>`+
      `<td class="${level(item.cpu)}">${esc(item.cpu)}%</td><td>${esc((item.rss_mb/1024).toFixed(1))}G</td>`+
      `<td>${esc(size(item.read_kbs))}/s</td><td>${esc(size(item.write_kbs))}/s</td><td>${esc(item.net)}</td>`+
      `<td class="${bw>=10240?'high':bw>=2048?'mid':'low'}">${esc(size(item.recv_kbs))}/s</td>`+
      `<td class="${bw>=10240?'high':bw>=2048?'mid':'low'}">${esc(size(item.sent_kbs))}/s</td>`+
      `<td class="left">${esc(item.user)}</td><td class="left cmd" title="${esc(item.cmd)}">${esc(item.cmd)}</td></tr>`}).join('')}
function render(){const data=state;if(!data||!data.cpu||!data.memory||!Array.isArray(data.processes)){
  document.getElementById('meta').textContent=data&&data.error?'采集失败：'+data.error:'正在采样，首次数据约需 2 秒...';return}
  const c=data.cpu,m=data.memory,na=data.net_attribution||{},nt=data.net_traffic||{},items=normalize(data);
  document.getElementById('meta').textContent=`主机 ${data.host} · ${data.os} · ${data.uptime} · 负载 ${c.load1}/${c.load5}/${c.load15}`+(data.netif?` · 网卡 ${data.netif}`:'');
  renderWarnings(data);const netDetail=`${sourceName(na.source)} · 覆盖 ${number(na.attributed_percent)}% · 未归属 ↓${size(na.unknown_rx_kbs)}/s ↑${size(na.unknown_tx_kbs)}/s · 丢包 ${number(na.dropped_packets)}`;
  document.getElementById('metrics').innerHTML=metric('CPU 使用率',number(c.percent)+'%',`负载 ${c.load1}`,level(c.percent),c.percent)+
    metric('内存',`${(number(m.used_mb)/1024).toFixed(1)}G / ${(number(m.total_mb)/1024).toFixed(1)}G`,`${number(m.percent)}% 已用`,level(m.percent),m.percent)+
    metric('根分区 /',number(data.disk_root_percent)+'%','已用空间',level(data.disk_root_percent),data.disk_root_percent)+
    metric('网卡总收 / 总发',`↓${size(nt.rx_kbs)}/s ↑${size(nt.tx_kbs)}/s`,netDetail,(number(nt.rx_kbs)+number(nt.tx_kbs))>=10240?'high':'low')+
    metric('对象数',items.length,`${data.processes.length} 个进程 · ${(data.network_entities||[]).length} 个容器汇总`);
  renderFindings(data);const receive=hotspot('接收最快', 'recv_kbs',items),send=hotspot('发送最快','sent_kbs',items);
  const hotspotSection=document.getElementById('hotspotSection');hotspotSection.hidden=!(receive||send);document.getElementById('hotspots').innerHTML=receive+send;
  const disks=(Array.isArray(data.disk_devices)?data.disk_devices:[]).filter(d=>['read_kbs','write_kbs','read_iops','write_iops','busy_percent','read_await_ms','write_await_ms'].some(key=>number(d[key])>0));
  document.getElementById('diskrows').innerHTML=disks.length?disks.map(d=>{const pressured=number(d.busy_percent)>=80||number(d.read_await_ms)>=20||number(d.write_await_ms)>=20;
    return `<tr><td class="left">${esc(d.name)}</td><td>↓${esc(size(d.read_kbs))}/s ↑${esc(size(d.write_kbs))}/s</td><td>${esc(d.read_iops)} / ${esc(d.write_iops)}</td>`+
      `<td class="${pressured?'high':'low'}">${esc(d.busy_percent)}%</td><td class="${pressured?'high':'low'}">${esc(d.read_await_ms)} / ${esc(d.write_await_ms)}ms</td><td>${esc(d.avg_queue_depth)}</td></tr>`}).join(''):
      '<tr><td class="left meta" colspan="6">本轮没有活跃磁盘 I/O</td></tr>';
  renderRows(items);document.getElementById('foot').textContent='最后更新 '+new Date().toLocaleTimeString()+` · 数据延迟 ${Math.max(0,Math.round(number(data.cache_age_ms)))}ms`}
document.getElementById('filters').addEventListener('click',event=>{const button=event.target.closest('button[data-filter]');if(!button)return;
  scopeFilter=button.dataset.filter;document.querySelectorAll('#filters button').forEach(item=>item.classList.toggle('active',item===button));render()});
document.querySelector('#mainTable thead').addEventListener('click',event=>{const key=event.target.dataset.key;if(!key)return;
  if(sortKey===key)sortDesc=!sortDesc;else{sortKey=key;sortDesc=true}render()});
function legacyCopy(command){const textarea=document.createElement('textarea');textarea.value=command;textarea.setAttribute('readonly','');
  textarea.setAttribute('aria-hidden','true');textarea.style.cssText='position:fixed;left:-9999px;top:0;opacity:0';document.body.appendChild(textarea);
  textarea.focus();textarea.select();textarea.setSelectionRange(0,textarea.value.length);let copied=false;
  try{copied=document.execCommand('copy')}catch(_){copied=false}textarea.remove();return copied}
async function copyCommand(command){if(navigator.clipboard&&window.isSecureContext){
  try{await navigator.clipboard.writeText(command);return true}catch(_){}}
  return legacyCopy(command)}
document.addEventListener('click',async event=>{const button=event.target.closest('.copy');if(!button)return;const command=decodeURIComponent(button.dataset.command||'');
  const old=button.textContent;if(await copyCommand(command)){button.textContent='已复制'}else{
    window.prompt('浏览器禁止自动复制，请手动复制以下命令：',command);button.textContent='请手动复制'}
  button.focus();setTimeout(()=>button.textContent=old,1600)});
async function poll(){try{const response=await fetch('/api?t='+Date.now());state=await response.json()}catch(_){state=null}render()}
poll();setInterval(poll,1000);
</script></body></html>"""


def detect_netif():
    configured = os.environ.get("SMON_NETIF", "").strip()
    if configured:
        return configured
    try:
        with open("/proc/net/route", encoding="ascii") as route_file:
            next(route_file, None)
            for line in route_file:
                fields = line.split()
                if len(fields) >= 4 and fields[1] == "00000000" and int(fields[3], 16) & 1:
                    return fields[0]
    except (OSError, ValueError):
        pass
    return ""


def find_net_collector():
    candidates = [
        os.environ.get("SMON_NET_BIN", ""),
        os.path.join(os.path.dirname(os.path.abspath(SMON)), "smon-net"),
        os.path.join(_DIR, "smon-net"),
        shutil.which("smon-net") or "",
    ]
    return next((path for path in candidates if path and os.access(path, os.X_OK)), "")


def collector_supervisor(collector, interface, snapshot):
    global NET_ERROR, NET_PROCESS
    while not STOP.is_set():
        process = None
        try:
            process = subprocess.Popen(
                [collector, "--interface", interface, "--interval", "1s", "--output", snapshot],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
            )
            with NET_PROCESS_LOCK:
                NET_PROCESS = process
                MONITOR_PIDS.add(process.pid)
            _, stderr = process.communicate()
            if not STOP.is_set():
                detail = (stderr or "").strip().splitlines()
                NET_ERROR = detail[0] if detail else f"smon-net exited with status {process.returncode}"
        except OSError as exc:
            NET_ERROR = str(exc)
        finally:
            with NET_PROCESS_LOCK:
                NET_PROCESS = None
        STOP.wait(1)


def filter_monitoring(payload, hidden_pids):
    payload["processes"] = [
        process for process in payload.get("processes", [])
        if process.get("pid") not in hidden_pids
    ]
    payload["network_entities"] = [
        entity for entity in payload.get("network_entities", [])
        if entity.get("pid") not in hidden_pids
    ]
    return payload


def collect(snapshot, interface):
    env = os.environ.copy()
    if snapshot:
        env["SMON_NET_SNAPSHOT"] = snapshot
    if interface:
        env["SMON_NETIF"] = interface
    env["SMON_FAST"] = "1"
    if NET_ERROR:
        env["SMON_NET_FALLBACK_REASON"] = NET_ERROR
    excluded = {str(os.getpid())}
    with NET_PROCESS_LOCK:
        excluded.update(str(pid) for pid in MONITOR_PIDS)
        if NET_PROCESS and NET_PROCESS.poll() is None:
            excluded.add(str(NET_PROCESS.pid))
    env["SMON_EXCLUDE_PIDS"] = ",".join(sorted(excluded))
    try:
        result = subprocess.run(
            [SMON, "-j", "-i", "1"], capture_output=True, text=True, timeout=25, env=env
        )
        if result.returncode != 0:
            detail = result.stderr.strip().splitlines()
            raise RuntimeError(detail[0] if detail else f"smon exited with status {result.returncode}")
        payload = json.loads(result.stdout)
        hidden_pids = {int(pid) for pid in excluded if pid.isdigit()}
        filter_monitoring(payload, hidden_pids)
        payload["sampled_at_ms"] = int(time.time() * 1000)
        return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    except Exception as exc:
        return json.dumps({"host": "?", "error": str(exc)}, ensure_ascii=False).encode("utf-8")


def sampler(snapshot, interface):
    while not STOP.is_set():
        started = time.monotonic()
        body = collect(snapshot, interface)
        with CACHE_LOCK:
            CACHE["json"] = body
            CACHE["at"] = time.time()
        STOP.wait(max(0, REFRESH - (time.monotonic() - started)))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/api":
            with CACHE_LOCK:
                body = CACHE["json"]
                cache_age_ms = max(0, int((time.time() - CACHE["at"]) * 1000)) if CACHE["at"] else 0
            try:
                payload = json.loads(body)
                payload["cache_age_ms"] = cache_age_ms
                body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
            except (TypeError, ValueError):
                pass
            content_type = "application/json; charset=utf-8"
        elif path == "/health":
            body = b"ok"
            content_type = "text/plain; charset=utf-8"
        else:
            body = HTML.encode("utf-8")
            content_type = "text/html; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def main():
    interface = detect_netif()
    collector = find_net_collector() if sys.platform.startswith("linux") else ""
    print(f"smon Web 面板: http://0.0.0.0:{PORT}/  (Ctrl+C 退出)")
    with tempfile.TemporaryDirectory(prefix="smon-web-") as temp_dir:
        snapshot = os.path.join(temp_dir, "net.tsv") if collector and interface else ""
        if snapshot:
            threading.Thread(
                target=collector_supervisor, args=(collector, interface, snapshot), daemon=True
            ).start()
            time.sleep(0.2)
        threading.Thread(target=sampler, args=(snapshot, interface), daemon=True).start()
        server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            STOP.set()
            server.server_close()
            with NET_PROCESS_LOCK:
                if NET_PROCESS and NET_PROCESS.poll() is None:
                    NET_PROCESS.terminate()


if __name__ == "__main__":
    main()
