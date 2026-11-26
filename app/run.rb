# run.rb — 레이드 웹앱 실행: ruby app/run.rb
# encoding: UTF-8
$stdout.sync = true
Encoding.default_external = 'UTF-8'
require_relative 'server'

port = (ENV['RAID_PORT'] || '4567').to_i
host = ENV['RAID_HOST'] || '127.0.0.1'
engine = RaidEngine.new(File.join(__dir__, 'data', 'raid.json'))

puts ''
puts '=========================================='
puts ' 레이드 전투 웹앱이 켜졌습니다'
puts "  관리자 : http://localhost:#{port}/admin"
puts "  관전자 : http://localhost:#{port}/watch"
puts "  관리자 비밀번호 : #{engine.admin_key}"
puts '  끄려면 이 창을 닫거나 Ctrl+C'
puts '=========================================='
puts ''
RaidServer.new(engine, host: host, port: port).run
