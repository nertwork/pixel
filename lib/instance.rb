#
# Pixel is an open source network monitoring system
# Copyright (C) 2016 all Pixel contributors!
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# instance.rb
#
require 'logger'
require 'json'
require 'digest/md5'
require 'ipaddr'
$LOG ||= Logger.new(STDOUT)

class Instance


  def self.fetch(hostname: nil)
    resource = '/v2/instance'

    params = "?hostname=#{hostname}" if hostname
    params ||= ''

    result = API.get(
      src: 'instance',
      dst: 'core',
      resource: "#{resource}#{params}",
      what: 'instances',
    )
    result.each do |object|
      unless object.is_a?(Instance)
        raise "Received bad object in Instance.fetch"
        return []
      end
    end
    return result
  end


  def self.get_master
    instance = API.get(
      src: 'instance',
      dst: 'core',
      resource: '/v2/instance/get_master',
      what: 'master instance'
    ).first
    return nil unless instance.class == Instance
    return instance
  end


  def self.fetch_from_db(db:, hostname: nil, master: nil, poller: nil)
    instances = []
    instance = db[:instance]
    instance = instance.where(:hostname => hostname) if hostname
    instance = instance.where(:master => true) if master
    instance = instance.where(:poller => true) if poller
    instance.each do |row|
      instances.push Instance.new(
        hostname: row[:hostname],
        ip: row[:ip],
        last_updated: row[:last_updated],
        core: row[:core],
        master: row[:master],
        poller: row[:poller],
        config_hash: row[:config_hash]
      )
    end
    return instances
  end


  def self.delete(db:, hostname:)
    DB[:instance].where(:hostname => hostname).delete
  end


  def initialize(hostname: nil, ip: nil, last_updated: nil, core: nil,
                 master: nil, poller: nil, config_hash: nil)
    @hostname = hostname
    @ip = IPAddr.new(ip) if ip
    @core = core
    @master = master
    @poller = poller
    @config_hash = config_hash
    @last_updated = last_updated
  end


  def hostname
    @hostname.to_s
  end


  def ip
    @ip || IPAddr.new
  end


  def core?
    !!@core
  end


  def master?
    !!@master
  end


  def set_master(value)
    @master = value
  end


  def poller?
    !!@poller
  end


  def config_hash
    @config_hash.to_s
  end


  def update!(config:)
    new_hostname = Socket.gethostname
    new_ip = IPAddr.new(UDPSocket.open {|s| s.connect("8.8.8.8", 1); s.addr.last})
    new_config_hash = config.hash

    @hostname = new_hostname
    @ip = new_ip
    @core = true if @core.nil?
    @master = false if @master.nil?
    @poller = false if @poller.nil?
    @config_hash = new_config_hash
    @last_updated = Time.now.to_i

    return self
  end


  def save(db)
    begin
      data = {}
      data[:hostname] = @hostname
      data[:ip] = @ip ? @ip.to_s : nil
      data[:core] = @core
      data[:master] = @master
      data[:poller] = @poller
      data[:config_hash] = @config_hash
      data[:last_updated] = @last_updated

      existing = db[:instance].where(:hostname => @hostname)
      if existing.update(data) != 1
        db[:instance].insert(data)
      end
    rescue Sequel::NotNullConstraintViolation, Sequel::ForeignKeyConstraintViolation => e
      $LOG.error("INSTANCE: Save failed. #{e.to_s.gsub(/\n/,'. ')}")
      return nil
    end

    return self
  end


  def send
    start = Time.now.to_i
    if API.post(
      src: 'instance',
      dst: 'core',
      resource: '/v2/instance',
      what: "instance #{@hostname}",
      data: to_json
    )
      elapsed = Time.now.to_i - start
      $LOG.info("INSTANCE: POST successful for #{@hostname} (#{elapsed} seconds)")
      return true
    else
      $LOG.error("INSTANCE: POST failed for #{@hostname}; Aborting")
      return false
    end
  end


  def to_json(*a)
    hash = {
      "json_class" => self.class.name,
      "data" => {}
    }

    hash['data']['hostname'] = @hostname
    hash['data']['ip'] = @ip
    hash['data']['core'] = @core
    hash['data']['master'] = @master
    hash['data']['poller'] = @poller
    hash['data']['config_hash'] = @config_hash
    hash['data']['last_updated'] = @last_updated

    hash.to_json(*a)
  end


  def self.json_create(json)
    data = json['data']
    return Instance.new(
      hostname: data['hostname'],
      ip: data['ip'],
      core: data['core'],
      master: data['master'],
      poller: data['poller'],
      config_hash: data['config_hash'],
      last_updated: data['last_updated']
    )
  end


  private # All methods below are private!!


end
