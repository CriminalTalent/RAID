// 네 창(로비·관전·참여·관리자)이 함께 쓰는 도우미
const COLS = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];
const ROWS = [1, 2, 3, 4, 5, 6, 7, 8];
const ARROW = { '상': '▲', '하': '▼', '좌': '◀', '우': '▶' };
const PHASE = { prep: '시작 위치 입력', boss_command: '보스 행동 대기', announcing: '라운드 준비', battle: '행동 입력', settling: '정산 중' };

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pct = (hp, max) => Math.max(0, Math.min(100, Math.round(hp / Math.max(max, 1) * 100)));
const short = s => [...String(s)].slice(0, 2).join('');
const $ = id => document.getElementById(id);

/* 공통 상단 메뉴 */
function navBar(active, extra = '') {
  const items = [['/', '로비', 'lobby'], ['/watch', '관전', 'watch'], ['/admin', '관리자', 'admin']];
  const el = document.createElement('nav');
  el.className = 'nav';
  el.innerHTML = `<span class="brand">RAID</span>` +
    items.map(([href, label, key]) => `<a class="item ${active === key ? 'on' : ''}" href="${href}" ${key === 'admin' && active !== 'admin' ? 'target="raid-admin"' : ''}>${label}</a>`).join('') +
    extra + `<span class="live"><span class="dot" id="livedot"></span><span id="livetext">연결 중</span></span>`;
  document.body.prepend(el);
}

/* 다른 창에서 무언가 바뀌면 곧바로 onChange 를 부른다.
   서버는 변화가 생길 때까지 답을 미루고(/api/wait), 같은 브라우저의 여러 창은
   그중 한 창만 서버에 묻고 나머지 창에 알려 준다 (브라우저 동시 연결 수 제한 대비). */
function live(onChange) {
  let v = -1, busy = false, again = false;
  const set = ok => { const d = $('livedot'), t = $('livetext'); if (d) d.classList.toggle('on', ok); if (t) t.textContent = ok ? '실시간 연결' : '연결 끊김, 다시 시도 중'; };
  const run = async () => {
    if (busy) { again = true; return; }
    busy = true;
    try { await onChange(); set(true); } catch (e) { set(false); }
    busy = false;
    if (again) { again = false; run(); }
  };
  const seen = nv => { if (nv !== v) { v = nv; run(); } else set(true); };
  const ch = 'BroadcastChannel' in window ? new BroadcastChannel('raid-live') : null;
  if (ch) ch.onmessage = e => e.data && e.data.v != null ? seen(e.data.v) : e.data === 'down' && set(false);
  async function poll() {
    let lv = 0, fails = 0;
    for (;;) {
      try {
        const r = await api('/api/wait?v=' + lv);
        lv = r.v; fails = 0; ch?.postMessage({ v: r.v }); seen(r.v);
      } catch (e) {
        set(false); ch?.postMessage('down'); fails++;
        await new Promise(res => setTimeout(res, Math.min(5000, 800 * fails)));
      }
    }
  }
  run();   // 처음 한 번은 바로 불러오기
  if (navigator.locks && ch) navigator.locks.request('raid-live', poll);  // 한 창만 서버에 묻기
  else poll();
}

function parsePos(p) {
  const m = /^([A-G])([1-8])$/.exec(String(p || '').toUpperCase());
  return m ? [COLS.indexOf(m[1]), Number(m[2]) - 1] : null;
}
function chebyshev(a, b) { const p = parsePos(a), q = parsePos(b); return p && q ? Math.max(Math.abs(p[0] - q[0]), Math.abs(p[1] - q[1])) : 99; }
function manhattan(a, b) { const p = parsePos(a), q = parsePos(b); return p && q ? Math.abs(p[0] - q[0]) + Math.abs(p[1] - q[1]) : 99; }
// 기존 규칙: "근접" = 대각선 포함 1칸, 숫자 사거리 = 가로+세로 칸 수
function inRange(from, to, range) {
  if (range === '근접') return chebyshev(from, to) <= 1;
  const n = parseInt(range, 10);
  return Number.isFinite(n) ? manhattan(from, to) <= n : false;
}

