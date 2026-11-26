# server.rb
# encoding: UTF-8
#
# 표준 라이브러리만 쓰는 작은 웹서버. 관리자/참여자/관전자 페이지와 API 제공.

require 'socket'
require 'uri'
require_relative 'engine'

class RaidServer
  PUBLIC = File.join(__dir__, 'public')
  PAGES = {
    '/' => 'index.html',
    '/admin' => 'admin.html',
    '/play' => 'play.html',
    '/watch' => 'watch.html'
  }.freeze

  def initialize(engine, host:, port:)
    @engine = engine
    @host = host
    @port = port
  end

  def run
    server = TCPServer.new(@host, @port)
    Thread.new do
      loop do
        @engine.tick!
        sleep 1
      end
    end
    loop do
      client = server.accept
      Thread.new(client) { |c| handle(c) }
    end
  end

  private

  def handle(client)
    request_line = client.gets.to_s
    method, target, = request_line.split(' ')
    headers = {}
    while (line = client.gets) && !["\r\n", "\n"].include?(line)
      k, v = line.split(':', 2)
      headers[k.to_s.strip.downcase] = v.to_s.strip
    end
    body = ''
    len = headers['content-length'].to_i
    body = client.read(len).to_s.force_encoding('UTF-8') if len.positive? && len < 2_000_000
    path, query = target.to_s.split('?', 2)
    params = URI.decode_www_form(query.to_s).to_h rescue {}
    path = path.chomp('/') if path.length > 1

    status, type, out = route(method, path, params, headers, body)
    respond(client, status, type, out)
  rescue => e
    puts "[웹 오류] #{e.class}: #{e.message}"
    respond(client, 500, 'application/json', JSON.generate('error' => '서버 오류가 났습니다.')) rescue nil
  ensure
    client.close rescue nil
  end

  def json(obj, status = 200)
    [status, 'application/json; charset=utf-8', JSON.generate(obj)]
  end

  def route(method, path, params, headers, body)
    if method == 'GET' && PAGES[path]
      file = PAGES[path].start_with?('/') ? PAGES[path] : File.join(PUBLIC, PAGES[path])
      return [200, 'text/html; charset=utf-8', File.read(file, encoding: 'UTF-8')]
    end

    if method == 'GET' && (m = path.match(%r{\A/assets/([a-z0-9_-]+\.(js|css))\z}))
      file = File.join(PUBLIC, 'assets', m[1])
      type = m[2] == 'js' ? 'application/javascript; charset=utf-8' : 'text/css; charset=utf-8'
      return [200, type, File.read(file, encoding: 'UTF-8')] if File.exist?(file)
    end

    data = body.to_s.empty? ? {} : (JSON.parse(body) rescue {})

    case [method, path]
    when ['GET', '/api/battles']
      return [200, 'application/json; charset=utf-8', @engine.mutex.synchronize { @engine.public_json }]
    when ['GET', '/api/wait']
      return json('v' => @engine.wait_change(params['v'].to_i, 20))
    when ['GET', '/api/play']
      view = @engine.mutex.synchronize { @engine.player_view(params['t']) }
      return json({ 'error' => '링크가 올바르지 않거나 끝난 전투입니다.' }, 404) unless view
      return json(view)
    when ['POST', '/api/play']
      notice = @engine.mutex.synchronize { @engine.player_submit!(data['t'], data['command'].to_s) }
      @engine.bump!
      return json('ok' => notice.nil?, 'notice' => notice)
    end

    if path.start_with?('/api/admin')
      return json({ 'error' => '관리자 비밀번호가 틀렸습니다.' }, 401) unless headers['x-admin-key'] == @engine.admin_key
      return admin(method, path, data)
    end

    [404, 'text/plain; charset=utf-8', 'Not Found']
  rescue RuntimeError => e
    json({ 'error' => e.message }, 400)
  end

  def admin(method, path, d)
    e = @engine
    e.mutex.synchronize do
      case [method, path]
      when ['GET', '/api/admin'] then nil
      when ['POST', '/api/admin/table'] then e.save_table!(d['key'].to_s, Array(d['rows']))
      when ['POST', '/api/admin/heal'] then e.heal_all!
      when ['POST', '/api/admin/start'] then e.start_battle!(runners: d['runners'], creature_name: d['creature'].to_s, auto_mode: d['auto'], positions: d['positions'] || {})
      when ['POST', '/api/admin/boss'] then e.boss_command!(d['id'], skill: d['skill'], targets: d['targets'], cells: d['cells'])
      when ['POST', '/api/admin/auto'] then e.set_auto!(d['id'], d['on'])
      when ['POST', '/api/admin/settle'] then e.settle_now!(d['id'])
      when ['POST', '/api/admin/end'] then e.end_battle!(d['id'])
      else return [404, 'text/plain; charset=utf-8', 'Not Found']
      end
      e.bump! unless method == 'GET'
      json(e.admin_view)
    end
  end

  def respond(client, code, type, body)
    reason = { 200 => 'OK', 400 => 'Bad Request', 401 => 'Unauthorized', 404 => 'Not Found', 500 => 'Internal Server Error' }[code]
    body = body.to_s.b
    client.write("HTTP/1.1 #{code} #{reason}\r\nContent-Type: #{type}\r\nContent-Length: #{body.bytesize}\r\n" \
                 "Cache-Control: no-store\r\nConnection: close\r\n\r\n")
    client.write(body)
  end
end
