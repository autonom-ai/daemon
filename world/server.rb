#!/usr/bin/env ruby
# world-mcp: a shared 2D arena where each agent profile controls one circle.
# stdio MCP server, file-backed world state so every seat's server instance
# shares one physics world without a daemon.
require 'json'
require 'fileutils'

module World
  DIR = File.dirname(__FILE__)
  STATE = File.join(DIR, 'world.json')
  W = 800.0
  H = 600.0
  DAMPING = 0.985        # per-second velocity retention
  RESTITUTION = 0.85     # circle-circle bounce energy
  WALL_BOUNCE = 0.8
  MAX_SPEED = 400.0

  TOOLS = [
    {
      'name' => 'world_spawn',
      'description' => 'Spawn your circle in the arena. One circle per profile. Returns your circle state.',
      'inputSchema' => { 'type' => 'object', 'properties' => { 'profile' => { 'type' => 'string' }, 'color' => { 'type' => 'string' } }, 'required' => %w[profile] }
    },
    {
      'name' => 'world_impulse',
      'description' => 'Apply an impulse (vx, vy) to your circle. Magnitude clamped; this is how you move.',
      'inputSchema' => { 'type' => 'object', 'properties' => { 'profile' => { 'type' => 'string' }, 'vx' => { 'type' => 'number' }, 'vy' => { 'type' => 'number' } }, 'required' => %w[profile vx vy] }
    },
    {
      'name' => 'world_look',
      'description' => 'Advance physics to now and return the full arena state.',
      'inputSchema' => { 'type' => 'object', 'properties' => {}, 'required' => [] }
    },
    {
      'name' => 'world_say',
      'description' => 'Set your circle\'s speech bubble (short string). Other circles see it on look.',
      'inputSchema' => { 'type' => 'object', 'properties' => { 'profile' => { 'type' => 'string' }, 'text' => { 'type' => 'string' } }, 'required' => %w[profile text] }
    },
    {
      'name' => 'world_reset',
      'description' => 'Clear the arena. Shared destructive op - announce in the room first.',
      'inputSchema' => { 'type' => 'object', 'properties' => {}, 'required' => [] }
    }
  ].freeze

  def self.load
    return { 'circles' => {}, 'last_tick' => Time.now.to_f } unless File.file?(STATE)

    JSON.parse(File.read(STATE))
  rescue JSON::ParserError
    { 'circles' => {}, 'last_tick' => Time.now.to_f }
  end

  def self.save(state)
    File.open(STATE, File::RDWR | File::CREAT, 0o600) do |f|
      f.flock(File::LOCK_EX)
      f.truncate(0)
      f.rewind
      f.write(JSON.generate(state))
      f.flush
    end
  end

  def self.step(state, now = Time.now.to_f)
    dt = [now - state['last_tick'].to_f, 2.0].min
    state['last_tick'] = now
    circles = state['circles'].values
    damp = DAMPING**dt
    circles.each do |c|
      c['vx'] *= damp
      c['vy'] *= damp
      c['x'] += c['vx'] * dt
      c['y'] += c['vy'] * dt
      r = c['r']
      if c['x'] < r || c['x'] > W - r
        c['x'] = c['x'].clamp(r, W - r)
        c['vx'] = -c['vx'] * WALL_BOUNCE
      end
      if c['y'] < r || c['y'] > H - r
        c['y'] = c['y'].clamp(r, H - r)
        c['vy'] = -c['vy'] * WALL_BOUNCE
      end
    end
    circles.combination(2) do |a, b|
      dx = b['x'] - a['x']
      dy = b['y'] - a['y']
      dist = Math.hypot(dx, dy)
      min = a['r'] + b['r']
      next if dist >= min || dist.zero?

      nx = dx / dist
      ny = dy / dist
      overlap = (min - dist) / 2.0
      a['x'] -= nx * overlap
      a['y'] -= ny * overlap
      b['x'] += nx * overlap
      b['y'] += ny * overlap
      dvx = b['vx'] - a['vx']
      dvy = b['vy'] - a['vy']
      rel = dvx * nx + dvy * ny
      next if rel > 0

      j = rel * -(1 + RESTITUTION) / 2.0
      a['vx'] -= j * nx
      a['vy'] -= j * ny
      b['vx'] += j * nx
      b['vy'] += j * ny
    end
    state
  end

  def self.call(name, args)
    state = step(load)
    case name
    when 'world_spawn'
      p = args['profile'].to_s
      return error('profile required') if p.empty?
      if state['circles'][p]
        return ok("Already in the arena: #{state['circles'][p].to_json}")
      end

      angle = rand * Math::PI * 2
      state['circles'][p] = {
        'x' => W / 2 + Math.cos(angle) * 150, 'y' => H / 2 + Math.sin(angle) * 150,
        'vx' => 0.0, 'vy' => 0.0, 'r' => 24.0,
        'color' => args['color'].to_s.empty? ? '#' + ('%06x' % (rand * 0xffffff)) : args['color'],
        'bubble' => nil
      }
      save(state)
      ok("Spawned #{p}: #{state['circles'][p].to_json}")
    when 'world_impulse'
      p = args['profile'].to_s
      c = state['circles'][p]
      return error("No circle for '#{p}' - spawn first") unless c

      speed = Math.hypot(args['vx'].to_f, args['vy'].to_f)
      scale = speed > MAX_SPEED ? MAX_SPEED / speed : 1.0
      c['vx'] += args['vx'].to_f * scale
      c['vy'] += args['vy'].to_f * scale
      save(state)
      ok("#{p} now at (#{c['x'].round},#{c['y'].round}) v=(#{c['vx'].round},#{c['vy'].round})")
    when 'world_say'
      p = args['profile'].to_s
      c = state['circles'][p]
      return error("No circle for '#{p}' - spawn first") unless c

      c['bubble'] = args['text'].to_s[0, 120]
      save(state)
      ok("#{p} says: #{c['bubble']}")
    when 'world_look'
      save(state)
      ok(JSON.pretty_generate('arena' => { 'w' => W, 'h' => H }, 'circles' => state['circles']))
    when 'world_reset'
      save({ 'circles' => {}, 'last_tick' => Time.now.to_f })
      ok('Arena cleared.')
    else
      error("Unknown tool: #{name}")
    end
  end

  def self.ok(text)
    { 'content' => [{ 'type' => 'text', 'text' => text }] }
  end

  def self.error(text)
    { 'content' => [{ 'type' => 'text', 'text' => text }], 'isError' => true }
  end
end

# Minimal MCP stdio loop.
$stdout.sync = true
$id = 0
def reply(result)
  puts JSON.generate('jsonrpc' => '2.0', 'id' => $id, 'result' => result)
end

while (line = $stdin.gets)
  msg = JSON.parse(line) rescue next
  next unless msg['id']

  $id = msg['id']
  case msg['method']
  when 'initialize'
    reply('protocolVersion' => '2024-11-05', 'capabilities' => { 'tools' => {} }, 'serverInfo' => { 'name' => 'world-mcp', 'version' => '0.1.0' })
  when 'tools/list'
    reply('tools' => World::TOOLS)
  when 'tools/call'
    reply(World.call(msg.dig('params', 'name'), msg.dig('params', 'arguments') || {}))
  when 'ping'
    reply({})
  else
    reply({})
  end
end