// 격자. opts: { me, picks:Set, pickable:fn(pos), inrange:Set }
function gridHTML(b, opts = {}) {
  const c = b.creature || {};
  const dead = new Set(b.dead || []), done = new Set(b.submitted || []);
  const bossCells = new Set(c.cells || []), skillCells = new Set(c.skill_cells || []);
  const byPos = {};
  (b.runners || []).forEach(r => { if (!dead.has(r.name) && r.hp > 0 && r.pos) byPos[r.pos] = r; });
  let h = '<div class="grid"><div class="lbl"></div>' + COLS.map(x => `<div class="lbl">${x}</div>`).join('');
  ROWS.forEach(y => {
    h += `<div class="lbl">${y}</div>`;
    COLS.forEach(x => {
      const pos = x + y, r = byPos[pos];
      const cls = ['cell', bossCells.has(pos) && 'boss', skillCells.has(pos) && 'skill', opts.inrange?.has(pos) && 'inrange',
        opts.pickable?.(pos) && 'pick', opts.picks?.has(pos) && 'picked'].filter(Boolean).join(' ');
      let inner = '';
      if (r) inner = `<div class="token ${r.name === opts.me ? 'me' : ''} ${done.has(r.name) ? 'done' : ''}" title="${esc(r.display)}">${esc(short(r.display))}</div>`;
      else if (pos === c.pos) inner = `${esc(short(c.name))}<span class="arrow">${ARROW[c.facing] || ''}</span>`;
      h += `<div class="${cls}" data-pos="${pos}" title="${pos}">${inner}</div>`;
    });
  });
  return h + '</div>';
}
function bindGrid(el, onPick) { el?.querySelectorAll('.cell.pick').forEach(n => n.onclick = () => onPick(n.dataset.pos)); }

function bossHTML(b) {
  const c = b.creature || {};
  return `<div class="unit"><div class="top"><span class="n"><b>${esc(c.name)}</b>${c.skill ? `<span class="tag warn">${esc(c.skill)}</span>` : ''}</span><span class="hp">${c.hp} / ${c.max_hp}</span></div><div class="bar boss"><i style="width:${pct(c.hp, c.max_hp)}%"></i></div></div>`;
}
function runnersHTML(b, me) {
  const dead = new Set(b.dead || []), done = new Set(b.submitted || []);
  return (b.runners || []).map(r => {
    const isDead = dead.has(r.name) || r.hp <= 0;
    const tag = isDead ? '<span class="tag bad">전투불능</span>' : (b.phase === 'battle' ? (done.has(r.name) ? '<span class="tag ok">제출</span>' : '<span class="tag">대기</span>') : '');
    return `<div class="unit ${isDead ? 'dead' : ''}"><div class="top"><span class="n">${esc(r.display)}${r.name === me ? ' <span class="sub">(나)</span>' : ''} ${tag}</span><span class="hp">${r.hp} / ${r.max_hp}</span></div><div class="bar"><i style="width:${pct(r.hp, r.max_hp)}%"></i></div></div>`;
  }).join('');
}
function statusHTML(b, skew) {
  return `<div class="status"><span><b>${b.phase === 'prep' ? '준비' : b.round + 'R'}</b> <span class="sub">${esc(b.active ? (PHASE[b.phase] || '') : '전투 종료')}</span></span><span class="timer" data-timer="${esc(b.id)}">${timerText(b, skew)}</span></div>`;
}
function logHTML(b, limit = 30) {
  return (b.log || []).slice(-limit).reverse().map(l =>
    `<article><time>${l.round}R · ${new Date(l.at * 1000).toLocaleTimeString('ko-KR', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</time>${esc(l.text)}</article>`
  ).join('') || '<div class="empty">아직 기록이 없습니다.</div>';
}
function timerText(b, skew) {
  if (!b || !b.active || (b.phase !== 'battle' && b.phase !== 'prep')) return '';
  const left = Math.max(0, b.round_started_at + b.action_wait - (Math.floor(Date.now() / 1000) + (skew || 0)));
  const n = (b.submitted || []).length;
  return `${b.phase === 'battle' ? `제출 ${n}/${b.required} · ` : ''}${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
}
function startTimers(getBattles, getSkew) {
  setInterval(() => document.querySelectorAll('[data-timer]').forEach(el => {
    const b = getBattles().find(x => x.id === el.dataset.timer); el.textContent = timerText(b, getSkew());
  }), 1000);
}

async function api(path, body, headers = {}) {
  const res = await fetch(path, body === undefined ? { headers, cache: 'no-store' } : {
    method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, headers), body: JSON.stringify(body)
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `오류 (${res.status})`);
  return data;
}
