// 세 페이지가 함께 쓰는 도우미
const COLS = ['A', 'B', 'C', 'D', 'E', 'F', 'G'];
const ROWS = [1, 2, 3, 4, 5, 6, 7, 8];
const ARROW = { '상': '▲', '하': '▼', '좌': '◀', '우': '▶' };
const PHASE = { prep: '준비 라운드 (시작 위치 입력)', boss_command: '보스 행동 대기', announcing: '라운드 준비 중', battle: '행동 입력 중', settling: '정산 중' };

const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const pct = (hp, max) => Math.max(0, Math.min(100, Math.round(hp / Math.max(max, 1) * 100)));
const short = s => [...String(s)].slice(0, 2).join('');
const $ = id => document.getElementById(id);

function parsePos(p) {
  const m = /^([A-G])([1-8])$/.exec(String(p || '').toUpperCase());
  return m ? [COLS.indexOf(m[1]), Number(m[2]) - 1] : null;
}
function chebyshev(a, b) { const p = parsePos(a), q = parsePos(b); return p && q ? Math.max(Math.abs(p[0] - q[0]), Math.abs(p[1] - q[1])) : 99; }
function manhattan(a, b) { const p = parsePos(a), q = parsePos(b); return p && q ? Math.abs(p[0] - q[0]) + Math.abs(p[1] - q[1]) : 99; }
// 기존 규칙: "근접" = 체비셰프 1칸, 숫자 사거리 = 맨해튼 거리
function inRange(from, to, range) {
  if (range === '근접') return chebyshev(from, to) <= 1;
  const n = parseInt(range, 10);
  return Number.isFinite(n) ? manhattan(from, to) <= n : false;
}

// 격자 HTML. opts: { me, picks:Set, pickable:fn(pos)->bool, inrange:Set, onPick }
function gridHTML(b, opts = {}) {
  const c = b.creature || {};
  const dead = new Set(b.dead || []);
  const done = new Set(b.submitted || []);
  const bossCells = new Set(c.cells || []);
  const skillCells = new Set(c.skill_cells || []);
  const byPos = {};
  (b.runners || []).forEach(r => { if (!dead.has(r.name) && r.hp > 0 && r.pos) byPos[r.pos] = r; });
  let h = '<div class="grid"><div class="lbl"></div>' + COLS.map(x => `<div class="lbl">${x}</div>`).join('');
  ROWS.forEach(y => {
    h += `<div class="lbl">${y}</div>`;
    COLS.forEach(x => {
      const pos = x + y, r = byPos[pos];
      const cls = ['cell',
        bossCells.has(pos) ? 'boss' : '',
        skillCells.has(pos) ? 'skill' : '',
        opts.inrange && opts.inrange.has(pos) ? 'inrange' : '',
        opts.pickable && opts.pickable(pos) ? 'pick' : '',
        opts.picks && opts.picks.has(pos) ? 'picked' : ''].join(' ');
      let inner = '';
      if (r) inner = `<div class="token ${r.name === opts.me ? 'me' : ''} ${done.has(r.name) ? 'done' : ''}" title="${esc(r.display)}">${esc(short(r.display))}</div>`;
      else if (pos === c.pos) inner = `${esc(short(c.name))}<span class="arrow">${ARROW[c.facing] || ''}</span>`;
      h += `<div class="${cls}" data-pos="${pos}" title="${pos}">${inner}</div>`;
    });
  });
  return h + '</div>';
}
function bindGrid(el, onPick) {
  el.querySelectorAll('.cell.pick').forEach(n => n.onclick = () => onPick(n.dataset.pos));
}

function unitsHTML(b) {
  const dead = new Set(b.dead || []), done = new Set(b.submitted || []);
  const c = b.creature || {};
  let h = `<div class="unit"><div class="top"><span><b>${esc(c.name)}</b>${c.skill ? `<span class="tag warn">${esc(c.skill)}</span>` : ''}</span><span>${c.hp} / ${c.max_hp}</span></div><div class="bar boss"><i style="width:${pct(c.hp, c.max_hp)}%"></i></div></div>`;
  (b.runners || []).forEach(r => {
    const isDead = dead.has(r.name) || r.hp <= 0;
    const tag = isDead ? '<span class="tag">전투불능</span>' : (b.phase === 'battle' ? (done.has(r.name) ? '<span class="tag ok">제출</span>' : '<span class="tag">대기</span>') : '');
    h += `<div class="unit ${isDead ? 'dead' : ''}"><div class="top"><span>${esc(r.display)}${tag}</span><span>${r.hp} / ${r.max_hp}</span></div><div class="bar"><i style="width:${pct(r.hp, r.max_hp)}%"></i></div></div>`;
  });
  return h;
}

function logHTML(b, limit = 30) {
  return (b.log || []).slice(-limit).reverse().map(l =>
    `<article><time>${l.round}라운드 · ${new Date(l.at * 1000).toLocaleTimeString('ko-KR')}</time>${esc(l.text)}</article>`
  ).join('') || '<div class="muted">아직 기록이 없습니다.</div>';
}

function timerText(b, skew) {
  if (!b || !b.active || (b.phase !== 'battle' && b.phase !== 'prep')) return '';
  const now = Math.floor(Date.now() / 1000) + (skew || 0);
  const left = Math.max(0, b.round_started_at + b.action_wait - now);
  return `입력 마감까지 ${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
}

async function api(path, body, headers = {}) {
  const res = await fetch(path, body === undefined ? { headers, cache: 'no-store' } : {
    method: 'POST', headers: Object.assign({ 'Content-Type': 'application/json' }, headers), body: JSON.stringify(body)
  });
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `오류 (${res.status})`);
  return data;
}
