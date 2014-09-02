require 'socket'
require 'influxdb'
require 'snmp'
require 'net/http'
require 'json'
require 'uri'
require_relative 'core_ext/hash'

module Poller

  def self.check_for_work(settings, db)
    concurrency = settings['poller']['concurrency']
    hostname = Socket.gethostname
    request = "/v1/devices/fetch_poll?count=#{concurrency}&hostname=#{hostname}"

    devices = API.get('core', request)
    if devices
      devices.each { |device, attributes| _poll(settings, device, attributes['ip']) }
      return 200 # Doesn't do any error checking here
    else # HTTP request failed
      puts Time.now.strftime('%T: ') + "HTTP request to check for work failed: #{request}"
      return 500
    end
  end

  def self._poll(settings, device, ip)
    # Convert poller settings into hash with symbols as keys
    poller_cfg = settings['poller'].dup || {}
    poller_cfg.symbolize!

    beginning = Time.now

    # This determines which OID names will get turned into per-second averages.
    avg_oid_regex = /octets|discards|errors|pkts/

    # These are the OIDs that will get pulled/stored for our interfaces.
    oid_names = Hash[
      'if_name'        => '1.3.6.1.2.1.31.1.1.1.1',
      'if_hc_in_octets'  => '1.3.6.1.2.1.31.1.1.1.6',
      'if_hc_out_octets' => '1.3.6.1.2.1.31.1.1.1.10',
      'if_hc_in_ucast_pkts' => '1.3.6.1.2.1.31.1.1.1.7',
      'if_hc_out_ucast_pkts' => '1.3.6.1.2.1.31.1.1.1.11',
      'if_high_speed'   => '1.3.6.1.2.1.31.1.1.1.15',
      'if_alias'       => '1.3.6.1.2.1.31.1.1.1.18',
      'if_mtu'         => '1.3.6.1.2.1.2.2.1.4',
      'if_admin_status' => '1.3.6.1.2.1.2.2.1.7',
      'if_oper_status'  => '1.3.6.1.2.1.2.2.1.8',
      'if_in_discards'  => '1.3.6.1.2.1.2.2.1.13',
      'if_in_errors'    => '1.3.6.1.2.1.2.2.1.14',
      'if_out_discards' => '1.3.6.1.2.1.2.2.1.19',
      'if_out_errors'   => '1.3.6.1.2.1.2.2.1.20'
    ]
    # Create the reverse hash of the OIDs above so we can easly get names from keys
    oid_numbers = oid_names.invert

    # This is where we define what the averages will be named
    avg_names = Hash[
      'if_hc_in_octets'  => 'bps_in',
      'if_hc_out_octets' => 'bps_out',
      'if_in_discards'  => 'discards_in',
      'if_in_errors'    => 'errors_in',
      'if_out_discards' => 'discards_out',
      'if_out_errors'   => 'errors_out',
      'if_hc_in_ucast_pkts' => 'pps_in',
      'if_hc_out_ucast_pkts' => 'pps_out'
    ]

    begin # Start exception handling

      pid = fork do

        if_table = {}
        count = nil
        begin
          # get SNMP data from the device
          count, if_table = query_device(ip, poller_cfg[:snmpv2_community], oid_numbers)
        rescue RuntimeError, ArgumentError => e
          puts "Error encountered while polling #{device}: " + e.to_s
          metadata = { :last_poll_result => 1 }
          post_data( {device => { :metadata => metadata }} )
          abort
        end

        influxdb = InfluxDB::Client.new(
          poller_cfg[:influx_db],
          :host => poller_cfg[:influx_ip],
          :username => poller_cfg[:influx_user],
          :password => poller_cfg[:influx_pass],
          :retry => 1)

        stale_indexes = [] # TODO: Need to use this to delete old interfaces

        request = "/v1/devices?device=#{device}"
        devices = API.get('core', request)
        unless devices # HTTP request failed
          puts Time.now.strftime('%T: ') + "HTTP request to get previous data failed: #{request}"
          devices = {}
        end
        last_values = devices[device] || {}
        last_values.each do |index,oids|
          oids.each { |name,value| oids[name] = to_i_if_numeric(value) }
          stale_indexes.push(index) unless if_table[index]
        end

        # Run through the hash we got from poll, processing the interesting interfaces
        interfaces = {}

        if_table.each do |if_index, oids|
          # Skip if we're not interested in processing this interface
          next unless oids['if_alias'] =~ poller_cfg[:interesting_alias]

          interfaces[if_index] = oids.dup
          interfaces[if_index]['if_index'] = if_index
          interfaces[if_index]['device'] = device
          interfaces[if_index]['last_updated'] = Time.now.to_i

          # Update the last change time if these values changed.
          %w( if_admin_status if_oper_status ).each do |oid|
            if(!last_values[if_index] || oids[oid].to_i != last_values[if_index][oid])
              interfaces[if_index][oid + '_time'] = Time.now.to_i
            end
          end

          oids.each do |oid_text,value|
            series_name = device + '.' + if_index + '.' + oid_text
            series_data = { :value => value.to_s, :time => Time.now.to_i }

            # Take the difference and average it out per second since the last poll
            #   if this OID supposed to be averaged
            # First make sure we have 2 data points -- if not we can't average
            if oid_text =~ avg_oid_regex && last_values[if_index]
              avg_series_name = device + '.' + if_index + '.' + avg_names[oid_text]
              average = (value.to_i - last_values[if_index][oid_text].to_i) / (Time.now.to_i - last_values[if_index]['last_updated'].to_i)
              average = average * 8 if series_name =~ /octets/
              avg_series_data = { :value => average, :time => Time.now.to_i }
              # Calculate utilization if we're a bps OID
              if avg_series_name =~ /bps/ && oids['if_high_speed'].to_i != 0
                util = '%.2f' % (average.to_f / (oids['if_high_speed'].to_i * 1000000) * 100)
                util = 100 if util.to_f > 100
                interfaces[if_index][avg_names[oid_text] + '_util'] = util
              end
              # write the average
              unless average < 0
                interfaces[if_index][avg_names[oid_text]] = average
                influxdb.write_point(avg_series_name, avg_series_data)
              end
            end
          end # End oids.each
        end # End if_index.each

        # Update the application
        interfaces['metadata'] = {
          :last_poll_duration => Time.now.to_i - beginning.to_i,
          :last_poll_result => 0,
          :last_poll_text => '',
        }
        result = post_data( {device => interfaces} )
        if result == 500
          puts Time.now.strftime('%T: ') + "Failed to contact main instance for post " + 
            "(#{device}: #{count} interfaces polled, #{interfaces.keys.size - 1} returned)"
        else
          puts Time.now.strftime('%T: ') + "Poll succeeded " + 
            "(#{device}: #{count} interfaces polled, #{interfaces.keys.size - 1} returned)"
        end

      end # End fork

      Process.detach(pid)
      puts "Forked PID #{pid} (#{device})"

    rescue StandardError => error
      raise error
    end
  end

  def self.query_device(ip, community, oid_numbers)
    SNMP::Manager.open(:host => ip, :community => community) do |session|
      if_table = {}
      count = 0
      session.walk(oid_numbers.keys) do |row|
        count += 1
        row.each do |vb|
          oid_text = oid_numbers[vb.name.to_str.gsub(/\.[0-9]+$/,'')]
          if_index = vb.name.to_str[/[0-9]+$/]
          if_table[if_index] ||= {}
          if_table[if_index][oid_text] = vb.value.to_s
        end
      end
      return count, if_table
    end
  end

  def self.post_data(devices, first_try=true)
    res = API.post('core', '/v1/devices', devices)
    unless res # HTTP request failed
      puts Time.now.strftime('%T: ') + "HTTP request to post device #{devices.keys[0]} failed"
      # If this is the first try, retry, otherwise return 500
      if first_try
        puts Time.now.strftime('%T: ') + "Retrying post for device #{devices.keys[0]} in 5 seconds..."
        sleep 5
        return post_data(devices, false)
      else
        return 500
      end
    end
    return res
  end

  def self.to_i_if_numeric(str)
    # This is sort of a hack, but gets shit converted to int
    begin
      ('%.0f' % str.to_s).to_i
    rescue ArgumentError, TypeError
      str
    end
  end

end
