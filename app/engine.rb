# engine.rb
# encoding: UTF-8
#
# 레이드 전투 엔진. 전투봇(battle/)의 규칙 코드를 그대로 불러와 쓴다.
# - 명중/회피/크리티컬/피해 계산, 정산 순서, 스킬, 쿨타임, 기숙사 패시브: battle/*.rb 그대로
# - 라운드 진행 함수(준비 → 보스 행동 → 행동 입력 → 정산): battle/main.rb 의 함수 본문을
#   실행 시점에 그대로 읽어 와 사용 (복사본을 따로 두지 않아 규칙이 어긋나지 않음)
# - 마스토돈 게시 → 웹 전투 기록으로, 구글 시트 → data/raid.json 으로 대체

require 'set'
require 'json'
require 'securerandom'
require 'monitor'

APP_DIR    = __dir__
BATTLE_DIR = File.expand_path('../battle', __dir__)
$LOAD_PATH.unshift(File.join(APP_DIR, 'stubs'))

ENV['WEB_ENABLED'] = 'true'

require File.join(BATTLE_DIR, 'sheet_manager')
require_relative 'local_sheet'
%w[battle_util battle_grid battle_skills battle_calculator battle_state
   battle_boss_patterns battle_round battle_session talk_lines web_state].each do |f|
  require File.join(BATTLE_DIR, f)
end

ACTION_WAIT_SECONDS = (ENV['RAID_ACTION_SECONDS'] || '300').to_i
ROUND_WAIT_SECONDS  = 0
CREATURE_COOLDOWN_KEY = '__creature__'.freeze
LOCATION_MAP = {}.freeze
BOT_USERNAME = '__raid__'.freeze

# 기본 스킬(참여자 화면에 버튼으로 나오는 것). data/raid.json 의 settings.skills 로 바꿀 수 있다.
DEFAULT_SKILLS = %w[공격 방어 회복 회피 순간이동 관찰].freeze

# ── battle/main.rb 에서 라운드 진행 함수만 그대로 불러오기 ─────────────────
MAIN_FUNCTIONS = %w[
  announce_prep_round handle_prep_input check_prep_completion
  announce_boss_turn announce_round process_action_for_session
  award_victory_credits! confiscate_defeat_credits! announce_scout_directions!
  announce_manual_battle_end! flush_pending_result! settle_session_if_needed
  select_auto_skill
].freeze

def load_main_functions!
  src = File.read(File.join(BATTLE_DIR, 'main.rb'), encoding: 'UTF-8')
  lines = src.lines
  MAIN_FUNCTIONS.each do |name|
    start = lines.index { |l| l.start_with?("def #{name}(") }
    raise "battle/main.rb 에서 #{name} 함수를 찾지 못했습니다" unless start
    stop = (start + 1...lines.size).find { |i| lines[i].rstrip == 'end' }
    eval(lines[start..stop].join, TOPLEVEL_BINDING, File.join(BATTLE_DIR, 'main.rb'), start + 1)
  end
end
load_main_functions!

# ── 마스토돈 게시 대신: 웹 전투 기록에 남긴다 ──────────────────────────────
# 마스토돈용 안내 문구(입력 형식, 텍스트 격자맵)는 웹 화면에 이미 있으므로 기록에서 뺀다.
def web_log_text(text)
  out = []
  skip_map = false
  text.to_s.split("\n").each do |line|
    if line.strip == '전장'
      skip_map = true
      next
    end
    if skip_map
      skip_map = false if line.strip == '□ = 빈칸'
      next
    end
    next if line.match?(/DM 또는 멘션|\A형식|\A(공격|지원|방어|순간이동): \[|\A아이템 사용|\A입력 대기|초 후 다음 라운드|\A─+\z/)
    out << line
  end
  out.join("\n").gsub(/\n{3,}/, "\n\n").strip
end

def post_session_thread(session, text, last_post_time)
  WebState.record_post(session, web_log_text(text))
  id = "web-#{SecureRandom.hex(4)}"
  [{ 'id' => id, 'all_ids' => [id], 'partial' => false }, Time.now]
end

def sheet_log(creature_sheet, session_id, round, event, detail)
  creature_sheet.append_battle_log([Time.now.strftime('%Y-%m-%d %H:%M:%S'), session_id.to_s, round.to_s, event.to_s, detail.to_s])
rescue => e
  puts "[기록 실패] #{e.message}"
end

# 마스토돈 DM 대신 참여자 화면에 안내 문구를 띄운다.
class WebListener
  def initialize
    @notices = {}
  end

  def send_dm(username, text)
    @notices[username.to_s] = { 'text' => text.to_s, 'at' => Time.now.to_i }
  end

  def notice_for(username)
    @notices[username.to_s]
  end

  def clear(username)
    @notices.delete(username.to_s)
  end
end

class RaidEngine
  attr_reader :store, :runner_sheet, :creature_sheet, :sessions, :mutex

  def initialize(data_path)
    @store = LocalStore.new(data_path, File.join(APP_DIR, 'data', 'sample.json'))
    @runner_sheet = LocalSheet.new(@store, 'runner')
    @creature_sheet = LocalSheet.new(@store, 'creature')
    @listener = WebListener.new
    @sessions = {}
    @tokens = {}
    @mutex = Monitor.new
    @last_post_time = Time.at(0)
    settings['admin_key'] ||= SecureRandom.alphanumeric(8)
    settings['skills'] ||= DEFAULT_SKILLS.dup
    @store.save!
  end

  def settings
    @store.to_h['settings'] ||= {}
  end

  def admin_key
    settings['admin_key']
  end

  def skills
    Array(settings['skills']).select { |s| s == '순간이동' || s == '관찰' || BattleSkills.get(s) }
  end

  # ── 데이터(스탯 표) ──────────────────────────────────────────
  TABLES = {
    'runners'     => ['runner', '스탯'],
    'creatures'   => ['creature', '스탯'],
    'boss_skills' => ['creature', '보스스킬']
  }.freeze

  def tables
    TABLES.transform_values { |(book, tab)| @store.book(book)[tab] || [] }
  end

  def save_table!(key, rows)
    book, tab = TABLES.fetch(key)
    @store.replace_tab!(book, tab, rows)
    @runner_sheet.invalidate_base_stats_cache!
    $boss_skill_cache = nil
  end

  def heal_all!
    rows = @store.book('runner')['스탯'] || []
    rows[1..].to_a.each { |r| r[4] = r[10].to_s if r[10].to_s.match?(/\A\d+\z/) }
    @store.save!
    @runner_sheet.invalidate_base_stats_cache!
  end

  def runner_ids
    (@store.book('runner')['스탯'] || [])[1..].to_a.map { |r| r[0].to_s.strip }.reject(&:empty?)
  end

  def creature_names
    (@store.book('creature')['스탯'] || [])[1..].to_a.map { |r| r[1].to_s.strip }.reject(&:empty?)
  end

  def boss_skill_names
    (@store.book('creature')['보스스킬'] || [])[1..].to_a.map { |r| r[0].to_s.strip }.reject(&:empty?)
  end

  # ── 전투 시작/종료 ──────────────────────────────────────────
  def start_battle!(runners:, creature_name:, auto_mode: false)
    runners = Array(runners).map { |r| r.to_s.strip }.reject(&:empty?).uniq
    raise '참여자를 한 명 이상 고르세요.' if runners.empty?
    busy = runners.select { |r| @sessions.values.any? { |s| s.active && s.includes_runner?(r) } }
    raise "이미 전투 중인 참여자가 있습니다: #{busy.join(', ')}" if busy.any?

    creature = creature_from_stats_sheet_by_name(@creature_sheet, creature_name)
    raise "크리쳐 '#{creature_name}'을(를) 찾지 못했습니다." unless creature
    creature[:pos] = 'D4' if creature[:pos].to_s.strip.empty?

    id = Time.now.strftime('%Y%m%d%H%M%S') + SecureRandom.hex(2)
    session = BattleSession.new(id: id, mode: :public, runner_names: runners, creature: creature.dup)
    session.auto_mode = auto_mode ? true : false
    session.dm_visibility = false
    @sessions[session.id] = session
    tokens = runners.to_h { |r| [r, SecureRandom.urlsafe_base64(9)] }
    tokens.each { |r, t| @tokens[t] = [session.id, r] }
    session.instance_variable_set(:@web_tokens, tokens)
    sheet_log(@creature_sheet, session.id, session.round, '전투 시작', "참여자: #{runners.join(', ')} / 상대: #{creature[:name]}")
    tick!
    session
  end

  def end_battle!(session_id)
    s = @sessions[session_id.to_s] or raise '전투를 찾지 못했습니다.'
    s.active = false
    s.auto_next_round_timer = nil
    s.awaiting_boss = false
    s.instance_variable_set(:@web_finish_noted, true)
    @last_post_time = announce_manual_battle_end!(s, nil, nil, @last_post_time)
    sheet_log(@creature_sheet, s.id, s.round, '전투 중단', '관리자 종료')
  end

  def set_auto!(session_id, on)
    s = @sessions[session_id.to_s] or raise '전투를 찾지 못했습니다.'
    s.auto_mode = on ? true : false
    if s.auto_mode && s.awaiting_boss
      skill = select_auto_skill(s.creature, @creature_sheet, s.passive_ctx)
      boss_command!(s.id, skill: skill) if skill
    end
  end

  # 보스 행동 지정 (기존 [보스행동커맨드/스킬/대상 또는 좌표] 와 같은 효과)
  def boss_command!(session_id, skill:, targets: [], cells: [])
    s = @sessions[session_id.to_s] or raise '전투를 찾지 못했습니다.'
    raise '지금은 보스 행동을 입력하는 단계가 아닙니다.' unless s.active && s.awaiting_boss
    skill = skill.to_s.strip
    raise '보스 스킬을 고르세요.' if skill.empty?
    override = { skill: skill }
    cells = Array(cells).map { |c| c.to_s.strip.upcase }.select { |c| BattleGrid.valid_pos?(c) }
    targets = Array(targets).map { |t| t.to_s.strip }.reject(&:empty?) & s.runner_names
    if cells.any?
      override[:cells] = cells
    elsif targets.any?
      override[:targets] = targets
    end
    s.passive_ctx[:boss_override] = override
    s.awaiting_boss = false
    s.phase = :announcing
    s.announced = false
    s.actions = {}
    s.processed_messages = {}
    s.start_time = Time.now
    sheet_log(@creature_sheet, s.id, s.round, '보스행동 지정', "#{skill} #{(cells + targets).join(', ')}")
    tick!
  end

  # 입력 대기 시간을 끝내고 바로 정산 (미제출자는 턴 상실)
  def settle_now!(session_id)
    s = @sessions[session_id.to_s] or raise '전투를 찾지 못했습니다.'
    raise '행동 입력 중이 아닙니다.' unless s.phase == :battle || s.phase == :prep
    s.start_time = Time.now - ACTION_WAIT_SECONDS - 1
    tick!
  end

  # 승리/패배 안내 (기존 봇은 조사봇 시트에 보상을 주며 안내했지만, 웹앱에서는 기록만 남긴다)
  def announce_finish!(s)
    return if s.instance_variable_get(:@web_finish_noted)
    s.instance_variable_set(:@web_finish_noted, true)
    text = if s.creature[:hp].to_i <= 0
             "[승리] #{s.creature[:name]} 처치!"
           elsif s.passive_ctx.key?(:escaped_by) || s.dead_runners.size < s.runner_names.size
             '[전투 종료]'
           else
             "[패배] #{s.creature[:name]}에게 전원 전투불능"
           end
    post_session_thread(s, text, @last_post_time)
  end

  # ── 참여자 ──────────────────────────────────────────────────
  def player_for(token)
    sid, name = @tokens[token.to_s]
    s = sid && @sessions[sid]
    [s, name]
  end

  def player_submit!(token, command)
    s, name = player_for(token)
    raise '링크가 올바르지 않거나 끝난 전투입니다.' unless s && s.active
    @listener.clear(name)
    case s.phase
    when :prep
      handle_prep_input(s, name, command, Set.new, SecureRandom.hex(4), @listener)
    when :battle
      raise '이미 이번 라운드 행동을 제출했습니다.' if s.processed_messages[name]
      process_action_for_session(s, name, command, Set.new, SecureRandom.hex(4), @runner_sheet, @runner_sheet, @listener)
    else
      raise '지금은 행동을 입력하는 단계가 아닙니다.'
    end
    notice = @listener.notice_for(name)
    tick!
    notice
  end

  def player_view(token)
    s, name = player_for(token)
    return nil unless s
    ctx = s.passive_ctx
    base = @runner_sheet.read_base_stats
    stat = base.find { |b| b[:name].to_s == name } || {}
    {
      'battle_id' => s.id,
      'me' => name,
      'display' => stat[:display_name].to_s.empty? ? name : stat[:display_name],
      'phase' => s.phase.to_s,
      'active' => s.active,
      'round' => s.round,
      'my_pos' => ctx[:positions].to_h[name],
      'submitted' => s.actions[name] ? { 'type' => s.actions[name][:type], 'target' => s.actions[name][:target] } : nil,
      'prep_done' => s.phase == :prep && ctx[:positions].to_h[name].to_s != '',
      'notice' => @listener.notice_for(name),
      'skills' => skills.map do |sk|
        d = BattleSkills.get(sk) || {}
        {
          'name' => sk,
          'category' => sk == '순간이동' ? '이동' : (sk == '관찰' ? '대기' : d[:category]),
          'range' => sk == '순간이동' ? '제한 없음' : d[:range].to_s,
          'cooldown' => d[:once] ? '1회' : d[:cooldown].to_i,
          'left' => ctx[:cooldowns][name][sk].to_i,
          'used_once' => d[:once] && ctx[:once_used][name][sk] ? true : false
        }
      end
    }
  end

  # ── 진행 루프 (1초마다) ─────────────────────────────────────
  def tick!
    @mutex.synchronize do
      @sessions.each_value do |s|
        begin
          next unless s.active
          was_active = true
          if s.phase == :prep && !s.announced
            @last_post_time = announce_prep_round(s, @runner_sheet, @runner_sheet, @last_post_time)
          end
          check_prep_completion(s, @creature_sheet)
          if s.phase == :announcing && !s.announced
            @last_post_time = announce_round(s, @runner_sheet, @creature_sheet, @runner_sheet, @last_post_time)
          end
          if s.phase == :boss_command && s.awaiting_boss && !s.announced
            @last_post_time = announce_boss_turn(s, @runner_sheet, @runner_sheet, @last_post_time)
          end
          @last_post_time, = settle_session_if_needed(s, @runner_sheet, @creature_sheet, @runner_sheet, @last_post_time, nil, nil)
          announce_finish!(s) if was_active && !s.active
        rescue => e
          puts "[엔진 오류] #{e.class}: #{e.message}"
          puts e.backtrace.first(5)
          sheet_log(@creature_sheet, s.id, s.round, '오류', "#{e.class}: #{e.message}")
        end
      end
      WebState.sync_sessions(@sessions)
      @sessions.delete_if { |_id, s| s.finished? && (Time.now - s.start_time) > 3600 }
      @tokens.delete_if { |_t, (sid, _)| !@sessions.key?(sid) }
    end
  end

  def admin_view
    @mutex.synchronize do
      {
        'tables' => tables,
        'runner_ids' => runner_ids,
        'creature_names' => creature_names,
        'boss_skills' => boss_skill_names,
        'skills' => skills,
        'all_skills' => BattleSkills.names.reject { |n| %w[지정공격1인 지정공격다인 범위공격 전체공격].include?(n) } + %w[순간이동 관찰],
        'battles' => @sessions.values.map do |s|
          {
            'id' => s.id,
            'active' => s.active,
            'phase' => s.phase.to_s,
            'round' => s.round,
            'auto' => s.auto_mode ? true : false,
            'awaiting_boss' => s.awaiting_boss ? true : false,
            'creature' => s.creature[:name],
            'runners' => s.runner_names,
            'actions' => s.actions.transform_values { |a| "#{a[:type]}#{a[:target].to_s.empty? ? '' : '/' + a[:target].to_s}" },
            'tokens' => s.instance_variable_get(:@web_tokens) || {}
          }
        end
      }
    end
  end
end
